// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { ERC4626 } from "solmate/mixins/ERC4626.sol";
import { MockERC20 } from "solmate/test/utils/mocks/MockERC20.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { BaseAdapter } from "sense-v1-core/adapters/abstract/BaseAdapter.sol";
import { Divider, TokenHandler } from "sense-v1-core/Divider.sol";
import { Periphery } from "sense-v1-core/Periphery.sol";
import { YT } from "sense-v1-core/tokens/YT.sol";
import { Errors as SenseCoreErrors } from "sense-v1-utils/libs/Errors.sol";

import { Space } from "../interfaces/Space.sol";
import { BalancerVault } from "../interfaces/BalancerVault.sol";

import { MockOwnableAdapter } from "./utils/MockOwnedAdapter.sol";
import { AddressBook } from "./utils/AddressBook.sol";
import { Permit2Helper } from "./utils/Permit2Helper.sol";
import { AutoRoller, RollerUtils, SpaceFactoryLike, DividerLike, PeripheryLike, OwnedAdapterLike } from "../AutoRoller.sol";
import { AutoRollerFactory } from "../AutoRollerFactory.sol";
import { RollerPeriphery } from "../RollerPeriphery.sol";

interface Authentication {
    function getActionId(bytes4) external returns (bytes32);
    function grantRole(bytes32,address) external;
}

interface ProtocolFeesController {
    function setSwapFeePercentage(uint256) external;
}

interface OldPeripheryLike {
    function swapYTsForTarget(address adapter, uint256 maturity, uint256 ytBal) external;
}

