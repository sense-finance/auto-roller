// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.11;

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { ERC4626 } from "solmate/mixins/ERC4626.sol";
import { DateTime } from "./external/DateTime.sol";

import { Divider } from "sense-v1-core/Divider.sol";
import { Periphery } from "sense-v1-core/Periphery.sol";
import { BaseAdapter as Adapter } from "sense-v1-core/adapters/BaseAdapter.sol";
import { YT } from "sense-v1-core/tokens/YT.sol";
import { Trust } from "sense-v1-utils/Trust.sol";

import { BalancerOracle } from "./interfaces/BalancerOracle.sol";
import { BalancerVault } from "./interfaces/BalancerVault.sol";
import { Space } from "./interfaces/Space.sol";

interface SpaceFactoryLike {
    function divider() external view returns (address);
    function create(address, uint256) external returns (address);
    function pools(address, uint256) external view returns (Space);
}

interface PeripheryLike {
    function sponsorSeries(address, uint256, bool) external returns (ERC20, YT);
    function swapYTsForTarget(address, uint256, uint256) external returns (uint256);
    function create(address, uint256) external returns (address);
    function pools(address, uint256) external view returns (Space);
    function MIN_YT_SWAP_IN() external view returns (uint256);
}

interface Opener {
    function onSponsorWindowOpened() external;
}

abstract contract OwnableAdapter is Adapter {
    function openSponsorWindow() external virtual {
        Opener(msg.sender).onSponsorWindowOpened();
    }
}

