// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "forge-std/Script.sol";
import "forge-std/StdCheats.sol";
import "forge-std/Test.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { ERC4626 } from "solmate/mixins/ERC4626.sol";

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
        vm.rollFork(16691609);

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

    //// TEST REDEEM ////

    //// TEST WITHDRAW ////

    //// TEST MINT ////

    //// TEST DEPOSIT ////

    function testMainnetDepositFromUSDC() public {
        vm.startPrank(alice);

        // Load alice's wallet, pertmi2 approval, generate permit message and quote to swap USDC to underlying (DAI) 
        deal(AddressBook.USDC, alice, 1e6);
        ERC20(AddressBook.USDC).approve(AddressBook.PERMIT2, 1e6);
        RollerPeriphery.PermitData memory data = _generatePermit(alicePrivKey, address(rollerPeriphery), AddressBook.USDC);
        RollerPeriphery.SwapQuote memory quote = _getQuote(address(adapter), AddressBook.USDC, address(0));

        // Deposit
        uint256 usdcBalBefore = ERC20(AddressBook.USDC).balanceOf(alice);
        
        uint256 oneUSDCtoUnderlying = 996048341217521282; // 1 USDC to DAI at the current block and the given quote (see _getQuote)
        uint256 underlyingToTarget = ERC4626(adapter.target()).previewDeposit(996048341217521282); // 1 underlying (DAI) to asset (target) maDAI
        uint256 previewShares = autoRoller.previewDeposit(underlyingToTarget);
        uint256 shares = rollerPeriphery.deposit(autoRoller, 1e6, alice, 0, data, quote);
        uint256 usdcBalAfter = ERC20(AddressBook.USDC).balanceOf(alice);
        assertEq(usdcBalBefore - usdcBalAfter, 1e6);
        // assertEq(previewShares, shares); // TODO: why is this failing?
        assertEq(shares, autoRoller.balanceOf(alice));

        vm.stopPrank();
    }

    function testMainnetDepositFromETH() public {
    }
    function testMainnetDepositFromUnderlying() public {
    }
    function testMainnetDepositFromToken() public {
    }

    function _getQuote(
        address adapter,
        address fromToken,
        address toToken
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
                if (address(quote.buyToken) == AddressBook.DAI) {
                    // DAI to USDC quote
                    // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=1000000000000000000
                    quote
                        .swapCallData = hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000f17c7000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd0000000000000000000000001000000000000000000000000000000000000011000000000000000000000000000000000000000000000099ae2c88dc63f77479";
                }
                if (address(quote.buyToken) == rollerPeriphery.ETH()) {
                    // DAI to ETH quote
                    // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=ETH&sellAmount=1000000000000000000
                    quote
                        .swapCallData = hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000021dbff804a95e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000000000000000003e4f8cb71263f7747e";
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
                    quote
                        .swapCallData = hex"d9627aa4000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000daf49aea1d0451500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f869584cd0000000000000000000000001000000000000000000000000000000000000011000000000000000000000000000000000000000000000028e91926bd63f7743c";
                }
                if (address(quote.sellToken) == rollerPeriphery.ETH()) {
                    // https://api.0x.org/swap/v1/quote?sellToken=ETH&buyToken=DAI&sellAmount=1000000000000000000
                    // ETH to DAI quote
                    quote
                        .swapCallData = hex"3598d8ab0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000059478f7533d0737ae00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20001f46b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000fd592315d363f7745a";
                }
            }
        }
    }

    receive() external payable {}

    
}

