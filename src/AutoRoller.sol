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

    uint256 public constant MATURITY_NOT_SET = type(uint256).max;
    uint256 public constant SECONDS_PER_YEAR = 31536000;
    uint256 public constant ONE = 1e18;

    /* ========== IMMUTABLES ========== */

    Divider          public immutable divider;
    BalancerVault    public immutable balancerVault;
    OwnableAdapter   public immutable adapter;
    uint256          public immutable ifee;

    /* ========== MUTABLE STORAGE ========== */

    int256 public cash;

    PeripheryLike    public periphery;
    SpaceFactoryLike public spaceFactory;

    // Active Series
    YT      public yt;
    ERC20   public pt;
    Space   public space;
    uint256 public pti;
    bytes32 public poolId;
    uint256 public initScale;
    uint256 public maturity = MATURITY_NOT_SET;

    uint256 public maxRate = 2e18;
    uint256 public fallbackRate = 0.12e18;

    uint256 targetDuration = 3;
    uint256 rollDistance = 30 days;
    uint256 lastRoll;

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

        // Prevent transfers to this contract and 0x00.
        balanceOf[address(this)] = type(uint256).max;
        balanceOf[address(0)   ] = type(uint256).max;

        adapter = _adapter;
        ifee    = _adapter.ifee(); // Assumption: ifee will not change. Don't break this assumption and expect good things.
    }

    /* ========== SERIES MANAGEMENT ========== */

    function roll() external {
        if (lastRoll != 0 || lastRoll + rollDistance > block.timestamp) revert RollWindowNotOpen();

        if (block.timestamp > maturity) {
            settle();
        }

        if (maturity != MATURITY_NOT_SET) {
            (uint256 excessBal, ) = _exitAndCombine(totalSupply);

            cash += int256(excessBal); // Estimate the Target that will be redeemable in the future, then discount it back.
        }

        uint256 assetBal = asset.balanceOf(address(this));
        uint256 baseUnit = 10**asset.decimals();
        if (assetBal < baseUnit) {
            unchecked {
                // Ensure there's enough Target in this contract to initialize a rate.
                deposit(baseUnit - assetBal, msg.sender);
            }
        }

        adapter.openSponsorWindow();

        lastRoll = block.timestamp;
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

                targetedRate = _powWad(results[0] + ONE, space.ts().mulWadDown(SECONDS_PER_YEAR * ONE)) - ONE;
            }
        }

        (uint256 year, uint256 month, ) = DateTime.timestampToDate(DateTime.addMonths(block.timestamp, targetDuration));

        uint256 nextMaturity = DateTime.timestampFromDateTime(
            year,
            month,
            1, // Top of month only.
            0,
            0,
            0
        );

        // Assign Series data.
        (pt, yt)  = periphery.sponsorSeries(address(adapter), nextMaturity, true);
        space     = spaceFactory.pools(address(adapter), nextMaturity);
        pti       = space.pti();
        poolId    = space.getPoolId();
        maturity  = nextMaturity;
        initScale = adapter.scale();

        // Allow Balancer to move the new PTs for joins & swaps.
        pt.approve(address(balancerVault), type(uint256).max);

        // Allow Periphery to move the new YTs for swaps.
        yt.approve(address(periphery), type(uint256).max);

        ERC20[] memory tokens = new ERC20[](2);
        tokens[pti]      = pt;
        tokens[1 - pti]  = asset;

        uint256 targetBal = asset.balanceOf(address(this));
        uint256 scale     = adapter.scale();

        (uint256 eqPTReserves, uint256 eqTargetReserves) = _getEQReserves(
            targetedRate,
            nextMaturity,
            0,
            targetBal,
            targetBal.mulWadDown(scale),
            scale
        );

        divider.issue(address(adapter), nextMaturity, _getTargetForIssuance(
            eqPTReserves, eqTargetReserves, targetBal, scale
        ));

        uint256[] memory balances = new uint256[](2);
        balances[1 - pti] = asset.balanceOf(address(this));

        // Initialize the targeted rate in the Space pool.
        _joinPool(
            poolId,
            BalancerVault.JoinPoolRequest({
                assets: tokens,
                maxAmountsIn: balances,
                userData: abi.encode(balances, 0), // No min BPT out: first join.
                fromInternalBalance: false
            })
        );
        _swap(
            BalancerVault.SingleSwap({
                poolId: poolId,
                kind: BalancerVault.SwapKind.GIVEN_IN,
                assetIn: address(pt),
                assetOut: address(asset),
                amount: eqPTReserves.mulDivDown(balances[1 - pti], targetBal),
                userData: hex""
            })
        );

        balances[pti    ] = pt.balanceOf(address(this));
        balances[1 - pti] = asset.balanceOf(address(this));

        _joinPool(
            poolId,
            BalancerVault.JoinPoolRequest({
                assets: tokens,
                maxAmountsIn: balances,
                userData: abi.encode(balances, 0), // No min BPT out: the pool was created in this tx and the join can't be sandwiched.
                fromInternalBalance: false
            })
        );
    }

    /// @notice Settle the active Series if the roll window isn't open but the Series has reacted maturity.
    /// @dev Calling this function cashes the current LP shares in for Target and initiates a cooldown phase.
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

        if (excessBal > 0 && isExcessPTs) {
            divider.redeem(address(adapter), maturity, excessBal);
        }

        maturity = MATURITY_NOT_SET; // Enter a cooldown phase where users can redeem without slippage.
        delete pt; delete yt; delete space; delete pti; delete poolId; delete initScale; // Re-set variables to defaults.
    }

    /// @notice Cash a previous Series' assets into Target
    function cashAssets(uint256 prevMaturity) public {
        ERC20 pt = ERC20(divider.pt(address(adapter), prevMaturity));
        YT yt = YT(divider.yt(address(adapter), prevMaturity));

        uint256 ptBal = pt.balanceOf(address(this));
        if (ptBal > 0 && divider.mscale(address(adapter), prevMaturity) > 0) {
            cash -= int256(divider.redeem(address(adapter), prevMaturity, ptBal));
        }

        if (yt.balanceOf(address(this)) > 0) {
            cash -= int256(yt.collect()); // Allow callers to cash collected Target from YTs anytime, even before maturity.
        }

        if (maturity != MATURITY_NOT_SET) {
            uint256 newShares = deposit(asset.balanceOf(address(this)), address(this)); // Roll all excess Target into the active Series.
            _burn(address(this), newShares);
        }
    }

    /* ========== 4626 ========== */

    function beforeWithdraw(uint256, uint256 shares) internal override {
        if (maturity != MATURITY_NOT_SET) {

            (uint256 excessBal, bool isExcessPTs) = _exitAndCombine(shares);

            if (isExcessPTs) {
                uint256 maxPTSale = maxPTSell();

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
            uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply - shares is non-zero.

            (ERC20[] memory tokens, uint256[] memory balances, ) = balancerVault.getPoolTokens(poolId);

            uint256 previewedLPBal = supply - shares == 0 ?
                shares.mulDivDown(space.balanceOf(address(this)), supply - shares) : shares;

            uint256 targetToJoin = previewedLPBal.mulDivDown(balances[1 - pti], space.totalSupply());

            balances[1 - pti] = targetToJoin;
            if (assets - targetToJoin > 0) { // Assumption: this will only be false if Space has only Target liquidity.
                balances[pti] = divider.issue(address(adapter), maturity, assets - targetToJoin);
            }

            _joinPool(
                poolId,
                BalancerVault.JoinPoolRequest({
                    assets: tokens,
                    maxAmountsIn: balances,
                    userData: abi.encode(balances, 0),
                    fromInternalBalance: false
                })
            );
        }
    }

    /// @notice Calculates the total assets of this vault using the current spot price of PTs/YTs, without factoring in slippage.
    function totalAssets() public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return asset.balanceOf(address(this));
        } else {
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();
            
            (uint256 targetBal, uint256 ptBal, uint256 ytBal, ) = _decomposeShares(ptReserves, targetReserves, totalSupply);

            uint256 stretchedRate = (ptReserves + space.totalSupply()).divWadDown(
                targetReserves.mulWadDown(initScale)
            );
            
            uint256 ptSpotPrice = space.getPriceFromImpliedRate(stretchedRate); // PT price in Target.

            if (ptBal >= ytBal) {
                unchecked {
                    uint256 diff = ptBal - ytBal;

                    // Target + combined PTs/YTs + PT spot value.
                    return targetBal + ptBal.divWadDown(adapter.scaleStored()) + ptSpotPrice.mulWadDown(diff);
                }
            } else {
                unchecked {
                    uint256 diff = ytBal - ptBal;

                    // Target + combined PTs/YTs + YT spot value.
                    return targetBal + ytBal.divWadDown(adapter.scaleStored()) + (ONE - ptSpotPrice).mulWadDown(diff);
                }
            }
        }
    }

    /// @notice The difference between convertToShares and previewDeposit is only that slippage is considered in the latter
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewDeposit(assets);
        } else {
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

            // Calculate how much Target we'll end up joining the pool with, and use that to preview minted LP shares.
            uint256 previewedLPBal = (assets - _getTargetForIssuance(ptReserves, targetReserves, assets, adapter.scaleStored()))
                .mulDivDown(space.totalSupply(), targetReserves);

            // Shares represent proportional ownership of the LP shares the vault holds.
            return supply == 0 ? 
                previewedLPBal : previewedLPBal.mulDivDown(supply, space.balanceOf(address(this)));
        }
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewMint(shares);
        } else {
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            (uint256 targetToJoin, uint256 ptsToJoin, , ) = _decomposeShares(ptReserves, targetReserves, shares);

            return targetToJoin + ptsToJoin.divWadDown(adapter.scaleStored().mulWadDown(1e18 - ifee)); // targetToJoin + targetToIssue
        }
    }

    /// @notice The difference between convertToAssets and previewRedeem is only that slippage is considered in the latter
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        if (maturity == MATURITY_NOT_SET) {
            return super.previewRedeem(shares);
        } else {
            (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

            (uint256 targetBal, uint256 ptBal, uint256 ytBal, ) = _decomposeShares(ptReserves, targetReserves, shares);

            uint256 scale = adapter.scaleStored();

            if (ptBal >= ytBal) {
                unchecked {
                    uint256 diff = ptBal - ytBal;

                    uint256 maxPTSale = maxPTSell();

                    if (diff > maxPTSale) {
                        // If there isn't enough liquidity to sell all of the PTs, sell the max that we can and ignore the remaining PTs.
                        diff = maxPTSale;
                    }

                    // Target + combined PTs/YTs + sold PTs.
                    return targetBal + ptBal.divWadDown(scale) + _previewSell(
                        ptReserves - ptBal, targetReserves - targetBal, diff, true, true
                    );
                }
            } else {
                unchecked {
                    uint256 diff = ytBal - ptBal;

                    if (diff > ptReserves) {
                        // If there isn't enough liquidity to sell all of the YTs, sell the max that we can and ignore the remaining YTs.
                        diff = ptReserves;
                    }

                    uint256 targetIn = _previewSell(
                        ptReserves - ptBal, targetReserves - targetBal, diff, true, false
                    );

                    // Target + combined PTs/YTs + sold YTs.
                    return targetBal + ytBal.divWadDown(scale) + diff.divWadDown(scale) - targetIn;
                }
            }
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

            (, uint256 ptBal, uint256 ytBal, uint256 lpBal) = _decomposeShares(ptReserves, targetReserves, shares);

            if (ptBal >= ytBal) {
                uint256 diff = ptBal - ytBal;

                uint256 maxPTSale = maxPTSell();

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

    function maxPTSell() public view returns (uint256) {
        (uint256 ptReserves, uint256 targetReserves) = _getSpaceReserves();

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

    /* ========== INTERNAL HELPERS ========== */

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
                divider.combine(address(adapter), maturity, ptBal); // side-effect: will burn all YTs in this contract after maturity.
                return (ytBal - ptBal, false);
            }
        }
    }

    /// @dev Calculates the amount of Target needed for issuance such that the PT:Target ratio in
    ///      the Space pool will be preserved after issuing and joining the PTs and remaining Target
    function _getTargetForIssuance(uint256 ptReserves, uint256 targetReserves, uint256 targetBal, uint256 scale) 
        internal view returns (uint256) 
    {
        return targetBal.mulWadDown(ptReserves.divWadDown(
            scale.mulWadDown(1e18 - ifee).mulWadDown(targetReserves) + ptReserves
        ));
    }

    function _previewSell(uint256 ptReserves, uint256 targetReserves, uint256 amount, bool ptIn, bool givenIn) 
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
        // Stretch the targeted rate to match the Space pool's timeshift period.
        // e.g. if the timestretch is 1/12 years in seconds, then the rate will be transformed from a yearly rate to a 12-year rate.
        uint256 stretchedRate = _powWad(rate + ONE, ONE.divWadDown(space.ts().mulWadDown(SECONDS_PER_YEAR * ONE))) - ONE;

        // Assumption: the swap to get to these reserves will be PTs -> Target, so we use the G2 fee.
        uint256 a = ONE - space.g2().mulWadDown(space.ts().mulWadDown((maturity - block.timestamp) * ONE));
        uint256 k = _powWad(initialPTReserves + poolSupply, a) + _powWad(initialTargetReserves.mulWadDown(initScale), a);
        uint256 eqPTReservesPartial = _powWad(
            k.divWadDown(ONE.divWadDown(_powWad(ONE + stretchedRate, a)) + ONE), ONE.divWadDown(a)
        );

        return (eqPTReservesPartial - poolSupply, eqPTReservesPartial.divWadDown(initScale.mulWadDown(ONE + stretchedRate)));
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
        uint256 lpBal = shares.mulDivUp(space.balanceOf(address(this)), totalSupply);
        uint256 percentOwnership = lpBal.divWadDown(space.totalSupply());

        return (percentOwnership.mulWadUp(targetReserves), percentOwnership.mulWadUp(ptReserves), yt.balanceOf(address(this)), lpBal);
    }

    function _powWad(uint256 x, uint256 y) internal pure returns (uint256) {
        require(x < 1 << 255);
        require(y < 1 << 255);

        return uint256(FixedPointMathLib.powWad(int256(x), int256(y))); // Assumption: x cannot be negative so this result will never be.
    }

    /* ========== BALANCER HELPERS ========== */

    function _joinPool(bytes32 poolId, BalancerVault.JoinPoolRequest memory request) internal {
        balancerVault.joinPool(poolId, address(this), address(this), request);
    }

    function _exitPool(bytes32 poolId, BalancerVault.ExitPoolRequest memory request) internal {
        balancerVault.exitPool(poolId, address(this), payable(address(this)), request);
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

    /* ========== ADMIN ========== */

    function setSpaceFactory(address newSpaceFactory) external requiresTrust {
        emit SpaceFactoryChanged(address(spaceFactory), newSpaceFactory);
        spaceFactory = SpaceFactoryLike(newSpaceFactory);
    }

    function setPeriphery(address newPeriphery) external requiresTrust {
        emit PeripheryChanged(address(periphery), newPeriphery);
        periphery = PeripheryLike(newPeriphery);
    }

    function setMaxRate(uint256 newMaxRate) external requiresTrust {
        emit MaxRateChanged(maxRate, newMaxRate);
        maxRate = newMaxRate;
    }

    function setFallbackRate(uint256 newFallbackRate) external requiresTrust {
        emit FallbackRateChanged(fallbackRate, newFallbackRate);
        fallbackRate = newFallbackRate;
    }

    function setTargetDuration(uint256 newTargetDuration) external requiresTrust {
        emit TargetDurationChanged(targetDuration, newTargetDuration);
        targetDuration = newTargetDuration;
    }

    function setRollDistance(uint256 newRollDistance) external requiresTrust {
        emit RollDistanceChanged(rollDistance, newRollDistance);
        rollDistance = newRollDistance;
    }

    /* ========== EVENTS ========== */

    event SpaceFactoryChanged(address oldSpaceFactory, address newSpaceFactory);
    event PeripheryChanged(address oldPeriphery, address newPeriphery);
    event MaxRateChanged(uint256 oldMaxRate, uint256 newMaxRate);
    event FallbackRateChanged(uint256 oldFallbackRate, uint256 newFallbackRate);
    event TargetDurationChanged(uint256 oldTargetDuration, uint256 newTargetDuration);
    event RollDistanceChanged(uint256 oldRollDistance, uint256 newRollDistance);
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