contract AutoRoller is ERC4626, Trust {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    /* ========== ERRORS ========== */

    error ActivePhaseOnly();
    error SeriesCannotBeActive();
    error InsufficientLiquidity();
    error RollWindowNotOpen();
    error OnlyAdapter();

    /* ========== CONSTANTS ========== */

    uint32 public constant MATURITY_NOT_SET = type(uint32).max;
    uint256 public constant SECONDS_PER_YEAR = 31536000;
    uint256 public constant MIN_ASSET_AMOUNT = 0.01e18;
    uint256 public constant ONE = 1e18;

    /* ========== IMMUTABLES ========== */

    Divider          public immutable divider;
    BalancerVault    public immutable balancerVault;
    OwnableAdapter   public immutable adapter;
    uint256          public immutable ifee;
    uint256          public immutable minSwapAmount;

    /* ========== MUTABLE STORAGE ========== */

    PeripheryLike    public periphery;
    SpaceFactoryLike public spaceFactory;

    // Active Series
    YT      public yt;
    ERC20   public pt;
    Space   public space;
    bytes32 public poolId;
    // Packed slot 1
    uint216 public initScale;
    uint32  public maturity = MATURITY_NOT_SET;
    uint8   public pti;

    // Packed slot 2
    uint88 public maxRate = 2e18;
    uint88 public fallbackRate = 0.12e18;
    uint16 public targetDuration = 3;
    uint32 public cooldown = 10 days;
    uint32 public lastSettle;

    constructor(
        ERC20 _target,
        Divider _divider,
        address _periphery,
        address _spaceFactory,
        address _balancerVault,
        OwnableAdapter _adapter
    ) ERC4626(
        _target,
        string(abi.encodePacked(_target.name(), " Sense Auto Roller")),
        string(abi.encodePacked(_target.symbol(), "-sAR"))
    ) Trust(msg.sender) {
        divider       = _divider;
        periphery     = PeripheryLike(_periphery);
        spaceFactory  = SpaceFactoryLike(_spaceFactory);
        balancerVault = BalancerVault(_balancerVault);

        // Allow the Divder to move this contract's Target for PT/YT issuance.
        _target.approve(address(_divider), type(uint256).max);

        // Allow Balancer to move this contract's Target for Space pools joins.
        _target.approve(address(_balancerVault), type(uint256).max);

        minSwapAmount = periphery.MIN_YT_SWAP_IN() / 10**(18 - decimals) + 1; // Rounds up to 1 for low decimal tokens.

        // Prevent transfers to this contract.
        balanceOf[address(this)] = type(uint256).max;

        adapter = _adapter;
        ifee    = _adapter.ifee(); // Assumption: ifee will not change. Don't break this assumption and expect good things.
    }

    /* ========== SERIES MANAGEMENT ========== */

    function roll() external {
        if (maturity != MATURITY_NOT_SET) revert RollWindowNotOpen();

        if (lastSettle == 0) {
            // If this is the first roll, lock some shares in by minting them for the zero address.
            // This prevents the contract from reaching an empty state during future active periods.
            deposit(MIN_ASSET_AMOUNT / 10**(18 - decimals) + 1, address(0));
        } else if (lastSettle + cooldown > block.timestamp) revert RollWindowNotOpen();

        adapter.openSponsorWindow();
    }

    function onSponsorWindowOpened() external { // Assumption: all of this Vault's LP shares will have been exited before this function is called.
        if (msg.sender != address(adapter)) revert OnlyAdapter();

        uint256 targetedRate = fallbackRate;

        if (space != Space(address(0))) {
            (, , , , , , uint256 sampleTs) = space.getSample(space.getTotalSamples() - 1);
            if (sampleTs > 0) {
                Space.OracleAverageQuery[] memory queries = new Space.OracleAverageQuery[](1);
                queries[0] = Space.OracleAverageQuery({
                    variable: Space.Variable.BPT_PRICE, // For Space, the BPT_PRICE slot contains the stretched implied rate.
                    secs: space.getLargestSafeQueryWindow() - 1 hours,
                    ago: 1 hours
                });

                uint256[] memory results = space.getTimeWeightedAverage(queries);

                 // Convert the stretched rate into a yearly rate.
                targetedRate = _powWad(results[0] + ONE, space.ts().mulWadDown(SECONDS_PER_YEAR * ONE)) - ONE;
            }
        }

        (uint256 year, uint256 month, ) = DateTime.timestampToDate(DateTime.addMonths(block.timestamp, targetDuration));
        uint256 nextMaturity = DateTime.timestampFromDateTime(year, month, 1 /* top of the month */, 0, 0, 0);

        // Assign Series data.
        (ERC20 _pt, YT _yt) = periphery.sponsorSeries(address(adapter), nextMaturity, true);
        Space   _space      = spaceFactory.pools(address(adapter), nextMaturity);
        bytes32 _poolId     = _space.getPoolId();

        uint8   _pti  = uint8(_space.pti());
        uint256 scale = adapter.scale();

        space = _space; // Set here b/c it's needed in _getEQReserves.

        // Allow Balancer to move the new PTs for joins & swaps.
        _pt.approve(address(balancerVault), type(uint256).max);

        // Allow Periphery to move the new YTs for swaps.
        _yt.approve(address(periphery), type(uint256).max);

        ERC20[] memory tokens = new ERC20[](2);

        tokens[_pti] = _pt; tokens[1 - _pti] = asset;

        uint256 targetBal = asset.balanceOf(address(this));

        (uint256 eqPTReserves, uint256 eqTargetReserves) = _getEQReserves(
            targetedRate,
            nextMaturity,
            0,
            targetBal,
            targetBal.mulWadDown(scale),
            scale
        );

        uint256 targetForIssuance = _getTargetForIssuance(eqPTReserves, eqTargetReserves, targetBal, scale);
        divider.issue(address(adapter), nextMaturity, targetForIssuance);

        uint256[] memory balances = new uint256[](2);
        balances[1 - _pti] = targetBal - targetForIssuance;

        // Initialize the targeted rate in the Space pool.
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
                assetOut: address(asset),
                amount: eqPTReserves.mulDivDown(balances[1 - _pti], targetBal),
                userData: hex""
            })
        );

        balances[_pti    ] = _pt.balanceOf(address(this));
        balances[1 - _pti] = asset.balanceOf(address(this));

        _joinPool(
            _poolId,
            BalancerVault.JoinPoolRequest({
                assets: tokens,
                maxAmountsIn: balances,
                userData: abi.encode(balances, 0), // No min BPT out: the pool was created in this tx and the join can't be sandwiched.
                fromInternalBalance: false
            })
        );

        poolId = _poolId;
        pt     = _pt;
        yt     = _yt;

        // Combined single SSTORE.
        initScale = _safeCastTo216(scale);
        maturity  = uint32(nextMaturity);
        pti       = _pti;
    }

    /// @notice Settle the active Series and enter a cooldown phase.
    function settle() public {
        uint256 assetBalPre = asset.balanceOf(address(this));
        divider.settleSeries(address(adapter), maturity); // Settlement will fail if maturity hasn't been reached.
        uint256 assetBalPost = asset.balanceOf(address(this));

        asset.safeTransfer(msg.sender, assetBalPost - assetBalPre); // Send settlement reward to the sender.

        (, address stake, uint256 stakeSize) = Adapter(adapter).getStakeAndTarget();
        if (stake != address(asset)) {
            ERC20(stake).safeTransfer(msg.sender, stakeSize);
        }

        (uint256 excessBal, bool isExcessPTs) = _exitAndCombine(totalSupply); // Collects & burns YTs as a side-effect.

        if (excessBal > 0) {
            if (isExcessPTs) {
                divider.redeem(address(adapter), maturity, excessBal); // Burns the PTs.
            } else {
                yt.collect(); // Burns the YTs.
            }
        }

        maturity = MATURITY_NOT_SET; // Enter a cooldown phase where users can redeem without slippage.
        lastSettle = uint32(block.timestamp);
        delete pt; delete yt; delete space; delete pti; delete poolId; delete initScale; // Re-set variables to defaults, collect gas refunds.
    }

    /* ========== 4626 ========== */

    function beforeWithdraw(uint256, uint256 shares) internal override {
        if (maturity != MATURITY_NOT_SET) {
            (uint256 excessBal, bool isExcessPTs) = _exitAndCombine(shares);
            
            if (excessBal < minSwapAmount) return;

            if (isExcessPTs) {
                (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();
                uint256 maxPTSale = _maxPTSell(ptReserves, targetReserves);

                if (excessBal > maxPTSale) revert InsufficientLiquidity(); // Need to wait for more liquidity or until a cooldown phase.

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

            uint256 targetToJoin = previewedLPBal.mulDivUp(balances[1 - _pti], space.totalSupply());

            balances[1 - _pti] = targetToJoin;

            if (assets - targetToJoin > 0) { // Assumption: this will only be false if Space has only Target liquidity.
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
        } else {
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();
            
            (uint256 targetBal, uint256 ptBal, uint256 ytBal, ) = _decomposeShares(ptReserves, targetReserves, totalSupply);

            uint256 ptSpotPrice = space.getPriceFromImpliedRate(
                (ptReserves + space.totalSupply()).divWadDown(targetReserves.mulWadDown(initScale)) - ONE
            ); // PT price in Target.

            uint256 scale = adapter.scaleStored();

            if (ptBal >= ytBal) {
                unchecked {
                    // Target + combined PTs/YTs + PT spot value in Target.
                    return targetBal + ptBal.divWadDown(scale) + ptSpotPrice.mulWadDown(ptBal - ytBal);
                }
            } else {
                uint256 ytSpotPrice = (ONE - ptSpotPrice.mulWadDown(scale)).divWadDown(scale);

                unchecked {
                    // Target + combined PTs/YTs + YT spot value in Target.
                    return targetBal + ytBal.divWadDown(scale) + ytSpotPrice.mulWadDown(ytBal - ptBal);
                }
            }
        }
    }

    /// @notice The same as convertToShares, except that slippage is considered in previewDeposit.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewDeposit(assets);
        } else {
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            // Calculate how much Target we'll end up joining the pool with, and use that to preview minted LP shares.
            uint256 previewedLPBal = (assets - _getTargetForIssuance(ptReserves, targetReserves, assets, adapter.scaleStored()))
                .mulDivDown(space.totalSupply(), targetReserves);

            // Shares represent proportional ownership of LP shares the vault holds.
            return previewedLPBal.mulDivDown(totalSupply, space.balanceOf(address(this)));
        }
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewMint(shares);
        } else {
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            (uint256 targetToJoin, uint256 ptsToJoin, , ) = _decomposeShares(ptReserves, targetReserves, shares);

            return targetToJoin + ptsToJoin.divWadUp(adapter.scaleStored().mulWadDown(1e18 - ifee)); // targetToJoin + targetToIssue
        }
    }

    /// @notice The same as convertToAssets, except that slippage is considered in previewRedeem.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewRedeem(shares);
        } else {
            require(shares <= totalSupply); // Bad. No error for you.

            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            (uint256 targetBal, uint256 ptBal, uint256 ytBal, ) = _decomposeShares(ptReserves, targetReserves, shares);

            uint256 scale = adapter.scaleStored();

            if (ptBal >= ytBal) {
                unchecked {
                    uint256 maxPTSale = _maxPTSell(ptReserves - ptBal, targetReserves - targetBal);

                    // If there isn't enough liquidity to sell all of the PTs, sell the max that we can and ignore the remaining PTs.
                    uint256 ptsToSell = _min(ptBal - ytBal, maxPTSale);

                    uint256 targetOut = ptsToSell > minSwapAmount ?
                        _previewSwap(ptReserves - ptBal, targetReserves - targetBal, ptsToSell, true, true) : 0;

                    // target + combined PTs/YTs + sold PTs.
                    return targetBal + ytBal.divWadDown(scale) + targetOut;
                }
            } else {
                unchecked {
                    // If there isn't enough liquidity to sell all of the YTs, sell the max that we can and ignore the remaining YTs.
                    uint256 ytsToSell = _min(ytBal - ptBal, ptReserves - ptBal);

                    // Target from combining YTs with PTs - target needed to buy PTs.
                    uint256 targetOut = ytsToSell > minSwapAmount ? 
                        ytsToSell.divWadDown(scale) - _previewSwap(ptReserves - ptBal, targetReserves - targetBal, ytsToSell, false, false) : 0;

                    // target + combined PTs/YTs + sold YTs.
                    return targetBal + ptBal.divWadDown(scale) + targetOut;
                }
            }
        }
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewWithdraw(assets);
        } else {
            // This is a pessimistic preview function as it takes the total assets at the moment, with full slippage, and works
            // backwards from that for the shares one needs. redeem should be preferred for users wishing to withdraw.
            uint256 maxAssetWithdrawal = previewRedeem(maxRedeem(address(0)));

            return assets.mulDivUp(totalSupply, maxAssetWithdrawal);
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
            uint256 shares = owner == address(0) ? totalSupply : balanceOf[owner];

            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            (uint256 targetBal, uint256 ptBal, uint256 ytBal, uint256 lpBal) = _decomposeShares(ptReserves, targetReserves, shares);

            if (ptBal >= ytBal) {
                uint256 diff = ptBal - ytBal;

                uint256 maxPTSale = _maxPTSell(ptReserves - ptBal, targetReserves - targetBal);

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
                uint256 diff = ytBal - ptBal;

                if (ptReserves >= diff) {
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
        uint256 supply = totalSupply;

        uint256 lpBal = shares.mulDivDown(space.balanceOf(address(this)), supply);

        ERC20[] memory tokens = new ERC20[](2);

        tokens[pti] = pt; tokens[1 - pti] = asset;

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
        uint256 ptBal = pt.balanceOf(address(this));

        unchecked {
            if (ptBal >= ytBal) {
                divider.combine(address(adapter), maturity, ytBal);
                return (ptBal - ytBal, true);
            } else {
                divider.combine(address(adapter), maturity, ptBal); // Side-effect: will burn all YTs in this contract after maturity.
                return (ytBal - ptBal, false);
            }
        }
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

    function _powWad(uint256 x, uint256 y) internal pure returns (uint256) {
        return uint256(FixedPointMathLib.powWad(_safeCastToInt(x), _safeCastToInt(y))); // Assumption: x cannot be negative so this result will never be.
    }

    function _safeCastToInt(uint256 x) internal pure returns (int256) {
        require(x < 1 << 255);
        return int256(x);
    }

    function _safeCastTo216(uint256 x) internal pure returns (uint216) {
        require(x < 1 << 216);
        return uint216(x);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }

    /* ========== INTERNAL VIEWS ========== */

    /// @dev Calculates the amount of Target needed for issuance such that the PT:Target ratio in
    ///      the Space pool will be preserved after issuing and joining the PTs and remaining Target
    function _getTargetForIssuance(uint256 ptReserves, uint256 targetReserves, uint256 targetBal, uint256 scale) 
        internal view returns (uint256) 
    {
        return targetBal.mulWadUp(ptReserves.divWadUp(
            scale.mulWadDown(1e18 - ifee).mulWadDown(targetReserves) + ptReserves
        ));
    }

    function _previewSwap(uint256 ptReserves, uint256 targetReserves, uint256 amount, bool ptIn, bool givenIn) 
        internal view returns (uint256) 
    {
        return space.onSwap(
            Space.SwapRequest({
                kind: givenIn ? BalancerVault.SwapKind.GIVEN_IN : BalancerVault.SwapKind.GIVEN_OUT,
                tokenIn: ptIn ? pt : asset,
                tokenOut: ptIn ? asset : pt,
                amount: amount,
                poolId: poolId,
                lastChangeBlock: 0,
                from: address(0),
                to: address(0),
                userData: ""
            }),
            ptIn ? ptReserves : targetReserves,
            ptIn ? targetReserves : ptReserves
        );
    }

    /// @dev Given initial Space conditions, determine the reserve balances required to establish the implied rate.
    function _getEQReserves(
        uint256 rate,
        uint256 maturity,
        uint256 initialPTReserves,
        uint256 initialTargetReserves,
        uint256 poolSupply,
        uint256 initScale
    ) internal view returns (uint256, uint256) {
        uint256 ts = space.ts();

        // Stretch the targeted rate to match the Space pool's timeshift period.
        // e.g. if the timestretch is 1/12 years in seconds, then the rate will be transformed from a yearly rate to a 12-year rate.
        uint256 stretchedRate = _powWad(rate + ONE, ONE.divWadDown(ts.mulWadDown(SECONDS_PER_YEAR * ONE))) - ONE;

        // Assumption: the swap to get to these reserves will be PTs -> Target, so we use the G2 fee.
        uint256 a = ONE - space.g2().mulWadDown(ts.mulWadDown((maturity - block.timestamp) * ONE));
        uint256 k = _powWad(initialPTReserves + poolSupply, a) + _powWad(initialTargetReserves.mulWadDown(initScale), a);
        uint256 eqPTReservesPartial = _powWad(
            k.divWadDown(ONE.divWadDown(_powWad(ONE + stretchedRate, a)) + ONE), ONE.divWadDown(a)
        );

        return (eqPTReservesPartial - poolSupply, eqPTReservesPartial.divWadDown(initScale.mulWadDown(ONE + stretchedRate)));
    }

    function _maxPTSell(uint256 ptReserves, uint256 targetReserves) public view returns (uint256) {
        (uint256 eqPTReserves, ) = _getEQReserves(
            maxRate, // Max acceptable implied rate.
            maturity,
            ptReserves,
            targetReserves,
            space.totalSupply(),
            initScale
        );

        return ptReserves >= eqPTReserves ? 0 : eqPTReserves - ptReserves;
    }

    function _getSpaceReserves() internal view returns (uint256, uint256) {
        (, uint256[] memory balances, ) = balancerVault.getPoolTokens(poolId);
        
        return (balances[pti], balances[1 - pti]);
    }

    /// @dev Decompose shares works to break shares into their constituent parts, 
    ///      and also preview the assets required to mint a given number of shares.
    function _decomposeShares(uint256 ptReserves, uint256 targetReserves, uint256 shares) 
        internal view returns (uint256, uint256, uint256, uint256)
    {
        uint256 totalLPBal = space.balanceOf(address(this));

        uint256 percentVaultOwnership = shares.divWadUp(totalSupply);
        uint256 percentPoolOwnership  = totalLPBal.mulDivDown(percentVaultOwnership, space.totalSupply());

        return (
            percentPoolOwnership.mulWadUp(targetReserves),
            percentPoolOwnership.mulWadUp(ptReserves),
            percentVaultOwnership.mulWadUp(yt.balanceOf(address(this))),
            percentVaultOwnership.mulWadUp(totalLPBal)
        );
    }

    /* ========== ADMIN ========== */

    function setSpaceFactory(address newSpaceFactory) external requiresTrust {
        emit SpaceFactoryChanged(address(spaceFactory), newSpaceFactory);
        spaceFactory = SpaceFactoryLike(newSpaceFactory);
    }

    function setPeriphery(address newPeriphery) external requiresTrust {
        emit PeripheryChanged(address(periphery), newPeriphery);
        periphery = PeripheryLike(newPeriphery);
    }

    function setMaxRate(uint88 newMaxRate) external requiresTrust {
        emit MaxRateChanged(maxRate, newMaxRate);
        maxRate = newMaxRate;
    }

    function setFallbackRate(uint88 newFallbackRate) external requiresTrust {
        emit FallbackRateChanged(fallbackRate, newFallbackRate);
        fallbackRate = newFallbackRate;
    }

    function setTargetDuration(uint16 newTargetDuration) external requiresTrust {
        emit TargetDurationChanged(targetDuration, newTargetDuration);
        targetDuration = newTargetDuration;
    }

    function setCooldown(uint32 newCooldown) external requiresTrust {
        emit CooldownChanged(cooldown, newCooldown);
        cooldown = newCooldown;
    }

    /* ========== EVENTS ========== */

    event SpaceFactoryChanged(address oldSpaceFactory, address newSpaceFactory);
    event PeripheryChanged(address oldPeriphery, address newPeriphery);
    event MaxRateChanged(uint88 oldMaxRate, uint88 newMaxRate);
    event FallbackRateChanged(uint88 oldFallbackRate, uint88 newFallbackRate);
    event TargetDurationChanged(uint16 oldTargetDuration, uint16 newTargetDuration);
    event CooldownChanged(uint32 oldCooldown, uint32 newCooldown);
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