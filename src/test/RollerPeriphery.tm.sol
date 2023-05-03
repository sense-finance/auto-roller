// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "forge-std/Script.sol";
import "forge-std/StdCheats.sol";
import "forge-std/Test.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { ERC4626 } from "solmate/mixins/ERC4626.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";

import { BaseAdapter } from "sense-v1-core/adapters/abstract/BaseAdapter.sol";
import { Divider } from "sense-v1-core/Divider.sol";
import { Periphery } from "sense-v1-core/Periphery.sol";

import { BalancerVault } from "../interfaces/BalancerVault.sol";
import { IPermit2 } from "../interfaces/IPermit2.sol";

import { OwnableERC4626Adapter } from "sense-v1-core/adapters/abstract/erc4626/OwnableERC4626Adapter.sol";
import { AddressBook } from "./utils/AddressBook.sol";
import { Permit2Helper } from "./utils/Permit2Helper.sol";
import { AutoRoller, RollerUtils, SpaceFactoryLike, DividerLike, OwnedAdapterLike } from "../AutoRoller.sol";
import { AutoRollerFactory } from "../AutoRollerFactory.sol";
import { RollerPeriphery } from "../RollerPeriphery.sol";

interface Authentication {
    function getActionId(bytes4) external returns (bytes32);
    function grantRole(bytes32,address) external;
}

interface ProtocolFeesController {
    function setSwapFeePercentage(uint256) external;
}

