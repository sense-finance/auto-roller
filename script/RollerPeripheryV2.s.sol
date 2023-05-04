// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

import "forge-std/Script.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { MockERC20 } from "solmate/test/utils/mocks/MockERC20.sol";
import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";

import { Divider, TokenHandler } from "sense-v1-core/Divider.sol";
import { Periphery } from "sense-v1-core/Periphery.sol";
import { YT } from "sense-v1-core/tokens/YT.sol";
import { Errors as SenseCoreErrors } from "sense-v1-utils/libs/Errors.sol";

import { Space } from "../src/interfaces/Space.sol";
import { BalancerVault } from "../src/interfaces/BalancerVault.sol";
import { IPermit2 } from "../src/interfaces/IPermit2.sol";

import { MockOwnableAdapter, BaseAdapter } from "../src/test/utils/MockOwnedAdapter.sol";
import { AddressBook } from "../src/test/utils/AddressBook.sol";
import { AutoRoller, RollerUtils, SpaceFactoryLike, DividerLike, PeripheryLike, OwnedAdapterLike } from "../src/AutoRoller.sol";
import { RollerPeriphery } from "../src/RollerPeriphery.sol";
import { AutoRollerFactory } from "../src/AutoRollerFactory.sol";
import { ProtocolFeesController, Authentication } from "../src/test/AutoRoller.t.sol";

