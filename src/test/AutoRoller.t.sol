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
    Periphery periphery;
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
        periphery = Periphery(AddressBook.PERIPHERY_1_3_0);
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
        vm.record();
        vm.assume(lad != address(this)); // For any address other than the testing contract

        // 1. Impersonate the fuzzed address and try to update admin params
        vm.startPrank(lad);
        vm.expectRevert("UNTRUSTED");
        autoRoller.setParam("SPACE_FACTORY", address(0xbabe));

        vm.expectRevert("UNTRUSTED");
        autoRoller.setParam("PERIPHERY", address(0xbabe));

        vm.expectRevert("UNTRUSTED");
        autoRoller.setParam("MAX_RATE", 1337);

        vm.expectRevert("UNTRUSTED");
        autoRoller.setParam("TARGET_RATE", 1337);

        vm.expectRevert("UNTRUSTED");
        autoRoller.setParam("TARGET_DURATION", 1337);

        vm.expectRevert("UNTRUSTED");
        autoRoller.setParam("COOLDOWN", 1337);

        (, bytes32[] memory writes) = vm.accesses(address(autoRoller));
        // Check that no storage slots were written to
        assertEq(writes.length, 0);
    }

    function testFuzzRoll(uint88 targetedRate) public {
        targetedRate = uint88(bound(uint256(targetedRate), 0.01e18, 2e18));

        // 1. Set a fuzzed fallback rate, which will be used when there is no oracle available.
        autoRoller.setParam("TARGET_RATE", targetedRate);

        // 2. Roll Target into the first Series.
        autoRoller.roll();

        // Check that less than 1e7 PTs & Target are leftover
        assertApproxEq(ERC20(divider.pt(address(mockAdapter), autoRoller.maturity())).balanceOf(address(autoRoller)), 0, 1e12);
        assertApproxEq(autoRoller.asset().balanceOf(address(autoRoller)), 0, 1e12);

        Space space = Space(spaceFactory.pools(address(mockAdapter), autoRoller.maturity()));
        ( , uint256[] memory balances, ) = balancerVault.getPoolTokens(space.getPoolId());
        uint256 pti = space.pti();

        uint256 stretchedImpliedRate = (balances[pti] + space.totalSupply())
            .divWadDown(balances[1 - pti].mulWadDown(mockAdapter.scale())) - 1e18;

        uint256 impliedRate = _powWad(stretchedImpliedRate + 1e18, space.ts().mulWadDown(SECONDS_PER_YEAR * 1e18)) - 1e18;

        // Check that the actual implied rate in the pool is close the fallback rate.
        assertRelApproxEq(impliedRate, targetedRate, 0.0001e18 /* 0.01% */);
    }

    function testRoll() public {
        // 1. Deposit during the initial cooldown phase.
        autoRoller.deposit(0.05e18, address(this));

        uint256 targetBalPre = target.balanceOf(address(this));
        // 2. Roll into the first Series.
        autoRoller.roll();
        uint256 targetBalPost = target.balanceOf(address(this));

        // Check that extra Target was pulled in during the roll to ensure the Vault had 0.01 unit of Target to initialize a rate with.
        assertEq(targetBalPre - targetBalPost, 0.01e18);

        // Sanity checks
        Space space = Space(spaceFactory.pools(address(mockAdapter), autoRoller.maturity()));
        assertTrue(address(space) != address(0));
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
        ERC20 yt = ERC20(divider.yt(address(mockAdapter), autoRoller.maturity()));
        assertEq(excessBal, yt.balanceOf(address(this)));
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
        uint256 targetBalPre = target.balanceOf(address(this));
        autoRoller.withdraw(0.2e18, address(this), address(this));
        uint256 targetBalPost = target.balanceOf(address(this));
        assertEq(targetBalPost - targetBalPre, 0.2e18);

        // Check that the Target dust leftover is small
        assertLt(target.balanceOf(address(autoRoller)), 1e9);
    }

    function testSettle() public {
        // 1. Roll into the first Series.
        autoRoller.roll();

        vm.expectRevert(abi.encodeWithSelector(SenseCoreErrors.OutOfWindowBoundaries.selector));
        autoRoller.settle();

        vm.warp(autoRoller.maturity() - divider.SPONSOR_WINDOW() - 1);
        vm.expectRevert(abi.encodeWithSelector(SenseCoreErrors.OutOfWindowBoundaries.selector));
        autoRoller.settle();

        ERC20 pt = ERC20(divider.pt(address(mockAdapter), autoRoller.maturity()));
        ERC20 yt = ERC20(divider.yt(address(mockAdapter), autoRoller.maturity()));

        vm.warp(autoRoller.maturity() - divider.SPONSOR_WINDOW());
        // 2. Settle the series and redeem the excess asset.
        autoRoller.settle();

        // Check that there are no PTs/YTs leftover
        assertEq(pt.balanceOf(address(autoRoller)), 0);
        assertEq(yt.balanceOf(address(autoRoller)), 0);

        assertEq(autoRoller.maturity(), autoRoller.MATURITY_NOT_SET());
    }

    function testSponsorshipWindow() public {
        (uint256 minm, uint256 maxm) = mockAdapter.getMaturityBounds();
        assertEq(minm, 0);
        assertEq(maxm, 0);

        vm.record();
        autoRoller.roll();
        (, bytes32[] memory writes) = vm.accesses(address(mockAdapter));

        assertEq(writes.length, 2);
        assertEq(writes[0], writes[1]);

        (minm, maxm) = mockAdapter.getMaturityBounds();
        assertEq(minm, 0);
        assertEq(maxm, 0);
    }

    function testFuzzMaxWithdraw(uint256 assets) public {
        autoRoller.roll();

        assets = bound(assets, 0.01e18, 100e18);

        target.mint(alice, assets);

        vm.prank(alice);
        target.approve(address(autoRoller), assets);

        vm.prank(alice);
        uint256 aliceTargetAmount = autoRoller.deposit(assets, alice);

        uint256 maxWithdraw = autoRoller.maxWithdraw(alice);
        assertRelApproxEq(maxWithdraw, assets, 0.001e18 /* 0.1% */);
    }

    function testFuzzTotalAssets(uint256 assets) public {
        autoRoller.roll();

        assets = bound(assets, 0.01e18, 100e18);

        target.mint(alice, assets);
        target.mint(bob, assets);

        vm.startPrank(alice);
        target.approve(address(autoRoller), assets);
        autoRoller.deposit(assets, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        target.approve(address(autoRoller), assets);
        autoRoller.deposit(assets, alice);
        vm.stopPrank();

        assertGt(autoRoller.totalAssets(), autoRoller.previewRedeem(autoRoller.totalSupply()));
    }

    // The following tests are adapted from Solmate's ERC4626 testing suite

    function testFuzzSingleMintRedeemActivePhase(uint256 aliceShareAmount) public {
        // 1. Roll into the first Series.
        autoRoller.roll();

        aliceShareAmount = bound(aliceShareAmount, 0.01e18, 100e18);

        target.mint(alice, aliceShareAmount);

        vm.prank(alice);
        target.approve(address(autoRoller), aliceShareAmount);

        uint256 alicePreDepositBal = target.balanceOf(alice);

        vm.prank(alice);
        // 2. Have Alice mint shares.
        uint256 aliceTargetAmount = autoRoller.mint(aliceShareAmount, alice);

        // Expect exchange rate to be close to 1:1 on initial mint.
        assertRelApproxEq(aliceShareAmount, aliceTargetAmount, 0.0001e18 /* 0.01% */);
        uint256 previewedSharesIn = autoRoller.previewWithdraw(aliceTargetAmount * 0.999e18 / 1e18);
        assertRelApproxEq(previewedSharesIn, aliceShareAmount, 0.001e18 /* 0.1% */);
        if (previewedSharesIn != aliceShareAmount) {
            // Confirm rounding expectations.
            assertGt(previewedSharesIn, aliceShareAmount * 0.999e18 / 1e18);
        }
        uint256 previewedSharesOut = autoRoller.previewDeposit(aliceTargetAmount);

        uint256 scalingFactor = 10**(18 - autoRoller.decimals());
        uint256 firstDeposit = (0.01e18 - 1) / scalingFactor + 1;

        assertRelApproxEq(previewedSharesOut, aliceShareAmount, 0.000001e18 /* 0.0001% */);
        assertRelApproxEq(autoRoller.totalSupply(), aliceShareAmount + firstDeposit, 0.001e18 /* 0.1% */);
        assertRelApproxEq(autoRoller.totalAssets(), aliceTargetAmount + firstDeposit, 0.001e18 /* 0.1% */);
        assertRelApproxEq(autoRoller.balanceOf(alice), aliceTargetAmount, 0.0001e18 /* 0.01% */);
        assertEq(target.balanceOf(alice), alicePreDepositBal - aliceTargetAmount);

        vm.prank(alice);
        autoRoller.redeem(aliceShareAmount, alice, alice);

        assertRelApproxEq(autoRoller.totalAssets(), firstDeposit, 0.001e18 /* 0.1% */);
        assertEq(autoRoller.balanceOf(alice), 0);
        assertRelApproxEq(target.balanceOf(alice), alicePreDepositBal, 0.001e18 /* 0.1% */);
    }

    function testFuzzSingleMintRedeemActivePhasePTsIn(uint256 shareAmount) public {
        // 1. Roll into the first Series.
        autoRoller.roll();

        shareAmount = bound(shareAmount, 0.001e18, 100e18);

        target.mint(alice, shareAmount * 5);
        target.mint(bob, shareAmount * 5);

        vm.prank(alice);
        target.approve(address(autoRoller), type(uint256).max);

        vm.prank(bob);
        target.approve(address(autoRoller), type(uint256).max);

        vm.prank(bob);
        // 2. Have Bob mint shares.
        autoRoller.mint(shareAmount, bob);

        // 3. Swap PTs in.
        target.mint(address(this), 1e18);
        target.approve(address(divider), 1e18);
        divider.issue(address(mockAdapter), autoRoller.maturity(), 1e18);

        ERC20 pt = ERC20(divider.pt(address(mockAdapter), autoRoller.maturity()));
        Space space = Space(spaceFactory.pools(address(mockAdapter), autoRoller.maturity()));

        pt.approve(address(balancerVault), 1e18);
        _swap(
            BalancerVault.SingleSwap({
                poolId: space.getPoolId(),
                kind: BalancerVault.SwapKind.GIVEN_IN,
                assetIn: address(pt),
                assetOut: address(autoRoller.asset()),
                amount: 0.001e18,
                userData: hex""
            })
        );

        uint256 alicePreDepositBal = target.balanceOf(alice);

        vm.prank(alice);
        // 4. Have Alice mint shares.
        uint256 aliceTargetAmount = autoRoller.mint(shareAmount, alice);

        // Expect exchange rate to be close to 1:1 on initial mint.
        uint256 previewedSharesIn1 = autoRoller.previewWithdraw(aliceTargetAmount);
        assertRelApproxEq(previewedSharesIn1, shareAmount, 0.005e18 /* 0.5% */);
        if (previewedSharesIn1 != shareAmount) {
            // Confirm rounding expectations.
            assertGt(previewedSharesIn1, shareAmount);
        }
        uint256 previewedSharesOut = autoRoller.previewDeposit(aliceTargetAmount);
        assertRelApproxEq(previewedSharesOut, shareAmount, 0.000001e18 /* 0.0001% */);
        assertEq(target.balanceOf(alice), alicePreDepositBal - aliceTargetAmount);

        target.mint(address(this), shareAmount * 2);
        target.approve(address(autoRoller), type(uint256).max);
        autoRoller.mint(shareAmount, address(this));

        uint256 previewedSharesIn2 = autoRoller.previewWithdraw(aliceTargetAmount);

        assertLt(previewedSharesIn2, previewedSharesIn1); // slippage is less, so it requires fewer shares to exit.

        vm.prank(alice);
        autoRoller.redeem(shareAmount, alice, alice);

        assertEq(autoRoller.balanceOf(alice), 0);
        assertRelApproxEq(target.balanceOf(alice), alicePreDepositBal, 0.005e18 /* 0.5% */);

        // Bob can withdraw.
        vm.prank(bob);
        autoRoller.redeem(shareAmount, bob, bob);
    }

    function testFuzzSingleDepositWithdraw(uint256 amount) public {
        // 1. Roll into the first Series.
        autoRoller.roll();

        amount = bound(amount, 0.001e18, 100e18);

        uint256 scalingFactor = 10**(18 - autoRoller.decimals());
        uint256 firstDeposit = (0.01e18 - 1) / scalingFactor + 1;

        target.mint(alice, amount);

        vm.prank(alice);
        target.approve(address(autoRoller), amount);

        uint256 alicePreDepositBal = target.balanceOf(alice);

        vm.prank(alice);
        uint256 aliceShareAmount = autoRoller.deposit(amount, alice);

        // Expect exchange rate to be 1:1 on initial deposit.
        assertRelApproxEq(autoRoller.previewWithdraw(amount * 0.999e18 / 1e18), aliceShareAmount, 0.001e18 /* 0.1% */);
        assertRelApproxEq(autoRoller.previewDeposit(amount), aliceShareAmount, 0.001e18 /* 0.1% */);
        assertEq(autoRoller.totalSupply(), aliceShareAmount + firstDeposit);
        assertRelApproxEq(autoRoller.totalAssets(), amount + firstDeposit, 0.001e18 /* 0.1% */);
        assertEq(autoRoller.balanceOf(alice), aliceShareAmount);
        assertRelApproxEq(autoRoller.convertToAssets(autoRoller.balanceOf(alice)), amount, 0.001e18 /* 0.1% */);
        assertEq(target.balanceOf(alice), alicePreDepositBal - amount);

        vm.startPrank(alice);
        autoRoller.withdraw(autoRoller.previewRedeem(autoRoller.balanceOf(alice)) * 0.99e18 / 1e18, alice, alice);
        autoRoller.redeem(autoRoller.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertRelApproxEq(autoRoller.totalAssets(), firstDeposit, 0.001e18 /* 0.1% */);
        assertEq(autoRoller.convertToAssets(autoRoller.balanceOf(alice)), 0);
        assertRelApproxEq(target.balanceOf(alice), alicePreDepositBal, 0.001e18 /* 0.1% */);
    }

    function testFuzzSingleDepositWithdrawPTsIn(uint256 amount) public {
        // 1. Roll into the first Series.
        autoRoller.roll();

        amount = bound(amount, 0.001e18, 100e18);

        uint256 scalingFactor = 10**(18 - autoRoller.decimals());
        uint256 firstDeposit = (0.01e18 - 1) / scalingFactor + 1;

        target.mint(alice, amount * 5);
        target.mint(bob, amount * 5);

        vm.prank(alice);
        target.approve(address(autoRoller), type(uint256).max);

        vm.prank(bob);
        target.approve(address(autoRoller), type(uint256).max);

        vm.prank(bob);
        // 2. Have Bob deposit.
        uint256 bobShareAmount = autoRoller.deposit(amount, bob);

        // 3. Swap PTs in.
        target.mint(address(this), 1e18);
        target.approve(address(divider), 1e18);
        divider.issue(address(mockAdapter), autoRoller.maturity(), 1e18);

        ERC20 pt = ERC20(divider.pt(address(mockAdapter), autoRoller.maturity()));
        Space space = Space(spaceFactory.pools(address(mockAdapter), autoRoller.maturity()));

        pt.approve(address(balancerVault), 1e18);
        _swap(
            BalancerVault.SingleSwap({
                poolId: space.getPoolId(),
                kind: BalancerVault.SwapKind.GIVEN_IN,
                assetIn: address(pt),
                assetOut: address(autoRoller.asset()),
                amount: 0.001e18,
                userData: hex""
            })
        );

        uint256 alicePreDepositBal = target.balanceOf(alice);

        vm.prank(alice);
        // 4. Have Alice deposit.
        uint256 aliceShareAmount = autoRoller.deposit(amount, alice);

        // Expect exchange rate to be 1:1 on initial deposit.
        assertRelApproxEq(autoRoller.previewWithdraw(amount * 0.999e18 / 1e18), aliceShareAmount, 0.005e18 /* 0.5% */);
        assertRelApproxEq(autoRoller.previewDeposit(amount), aliceShareAmount, 0.005e18 /* 0.5% */);
        assertEq(autoRoller.totalSupply(), aliceShareAmount + bobShareAmount + firstDeposit);
        assertEq(autoRoller.balanceOf(alice), aliceShareAmount);
        assertEq(target.balanceOf(alice), alicePreDepositBal - amount);

        vm.startPrank(alice);
        autoRoller.withdraw(autoRoller.previewRedeem(autoRoller.balanceOf(alice)) * 0.99e18 / 1e18, alice, alice);
        autoRoller.redeem(autoRoller.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertEq(autoRoller.convertToAssets(autoRoller.balanceOf(alice)), 0);
        assertRelApproxEq(target.balanceOf(alice), alicePreDepositBal, 0.001e18 /* 0.1% */);
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

    function _powWad(uint256 x, uint256 y) internal pure returns (uint256) {
        require(x < 1 << 255);
        require(y < 1 << 255);

        return uint256(FixedPointMathLib.powWad(int256(x), int256(y))); // Assumption: x cannot be negative so this result will never be.
    }
}