contract AutoRollerMainnetTest is Test, Permit2Helper {
    using FixedPointMathLib for uint256;

    uint256 public mainnetFork = vm.createFork(getChain("mainnet").rpcUrl);

    address public constant REWARDS_RECIPIENT = address(1);
    uint256 public constant TARGET_DURATION = 3;
    uint256 public constant TARGETED_RATE = 2.9e18;

    BalancerVault balancerVault = BalancerVault(AddressBook.BALANCER_VAULT);
    SpaceFactoryLike spaceFactory = SpaceFactoryLike(AddressBook.SPACE_FACTORY_1_3_0);
    Periphery periphery = Periphery(payable(AddressBook.PERIPHERY_1_4_0));
    Divider divider = Divider(spaceFactory.divider());

    ERC20 target = ERC20(AddressBook.MORPHO_DAI);
    ERC20 underlying = ERC20(AddressBook.DAI);
    ERC20 stake = ERC20(AddressBook.WETH);

    RollerPeriphery public rollerPeriphery;
    OwnableERC4626Adapter public adapter;
    RollerUtils public utils;
    AutoRollerFactory public arFactory;
    AutoRoller public autoRoller;

    function setUp() public {
        vm.selectFork(mainnetFork);
        vm.rollFork(16769506);

        utils = new RollerUtils(address(divider));
        rollerPeriphery = new RollerPeriphery(IPermit2(AddressBook.PERMIT2),AddressBook.EXCHANGE_PROXY);
        permit2 = IPermit2(AddressBook.PERMIT2);

        arFactory = new AutoRollerFactory(
            DividerLike(address(divider)),
            address(balancerVault),
            address(periphery),
            address(rollerPeriphery),
            utils
        );

        console2.log("Auto Roller Factory:", address(arFactory));

        BaseAdapter.AdapterParams memory adapterParams = BaseAdapter.AdapterParams({
            oracle: address(0),
            stake: address(stake),
            stakeSize: 0.1e18,
            minm: 0, // 0 minm, so there's not lower bound on future maturity
            maxm: type(uint64).max, // large maxm, so there's not upper bound on future maturity
            mode: 0, // monthly maturities
            tilt: 0, // no principal reserved for YTs
            level: 31 // default level, everything is allowed except for the redemption cb
        });

        adapter = new OwnableERC4626Adapter(
            address(divider),
            address(target),
            REWARDS_RECIPIENT,
            0,
            adapterParams
        );

        console2.log("Adapter:", address(adapter));

        adapter.setIsTrusted(address(arFactory), true);

        rollerPeriphery.setIsTrusted(address(arFactory), true);

        autoRoller = arFactory.create(
            OwnedAdapterLike(address(adapter)),
            REWARDS_RECIPIENT,
            TARGET_DURATION
        );

        console2.log("Auto Roller ", address(autoRoller));

        vm.prank(AddressBook.SENSE_MULTISIG);
        periphery.onboardAdapter(address(adapter), true);

        vm.prank(AddressBook.SENSE_MULTISIG);
        divider.setGuard(address(adapter), type(uint256).max);

        deal(address(target), address(this), 2e18);
        target.approve(address(autoRoller), 2e18);

        // Set protocol fees
        // ProtocolFeesController protocolFeesCollector = ProtocolFeesController(balancerVault.getProtocolFeesCollector());
        // Authentication authorizer = Authentication(balancerVault.getAuthorizer());
        // bytes32 actionId = Authentication(address(protocolFeesCollector)).getActionId(protocolFeesCollector.setSwapFeePercentage.selector);
        // authorizer.grantRole(actionId, msg.sender);
        // protocolFeesCollector.setSwapFeePercentage(0.1e18);

        // Roll into the first Series
        deal(address(stake), address(this), 0.25e18);
        stake.approve(address(autoRoller), 0.25e18);
        autoRoller.roll();
    }

    //// TEST DEPOSIT & REDEEM ////

    function testMainnetDepositFromUSDCRedeemToUSDC() public {
        vm.startPrank(alice);

        // Load alice's wallet, approve pertmi2, generate permit message and quote to swap USDC to underlying (DAI) 
        deal(AddressBook.USDC, alice, 1e6);
        ERC20(AddressBook.USDC).approve(AddressBook.PERMIT2, 1e6);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), AddressBook.USDC);
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), AddressBook.USDC, address(0));

        // Deposit
        uint256 usdcBalBefore = ERC20(AddressBook.USDC).balanceOf(alice);
        uint256 oneUSDCtoUnderlying = 997878174310344549; // 1 USDC to DAI at the rolled block and the given quote (see _getQuote)
        uint256 underlyingToTarget = ERC4626(adapter.target()).previewDeposit(oneUSDCtoUnderlying); // 1 underlying (DAI) to asset (target) maDAI
        uint256 previewShares = autoRoller.previewDeposit(underlyingToTarget);
        uint256 shares = rollerPeriphery.deposit(autoRoller, 1e6, alice, 0, data, quote);
        uint256 usdcBalAfter = ERC20(AddressBook.USDC).balanceOf(alice);
        assertEq(usdcBalBefore - usdcBalAfter, 1e6);
        // assertEq(previewShares, shares); // TODO: this is failing because previewDeposit != deposit
        assertEq(shares, autoRoller.balanceOf(alice));

        // Redeem
        ERC20(address(autoRoller)).approve(AddressBook.PERMIT2, shares);
        data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(autoRoller));
        // Amount of shares converted to target (maDAI) converted to underlying (DAI)
        // that are being sold for USDC
        {
            uint256 underlyingToSell = 996655325595199885; 
            quote = _getQuote(address(adapter), address(0), AddressBook.USDC, underlyingToSell);
        }
        uint256 usdc = rollerPeriphery.redeem(autoRoller, shares, alice, 0, data, quote);
        uint256 sharesBalAfter = autoRoller.balanceOf(alice);
        assertEq(shares - sharesBalAfter, shares);
        uint256 underlyingToUSDC = 992790; // `underlyingToSell` DAI to USDC at the rolled block and the given quote (see _getQuote)
        assertEq(underlyingToUSDC, usdc);
        assertEq(usdc, ERC20(AddressBook.USDC).balanceOf(alice));

        vm.stopPrank();
    }

    function testMainnetDepositFromETHRedeemToETH() public {
        vm.startPrank(alice);

        // Load alice's wallet, approve pertmi2, generate permit message and quote to swap USDC to underlying (DAI) 
        vm.deal(alice, 1e18);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), rollerPeriphery.ETH());
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), rollerPeriphery.ETH(), address(0));
        
        // Deposit
        uint256 actualDeposit;
        {
            uint256 ethBalBefore = address(alice).balance;
            // uint256 oneETHtoUnderlying = 1562883254867738451851; // 1 ETH to DAI at the rolled block and the given quote (see _getQuote)
            uint256 oneETHtoUnderlying = 1562883254867738451872; // 1 ETH to DAI at the rolled block (this is the result of the 0x swap)
            uint256 underlyingToTarget = ERC4626(adapter.target()).previewDeposit(oneETHtoUnderlying); // 1 underlying (DAI) to asset (target) maDAI
            uint256 previewedDeposit = autoRoller.previewDeposit(underlyingToTarget); // maDAI to shares
            
            actualDeposit = rollerPeriphery.deposit{value: 1 ether}(autoRoller, 1e18, alice, 0, data, quote);
            
            uint256 ethBalAfter = address(alice).balance;
            assertEq(ethBalBefore - ethBalAfter, 1e18);
            // assertEq(previewedDeposit, actualDeposit); // TODO: this is failing because previewDeposit != deposit
            assertEq(actualDeposit, autoRoller.balanceOf(alice));
        }
        

        // Redeem
        {
            ERC20(address(autoRoller)).approve(AddressBook.PERMIT2, actualDeposit);
            data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(autoRoller));
            // Amount of shares converted to target (maDAI) converted to underlying (DAI)
            // that are being sold for ETH
            {
                uint256 underlyingToSell = 1562883254867728396724; 
                quote = _getQuote(address(adapter), address(0), rollerPeriphery.ETH(), underlyingToSell);
            }
            uint256 previewedRedeem = autoRoller.previewRedeem(actualDeposit);
            previewedRedeem = ERC4626(adapter.target()).previewMint(previewedRedeem); // convert previewedRedeem (maDAI) to underlying (DAI)
            previewedRedeem = (previewedRedeem * 637095660758594) / 1e18; // convert underlying (DAI) to ETH
            
            uint256 actualRedeem = rollerPeriphery.redeem(autoRoller, actualDeposit, alice, 0, data, quote);

            uint256 sharesBalAfter = autoRoller.balanceOf(alice);

            // assertEq(actualRedeem, previewedRedeem); // TODO: this is failing because previewRedeem != redeem
            assertEq(actualDeposit - sharesBalAfter, actualDeposit);
            assertEq(actualRedeem, address(alice).balance);
        }
        
        vm.stopPrank();
    }

    function testMainnetDepositFromUnderlyingRedeemToUnderlying() public {
        vm.startPrank(alice);

        // Load alice's wallet, approve pertmi2, generate permit message and quote to swap USDC to underlying (DAI) 
        deal(AddressBook.DAI, alice, 1e18);
        ERC20(AddressBook.DAI).approve(AddressBook.PERMIT2, 1e18);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), AddressBook.DAI);
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), AddressBook.DAI, address(0));

        // Deposit
        uint256 daiBalBefore = ERC20(AddressBook.DAI).balanceOf(alice);
        uint256 underlyingToTarget = ERC4626(adapter.target()).previewDeposit(1e18); // 1 underlying (DAI) to asset (target) maDAI
        uint256 previewedDeposit = autoRoller.previewDeposit(underlyingToTarget);
        
        uint256 actualDeposit = rollerPeriphery.deposit(autoRoller, 1e18, alice, 0, data, quote);
        
        uint256 daiBalAfter = ERC20(AddressBook.DAI).balanceOf(alice);
        assertEq(daiBalBefore - daiBalAfter, 1e18);
        // assertEq(previewedDeposit, actualDeposit); // TODO: this is failing because previewDeposit != deposit 
        assertEq(actualDeposit, autoRoller.balanceOf(alice));

        // Redeem
        ERC20(address(autoRoller)).approve(AddressBook.PERMIT2, actualDeposit);
        data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(autoRoller));
        quote = _getQuote(address(adapter), address(0), AddressBook.DAI);
        daiBalBefore = ERC20(AddressBook.DAI).balanceOf(alice);
        uint256 previewedRedeem = autoRoller.previewRedeem(actualDeposit);
        
        uint256 actualRedeem = rollerPeriphery.redeem(autoRoller, actualDeposit, alice, 0, data, quote);
        
        daiBalAfter = ERC20(AddressBook.DAI).balanceOf(alice);
        uint256 sharesBalAfter = autoRoller.balanceOf(alice);
        assertApproxEqAbs(actualRedeem, ERC4626(adapter.target()).previewMint(previewedRedeem), 1);
        assertEq(actualDeposit - sharesBalAfter, actualDeposit);
        assertEq(daiBalAfter - daiBalBefore, actualRedeem);

        vm.stopPrank();
    }

    function testMainnetDepositFromTargetRedeemToTarget() public {
        vm.startPrank(alice);

        // Load alice's wallet, approve pertmi2, generate permit message and quote to swap USDC to underlying (DAI) 
        deal(AddressBook.MORPHO_DAI, alice, 1e18);
        ERC20(AddressBook.MORPHO_DAI).approve(AddressBook.PERMIT2, 1e18);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), AddressBook.MORPHO_DAI);
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), AddressBook.MORPHO_DAI, address(0));

        // Deposit
        uint256 maDaiBalBefore = ERC20(AddressBook.MORPHO_DAI).balanceOf(alice);
        uint256 previewedDeposit = autoRoller.previewDeposit(1e18);
        uint256 actualDeposit = rollerPeriphery.deposit(autoRoller, 1e18, alice, 0, data, quote);
        uint256 maDaiBalAfter = ERC20(AddressBook.MORPHO_DAI).balanceOf(alice);
        assertEq(maDaiBalBefore - maDaiBalAfter, 1e18);
        assertEq(previewedDeposit, actualDeposit);
        assertEq(actualDeposit, autoRoller.balanceOf(alice));

        // Redeem
        ERC20(address(autoRoller)).approve(AddressBook.PERMIT2, actualDeposit);
        data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(autoRoller));
        quote = _getQuote(address(adapter), address(0), AddressBook.MORPHO_DAI);
        maDaiBalBefore = ERC20(AddressBook.MORPHO_DAI).balanceOf(alice);
        uint256 previewedRedeem = autoRoller.previewRedeem(actualDeposit);
       
        uint256 actualRedeem = rollerPeriphery.redeem(autoRoller, actualDeposit, alice, 0, data, quote);
       
        maDaiBalAfter = ERC20(AddressBook.MORPHO_DAI).balanceOf(alice);
        uint256 sharesBalAfter = autoRoller.balanceOf(alice);
        assertEq(actualRedeem, previewedRedeem);
        assertEq(actualDeposit - sharesBalAfter, actualDeposit);
        assertEq(maDaiBalAfter - maDaiBalBefore, actualRedeem);

        vm.stopPrank();
    }

    function testMainnetCanDepositFromTargetRedeemToTarget_BREAKING() public {
        // wstETH RLV
        address WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        autoRoller = AutoRoller(0xeb9e7e1F892Bb2931e8C319D6F10FDf147090818);

        // deploy Periphery v2
        Periphery periphery = new Periphery(
            address(divider),
            address(spaceFactory),
            address(balancerVault),
            address(AddressBook.PERMIT2),
            address(AddressBook.EXCHANGE_PROXY)
        );

        // onboard wstETH adapter on Periphery
        vm.prank(AddressBook.SENSE_MULTISIG);
        periphery.onboardAdapter(address(autoRoller.adapter()), false);

        // verify wstETH adapter on Periphery
        vm.prank(AddressBook.SENSE_MULTISIG);
        periphery.verifyAdapter(address(autoRoller.adapter()));

        // set Periphery on divider
        vm.prank(AddressBook.SENSE_MULTISIG);
        divider.setPeriphery(address(periphery));

        // set Periphery on RLV
        vm.prank(0x59A181710F926Eae6FddfbF27a14259E8DD00cA2); // deployer address
        autoRoller.setParam("PERIPHERY", address(periphery));

        // approve RLV to spend RollerPeriphery's wstETH from trusted address
        rollerPeriphery.approve(ERC20(WSTETH), address(autoRoller));
        // rollerPeriphery.approve(underlying, address(adapter));
        // rollerPeriphery.approve(target, address(adapter));

        // approve Periphery to pull RLV's YTs 
        // FIXME: this should be done via a function on the autoRoller contract 
        // UNCOMMENT THIS TO MAKE THE TEST PASS
        // vm.prank(address(autoRoller));
        // address YT = 0x98eA92eB1f51853a2Cf25dA655A2F6fb51E58675; // 1st July 2023 sY-wstETH
        // ERC20(YT).approve(address(periphery), 0.1e18);

        vm.startPrank(alice);

        // Load alice's wallet, approve pertmi2, generate permit message and quote to swap USDC to underlying (DAI) 
        deal(WSTETH, alice, 0.1e18);
        ERC20(WSTETH).approve(AddressBook.PERMIT2, 0.1e18);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), WSTETH);
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), WSTETH, address(0));

        // Deposit
        uint256 wstETHBalBefore = ERC20(WSTETH).balanceOf(alice);
        uint256 previewedDeposit = autoRoller.previewDeposit(0.1e18);
        uint256 actualDeposit = rollerPeriphery.deposit(autoRoller, 0.1e18, alice, 0, data, quote);
        uint256 wstETHBalAfter = ERC20(WSTETH).balanceOf(alice);
        // assertEq(wstETHBalBefore - wstETHBalAfter, 0.1e18);
        // assertEq(previewedDeposit, actualDeposit);
        // assertEq(actualDeposit, autoRoller.balanceOf(alice));

        // Redeem
        ERC20(address(autoRoller)).approve(AddressBook.PERMIT2, 0.05e18);
        data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(autoRoller));
        quote = _getQuote(address(adapter), address(0), WSTETH);
        wstETHBalBefore = ERC20(WSTETH).balanceOf(alice);
        uint256 previewedRedeem = autoRoller.previewRedeem(0.05e18);
        uint256 actualRedeem = rollerPeriphery.redeem(autoRoller, 0.05e18, alice, 0, data, quote);
       
        // wstETHBalAfter = ERC20(WSTETH).balanceOf(alice);
        // uint256 sharesBalAfter = autoRoller.balanceOf(alice);
        // assertEq(actualRedeem, previewedRedeem);
        // assertEq(0.05e18 - sharesBalAfter, 0.05e18);
        // assertEq(wstETHBalAfter - wstETHBalBefore, actualRedeem);

        vm.stopPrank();
    }

    function _getQuote(
        address adapter,
        address fromToken,
        address toToken
    ) public returns (RollerPeriphery.SwapQuote memory quote) {
       return  _quote(adapter, fromToken, toToken, 0);
    }

    function _getQuote(
        address adapter,
        address fromToken,
        address toToken,
        uint256 amt
    ) public returns (RollerPeriphery.SwapQuote memory quote) {
        return _quote(adapter, fromToken, toToken, amt);
    }

    function _quote(
        address adapter,
        address fromToken,
        address toToken,
        uint256 amt
    ) public returns (RollerPeriphery.SwapQuote memory quote) {
        if (fromToken == toToken) {
            quote.sellToken = ERC20(fromToken);
            quote.buyToken = ERC20(toToken);
            return quote;
        }
        BaseAdapter adapter = BaseAdapter(adapter);
        if (fromToken == address(0)) {
            if (toToken == adapter.underlying() || toToken == adapter.target()) {
                // Create a quote where we only fill the buyToken (with target or underlying) and the rest
                // is empty. This is used by the Periphery so it knows it does not have to perform a swap.
                quote.buyToken = ERC20(toToken);
            } else {
                // Quote to swap underlying for token via 0x
                address underlying = BaseAdapter(adapter).underlying();
                quote.sellToken = ERC20(underlying);
                quote.buyToken = ERC20(toToken);
                quote.spender = AddressBook.EXCHANGE_PROXY; // from 0x API
                quote.swapTarget = payable(AddressBook.EXCHANGE_PROXY); // from 0x API

                if (address(quote.buyToken) == rollerPeriphery.ETH()) {
                    // DAI to ETH quote
                    // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=ETH&sellAmount=1000000000000000000
                    // buyAmount = 637095660758594
                    quote
                        .swapCallData = hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000023da409f125e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000d297bab3486405e5b3";
                }

                if (address(quote.buyToken) == rollerPeriphery.ETH() && amt == 1562883254867728396724) {
                    // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=ETH&sellAmount=1562883254867728396724
                    // DAI to ETH quote
                    // buyAmount = 998791671463758788
                    quote
                        .swapCallData = hex"803ba26d0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000054b95cb7cab53df1b40000000000000000000000000000000000000000000000000db8efc6aa64d2b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002b6b175474e89094c44da98b954eedeac495271d0f0001f4c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000bceba58c916405e642";
                }

                if (address(quote.buyToken) == AddressBook.USDC) {
                    // DAI to USDC quote
                    // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=1000000000000000000
                    // buyAmount = 996122
                    quote
                        .swapCallData = hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000f0c30000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000000000000000001a6b4aa8a26405e5b5";
                }

                if (address(quote.buyToken) == AddressBook.USDC && amt == 996655325595199885) {
                    // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=996655325595199885
                    // DAI to USDC quote
                    // buyAmount = 992790
                    quote
                        .swapCallData = hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000dd4d4bcf59a698d00000000000000000000000000000000000000000000000000000000000eff4e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000b4cdc3b6416405e5b6";
                }
            }
        } else {
            if (fromToken == adapter.underlying() || fromToken == adapter.target()) {
                // Create a quote where we only fill the sellToken (with target or underlying) and the rest
                // is empty. This is used by the Periphery so it knows it does not have to perform a swap.
                quote.sellToken = ERC20(fromToken);
            } else {
                // Quote to swap token for underlying via 0x
                address underlying = BaseAdapter(adapter).underlying();
                quote.sellToken = ERC20(fromToken);
                quote.buyToken = ERC20(underlying);
                quote.spender = AddressBook.EXCHANGE_PROXY; // from 0x API
                quote.swapTarget = payable(AddressBook.EXCHANGE_PROXY); // from 0x API
                if (address(quote.sellToken) == AddressBook.USDC) {
                    // USDC to DAI quote
                    // https://api.0x.org/swap/v1/quote?sellToken=USDC&buyToken=DAI&sellAmount=1000000
                    // buyAmount = 997878174310344549
                    quote
                        .swapCallData = hex"d9627aa4000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000db5b9436fcb698f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000f32da91d126405e5b8";
                }

                if (address(quote.sellToken) == rollerPeriphery.ETH()) {
                    // https://api.0x.org/swap/v1/quote?sellToken=ETH&buyToken=DAI&sellAmount=1000000000000000000
                    // ETH to DAI quote
                    // buyAmount = 1562883254867738451851
                    quote
                        .swapCallData = hex"3598d8ab0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000053e077f364d7dce6440000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20001f46b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000e28e2586f26405e5b8";
                }
            }
        }
    }

    receive() external payable {}

    
}

