// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.11;

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { ERC4626 } from "solmate/mixins/ERC4626.sol";

import { DateTime } from "./external/DateTime.sol";

import { SafeCast } from "./SafeCast.sol";

import { BalancerVault } from "./interfaces/BalancerVault.sol";
import { Space } from "./interfaces/Space.sol";

interface SpaceFactoryLike {
    function divider() external view returns (address);
    function create(address, uint256) external returns (address);
    function pools(address, uint256) external view returns (Space);
}

interface DividerLike {
    function issue(address, uint256, uint256) external returns (uint256);
    function settleSeries(address, uint256) external;
    function mscale(address, uint256) external view returns (uint256);
    function redeem(address, uint256, uint256) external;
    function combine(address, uint256, uint256) external;
}

interface YTLike {
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function collect() external;
    function balanceOf(address) external view returns (uint256);
}

interface PeripheryLike {
    function sponsorSeries(address, uint256, bool) external returns (ERC20, YTLike);
    function swapYTsForTarget(address, uint256, uint256) external returns (uint256);
    function create(address, uint256) external returns (address);
    function spaceFactory() external view returns (SpaceFactoryLike);
    function MIN_YT_SWAP_IN() external view returns (uint256);
}

interface AdapterLike {
    function ifee() external view returns (uint256);
    function openSponsorWindow() external;
    function scale() external returns (uint256);
    function scaleStored() external view returns (uint256);
    function getStakeAndTarget() external view returns (address,address,uint256);
}

