// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.11;

import { Vm } from "forge-std/Vm.sol";
import { stdCheats } from "forge-std/stdlib.sol";
import { console } from "forge-std/console.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { MockERC20 } from "solmate/test/utils/mocks/MockERC20.sol";
import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";

import { BaseAdapter } from "sense-v1-core/adapters/BaseAdapter.sol";
import { Divider, TokenHandler } from "sense-v1-core/Divider.sol";
import { Periphery } from "sense-v1-core/Periphery.sol";
import { YT } from "sense-v1-core/tokens/YT.sol";
import { Errors as SenseCoreErrors } from "sense-v1-utils/libs/Errors.sol";

import { Space } from "../interfaces/Space.sol";
import { BalancerVault } from "../interfaces/BalancerVault.sol";

import { MockAdapter } from "./utils/MockOwnedAdapter.sol";
import { AddressBook } from "./utils/AddressBook.sol";
import { AutoRoller, SpaceFactoryLike } from "../AutoRoller.sol";


contract AutoRollerTest is DSTestPlus, stdCheats {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int128;

    Vm internal constant vm = Vm(HEVM_ADDRESS);
    uint256 public constant SECONDS_PER_YEAR = 31536000;

    address alice = address(0x1337);
    address bob = address(0x133701);

    MockERC20 target;
    MockERC20 underlying;
    MockAdapter mockAdapter;

    SpaceFactoryLike spaceFactory;
    BalancerVault balancerVault;
    Divider divider;
    ERC20 pt;
    ERC20 yt;

    AutoRoller autoRoller;

    function setUp() public {
        target     = new MockERC20("TestTarget", "TT0", 18);
        underlying = new MockERC20("TestUnderlying", "TU0", 18);

        (balancerVault, spaceFactory) = (
            BalancerVault(AddressBook.BALANCER_VAULT),
            SpaceFactoryLike(AddressBook.SPACE_FACTORY_1_3_0)
        );
        Periphery periphery = Periphery(AddressBook.PERIPHERY_1_3_0);
        divider = Divider(spaceFactory.divider());

        vm.label(address(spaceFactory), "SpaceFactory");
        vm.label(address(divider), "Divider");
        vm.label(address(periphery), "Periphery");
        vm.label(address(balancerVault), "BalancerVault");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        BaseAdapter.AdapterParams memory mockAdapterParams = BaseAdapter.AdapterParams({
            oracle: address(0),
            stake: address(new MockERC20("Stake", "ST", 18)), // stake size is 0, so the we don't actually need any stake token
            stakeSize: 0,
            minm: 0, // 0 minm, so there's not lower bound on future maturity
            maxm: type(uint64).max, // large maxm, so there's not upper bound on future maturity
            mode: 0, // monthly maturities
            tilt: 0, // no principal reserved for YTs
            level: 31 // default level, everything is allowed except for the redemption cb
        });

        mockAdapter = new MockAdapter(
            address(divider),
            address(target),
            address(underlying),
            mockAdapterParams
        );

        autoRoller = new AutoRoller(target, divider, address(periphery), address(spaceFactory), address(balancerVault), mockAdapter);

        mockAdapter.setIsTrusted(address(autoRoller), true);

        // Start multisig (admin) prank calls   
        vm.startPrank(AddressBook.SENSE_MULTISIG);
        periphery.onboardAdapter(address(mockAdapter), true);
        divider.setGuard(address(mockAdapter), type(uint256).max);
        vm.stopPrank();

        target.mint(address(this), 2e18);
        target.approve(address(autoRoller), 2e18);
    }

    // Auth

    function testFuzzUpdateAdminParams(address lad) public {
        hevm.record();
        hevm.assume(lad != address(this)); // For any address other than the testing contract

        // 1. Impersonate the fuzzed address and try to update admin params
        hevm.startPrank(lad);
        hevm.expectRevert("UNTRUSTED");
        autoRoller.setSpaceFactory(address(0xbabe));

        hevm.expectRevert("UNTRUSTED");
        autoRoller.setPeriphery(address(0xbabe));

        hevm.expectRevert("UNTRUSTED");
        autoRoller.setMaxRate(1337);

        hevm.expectRevert("UNTRUSTED");
        autoRoller.setFallbackRate(1337);

        hevm.expectRevert("UNTRUSTED");
        autoRoller.setTargetDuration(1337);

        hevm.expectRevert("UNTRUSTED");
        autoRoller.setCooldown(1337);

        (, bytes32[] memory writes) = hevm.accesses(address(autoRoller));
        // Check that no storage slots were written to
        assertEq(writes.length, 0);
    }

    function testFuzzRoll(uint88 fallbackRate) public {
        fallbackRate = uint88(bound(uint256(fallbackRate), 0.01e18, 2e18));

        // 1. Set a fuzzed fallback rate, which will be used when there is no oracle available.
        autoRoller.setFallbackRate(fallbackRate);

        // 2. Roll Target into the first Series.
        autoRoller.roll();

        // Check that less than 1e7 PTs & Target are leftover
        assertApproxEq(autoRoller.pt().balanceOf(address(autoRoller)), 0, 1e12);
        assertApproxEq(autoRoller.asset().balanceOf(address(autoRoller)), 0, 1e12);

        Space space = autoRoller.space();
        ( , uint256[] memory balances, ) = balancerVault.getPoolTokens(space.getPoolId());
        uint256 pti = space.pti();

        uint256 stretchedImpliedRate = (balances[pti] + space.totalSupply())
            .divWadDown(balances[1 - pti].mulWadDown(mockAdapter.scale())) - 1e18;

        uint256 impliedRate = _powWad(stretchedImpliedRate + 1e18, space.ts().mulWadDown(SECONDS_PER_YEAR * 1e18)) - 1e18;

        // Check that the actual implied rate in the pool is close the fallback rate.
        assertRelApproxEq(impliedRate, fallbackRate, 0.0001e18 /* 0.01% */);
    }

    function testRoll() public {
        // 1. Deposit during the initial cooldown phase.
        autoRoller.deposit(0.05e18, address(this));

        uint256 targetBalPre = target.balanceOf(address(this));
        // 2. Roll into the first Series.
        autoRoller.roll();
        uint256 targetBalPost = target.balanceOf(address(this));

        // Check that extra Target was pulled in during the roll to ensure the Vault had 1 unit of Target to initialize a rate with.
        assertEq(targetBalPre - targetBalPost, 0.01e18 + 1);

        // Sanity checks
        assertEq(address(autoRoller.space()), address(spaceFactory.pools(address(mockAdapter), autoRoller.maturity())));
        assertLt(autoRoller.maturity(), autoRoller.MATURITY_NOT_SET());
    }

    function testEject() public {
        // 1. Deposit during the initial cooldown phase.
        autoRoller.deposit(1e18, address(this));

        // 2. Roll into the first Series.
        autoRoller.roll();

        // 3. Eject everything.
        ( , uint256 excessBal, bool isExcessPTs) = autoRoller.eject(autoRoller.balanceOf(address(this)), address(this), address(this));

        // Expect a little YT excess.
        assertBoolEq(isExcessPTs, false);
        assertGt(excessBal, 1e6);
        assertLt(excessBal, 1e16);
        assertEq(excessBal, autoRoller.yt().balanceOf(address(this)));
    }

    function testCooldown() public {
        autoRoller.roll();

        vm.expectRevert(abi.encodeWithSelector(AutoRoller.RollWindowNotOpen.selector));
        autoRoller.roll();

        uint256 maturity = autoRoller.maturity();
        
        vm.warp(maturity);

        vm.expectRevert(abi.encodeWithSelector(AutoRoller.RollWindowNotOpen.selector));
        autoRoller.roll();

        vm.warp(maturity + autoRoller.cooldown());

        vm.expectRevert(abi.encodeWithSelector(AutoRoller.RollWindowNotOpen.selector));
        autoRoller.roll();

        vm.warp(maturity);

        autoRoller.settle();

        vm.expectRevert(abi.encodeWithSelector(AutoRoller.RollWindowNotOpen.selector));
        autoRoller.roll();

        vm.warp(maturity + autoRoller.cooldown());
        autoRoller.roll();
    }

    function testDepositWithdraw() public {
        // 1. Deposit during the initial cooldown phase.
        autoRoller.deposit(0.2e18, address(this));
        assertEq(autoRoller.balanceOf(address(this)), 0.2e18);

        // 2. Deposit again, this time minting the Vault shares to alice.
        autoRoller.deposit(0.2e18, alice);
        assertEq(autoRoller.balanceOf(alice), 0.2e18);

        vm.prank(alice);
        // 3. Withdraw all of Alice's Target.
        autoRoller.withdraw(0.2e18, alice, alice);
        assertEq(autoRoller.balanceOf(alice), 0);
        assertEq(target.balanceOf(alice), 0.2e18);

        // 4. Roll the Target into the first Series.
        autoRoller.roll();

        // 5. Deposit during the first active phase.
        autoRoller.deposit(0.3e18, address(this));
        assertRelApproxEq(autoRoller.balanceOf(address(this)), 0.5e18, 0.0001e18 /* 0.01% */);

        // 6. Withdraw while still in the active phase.
        // autoRoller.withdraw(0.2e18, address(this), address(this)); todo verify
    }

    function testSettle() public {
        // 1. Roll into the first Series.
        autoRoller.roll();

        vm.expectRevert(abi.encodeWithSelector(SenseCoreErrors.OutOfWindowBoundaries.selector));
        autoRoller.settle();

        vm.warp(autoRoller.maturity() - divider.SPONSOR_WINDOW() - 1);
        vm.expectRevert(abi.encodeWithSelector(SenseCoreErrors.OutOfWindowBoundaries.selector));
        autoRoller.settle();

        ERC20 pt = autoRoller.pt();
        YT yt = autoRoller.yt();

        vm.warp(autoRoller.maturity() - divider.SPONSOR_WINDOW());
        // 2. Settle the series and redeem the excess asset.
        autoRoller.settle();

        // Check that there are no PTs/YTs leftover
        assertEq(pt.balanceOf(address(autoRoller)), 0);
        assertEq(yt.balanceOf(address(autoRoller)), 0);

        assertEq(autoRoller.maturity(), autoRoller.MATURITY_NOT_SET());
    }

    // The following tests are adapted from Solmate's ERC4626 testing suite

    function testFuzzSingleMintRedeemActivePhase(uint256 aliceShareAmount) public {
        // 1. Roll into the first Series.
        autoRoller.roll();

        aliceShareAmount = bound(aliceShareAmount, 0.01e18, 100e18);

        target.mint(alice, aliceShareAmount);

        hevm.prank(alice);
        target.approve(address(autoRoller), aliceShareAmount);

        uint256 alicePreDepositBal = target.balanceOf(alice);

        hevm.prank(alice);
        uint256 aliceTargetAmount = autoRoller.mint(aliceShareAmount, alice);

        // Expect exchange rate to be close to 1:1 on initial mint.
        assertRelApproxEq(aliceShareAmount, aliceTargetAmount, 0.0001e18 /* 0.01% */);
        // assertEq(autoRoller.previewWithdraw(aliceShareAmount), aliceTargetAmount);
        uint256 previewedShares = autoRoller.previewDeposit(aliceTargetAmount);
        assertRelApproxEq(previewedShares, aliceShareAmount, 0.000001e18 /* 0.0001% */);
        if (previewedShares != aliceShareAmount) {
            // Confirm rounding expectations.
            assertLt(previewedShares, aliceShareAmount);
        }
        assertRelApproxEq(autoRoller.totalSupply(), aliceShareAmount + 0.01e18, 0.00001e18 /* 0.001% */);
        assertRelApproxEq(autoRoller.totalAssets(), aliceTargetAmount + 0.01e18, 0.00001e18 /* 0.001% */);
        assertRelApproxEq(autoRoller.balanceOf(alice), aliceTargetAmount, 0.0001e18 /* 0.01% */);
        assertEq(target.balanceOf(alice), alicePreDepositBal - aliceTargetAmount);

        hevm.prank(alice);
        autoRoller.redeem(aliceShareAmount, alice, alice);

        assertRelApproxEq(autoRoller.totalAssets(), 0.01e18, 0.0001e18 /* 0.01% */);
        assertEq(autoRoller.balanceOf(alice), 0);
        assertRelApproxEq(target.balanceOf(alice), alicePreDepositBal, 0.000001e18 /* 0.0001% */);
    }

    function _powWad(uint256 x, uint256 y) internal pure returns (uint256) {
        require(x < 1 << 255);
        require(y < 1 << 255);

        return uint256(FixedPointMathLib.powWad(int256(x), int256(y))); // Assumption: x cannot be negative so this result will never be.
    }
}