contract AutoRollerTest is Test, Permit2Helper {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int128;
    using SafeTransferLib for ERC20;

    uint256 public constant SECONDS_PER_YEAR = 31536000;
    uint256 public constant STAKE_SIZE = 0.1e18;

    address public constant REWARDS_RECIPIENT = address(1);
    uint256 public constant TARGET_DURATION = 3;
    uint256 public constant TARGETED_RATE = 2.9e18;

    uint256 scalingFactor;

    MockERC20 target;
    MockERC20 underlying;
    ERC20 stake;
    MockOwnableAdapter mockAdapter;
    RollerUtils utils;

    SpaceFactoryLike spaceFactory;
    BalancerVault balancerVault;
    Periphery periphery;
    Divider divider;
    ERC20 pt;
    ERC20 yt;

    BaseAdapter.AdapterParams mockAdapterParams;

    RollerPeriphery rollerPeriphery;
    AutoRollerFactory arFactory;
    AutoRoller autoRoller;

    function setUp() public {
        vm.warp(1678336715); // Wed Mar 08 2023 23:38:35 GMT-0500

        target     = new MockERC20("TestTarget", "TT0", 18);
        underlying = new MockERC20("TestUnderlying", "TU0", 18);

        scalingFactor = 10**(18 - target.decimals());

        (balancerVault, spaceFactory, divider, periphery) = (
            BalancerVault(AddressBook.BALANCER_VAULT),
            SpaceFactoryLike(AddressBook.SPACE_FACTORY_1_3_0),
            Divider(AddressBook.DIVIDER_1_2_0),
            Periphery(payable(AddressBook.PERIPHERY_2_0_0))
        );

        vm.label(address(spaceFactory), "SpaceFactory");
        vm.label(address(divider), "Divider");
        vm.label(address(periphery), "Periphery");
        vm.label(address(balancerVault), "BalancerVault");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        stake = ERC20(AddressBook.DAI);

        mockAdapterParams = BaseAdapter.AdapterParams({
            oracle: address(0),
            stake: address(stake),
            stakeSize: STAKE_SIZE,
            minm: 0, // 0 minm, so there's not lower bound on future maturity
            maxm: type(uint64).max, // large maxm, so there's not upper bound on future maturity
            mode: 0, // monthly maturities
            tilt: 0, // no principal reserved for YTs
            level: 31 // default level, everything is allowed except for the redemption cb
        });

        mockAdapter = new MockOwnableAdapter(
            address(divider),
            address(target),
            address(underlying),
            mockAdapterParams
        );

        utils = new RollerUtils(address(divider));

        rollerPeriphery = new RollerPeriphery(permit2, address(0));

        arFactory = new AutoRollerFactory(
            DividerLike(address(divider)),
            address(balancerVault),
            address(periphery),
            address(rollerPeriphery),
            utils
        );

        mockAdapter.setIsTrusted(address(arFactory), true);
        rollerPeriphery.setIsTrusted(address(arFactory), true);

        autoRoller = arFactory.create(
            OwnedAdapterLike(address(mockAdapter)),
            REWARDS_RECIPIENT,
            TARGET_DURATION
        );

        // Start multisig (admin) prank calls   
        vm.prank(AddressBook.SENSE_MULTISIG);
        periphery.onboardAdapter(address(mockAdapter), true);

        vm.prank(AddressBook.SENSE_MULTISIG);
        divider.setGuard(address(mockAdapter), type(uint256).max);

        // vm.stopPrank();

        // Mint Target
        target.mint(address(this), 2e18);
        target.approve(address(autoRoller), 2e18);

        // Mint Stake
        deal(address(stake), address(this), 1e18);
        stake.allowance(address(this), address(autoRoller));
        stake.safeApprove(address(autoRoller), 1e18);
    }

    // Auth

    function testFuzzUpdateAdminParams(address lad) public {
        vm.record();
        vm.assume(lad != address(this)); // For any address other than the testing contract

        // 1. Impersonate the fuzzed address and try to update admin params
        vm.startPrank(lad);
        vm.expectRevert();
        autoRoller.setParam("SPACE_FACTORY", address(0xbabe));

        vm.expectRevert();
        autoRoller.setParam("PERIPHERY", address(0xbabe));

        vm.expectRevert();
        autoRoller.setParam("OWNER", address(0xbabe));

        vm.expectRevert();
        autoRoller.setParam("MAX_RATE", 1337);

        vm.expectRevert();
        autoRoller.setParam("TARGET_DURATION", 1337);

        vm.expectRevert();
        autoRoller.setParam("COOLDOWN", 1337);

        (, bytes32[] memory writes) = vm.accesses(address(autoRoller));
        // Check that no storage slots were written to
        assertEq(writes.length, 0);
    }

    function testFuzzRoll(uint88 targetedRate) public {
        targetedRate = uint88(bound(uint256(targetedRate), 0.01e18, 50e18));

        // 1. Set a fuzzed fallback rate on a new auto roller.
        AutoRoller autoRoller = arFactory.create(
            OwnedAdapterLike(address(mockAdapter)),
            REWARDS_RECIPIENT,
            TARGET_DURATION
        );

        target.approve(address(autoRoller), 2e18);
        stake.safeApprove(address(autoRoller), 0.2e18);

        autoRoller.roll();

        uint256 maturity = autoRoller.maturity();
        vm.warp(maturity);

        vm.mockCall(address(utils), abi.encodeWithSelector(utils.getNewTargetedRate.selector), abi.encode(targetedRate));
        autoRoller.settle();

        vm.warp(maturity + autoRoller.cooldown());

        mockAdapter.setIsTrusted(address(autoRoller), true);

        // 2. Roll Target into the next series (using fuzz param targeted rate).
        autoRoller.roll();

        maturity = autoRoller.maturity();

        // Check that less than 1e7 PTs & Target are leftover
        assertApproxEqAbs(ERC20(divider.pt(address(mockAdapter), maturity)).balanceOf(address(autoRoller)), 0, 1e12);
        assertApproxEqAbs(autoRoller.asset().balanceOf(address(autoRoller)), 0, 1e12);

        Space space = Space(spaceFactory.pools(address(mockAdapter), maturity));
        ( , uint256[] memory balances, ) = balancerVault.getPoolTokens(space.getPoolId());
        uint256 pti = space.pti();

        balances[pti] = balances[pti] * scalingFactor;
        balances[1 - pti] = balances[1 - pti] * scalingFactor;

        uint256 stretchedImpliedRate = (balances[pti] + space.adjustedTotalSupply())
            .divWadDown(balances[1 - pti].mulWadDown(mockAdapter.scale())) - 1e18;

        // Check that the actual stretched implied rate in the pool is close the targeted rate.
        assertApproxEqRel(stretchedImpliedRate, targetedRate, 0.01e18 /* 0.01% */);
    }

    function testRoll() public {
        // 1. Deposit during the initial cooldown phase.
        autoRoller.deposit(0.05e18, address(this));

        uint256 targetBalPre = target.balanceOf(address(this));
        uint256 stakeBalPre = stake.balanceOf(address(this));

        // Can't open sponsor window directly
        (, , uint256 stakeSize) = mockAdapter.getStakeAndTarget();
        vm.expectRevert(abi.encodeWithSelector(AutoRoller.OnlyAdapter.selector));
        autoRoller.onSponsorWindowOpened(ERC20(address(stake)), stakeSize);

        // 2. Roll into the first Series.
        autoRoller.roll();
        uint256 targetBalPost = target.balanceOf(address(this));
        uint256 stakeBalPost = stake.balanceOf(address(this));

        // Check that extra Target was pulled in during the roll to ensure the Vault had 0.01 unit of Target to initialize a rate with.
        assertEq(targetBalPre - targetBalPost, 0.01e18 / scalingFactor);
        assertEq(stakeBalPre - stakeBalPost, STAKE_SIZE);

        // Sanity checks
        Space space = Space(spaceFactory.pools(address(mockAdapter), autoRoller.maturity()));
        assertTrue(address(space) != address(0));
        assertLt(autoRoller.maturity(), type(uint32).max);
    }

    function testEject() public {
        // 1. Deposit during the initial cooldown phase.
        autoRoller.deposit(1e18, address(this));

        // Can only eject during an active phase
        uint256 shareBal = autoRoller.balanceOf(address(this));
        vm.expectRevert(abi.encodeWithSelector(AutoRoller.ActivePhaseOnly.selector));
        autoRoller.eject(shareBal, address(this), address(this));

        // 2. Roll into the first Series.
        autoRoller.roll();

        // 3. Eject everything.
        ( , uint256 excessBal, bool isExcessPTs) = autoRoller.eject(autoRoller.balanceOf(address(this)), address(this), address(this));

        // Expect just a little YT excess.
        assertEq(isExcessPTs, false);
        assertLt(excessBal, 1e16);
        assertEq(excessBal, ERC20(divider.yt(address(mockAdapter), autoRoller.maturity())).balanceOf(address(this)));
    }

    function testFuzzEjectYieldCollection(uint256 scaleDst, uint256 deposit) public {
        mockAdapter.setScale(1.1e18);

        scaleDst = bound(scaleDst, 1.1e18, 10000e18);
        deposit = bound(deposit, 1e18, 10000e18);

        // 1. Deposit during the initial cooldown phase.
        target.mint(address(this), deposit);
        target.approve(address(autoRoller), deposit + 1e18);
        autoRoller.deposit(deposit, address(this));

        // 2. Roll into the first Series.
        autoRoller.roll();

        // Double the scale so that yield accrued will be exactly half of the escrowed asset.
        mockAdapter.setScale(scaleDst);

        uint256 targetBalPre = target.balanceOf(address(this));

        uint256 shareBal = autoRoller.balanceOf(address(this));

        autoRoller.eject(shareBal / 2, address(this), address(this));

        uint256 targetBalPost1 = target.balanceOf(address(this));

        autoRoller.eject(shareBal / 2, address(this), address(this));

        uint256 targetBalPost2 = target.balanceOf(address(this));

        assertApproxEqAbs(targetBalPost2 - targetBalPost1, targetBalPost1 - targetBalPre, 5);
    }

    function testCooldown() public {
        uint256 cooldown = 10 days;
        autoRoller.setParam("COOLDOWN", cooldown);
        autoRoller.roll();

        vm.expectRevert(abi.encodeWithSelector(AutoRoller.RollWindowNotOpen.selector));
        autoRoller.roll();

        uint256 maturity = autoRoller.maturity();
        
        vm.warp(maturity);

        vm.expectRevert(abi.encodeWithSelector(AutoRoller.RollWindowNotOpen.selector));
        autoRoller.roll();

        vm.warp(maturity + cooldown);

        vm.expectRevert(abi.encodeWithSelector(AutoRoller.RollWindowNotOpen.selector));
        autoRoller.roll();

        vm.warp(maturity);

        // Since alice didn't roll, she can't settle
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AutoRoller.InvalidSettler.selector));
        autoRoller.settle();

        autoRoller.settle();

        vm.expectRevert(abi.encodeWithSelector(AutoRoller.RollWindowNotOpen.selector));
        autoRoller.roll();

        vm.warp(maturity + cooldown);
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
        assertApproxEqRel(autoRoller.balanceOf(address(this)), 0.5e18, 0.0001e18 /* 0.01% */);

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

        assertEq(autoRoller.maturity(), type(uint32).max);
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

    function testClaimRewards() public {
        autoRoller.roll();

        MockERC20 rewardToken = new MockERC20("RewardsToken", "RT", 18);

        uint256 MINT_AMT = 1.1e18;
        rewardToken.mint(address(autoRoller), MINT_AMT);

        ERC20 pt = ERC20(divider.pt(address(mockAdapter), autoRoller.maturity()));
        ERC20 yt = ERC20(divider.yt(address(mockAdapter), autoRoller.maturity()));
        Space space = Space(spaceFactory.pools(address(mockAdapter), autoRoller.maturity()));

        vm.expectRevert();
        autoRoller.claimRewards(ERC20(address(target)));

        vm.expectRevert();
        autoRoller.claimRewards(ERC20(address(pt)));

        vm.expectRevert();
        autoRoller.claimRewards(ERC20(address(yt)));

        vm.expectRevert();
        autoRoller.claimRewards(ERC20(address(space)));

        assertEq(rewardToken.balanceOf(REWARDS_RECIPIENT), 0);
        autoRoller.claimRewards(ERC20(address(rewardToken)));
        assertEq(rewardToken.balanceOf(REWARDS_RECIPIENT), MINT_AMT);
    }

    function testFuzzMaxWithdraw(uint256 assets) public {
        autoRoller.roll();

        assets = bound(assets, 0.01e18, 100e18);

        target.mint(alice, assets);

        vm.prank(alice);
        target.approve(address(autoRoller), assets);

        vm.prank(alice);
        autoRoller.deposit(assets, alice);

        uint256 maxWithdraw = autoRoller.maxWithdraw(alice);
        assertApproxEqRel(maxWithdraw, assets, 0.001e18 /* 0.1% */);
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

        vm.warp(autoRoller.maturity());
        autoRoller.settle();

        assertEq(autoRoller.totalAssets(), autoRoller.previewRedeem(autoRoller.totalSupply()));
    }

    function testFuzzMintRedeemCooldown(uint256 assets) public {
        assets = bound(assets, 0.01e18, 100e18);

        target.mint(alice, assets);

        vm.prank(alice);
        target.approve(address(autoRoller), assets);

        uint256 previewedMint = autoRoller.previewMint(assets);
        vm.prank(alice);
        uint256 actualMint = autoRoller.mint(assets, alice);
        assertEq(actualMint, previewedMint);

        uint256 previewedRedeem = autoRoller.previewRedeem(actualMint);

        vm.prank(alice);
        uint256 actualRedeem = autoRoller.redeem(actualMint, alice, alice);
        assertEq(actualRedeem, previewedRedeem);
    }

    // The following tests are adapted from Solmate's ERC4626 testing suite

    function testFuzzSingleMintRedeemActivePhase2(uint256 aliceShareAmount) public {
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
        assertApproxEqRel(aliceShareAmount, aliceTargetAmount, 0.0001e18 /* 0.01% */);
        uint256 previewedSharesIn = autoRoller.previewWithdraw(aliceTargetAmount * 0.999e18 / 1e18);
        assertApproxEqRel(previewedSharesIn, aliceShareAmount, 0.001e18 /* 0.1% */);
        if (previewedSharesIn != aliceShareAmount) {
            // Confirm rounding expectations.
            assertGt(previewedSharesIn, aliceShareAmount * 0.999e18 / 1e18);
        }
        uint256 previewedSharesOut = autoRoller.previewDeposit(aliceTargetAmount);

        uint256 scalingFactor = 10**(18 - autoRoller.decimals());
        uint256 firstDeposit = (0.01e18 - 1) / scalingFactor + 1;

        assertApproxEqRel(previewedSharesOut, aliceShareAmount, 0.00001e18 /* 0.0001% */);
        assertApproxEqRel(autoRoller.totalSupply(), aliceShareAmount + firstDeposit, 0.001e18 /* 0.1% */);
        assertApproxEqRel(autoRoller.totalAssets(), aliceTargetAmount + firstDeposit, 0.001e18 /* 0.1% */);
        assertApproxEqRel(autoRoller.balanceOf(alice), aliceTargetAmount, 0.0001e18 /* 0.01% */);
        assertEq(target.balanceOf(alice), alicePreDepositBal - aliceTargetAmount);

        vm.prank(alice);
        autoRoller.redeem(aliceShareAmount, alice, alice);

        assertApproxEqRel(autoRoller.totalAssets(), firstDeposit, 0.001e18 /* 0.1% */);
        assertEq(autoRoller.balanceOf(alice), 0);
        assertApproxEqRel(target.balanceOf(alice), alicePreDepositBal, 0.001e18 /* 0.1% */);
    }

    function testFuzzSingleMintRedeemActivePhasePTsIn(uint256 shareAmount) public {
        // 1. Roll into the first Series.
        autoRoller.roll();

        shareAmount = bound(shareAmount, 0.01e18, 100e18);

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
        assertApproxEqRel(previewedSharesIn1, shareAmount, 0.005e18 /* 0.5% */);
        if (previewedSharesIn1 != shareAmount) {
            // Confirm rounding expectations.
            assertGt(previewedSharesIn1, shareAmount);
        }
        uint256 previewedSharesOut = autoRoller.previewDeposit(aliceTargetAmount);
        assertApproxEqRel(previewedSharesOut, shareAmount, 0.000001e18 /* 0.0001% */);
        assertEq(target.balanceOf(alice), alicePreDepositBal - aliceTargetAmount);

        target.mint(address(this), shareAmount * 2);
        target.approve(address(autoRoller), type(uint256).max);
        autoRoller.mint(shareAmount, address(this));

        uint256 previewedSharesIn2 = autoRoller.previewWithdraw(aliceTargetAmount);

        assertLt(previewedSharesIn2, previewedSharesIn1); // slippage is less, so it requires fewer shares to exit.

        vm.prank(alice);
        autoRoller.redeem(shareAmount, alice, alice);

        assertEq(autoRoller.balanceOf(alice), 0);
        assertApproxEqRel(target.balanceOf(alice), alicePreDepositBal, 0.005e18 /* 0.5% */);

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
        assertApproxEqRel(autoRoller.previewWithdraw(amount * 0.999e18 / 1e18), aliceShareAmount, 0.001e18 /* 0.1% */);
        assertApproxEqRel(autoRoller.previewDeposit(amount), aliceShareAmount, 0.001e18 /* 0.1% */);
        assertEq(autoRoller.totalSupply(), aliceShareAmount + firstDeposit);
        assertApproxEqRel(autoRoller.totalAssets(), amount + firstDeposit, 0.001e18 /* 0.1% */);
        assertEq(autoRoller.balanceOf(alice), aliceShareAmount);
        assertApproxEqRel(autoRoller.convertToAssets(autoRoller.balanceOf(alice)), amount, 0.001e18 /* 0.1% */);
        assertEq(target.balanceOf(alice), alicePreDepositBal - amount);

        vm.startPrank(alice);
        autoRoller.withdraw(autoRoller.previewRedeem(autoRoller.balanceOf(alice)) * 0.99e18 / 1e18, alice, alice);
        autoRoller.redeem(autoRoller.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertApproxEqRel(autoRoller.totalAssets(), firstDeposit, 0.001e18 /* 0.1% */);
        assertEq(autoRoller.convertToAssets(autoRoller.balanceOf(alice)), 0);
        assertApproxEqRel(target.balanceOf(alice), alicePreDepositBal, 0.001e18 /* 0.1% */);
    }

    function testFuzzSingleDepositWithdrawPTsIn(uint256 amount) public {
        // 1. Roll into the first Series.
        autoRoller.roll();

        amount = bound(amount, 0.01e18, 100e18);

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
        assertApproxEqRel(autoRoller.previewWithdraw(amount * 0.999e18 / 1e18), aliceShareAmount, 0.005e18 /* 0.5% */);
        return;

        assertApproxEqRel(autoRoller.previewDeposit(amount), aliceShareAmount, 0.005e18 /* 0.5% */);
        assertEq(autoRoller.totalSupply(), aliceShareAmount + bobShareAmount + firstDeposit);
        assertEq(autoRoller.balanceOf(alice), aliceShareAmount);
        assertEq(target.balanceOf(alice), alicePreDepositBal - amount);

        vm.startPrank(alice);
        autoRoller.withdraw(autoRoller.previewRedeem(autoRoller.balanceOf(alice)) * 0.99e18 / 1e18, alice, alice);
        autoRoller.redeem(autoRoller.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertEq(autoRoller.convertToAssets(autoRoller.balanceOf(alice)), 0);
        assertApproxEqRel(target.balanceOf(alice), alicePreDepositBal, 0.001e18 /* 0.1% */);
    }

    // FPS Audit SC.1 test

    function testMintSandwich() public {
        // 1. Large whale deposit from a third party (ensures sufficient liquidity later in the attack)
        target.mint(address(this), 10e18);
        target.approve(address(autoRoller), type(uint256).max);
        autoRoller.deposit(10e18, alice);

        // 2. Roll the Target into the first Series.
        autoRoller.roll();

        // 3. Deposit and PT donation (1st half of sandwich)
        uint256 attackerOutflow = 0;
        uint256 before = target.balanceOf(address(this));
        autoRoller.deposit(1e18, address(this));
        uint256 aafter = target.balanceOf(address(this));
        attackerOutflow += before - aafter;

        ERC20 pt = ERC20(divider.pt(address(mockAdapter), autoRoller.maturity()));
        ERC20 yt = ERC20(divider.yt(address(mockAdapter), autoRoller.maturity()));
        target.mint(address(this), 1e18);
        target.approve(address(divider), 1e18);
        before = target.balanceOf(address(this));
        uint256 ptBal = pt.balanceOf(address(this));
        uint256 ytBal = yt.balanceOf(address(this));
        divider.issue(address(mockAdapter), autoRoller.maturity(), 1e18);
        aafter = target.balanceOf(address(this));
        ptBal = pt.balanceOf(address(this)) - ptBal;  // ptBal is now just the PTs issued, in case there was any dust balance before
        ytBal = yt.balanceOf(address(this)) - ytBal;  // same for ytBal; we'll convert these back to target at the end
        attackerOutflow += before - aafter;
        pt.transfer(address(autoRoller), ptBal);

        // 3. Mint shares
        address mintor = address(new Mintooor(autoRoller, target));
        uint256 beforeBal = 5e18;  // mintor has more target than they intend to deposit
        target.mint(mintor, beforeBal);
        Mintooor(mintor).mint(0.5e18);
        // uint256 afterBal = target.balanceOf(mintor);

        // 4. Redeem (2nd half of sandwich)
        before = target.balanceOf(address(this));
        autoRoller.redeem(autoRoller.balanceOf(address(this)), address(this), address(this));
        OldPeripheryLike periphery = OldPeripheryLike(AddressBook.PERIPHERY_2_0_0);
        yt.approve(address(periphery), type(uint256).max);
        periphery.swapYTsForTarget(address(mockAdapter), autoRoller.maturity(), ytBal);
        aafter = target.balanceOf(address(this));
        uint256 attackerInflow = aafter - before;
        assertGt(attackerOutflow, attackerInflow);
    }

    // Roller Periphery

    function testRollerPeripheryDepositRedeem() public {
        RollerPeriphery rollerPeriphery = new RollerPeriphery(permit2, address(0));
        rollerPeriphery.approve(ERC20(address(target)), address(autoRoller));

        autoRoller.roll();

        target.mint(alice, 1.1e18);

        vm.startPrank(alice);

        // Approve PERMIT2 to spend alice's target
        target.approve(address(permit2), 1.1e18);

        uint256 previewedShares = autoRoller.previewDeposit(1.1e18);
        uint256 shareBalPre = autoRoller.balanceOf(alice);

        // Generate permit for the periphery to spend alice's target
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(target));

        // Get quote for the periphery to swap target for target
        // Note that this is an empty quote where only we are interested in the sellToken being target
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(target), address(0));

        // Slippage check should fail if it's below what's previewed
        vm.expectRevert(abi.encodeWithSelector(RollerPeriphery.MinSharesError.selector));
        rollerPeriphery.deposit(autoRoller, 1.1e18, alice, previewedShares + 1, data, quote);

        uint256 receivedShares = rollerPeriphery.deposit(autoRoller, 1.1e18, alice, previewedShares, data, quote);

        uint256 shareBalPost = autoRoller.balanceOf(alice);

        assertEq(previewedShares, receivedShares);
        assertEq(receivedShares, shareBalPost - shareBalPre);

        uint256 assetBalPre = target.balanceOf(alice);
        
        // Approve PERMIT2 to spend alice's shares
        autoRoller.approve(address(permit2), shareBalPost);

        uint256 previewedAssets = autoRoller.previewRedeem(shareBalPost);

        // Generate permit for the periphery to spend alice's shares
        data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(autoRoller));
        
        // Get quote for the periphery to swap target for target
        // Note that this is an empty quote where only we are interested in the buyToken being target
        quote = _getQuote(address(0), address(target));

        // Slippage check should fail if it's below what's previewed
        vm.expectRevert(abi.encodeWithSelector(RollerPeriphery.MinAmountOutError.selector));
        rollerPeriphery.redeem(autoRoller, shareBalPost, alice, previewedAssets + 1, data, quote);

        uint256 receivedAssets = rollerPeriphery.redeem(autoRoller, shareBalPost, alice, previewedAssets, data, quote);

        uint256 assetBalPost = target.balanceOf(alice);

        assertEq(previewedAssets, receivedAssets);
        assertEq(receivedAssets, assetBalPost - assetBalPre);

        // No asset or share left in the periphery
        assertEq(autoRoller.balanceOf(address(rollerPeriphery)), 0);
        assertEq(ERC20(autoRoller.asset()).balanceOf(address(rollerPeriphery)), 0);

        vm.stopPrank();
    }

    function testRollerPeripheryDepositRedeemUnderlying() public {
        autoRoller.roll();

        underlying.mint(alice, 1.1e18);

        vm.startPrank(alice);

        // Approve PERMIT2 to spend alice's shares
        underlying.approve(address(permit2), 1.1e18);

        uint256 targetValue = uint(1.1e18).divWadDown(mockAdapter.scale());

        uint256 previewedShares = autoRoller.previewDeposit(targetValue);
        uint256 shareBalPre = autoRoller.balanceOf(alice);

        // Generate permit for the periphery to spend alice's underlying
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(underlying));
        
        // Get quote for the periphery to swap underlying for target
        // Note that this is an empty quote where only we are interested in the buyToken being target
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(underlying), address(0));

        // Slippage check should fail if it's below what's previewed
        vm.expectRevert(abi.encodeWithSelector(RollerPeriphery.MinSharesError.selector));
        rollerPeriphery.deposit(autoRoller, 1.1e18, alice, previewedShares + 1, data, quote);

        uint256 receivedShares = rollerPeriphery.deposit(autoRoller, 1.1e18, alice, previewedShares, data, quote);

        uint256 shareBalPost = autoRoller.balanceOf(alice);

        assertEq(previewedShares, receivedShares);
        assertEq(receivedShares, shareBalPost - shareBalPre);

        uint256 underlyingBalPre = underlying.balanceOf(alice);

        // Approve PERMIT2 to spend alice's shares
        autoRoller.approve(address(permit2), shareBalPost);

        uint256 previewedAssets = autoRoller.previewRedeem(shareBalPost);
        uint256 previewedUnderlying = previewedAssets.mulWadDown(mockAdapter.scale());

        // Generate permit for the periphery to spend alice's shares
        data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(autoRoller));

        // Get quote for the periphery to swap target for underlying
        // Note that this is an empty quote where only we are interested in the buyToken being underlying
        quote = _getQuote(address(0), address(underlying));
        
        // Slippage check should fail if it's below what's previewed
        vm.expectRevert(abi.encodeWithSelector(RollerPeriphery.MinAmountOutError.selector));
        rollerPeriphery.redeem(autoRoller, shareBalPost, alice, previewedUnderlying + 1, data, quote);

        uint256 receivedUnderlying = rollerPeriphery.redeem(autoRoller, shareBalPost, alice, previewedUnderlying, data, quote);

        uint256 underlyingBalPost = underlying.balanceOf(alice);

        assertEq(previewedUnderlying, receivedUnderlying);
        assertEq(receivedUnderlying, underlyingBalPost - underlyingBalPre);

        // No asset or share or underlying left in the periphery
        assertEq(autoRoller.balanceOf(address(rollerPeriphery)), 0);
        assertEq(ERC20(autoRoller.asset()).balanceOf(address(rollerPeriphery)), 0);
        assertEq(underlying.balanceOf(address(rollerPeriphery)), 0);

        vm.stopPrank();
    }

    function testRollerPeripheryMintWithdraw() public {
        target.mint(alice, 2e18);

        RollerPeriphery rollerPeriphery = new RollerPeriphery(permit2, address(0));
        rollerPeriphery.approve(ERC20(address(target)), address(autoRoller));
    
        autoRoller.roll();

        vm.startPrank(alice);

        // Approve PERMIT2 to spend alice's shares
        target.approve(address(permit2), 1.1e18);

        uint256 previewedAssets = autoRoller.previewMint(1.1e18);
        uint256 assetBalPre = target.balanceOf(alice);

        // Generate permit for the periphery to spend alice's target
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(target));

        // Slippage check should fail if it's below what's previewed
        vm.expectRevert(abi.encodeWithSelector(RollerPeriphery.MaxAssetError.selector));
        rollerPeriphery.mintFromTarget(autoRoller, 1.1e18, alice, previewedAssets - 1, data);

        uint256 pulledAssets = rollerPeriphery.mintFromTarget(autoRoller, 1.1e18, alice, previewedAssets, data);

        uint256 assetBalPost = target.balanceOf(alice);

        assertEq(previewedAssets, pulledAssets);
        assertEq(pulledAssets, assetBalPre - assetBalPost);

        uint256 shareBalPre = autoRoller.balanceOf(alice);

        // Approve PERMIT2 to spend alice's shares
        autoRoller.approve(address(permit2), shareBalPre);

        uint256 previewedShares = autoRoller.previewWithdraw(pulledAssets * 0.99e18 / 1e18);

        data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(autoRoller));

        // Slippage check should fail if it's below what's previewed
        vm.expectRevert(abi.encodeWithSelector(RollerPeriphery.MaxSharesError.selector));
        rollerPeriphery.withdrawTarget(autoRoller, pulledAssets * 0.99e18 / 1e18, alice, previewedShares - 1, data);

        uint256 pulledShares = rollerPeriphery.withdrawTarget(autoRoller, pulledAssets * 0.99e18 / 1e18, alice, previewedShares, data);
        uint256 shareBalPost = autoRoller.balanceOf(alice);

        assertEq(previewedShares, pulledShares);
        assertEq(pulledShares, shareBalPre - shareBalPost);

        // No asset or share left in the periphery
        assertEq(autoRoller.balanceOf(address(rollerPeriphery)), 0);
        assertEq(ERC20(autoRoller.asset()).balanceOf(address(rollerPeriphery)), 0);

        vm.stopPrank();
    }

    function testRollerPeripheryMintWithdrawUnderlying() public {
        autoRoller.roll();

        underlying.mint(alice, 1.1e18);

        vm.startPrank(alice);

        // Approve PERMIT2 to spend alice's shares
        underlying.approve(address(permit2), 1.1e18);

        uint256 targetValue = uint(1.1e18).divWadDown(mockAdapter.scale());

        uint256 previewedAssets = autoRoller.previewMint(0.9e18);
        uint256 previewedUnderlying = previewedAssets.mulWadDown(mockAdapter.scale());

        uint256 underlyingBalPre = underlying.balanceOf(alice);

        // Generate permit for the periphery to spend alice's underlying
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(underlying));

        // Slippage check should fail if it's below what's previewed
        vm.expectRevert(abi.encodeWithSelector(RollerPeriphery.MaxUnderlyingError.selector));
        rollerPeriphery.mintFromUnderlying(autoRoller, 0.9e18, alice, previewedUnderlying - 1, data);

        uint256 pulledUnderlying = rollerPeriphery.mintFromUnderlying(autoRoller, 0.9e18, alice, previewedUnderlying, data);
        uint256 pulledAssets = pulledUnderlying.divWadUp(mockAdapter.scale());

        uint256 underlyingBalPost = underlying.balanceOf(alice);

        assertApproxEqAbs(previewedUnderlying, pulledUnderlying, 1);
        assertApproxEqAbs(pulledUnderlying, underlyingBalPre - underlyingBalPost, 1);

        uint256 shareBalPre = autoRoller.balanceOf(alice);

        // Approve PERMIT2 to spend alice's shares
        autoRoller.approve(address(permit2), shareBalPre);

        uint256 previewedShares = autoRoller.previewWithdraw(pulledAssets * 0.99e18 / 1e18);

        // Generate permit for the periphery to spend alice's shares
        data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(autoRoller));

        // Slippage check should fail if it's below what's previewed
        vm.expectRevert(abi.encodeWithSelector(RollerPeriphery.MaxSharesError.selector));
        rollerPeriphery.withdrawUnderlying(autoRoller, pulledUnderlying * 0.99e18 / 1e18, alice, previewedShares - 1, data);
        
        uint256 pulledShares = rollerPeriphery.withdrawUnderlying(autoRoller, pulledUnderlying * 0.99e18 / 1e18, alice, previewedShares, data);
        uint256 shareBalPost = autoRoller.balanceOf(alice);

        assertApproxEqAbs(previewedShares, pulledShares, 1);
        assertApproxEqAbs(pulledShares, shareBalPre - shareBalPost, 1);

        // No asset or share left in the periphery
        assertEq(autoRoller.balanceOf(address(rollerPeriphery)), 0);
        assertEq(ERC20(autoRoller.asset()).balanceOf(address(rollerPeriphery)), 0);
        assertEq(underlying.balanceOf(address(rollerPeriphery)), 0);

        vm.stopPrank();
    }

    function testRollerPeripheryEject() public {
        RollerPeriphery rollerPeriphery = new RollerPeriphery(permit2, address(0));
        rollerPeriphery.approve(ERC20(address(target)), address(autoRoller));

        autoRoller.roll();

        vm.startPrank(alice);

        target.mint(alice, 1.1e18);

        // Approve PERMIT2 to spend alice's target
        target.approve(address(permit2), 1.1e18);

        // Generate permit for the periphery to spend alice's target
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(target));

        // Get quote for the periphery to swap target for target
        // Note that this is an empty quote where only we are interested in the sellToken being target
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(target), address(0));

        uint256 receivedShares = rollerPeriphery.deposit(autoRoller, 1.1e18, alice, 0, data, quote);

        autoRoller.approve(address(rollerPeriphery), receivedShares);

        uint256 assets; uint256 excessBal; bool isExcessPTs;
        uint256 id = vm.snapshot();
        (assets, excessBal, isExcessPTs) = rollerPeriphery.eject(autoRoller, receivedShares, alice, 0, 0);
        vm.revertTo(id);
        
        // Min expected check should fail if it's below what's previewed, for assets or excess
        vm.expectRevert(abi.encodeWithSelector(RollerPeriphery.MinAssetsOrExcessError.selector));
        rollerPeriphery.eject(autoRoller, receivedShares, alice, assets + 1, excessBal);
        vm.expectRevert(abi.encodeWithSelector(RollerPeriphery.MinAssetsOrExcessError.selector));
        rollerPeriphery.eject(autoRoller, receivedShares, alice, assets, excessBal + 1);

        rollerPeriphery.eject(autoRoller, receivedShares, alice, assets, excessBal);

        vm.stopPrank();
    }

    function testRollerPeripheryCanReceiveETH() public {
        // we make sure functions have the payable modifier, otherwise, this would not even compile
        RollerPeriphery.PermitData memory data;
        RollerPeriphery.SwapQuote memory quote;
        
        vm.expectRevert();
        rollerPeriphery.redeem{ value: 1e18 }(autoRoller, 0, address(0), 0, data, quote);
        vm.expectRevert();
        rollerPeriphery.deposit{ value: 1e18 }(autoRoller, 0, address(0), 0, data, quote);
    }

    function testExternalSettlement() public {
        autoRoller.roll();

        autoRoller.deposit(1.1e18, address(this));

        uint256 maturity = autoRoller.maturity();
        
        vm.warp(maturity + divider.SPONSOR_WINDOW() + 1);

        // Series must be settled for cooldown
        vm.expectRevert();
        autoRoller.startCooldown();

        divider.settleSeries(address(mockAdapter), maturity);

        Space space = Space(spaceFactory.pools(address(mockAdapter), maturity));

        vm.expectRevert(SenseCoreErrors.AlreadySettled.selector);
        autoRoller.settle();

        assertTrue(space.balanceOf(address(autoRoller)) > 0);
        autoRoller.startCooldown();
        assertEq(space.balanceOf(address(autoRoller)), 0);
    }


    function testTargetedRate() public {
        autoRoller.setParam("TARGET_DURATION", 6);

        autoRoller.roll();

        autoRoller.deposit(1.1e18, address(this));

        vm.warp(autoRoller.maturity());

        mockAdapter.setScale(1.05e18);

        vm.expectCall(address(utils), abi.encodeWithSelector(utils.getNewTargetedRate.selector));
        autoRoller.settle();
    }

    function testFactoryParams() public {
        vm.expectRevert("UNTRUSTED");
        vm.prank(alice);
        arFactory.setPeriphery(address(1));

        vm.expectRevert("UNTRUSTED");
        vm.prank(alice);
        arFactory.setRollerPeriphery(address(1));

        vm.expectRevert("UNTRUSTED");
        vm.prank(alice);
        arFactory.setUtils(address(1));

        arFactory.setPeriphery(address(2));
        arFactory.setRollerPeriphery(address(2));
        arFactory.setUtils(address(2));
        assertEq(address(arFactory.periphery()), address(2));
        assertEq(address(arFactory.rollerPeriphery()), address(2));
        assertEq(address(arFactory.utils()), address(2));
    }

    function testGetNewTargetedRate() public {
        autoRoller.roll();

        uint256 maturity = autoRoller.maturity();
        Space space = Space(spaceFactory.pools(address(mockAdapter), maturity));

        // Can't get new targeted rate before maturity.
        vm.expectRevert();
        utils.getNewTargetedRate(0, address(mockAdapter), maturity, space);

        vm.warp(maturity);
        autoRoller.settle();

        // Targeted rate is 0 if scale has gone down.
        mockAdapter.setScale(0.9e18);
        uint256 targetedRate = utils.getNewTargetedRate(0, address(mockAdapter), maturity, space);
        assertEq(targetedRate, 0);
    }

    function testFactoryRollerQuantityLimit() public {
        // 1. Untrusted addresses can't create more than one roller on the same adapter.
        vm.startPrank(address(0xfede));
        vm.expectRevert(abi.encodeWithSelector(AutoRollerFactory.RollerQuantityLimitExceeded.selector));
        autoRoller = arFactory.create(
            OwnedAdapterLike(address(mockAdapter)),
            REWARDS_RECIPIENT,
            TARGET_DURATION
        );
        // ... even if the rewards recipient is different (changing the salt).
        vm.expectRevert(abi.encodeWithSelector(AutoRollerFactory.RollerQuantityLimitExceeded.selector));
        autoRoller = arFactory.create(
            OwnedAdapterLike(address(mockAdapter)),
            address(0x13372),
            TARGET_DURATION
        );

        // ... but they can still create rollers on new adapters.
        MockOwnableAdapter mockAdapter2 = new MockOwnableAdapter(
            address(divider),
            address(target),
            address(underlying),
            mockAdapterParams
        );
        mockAdapter2.setIsTrusted(address(arFactory), true);
        arFactory.create(OwnedAdapterLike(address(mockAdapter2)), REWARDS_RECIPIENT, TARGET_DURATION);
        vm.stopPrank();

        // 2. The testing contract address, however, can create as many rollers as it wants since it's trusted.
        assertEq(arFactory.isTrusted(address(this)), true);
        arFactory.create(
            OwnedAdapterLike(address(mockAdapter)),
            REWARDS_RECIPIENT,
            TARGET_DURATION
        );
        arFactory.create(
            OwnedAdapterLike(address(mockAdapter)),
            REWARDS_RECIPIENT,
            TARGET_DURATION
        );
    }

    // function testRedeemPreviewReversion() public {

    // }

    // exxcess pts or yts
    // redeem doesn't revert
    // decimals

    function _swap(BalancerVault.SingleSwap memory request) internal {
        BalancerVault.FundManagement memory funds = BalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        balancerVault.swap(request, funds, 0, type(uint256).max);
    }

    function _getQuote(address fromToken, address toToken) public returns (RollerPeriphery.SwapQuote memory quote) {
        if (fromToken == address(0)) {
            quote.buyToken = ERC20(toToken);
        } else {
            quote.sellToken = ERC20(fromToken);
        }
    }
}

contract Mintooor {
    AutoRoller immutable roller;
    constructor(AutoRoller _roller, MockERC20 target) {
        roller = _roller;
        target.approve(address(_roller), type(uint256).max);
    }
    function mint(uint256 shares) external {
        roller.mint(shares, address(this));
    }
}