contract AutoRoller is ERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using SafeCast for *;

    /* ========== ERRORS ========== */

    error ActivePhaseOnly();
    error UnrecognizedParam(bytes32 what);
    error InsufficientLiquidity();
    error RollWindowNotOpen();
    error OnlyAdapter();
    error InvalidSettler();

    /* ========== CONSTANTS ========== */

    uint32 internal constant MATURITY_NOT_SET = type(uint32).max;
    int256 internal constant WITHDRAWAL_GUESS_OFFSET = 0.95e18;

    /* ========== IMMUTABLES ========== */

    DividerLike   internal immutable divider;
    BalancerVault internal immutable balancerVault;
    AdapterLike   internal immutable adapter;

    uint256 internal immutable ifee;
    uint256 internal immutable minSwapAmount;
    uint256 internal immutable firstDeposit;
    uint256 internal immutable maxError; // A conservative buffer for "rounding" swap previews that accounts for compounded pow of imprecision.
    address internal immutable rewardRecipient;

    /* ========== MUTABLE STORAGE ========== */

    PeripheryLike    internal periphery;
    SpaceFactoryLike internal spaceFactory;
    address          internal owner;
    RollerUtils      internal utils;

    // Active Series
    YTLike  internal yt;
    ERC20   internal pt;
    Space   internal space;
    bytes32 internal poolId;
    address internal lastRoller;

    // Separate slots to meet contract size limits.
    uint256 internal initScale;
    uint256 public  maturity = MATURITY_NOT_SET;
    uint256 internal pti;

    uint256 internal maxRate        = 53144e19; // Max implied rate stretched to Space pool's TS period. (531440% over 12 years ≈ 200% APY)
    uint256 internal targetedRate   = 2.9e18; // Targeted implied rate stretched to Space pool's TS period. (2.9% over 12 years ≈ 0.12% APY)
    uint256 internal targetDuration = 3; // Number of months or weeks in the future newly sponsored Series should mature.
    uint256 public cooldown       = 10 days;
    uint256 public lastSettle;

    constructor(
        ERC20 _target,
        DividerLike _divider,
        address _periphery,
        address _spaceFactory,
        address _balancerVault,
        AdapterLike _adapter,
        RollerUtils _utils,
        address _rewardRecipient
    ) ERC4626(
        _target,
        string(abi.encodePacked(_target.name(), " Sense Auto Roller")),
        string(abi.encodePacked(_target.symbol(), "-sAR"))
    ) {
        divider       = _divider;
        periphery     = PeripheryLike(_periphery);
        spaceFactory  = SpaceFactoryLike(_spaceFactory);
        balancerVault = BalancerVault(_balancerVault);

        // Allow the Divder to move this contract's Target for PT/YT issuance.
        _target.safeApprove(address(_divider), type(uint256).max);

        // Allow Balancer to move this contract's Target for Space pools joins.
        _target.safeApprove(address(_balancerVault), type(uint256).max);

        uint256 scalingFactor = 10**(18 - decimals);

        minSwapAmount = (periphery.MIN_YT_SWAP_IN() - 1) / scalingFactor + 1; // Rounds up to cover low decimal tokens.
        maxError      = (1e7 - 1) / scalingFactor + 1;
        firstDeposit  = (0.01e18 - 1) / scalingFactor + 1;

        adapter = _adapter;
        ifee    = _adapter.ifee(); // Assumption: ifee will not change. Don't break this assumption and expect good things.
        owner   = msg.sender;
        utils   = _utils;
        rewardRecipient = _rewardRecipient;
    }

    /* ========== SERIES MANAGEMENT ========== */

    /// @notice Roll into the next Series if there isn't an active series and the cooldown period has elapsed.
    function roll() external {
        if (maturity != MATURITY_NOT_SET) revert RollWindowNotOpen();

        if (lastSettle == 0) {
            // If this is the first roll, lock some shares in by minting them for the zero address.
            // This prevents the contract from reaching an empty state during future active periods.
            deposit(firstDeposit, address(0));
        } else if (lastSettle + cooldown > block.timestamp) {
            revert RollWindowNotOpen();
        }

        lastRoller = msg.sender;
        adapter.openSponsorWindow();
    }

    function onSponsorWindowOpened(ERC20 stake, uint256 stakeSize) external { // Assumption: all of this Vault's LP shares will have been exited before this function is called.
        if (msg.sender != address(adapter)) revert OnlyAdapter();

        stake.safeTransferFrom(lastRoller, address(this), stakeSize);

        // Allow the Periphery to move stake for sponsoring the Series.
        stake.safeApprove(address(periphery), stakeSize);

        uint256 _maturity = utils.getFutureMaturity(targetDuration);

        // Assign Series data.
        (ERC20 _pt, YTLike _yt) = periphery.sponsorSeries(address(adapter), _maturity, true);
        (Space _space, bytes32 _poolId, uint256 _pti, uint256 _initScale) = utils.getSpaceData(periphery, AdapterLike(msg.sender), _maturity);

        // Allow Balancer to move the new PTs for joins & swaps.
        _pt.approve(address(balancerVault), type(uint256).max);

        // Allow Periphery to move the new YTs for swaps.
        _yt.approve(address(periphery), type(uint256).max);

        ERC20 _asset = asset;

        ERC20[] memory tokens = new ERC20[](2);
        tokens[1 - _pti] = _asset;
        tokens[_pti] = _pt;

        uint256 targetBal = _asset.balanceOf(address(this));

        (uint256 eqPTReserves, uint256 eqTargetReserves) = _space.getEQReserves(
            targetedRate,
            _maturity,
            0,
            targetBal,
            targetBal.mulWadDown(_initScale),
            _space.g2()
        );

        uint256 targetForIssuance = _getTargetForIssuance(eqPTReserves, eqTargetReserves, targetBal, _initScale);
        divider.issue(address(adapter), _maturity, targetForIssuance);

        uint256[] memory balances = new uint256[](2);
        balances[1 - _pti] = targetBal - targetForIssuance;

        // Initialize the targeted rate in the Space pool with a join, a swap, and another join.
        _joinPool(
            _poolId,
            BalancerVault.JoinPoolRequest({
                assets: tokens,
                maxAmountsIn: balances,
                userData: abi.encode(balances, 0), // No min BPT out: first join.
                fromInternalBalance: false
            })
        );
        _swap(
            BalancerVault.SingleSwap({
                poolId: _poolId,
                kind: BalancerVault.SwapKind.GIVEN_IN,
                assetIn: address(_pt),
                assetOut: address(tokens[1 - _pti]),
                amount: eqPTReserves.mulDivDown(balances[1 - _pti], targetBal),
                userData: hex""
            })
        );

        balances[_pti    ] = _pt.balanceOf(address(this));
        balances[1 - _pti] = _asset.balanceOf(address(this));

        _joinPool(
            _poolId,
            BalancerVault.JoinPoolRequest({
                assets: tokens,
                maxAmountsIn: balances,
                userData: abi.encode(balances, 0), // No min BPT out: the pool was created in this tx and the join can't be sandwiched.
                fromInternalBalance: false
            })
        );

        // Cache Series data.
        space  = _space;
        poolId = _poolId;
        pt     = _pt;
        yt     = _yt;

        // Combined single SSTORE.
        initScale = _initScale;
        maturity  = _maturity; // OK until Feb 07, 2106
        pti       = _pti;

        emit Rolled(_maturity, uint256(_initScale), address(_space), msg.sender);
    }

    /// @notice Settle the active Series and enter a cooldown phase.
    function settle() public {
        if(msg.sender != lastRoller) revert InvalidSettler();

        uint256 assetBalPre = asset.balanceOf(address(this));
        divider.settleSeries(address(adapter), maturity); // Settlement will fail if maturity hasn't been reached.
        uint256 assetBalPost = asset.balanceOf(address(this));

        asset.safeTransfer(msg.sender, assetBalPost - assetBalPre); // Send issuance fees to the sender.

        (, address stake, uint256 stakeSize) = adapter.getStakeAndTarget();
        if (stake != address(asset)) {
            ERC20(stake).safeTransfer(msg.sender, stakeSize);
        }

        startCooldown();
    }

    // Enter a cooldown phase where users can redeem without slippage.
    function startCooldown() public {
        require(divider.mscale(address(adapter), maturity) != 0);

        (uint256 excessBal, bool isExcessPTs) = _exitAndCombine(totalSupply);

        if (isExcessPTs) {
            divider.redeem(address(adapter), maturity, excessBal); // Burns the PTs.
        } else {
            yt.collect(); // Burns the YTs.
        }

        maturity   = MATURITY_NOT_SET;
        lastSettle = uint32(block.timestamp);
        delete pt; delete yt; delete space; delete pti; delete poolId; delete initScale; // Re-set variables to defaults, collect gas refund.
    }

    /* ========== 4626 ========== */

    function beforeWithdraw(uint256, uint256 shares) internal override {
        if (maturity != MATURITY_NOT_SET) {
            (uint256 excessBal, bool isExcessPTs) = _exitAndCombine(shares);

            if (excessBal < minSwapAmount) return;

            if (isExcessPTs) {
                (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();
                uint256 maxPTSale = _maxPTSell(ptReserves, targetReserves, space.adjustedTotalSupply());

                if (excessBal > maxPTSale) revert InsufficientLiquidity(); // Need to eject, wait for more liquidity, or wait until a cooldown phase.

                _swap(
                    BalancerVault.SingleSwap({
                        poolId: poolId,
                        kind: BalancerVault.SwapKind.GIVEN_IN,
                        assetIn: address(pt),
                        assetOut: address(asset),
                        amount: excessBal,
                        userData: hex""
                    })
                );
            } else {
                periphery.swapYTsForTarget(address(adapter), maturity, excessBal); // Swapping YTs will fail if there isn't enough liquidity.
            }
        }
    }

    function afterDeposit(uint256 assets, uint256 shares) internal override {
        if (maturity != MATURITY_NOT_SET) {
            uint256 _supply = totalSupply; // Saves extra SLOADs.
            bytes32 _poolId = poolId;
            uint256 _pti    = pti;

            (ERC20[] memory tokens, uint256[] memory balances, ) = balancerVault.getPoolTokens(_poolId);

            uint256 previewedLPBal = _supply - shares == 0 ?
                shares : shares.mulDivUp(space.balanceOf(address(this)), _supply - shares); // _supply - shares b/c this is after minting new shares.

            uint256 targetToJoin = previewedLPBal.mulDivUp(balances[1 - _pti], space.adjustedTotalSupply());

            balances[1 - _pti] = targetToJoin;

            if (assets - targetToJoin > 0) { // Assumption: this is false if Space has only Target liquidity.
                balances[_pti] = divider.issue(address(adapter), maturity, assets - targetToJoin);
            }

            _joinPool(
                _poolId,
                BalancerVault.JoinPoolRequest({
                    assets: tokens,
                    maxAmountsIn: balances,
                    userData: abi.encode(balances, 0),
                    fromInternalBalance: false
                })
            );
        }
    }

    /// @notice Calculates the total assets of this vault using the current spot prices, with no regard for slippage.
    function totalAssets() public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return asset.balanceOf(address(this));
        } 
        else {
            Space _space = space;
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();
            
            (uint256 targetBal, uint256 ptBal, uint256 ytBal, ) = _decomposeShares(ptReserves, targetReserves, totalSupply, true);

            uint256 ptSpotPrice = _space.getPriceFromImpliedRate(
                (ptReserves + _space.adjustedTotalSupply()).divWadDown(targetReserves.mulWadDown(initScale)) - 1e18
            ); // PT price in Target.

            uint256 scale = adapter.scaleStored();

            if (ptBal >= ytBal) {
                // Target + combined PTs/YTs + PT spot value in Target.
                return targetBal + ytBal.divWadDown(scale) + ptSpotPrice.mulWadDown(ptBal - ytBal);
            } else {
                uint256 ytSpotPrice = (1e18 - ptSpotPrice.mulWadDown(scale)).divWadDown(scale);

                // Target + combined PTs/YTs + YT spot value in Target.
                return targetBal + ptBal.divWadDown(scale) + ytSpotPrice.mulWadDown(ytBal - ptBal);
            }
        }
    }

    /// @notice The same as convertToShares, except that slippage is considered in previewDeposit.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewDeposit(assets);
        } else {
            Space _space = space;
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            // Calculate how much Target we'll end up joining the pool with, and use that to preview minted LP shares.
            uint256 previewedLPBal = (assets - _getTargetForIssuance(ptReserves, targetReserves, assets, adapter.scaleStored()))
                .mulDivDown(_space.adjustedTotalSupply(), targetReserves);

            // Shares represent proportional ownership of LP shares the vault holds.
            return previewedLPBal.mulDivDown(totalSupply, _space.balanceOf(address(this)));
        }
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewMint(shares);
        } else {
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            (uint256 targetToJoin, uint256 ptsToJoin, , ) = _decomposeShares(ptReserves, targetReserves, shares, true);

            return targetToJoin + ptsToJoin.divWadUp(adapter.scaleStored().mulWadDown(1e18 - ifee)); // targetToJoin + targetToIssue
        }
    }

    /// @notice The same as convertToAssets, except that slippage is considered in previewRedeem.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewRedeem(shares);
        } else {
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            (uint256 targetBal, uint256 ptBal, uint256 ytBal, uint256 lpBal) = _decomposeShares(ptReserves, targetReserves, shares, false);

            uint256 scale = adapter.scaleStored();

            ptReserves     = ptReserves - ptBal;
            targetReserves = targetReserves - targetBal;

            uint256 spaceSupply = space.adjustedTotalSupply();

            // Adjust balances for loose asset share.
            ptBal       = ptBal       + lpBal.mulDivDown(pt.balanceOf(address(this)), spaceSupply);
            targetBal   = targetBal   + lpBal.mulDivDown(asset.balanceOf(address(this)), spaceSupply);
            spaceSupply = spaceSupply - lpBal;

            if (ptBal > ytBal) {
                unchecked {
                    // Safety: an inequality check is done before ptBal - ytBal.
                    //         shares must be lte total supply, so ptReserves & targetReserves wil always be gte ptBal & targetBal.
                    uint256 maxPTSale = _maxPTSell(
                        ptReserves,
                        targetReserves,
                        spaceSupply
                    );

                    // If there isn't enough liquidity to sell all of the PTs, sell the max that we can and ignore the remaining PTs.
                    uint256 ptsToSell = _min(ptBal - ytBal, maxPTSale);

                    uint256 targetOut = ptsToSell > minSwapAmount ?
                        space.onSwapPreview(
                            true,
                            true,
                            ptsToSell,
                            ptReserves,
                            targetReserves,
                            spaceSupply,
                            scale
                        ) : 0;

                    // target + combined PTs/YTs + sold PTs - buffer for pow of discrepencies.
                    return targetBal + ytBal.divWadDown(scale) + targetOut - maxError;
                }
            } else {
                unchecked {
                    // Safety: an inequality check is done before ytBal - ptBal.
                    //         shares must be lte total supply, so ptReserves & targetReserves wil always be gte ptBal & targetBal.

                    // If there isn't enough liquidity to sell all of the YTs, sell the max that we can and ignore the remaining YTs.
                    uint256 ytsToSell = _min(ytBal - ptBal, ptReserves);

                    // Target from combining YTs with PTs - target needed to buy PTs.
                    uint256 targetOut = ytsToSell > minSwapAmount ? 
                        ytsToSell.divWadDown(scale) - space.onSwapPreview(
                            false,
                            false,
                            ytsToSell,
                            targetReserves,
                            ptReserves,
                            spaceSupply,
                            scale
                        ) : 0;

                    // target + combined PTs/YTs + sold YTs - buffer for pow of discrepencies.
                    return targetBal + ptBal.divWadDown(scale) + targetOut - maxError;
                }
            }
        }
    }

    /// @notice Amount of shares needed to redeem the given assets, erring on the side of overestimation.
    ///         The calculation for previewWithdraw is quite imprecise and expensive, so previewRedeem & redeem
    ///         should be favored over previewWithdraw & withdraw.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewWithdraw(assets);
        } else {
            uint256 _supply = totalSupply;

            int256 prevGuess  = _min(assets, _supply).safeCastToInt();
            int256 prevAnswer = previewRedeem(prevGuess.safeCastToUint()).safeCastToInt() - assets.safeCastToInt();

            int256 guess = prevGuess * WITHDRAWAL_GUESS_OFFSET / 1e18;

            int256 supply = _supply.safeCastToInt();

            // Find the root or get very close to it using the secant method, which is slightly more efficient than Newton's
            // method if the cost of evaluating f and f' is similar.
            for (uint256 i = 0; i < 20;) { // 20 chosen as a safe bound for convergence from practical trials.
                if (guess > supply) {
                    guess = supply;
                }

                int256 answer = previewRedeem(guess.safeCastToUint()).safeCastToInt() - assets.safeCastToInt();

                if (answer >= 0 && answer <= assets.mulWadDown(0.001e18).safeCastToInt() || (prevAnswer == answer)) { // Err on the side of overestimating shares needed. Could reduce precision for gas efficiency.
                    break;
                }

                if (guess == supply && answer < 0) revert InsufficientLiquidity();

                int256 nextGuess = guess - (answer * (guess - prevGuess) / (answer - prevAnswer));
                prevGuess  = guess;
                prevAnswer = answer;
                guess      = nextGuess;

                unchecked { ++i; }
            }

            return guess.safeCastToUint() + maxError; // Buffer for pow discrepancies.
        }
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.maxWithdraw(owner);
        } else {
            return previewRedeem(maxRedeem(owner));
        }
    }

    function maxRedeem(address owner) public view override returns (uint256) { // No idiosyncratic owner restrictions.
        if (maturity == MATURITY_NOT_SET) {
            return super.maxRedeem(owner);
        } else {
            uint256 shares = balanceOf[owner];

            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            (uint256 targetBal, uint256 ptBal, uint256 ytBal, uint256 lpBal) = _decomposeShares(ptReserves, targetReserves, shares, false);

            ptReserves     = ptReserves - ptBal;
            targetReserves = targetReserves - targetBal;

            uint256 spaceSupply = space.adjustedTotalSupply();

            ptBal       = ptBal       + lpBal.mulDivDown(pt.balanceOf(address(this)), spaceSupply);
            targetBal   = targetBal   + lpBal.mulDivDown(asset.balanceOf(address(this)), spaceSupply);
            spaceSupply = spaceSupply - lpBal;

            bool isExcessPTs = ptBal > ytBal;
            uint256 diff = isExcessPTs ? ptBal - ytBal : ytBal - ptBal;

            if (isExcessPTs) {
                uint256 maxPTSale = _maxPTSell(ptReserves, targetReserves, spaceSupply);

                if (maxPTSale >= diff) {
                    // We have enough liquidity to handle the sale.
                    return shares;
                } else {
                    // For every unit of LP Share, the excess PT balance grows by "hole".
                    uint256 hole = diff.divWadDown(lpBal);

                    // Determine how many shares we can redeem without exceeding sell limits.
                    return maxPTSale.divWadDown(hole).mulDivDown(totalSupply, space.balanceOf(address(this)));
                }
            } else {
                if (ptReserves >= diff) { // We can redeem YTs up to the point where there are PTs in Space to swap for.
                    // We have enough liquidity to handle the sale.
                    return shares;
                } else {
                    // For every unit of LP Share, the excess YT balance grows by "hole".
                    uint256 hole = diff.divWadDown(lpBal);

                    // Determine how many shares we can redeem without exceeding sell limits.
                    return ptReserves.divWadDown(hole).mulDivDown(totalSupply, space.balanceOf(address(this)));
                }
            }
        }
    }

    /* ========== 4626 EXTENSIONS ========== */

    /// @notice Quick exit into the constituent assets
    /// @dev Outside of the ERC 4626 standard
    function eject(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256 assets, uint256 excessBal, bool isExcessPTs) {
        if (maturity == MATURITY_NOT_SET) revert ActivePhaseOnly();

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        (excessBal, isExcessPTs) = _exitAndCombine(shares);

        _burn(owner, shares); // Burn after percent ownership is determined in _exitAndCombine.

        if (isExcessPTs) {
            pt.transfer(receiver, excessBal);
        } else {
            yt.transfer(receiver, excessBal);
        }

        asset.transfer(receiver, assets = asset.balanceOf(address(this)));
        emit Ejected(msg.sender, receiver, owner, assets, shares,
            isExcessPTs ? excessBal : 0,
            isExcessPTs ? 0 : excessBal
        );
    }

    /* ========== GENERAL UTILS ========== */

    function _exitAndCombine(uint256 shares) internal returns (uint256, bool) {
        uint256 supply = totalSupply; // Save extra SLOAD.

        uint256 lpBal      = shares.mulDivDown(space.balanceOf(address(this)), supply);
        uint256 totalPTBal = pt.balanceOf(address(this));
        uint256 ptShare    = shares.mulDivDown(totalPTBal, supply);

        ERC20[] memory tokens = new ERC20[](2);
        tokens[1 - pti] = asset;
        tokens[pti] = pt;

        _exitPool(
            poolId,
            BalancerVault.ExitPoolRequest({
                assets: tokens,
                minAmountsOut: new uint256[](2),
                userData: abi.encode(lpBal),
                toInternalBalance: false
            })
        );

        uint256 ytBal = shares.mulDivDown(yt.balanceOf(address(this)), supply);
        ptShare = ptShare + pt.balanceOf(address(this)) - totalPTBal;

        unchecked {
            // Safety: an inequality check is done before subtraction.
            if (ptShare > ytBal) {
                divider.combine(address(adapter), maturity, ytBal);
                return (ptShare - ytBal, true);
            } else { // Set excess PTs to false if the balances are exactly equal.
                divider.combine(address(adapter), maturity, ptShare);
                return (ytBal - ptShare, false);
            }
        }
    }

    function claimRewards(ERC20 coin) external {
        require(coin != asset);
        if (maturity != MATURITY_NOT_SET) {
            require(coin != ERC20(address(yt)) && coin != pt && coin != ERC20(address(space)));
        }
        coin.transfer(rewardRecipient, coin.balanceOf(address(this)));
    }

    /* ========== BALANCER UTILS ========== */

    function _joinPool(bytes32 _poolId, BalancerVault.JoinPoolRequest memory request) internal {
        balancerVault.joinPool(_poolId, address(this), address(this), request);
    }

    function _exitPool(bytes32 _poolId, BalancerVault.ExitPoolRequest memory request) internal {
        balancerVault.exitPool(_poolId, address(this), payable(address(this)), request);
    }

    function _swap(BalancerVault.SingleSwap memory request) internal {
        BalancerVault.FundManagement memory funds = BalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        balancerVault.swap(request, funds, 0, type(uint256).max);
    }

    /* ========== NUMERICAL UTILS ========== */

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }

    /* ========== INTERNAL VIEWS ========== */

    /// @dev Calculates the amount of Target needed for issuance such that the PT:Target ratio in
    ///      the Space pool will be preserved after issuing and joining issued PTs and remaining Target.
    function _getTargetForIssuance(uint256 ptReserves, uint256 targetReserves, uint256 targetBal, uint256 scale) 
        internal view returns (uint256) 
    {
        return targetBal.mulWadUp(ptReserves.divWadUp(
            scale.mulWadDown(1e18 - ifee).mulWadDown(targetReserves) + ptReserves
        ));
    }

    function _getSpaceReserves() internal view returns (uint256, uint256) {
        (, uint256[] memory balances, ) = balancerVault.getPoolTokens(poolId);
        uint256 _pti = pti;
        return (balances[_pti], balances[1 - _pti]);
    }

    /// @dev Decompose shares works to break shares into their constituent parts, 
    ///      and also preview the assets required to mint a given number of shares.
    function _decomposeShares(uint256 ptReserves, uint256 targetReserves, uint256 shares, bool withLoose)
        internal view returns (uint256, uint256, uint256, uint256)
    {
        uint256 supply      = totalSupply;
        uint256 totalLPBal  = space.balanceOf(address(this));
        uint256 spaceSupply = space.adjustedTotalSupply();

        // Shares have a right to a portion of the PTs/asset floating around unencombered in this contract.
        return (
            shares.mulDivUp(totalLPBal.mulDivUp(targetReserves, spaceSupply) + (withLoose ? asset.balanceOf(address(this)) : 0), supply),
            shares.mulDivUp(totalLPBal.mulDivUp(ptReserves, spaceSupply) + (withLoose ? pt.balanceOf(address(this)) : 0), supply),
            shares.mulDivUp(yt.balanceOf(address(this)), supply),
            shares.mulDivUp(totalLPBal, supply)
        );
    }

    /* ========== SPACE POOL SOLVERS ========== */

    function _maxPTSell(uint256 ptReserves, uint256 targetReserves, uint256 spaceSupply) public view returns (uint256) {
        (uint256 eqPTReserves, ) = space.getEQReserves(
            maxRate, // Max acceptable implied rate.
            maturity,
            ptReserves,
            targetReserves,
            spaceSupply,
            initScale
        );

        return ptReserves >= eqPTReserves ? 0 : eqPTReserves - ptReserves; // Edge case: the pool is already above the max rate.
    }

    /* ========== ADMIN ========== */

    function setParam(bytes32 what, address data) external {
        require(msg.sender == owner);
        if (what == "SPACE_FACTORY") spaceFactory = SpaceFactoryLike(data);
        else if (what == "PERIPHERY") periphery = PeripheryLike(data);
        else if (what == "OWNER") owner = data;
        else revert UnrecognizedParam(what);
        emit ParamChanged(what, data);
    }

    function setParam(bytes32 what, uint256 data) external {
        require(msg.sender == owner);
        if (what == "MAX_RATE") maxRate = data;
        else if (what == "TARGETED_RATE") {
            require(lastSettle == 0 || lastSettle + cooldown >= block.timestamp - 1 days);
            targetedRate = data;
        }
        else if (what == "TARGET_DURATION") targetDuration = data;
        else if (what == "COOLDOWN") {
            require(lastSettle == 0 || maturity != MATURITY_NOT_SET); // Can't update cooldown during cooldown period.
            cooldown = data;
        }
        else revert UnrecognizedParam(what);
        emit ParamChanged(what, data);
    }

    /* ========== EVENTS ========== */

    event ParamChanged(bytes32 what, address newData);
    event ParamChanged(bytes32 what, uint256 newData);

    event Rolled(uint256 nextMaturity, uint256 initScale, address space, address roller);
    event Ejected(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares,
        uint256 pts,
        uint256 yts
    );
}

contract RollerUtils {
    function getFutureMaturity(uint256 monthsForward) public view returns (uint256) {
        (uint256 year, uint256 month, ) = DateTime.timestampToDate(DateTime.addMonths(block.timestamp, monthsForward));
        return DateTime.timestampFromDateTime(year, month, 1 /* top of the month */, 0, 0, 0);
    }

    function getSpaceData(PeripheryLike periphery, AdapterLike adapter, uint256 nextMaturity)
        public returns (Space, bytes32, uint256, uint256)
    {
        Space _space = periphery.spaceFactory().pools(address(adapter), nextMaturity);
        return (_space, _space.getPoolId(), _space.pti(), adapter.scale());
    }
}
