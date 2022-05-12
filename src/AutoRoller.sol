// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.11;

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { ERC4626 } from "solmate/mixins/ERC4626.sol";

import { Divider } from "sense-v1-core/Divider.sol";
import { BaseAdapter as Adapter } from "sense-v1-core/adapters/BaseAdapter.sol";
import { Trust } from "sense-v1-utils/Trust.sol";

import { BalancerVault } from "./interfaces/BalancerVault.sol";
import { Space } from "./interfaces/Space.sol";

import { MockERC20 } from "solmate/test/utils/mocks/MockERC20.sol";

interface SpaceFactoryLike {
    function divider() external view returns (address);
    function create(address, uint256) external returns (address);
    function pools(address, uint256) external view returns (address);
}

interface Opener {
    function onSponsorWindowOpened() external;
}

abstract contract OwnableAdapter is Adapter {
    function openSponsorWindow() external {
        Opener(msg.sender).onSponsorWindowOpened();
    }
}

// could we do this with an x4626-like contract?
contract AutoRoller is ERC4626, Trust {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    OwnableAdapter public adapter;
    SpaceFactoryLike public spaceFactory;
    
    uint256 public beforeWithdrawHookCalledCounter = 0;
    uint256 public afterDepositHookCalledCounter = 0;

    struct Series {
        address yt;
        address pt;
        address space;
    }
    Series public activeSeries;

    constructor(
        ERC20 _target,
        // address _adapter,
        address _spaceFactory,
        string memory _name,
        string memory _symbol
    ) ERC4626(_target, _name, _symbol) Trust(msg.sender) {
        // adapter
        spaceFactory = SpaceFactoryLike(_spaceFactory);
        // _target.approve(address(_adapter), type(uint256).max);
    }

    function init(OwnableAdapter _adapter) public {
        adapter = _adapter;
    }

    function roll() public {
        adapter.openSponsorWindow();

        // take TWAR from space pool and initialize a price on the new space pool
        // pay the caller some small fee (privledged role or mev?)
    }
    // Adapter callback
    function onSponsorWindowOpened() public {

        // take TWAR from space pool and initialize a price on the new space pool
        // pay the caller some small fee (privledged role or mev?)

        // withdraw, redeem

        // uint256 nextMaturity = now + 1;

        // Get token balances
        // uint256 targetBal = target.balanceOf(this);

        // assume that we can swap the pts out for target

        // Sponsor the new Series
        // (address pt, address yt) = periphery.sponsorSeries(address(adapter), nextMaturity, true);
        // address space = spaceFactory.pools(address(adapter), nextMaturity);

        // Issue PTs
        // targetBal
        // fair reserves calc given the target balance and 
        // divider.issue(address(adapter), nextMaturity, target.balanceOf(this));

        // adapter.

    }

    // should we keep 80% in the pool or something?



    function totalAssets() public view override returns (uint256) {
        // lp shares -> target and pt shares -> target

        return asset.balanceOf(address(this));
    }

    function beforeWithdraw(uint256, uint256) internal override {
        beforeWithdrawHookCalledCounter++;

        // Pull the liqudity from the pool, sell pts (or combine with yts), then give back the liquidity
        // need amm equations here for the preview & total assets functions, don't we
    }

    function afterDeposit(uint256 assets, uint256) internal override {
        // What if the adapter is the zero address?

        // we have Target here, then we put it into the current series space pool
        // are we ok with the downward pressure on the rate from a single-sided target liquidity add?
    }

    /// @notice Update the address for the Space Factory
    /// @param newSpaceFactory The Space Factory addresss to set
    function setSpaceFactory(address newSpaceFactory) external requiresTrust {
        emit SpaceFactoryChanged(address(spaceFactory), newSpaceFactory);
        spaceFactory = SpaceFactoryLike(newSpaceFactory);
    }

    // params for target series
    // lock/end contract
    // what do with the yts when initialized a price?
    // roller role,

    event SpaceFactoryChanged(address oldSpaceFactory, address newSpaceFactory);
}