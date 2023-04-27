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

        address senseMultisig = 0xDd76360C26Eaf63AFCF3a8d2c0121F13AE864D57;
        console.log("Sense multisig is:", senseMultisig);

        // get contracts
        (BalancerVault balancerVault, SpaceFactoryLike spaceFactory) = (
            BalancerVault(AddressBook.BALANCER_VAULT),
            SpaceFactoryLike(AddressBook.SPACE_FACTORY_1_3_0)
        );
        // TODO: replace for new periphery once its deployed
        Periphery periphery = Periphery(AddressBook.PERIPHERY_1_4_0); 
        Divider divider = Divider(spaceFactory.divider());
        AutoRollerFactory arFactory = AutoRollerFactory(AddressBook.RLV_FACTORY);

        console.log("-------------------------------------------------------");
        console.log("Deploy Roller Periphery v2");
        console.log("-------------------------------------------------------");

        vm.startBroadcast(deployer); // deploy from deployer address

        RollerPeriphery rollerPeriphery = new RollerPeriphery(IPermit2(AddressBook.PERMIT2), AddressBook.EXCHANGE_PROXY);
        console2.log("- RollerPeriphery deployed @ ", address(arFactory));

        console.log("- Add AutoRoller factory as trusted on RollerPeriphery");
        rollerPeriphery.setIsTrusted(address(arFactory), true);

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
}