// Deploys RollerPeriphery v2
contract MainnetDeploymentScript is Script {
    uint256 public mainnetFork;
    string public MAINNET_RPC_URL = vm.envString("RPC_URL_MAINNET");

    uint8 public constant MAINNET = 1;
    uint8 public constant FORK = 111;
    address public constant REWARDS_RECIPIENT = address(1);
    uint256 public constant TARGET_DURATION = 3;
    uint256 public constant TARGETED_RATE = 2.9e18;

    function run() external {
        uint256 chainId = block.chainid;
        console.log("Chain ID:", chainId);

        if (chainId == FORK) {
            mainnetFork = vm.createFork(MAINNET_RPC_URL);
            vm.selectFork(mainnetFork);
        }

        // Get deployer from mnemonic
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.rememberKey(deployerPrivateKey);
        console.log("Deploying from:", deployer);

        address senseMultisig = AddressBook.SENSE_MULTISIG;
        console.log("Sense multisig is:", senseMultisig);

        // get contracts
        (BalancerVault balancerVault, SpaceFactoryLike spaceFactory) = (
            BalancerVault(AddressBook.BALANCER_VAULT),
            SpaceFactoryLike(AddressBook.SPACE_FACTORY_1_3_0)
        );

        // TODO: replace for new periphery once its deployed
        Periphery periphery = Periphery(payable(AddressBook.PERIPHERY_1_4_0)); 
        Divider divider = Divider(spaceFactory.divider());
        AutoRollerFactory arFactory = AutoRollerFactory(AddressBook.RLV_FACTORY);

        console.log("-------------------------------------------------------");
        console.log("Deploy Roller Periphery v2");
        console.log("-------------------------------------------------------");

        vm.startBroadcast(deployer); // deploy from deployer address

        RollerPeriphery rollerPeriphery = new RollerPeriphery(IPermit2(AddressBook.PERMIT2), AddressBook.EXCHANGE_PROXY);
        console2.log("- RollerPeriphery deployed @ ", address(rollerPeriphery));

        console.log("- Add AutoRoller factory as trusted on RollerPeriphery");
        rollerPeriphery.setIsTrusted(address(arFactory), true);

        _doApprovals(rollerPeriphery);

        vm.stopBroadcast();

        // mainnet would require multisig to make these calls
        if (chainId != MAINNET) {
            console.log("- Fund multisig to be able to make calls from that address");
            vm.deal(senseMultisig, 1 ether);

            // broadcast following txs from multisig
            vm.startPrank(address(senseMultisig));

            arFactory.setRollerPeriphery(address(rollerPeriphery));
            console2.log("- New RollerPeriphery has been set on AutoRoller factory");
            
            // TODO: replace for new periphery once its deployed
            arFactory.setPeriphery(AddressBook.PERIPHERY_1_4_0);
            console2.log("- New Periphery has been set on AutoRoller factory");

            vm.stopPrank();
        }

        console.log("-------------------------------------------------------");
        console.log("Sanity check: deploy mock tokens, a mock ownable adapter and create an AutoRoller");
        console.log("-------------------------------------------------------");

        MockERC20 target = new MockERC20("cUSDC", "cUSDC", 18);
        MockERC20 underlying = new MockERC20("USDC", "USDC", 18);
        MockERC20 stake = new MockERC20("STAKE", "ST", 18);

        BaseAdapter.AdapterParams memory mockAdapterParams = BaseAdapter.AdapterParams({
            oracle: address(0),
            stake: address(stake),
            stakeSize: 0.1e18,
            minm: 0, // 0 minm, so there's not lower bound on future maturity
            maxm: type(uint64).max, // large maxm, so there's not upper bound on future maturity
            mode: 0, // monthly maturities
            tilt: 0, // no principal reserved for YTs
            level: 31 // default level, everything is allowed except for the redemption cb
        });

        MockOwnableAdapter mockAdapter = new MockOwnableAdapter(
            address(divider),
            address(target),
            address(underlying),
            mockAdapterParams
        );

        mockAdapter.setIsTrusted(address(arFactory), true);

        AutoRoller autoRoller = arFactory.create(
            OwnedAdapterLike(address(mockAdapter)),
            REWARDS_RECIPIENT,
            TARGET_DURATION
        );

        console2.log("- RLV created @ ", address(autoRoller));

        vm.prank(address(senseMultisig));
        periphery.onboardAdapter(address(mockAdapter), true);

        vm.prank(address(senseMultisig));
        divider.setGuard(address(mockAdapter), type(uint256).max);

        stake.mint(address(this), 0.1e18);
        stake.approve(address(autoRoller), 0.1e18);

        target.mint(address(this), 2e18);
        target.approve(address(autoRoller), 2e18);

        // Roll into the first Series
        autoRoller.roll();
        console2.log("- Series successfully rolled!");
    }

    function _doApprovals(RollerPeriphery rollerPeriphery) internal {
        // RLVs
        address WSTETH_RLV = 0xeb9e7e1F892Bb2931e8C319D6F10FDf147090818;
        address MAUSDC_RLV = 0x5A41f64eaf49d1582A289B197A4c5D64b2342aAe;
        address MAUSDT_RLV = 0x321DfB34851E1663C91d07Cb5496e55A70aDE253;
        address SANFRAX_EUR_WRAPPER_RLV = 0x419BC9B5c22A1800E6bFB94136a4b0e7c9F63d60;
        address IDLE_USDC_JUNIOR_4626_RLV = 0x11f4a165f077186123b10444c14C01b68a770140;
        address AURAWSTETH_RETH_SFRXETH_BPT_VAULT_WRAPPER_RLV = 0xCDCf0fa94217B0a5Bc7E6650A78c1302eCd5D067;

        address[] memory rlvAddresses = new address[](6);
        rlvAddresses[0] = WSTETH_RLV;
        rlvAddresses[1] = MAUSDC_RLV;
        rlvAddresses[2] = MAUSDT_RLV;
        rlvAddresses[3] = SANFRAX_EUR_WRAPPER_RLV;
        rlvAddresses[4] = IDLE_USDC_JUNIOR_4626_RLV;
        rlvAddresses[5] = AURAWSTETH_RETH_SFRXETH_BPT_VAULT_WRAPPER_RLV;
        
        for (uint256 i = 0; i < 6; i++) {
            AutoRoller rlv = AutoRoller(rlvAddresses[i]);
            console2.log("- Making approvals for RLV %s", rlv.name());
            OwnedAdapterLike adapter = rlv.adapter();
            ERC20 target = ERC20(adapter.target());
            ERC20 underlying = ERC20(adapter.underlying());

            // Allow the new roller to move the roller periphery's target
            if (target.allowance(address(rollerPeriphery), address(rlv)) == 0) {
                rollerPeriphery.approve(target, address(rlv));
            }

            // Allow the adapter to move the roller periphery's underlying & target if it can't already
            if (underlying.allowance(address(rollerPeriphery), address(adapter)) == 0) {
                rollerPeriphery.approve(underlying, address(adapter));
            }
            if (target.allowance(address(rollerPeriphery), address(adapter)) == 0) {
                rollerPeriphery.approve(target, address(adapter));
            }
        }
    }
}