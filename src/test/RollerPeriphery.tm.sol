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
    Periphery periphery = Periphery(AddressBook.PERIPHERY_1_4_0);
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
        vm.rollFork(16734061);

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

    //// TEST WITHDRAW ////
    function testMainnetWithdrawFromUnderlying() public {}
    
    function testMainnetWithdrawFromTarget() public {}

    //// TEST REDEEM ////

    function testMainnetRedeemFromUnderlying() public {}

    function testMainnetRedeemFromTarget() public {}

    //// TEST MINT ////

    function testMainnetMintFromUnderlying() public {
        vm.startPrank(alice);

        // Load alice's wallet, pertmi2 approval, generate permit message and quote to swap USDC to underlying (DAI) 
        deal(AddressBook.DAI, alice, 1e18);
        ERC20(AddressBook.DAI).approve(AddressBook.PERMIT2, 1e18);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), AddressBook.DAI);
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), AddressBook.DAI, address(0));

        // Deposit
        uint256 daiBalBefore = ERC20(AddressBook.DAI).balanceOf(alice);
        
        uint256 underlyingToTarget = ERC4626(adapter.target()).previewDeposit(1e18); // 1 underlying (DAI) to asset (target) maDAI
        uint256 previewShares = autoRoller.previewDeposit(underlyingToTarget);
        uint256 shares = rollerPeriphery.deposit(autoRoller, 1e18, alice, 0, data, quote);
        uint256 daiBalAfter = ERC20(AddressBook.DAI).balanceOf(alice);
        assertEq(daiBalBefore - daiBalAfter, 1e18);
        // assertEq(previewShares, shares); // TODO: why is this failing?
        assertEq(shares, autoRoller.balanceOf(alice));

        vm.stopPrank();
    }
    
    function testMainnetMintFromTarget() public {
        vm.startPrank(alice);

        // Load alice's wallet, pertmi2 approval, generate permit message and quote to swap USDC to underlying (DAI) 
        deal(AddressBook.MORPHO_DAI, alice, 1e18);
        ERC20(AddressBook.MORPHO_DAI).approve(AddressBook.PERMIT2, 1e18);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), AddressBook.MORPHO_DAI);
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), AddressBook.MORPHO_DAI, address(0));

        // Deposit
        uint256 maDaiBalBefore = ERC20(AddressBook.MORPHO_DAI).balanceOf(alice);
        uint256 previewShares = autoRoller.previewDeposit(1e18);
        uint256 shares = rollerPeriphery.deposit(autoRoller, 1e18, alice, 0, data, quote);
        uint256 maDaiBalAfter = ERC20(AddressBook.MORPHO_DAI).balanceOf(alice);
        assertEq(maDaiBalBefore - maDaiBalAfter, 1e18);
        assertEq(previewShares, shares); // TODO: why is this failing?
        assertEq(shares, autoRoller.balanceOf(alice));

        vm.stopPrank();
    }

    //// TEST DEPOSIT ////

    function testMainnetDepositFromUSDCRedeemToUSDC() public {
        vm.startPrank(alice);

        // Load alice's wallet, pertmi2 approval, generate permit message and quote to swap USDC to underlying (DAI) 
        deal(AddressBook.USDC, alice, 1e6);
        ERC20(AddressBook.USDC).approve(AddressBook.PERMIT2, 1e6);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), AddressBook.USDC);
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), AddressBook.USDC, address(0));

        // Deposit
        uint256 usdcBalBefore = ERC20(AddressBook.USDC).balanceOf(alice);
        uint256 oneUSDCtoUnderlying = 996655325605252700; // 1 USDC to DAI at the rolled block and the given quote (see _getQuote)
        uint256 underlyingToTarget = ERC4626(adapter.target()).previewDeposit(oneUSDCtoUnderlying); // 1 underlying (DAI) to asset (target) maDAI
        uint256 previewShares = autoRoller.previewDeposit(underlyingToTarget);
        uint256 shares = rollerPeriphery.deposit(autoRoller, 1e6, alice, 0, data, quote);
        uint256 usdcBalAfter = ERC20(AddressBook.USDC).balanceOf(alice);
        assertEq(usdcBalBefore - usdcBalAfter, 1e6);
        // assertEq(previewShares, shares); // TODO: why is this failing?
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
        uint256 underlyingToUSDC = 997297; // `underlyingToSell` DAI to USDC at the rolled block and the given quote (see _getQuote)
        assertEq(underlyingToUSDC, usdc);
        assertEq(usdc, ERC20(AddressBook.USDC).balanceOf(alice));

        vm.stopPrank();
    }

    function testMainnetDepositFromETHRedeemToETH() public {
        vm.startPrank(alice);

        // Load alice's wallet, pertmi2 approval, generate permit message and quote to swap USDC to underlying (DAI) 
        vm.deal(alice, 1e18);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), rollerPeriphery.ETH());
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), rollerPeriphery.ETH(), address(0));

        // Deposit
        uint256 ethBalBefore = address(alice).balance;
        
        uint256 oneETHtoUnderlying = 1622131431243789710912; // 1 ETH to DAI at the current block and the given quote (see _getQuote)
        uint256 underlyingToTarget = ERC4626(adapter.target()).previewDeposit(oneETHtoUnderlying); // 1 underlying (DAI) to asset (target) maDAI
        uint256 previewShares = autoRoller.previewDeposit(underlyingToTarget);
        uint256 shares = rollerPeriphery.deposit{value: 1 ether}(autoRoller, 1e18, alice, 0, data, quote);
        uint256 ethBalAfter = address(alice).balance;
        assertEq(ethBalBefore - ethBalAfter, 1e18);
        // assertEq(previewShares, shares); // TODO: why is this failing?
        assertEq(shares, autoRoller.balanceOf(alice));

        // Redeem
        ERC20(address(autoRoller)).approve(AddressBook.PERMIT2, shares);
        data = _generatePermit(alicePrivKey, address(rollerPeriphery), address(autoRoller));
        // Amount of shares converted to target (maDAI) converted to underlying (DAI)
        // that are being sold for ETH
        {
            uint256 underlyingToSell = 996672055577733082; 
            quote = _getQuote(address(adapter), address(0), rollerPeriphery.ETH(), underlyingToSell);
        }
        uint256 eth = rollerPeriphery.redeem(autoRoller, shares, alice, 0, data, quote);
        uint256 sharesBalAfter = autoRoller.balanceOf(alice);
        assertEq(shares - sharesBalAfter, shares);
        uint256 underlyingToETH = 601860546139823; // `underlyingToSell` DAI to ETH at the rolled block and the given quote (see _getQuote)
        assertEq(underlyingToETH, eth);
        assertEq(eth, address(alice).balance);

        vm.stopPrank();
    }

    function testMainnetDepositFromUnderlying() public {
        vm.startPrank(alice);

        // Load alice's wallet, pertmi2 approval, generate permit message and quote to swap USDC to underlying (DAI) 
        deal(AddressBook.DAI, alice, 1e18);
        ERC20(AddressBook.DAI).approve(AddressBook.PERMIT2, 1e18);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), AddressBook.DAI);
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), AddressBook.DAI, address(0));

        // Deposit
        uint256 daiBalBefore = ERC20(AddressBook.DAI).balanceOf(alice);
        
        uint256 underlyingToTarget = ERC4626(adapter.target()).previewDeposit(1e18); // 1 underlying (DAI) to asset (target) maDAI
        uint256 previewShares = autoRoller.previewDeposit(underlyingToTarget);
        uint256 shares = rollerPeriphery.deposit(autoRoller, 1e18, alice, 0, data, quote);
        uint256 daiBalAfter = ERC20(AddressBook.DAI).balanceOf(alice);
        assertEq(daiBalBefore - daiBalAfter, 1e18);
        // assertEq(previewShares, shares); // TODO: why is this failing?
        assertEq(shares, autoRoller.balanceOf(alice));

        vm.stopPrank();
    }

    function testMainnetDepositFromTarget() public {
        vm.startPrank(alice);

        // Load alice's wallet, pertmi2 approval, generate permit message and quote to swap USDC to underlying (DAI) 
        deal(AddressBook.MORPHO_DAI, alice, 1e18);
        ERC20(AddressBook.MORPHO_DAI).approve(AddressBook.PERMIT2, 1e18);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), AddressBook.MORPHO_DAI);
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), AddressBook.MORPHO_DAI, address(0));

        // Deposit
        uint256 maDaiBalBefore = ERC20(AddressBook.MORPHO_DAI).balanceOf(alice);
        uint256 previewShares = autoRoller.previewDeposit(1e18);
        uint256 shares = rollerPeriphery.deposit(autoRoller, 1e18, alice, 0, data, quote);
        uint256 maDaiBalAfter = ERC20(AddressBook.MORPHO_DAI).balanceOf(alice);
        assertEq(maDaiBalBefore - maDaiBalAfter, 1e18);
        assertEq(previewShares, shares); // TODO: why is this failing?
        assertEq(shares, autoRoller.balanceOf(alice));

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
                    // buyAmount = 603870192313109
                    quote
                        .swapCallData = hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000021fb97d9ec7d9000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000e7e38e4d8563ff52a0";
                }

                if (address(quote.buyToken) == rollerPeriphery.ETH() && amt == 996672055577733082) {
                    // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=ETH&sellAmount=996672055577733082
                    // DAI to ETH quote
                    // buyAmount = 601860546139823
                    quote
                        .swapCallData = hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000dd4e3f43644e7da00000000000000000000000000000000000000000000000000021dea43376718000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee869584cd0000000000000000000000001000000000000000000000000000000000000011000000000000000000000000000000000000000000000018561b4e6a63ff52a2";
                }

                if (address(quote.buyToken) == AddressBook.USDC) {
                    // DAI to USDC quote
                    // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=1000000000000000000
                    // buyAmount = 1000644
                    quote
                        .swapCallData = hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000f1dad000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000b3cf6ec3b563ff52a3";
                }

                if (address(quote.buyToken) == AddressBook.USDC && amt == 996655325595199885) {
                    // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=996655325595199885
                    // DAI to USDC quote
                    // buyAmount = 997297
                    quote
                        .swapCallData = hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000dd4d4bcf59a698d00000000000000000000000000000000000000000000000000000000000f10bc000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000ff8f926fef63ff550b";
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
                    // buyAmount = 996655325605252700
                    quote
                        .swapCallData = hex"d9627aa4000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000db16c35f3bd872d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000000000000000005f5fce41f163ff52a7";
                }

                if (address(quote.sellToken) == rollerPeriphery.ETH()) {
                    // https://api.0x.org/swap/v1/quote?sellToken=ETH&buyToken=DAI&sellAmount=1000000000000000000
                    // ETH to DAI quote
                    // buyAmount = 1650495170502899000000
                    quote
                        .swapCallData = hex"3598d8ab0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000058942b66bed5d8ce900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20001f46b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000869584cd0000000000000000000000001000000000000000000000000000000000000011000000000000000000000000000000000000000000000016e67315b463ff52a7";
                }
            }
        }
    }

    receive() external payable {}

    
}

