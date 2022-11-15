// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.13;

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

import { MockOwnableAdapter, BaseAdapter } from "../src/test/utils/MockOwnedAdapter.sol";
import { AddressBook } from "../src/test/utils/AddressBook.sol";
import { AutoRoller, RollerUtils, SpaceFactoryLike, DividerLike, PeripheryLike, OwnedAdapterLike } from "../src/AutoRoller.sol";
import { RollerPeriphery } from "../src/RollerPeriphery.sol";
import { AutoRollerFactory } from "../src/AutoRollerFactory.sol";
import { ProtocolFeesController, Authentication } from "../src/test/AutoRoller.t.sol";

contract TestnetDeploymentScript is Script {

    address public constant REWARDS_RECIPIENT = address(1);
    uint256 public constant TARGET_DURATION = 3;
    uint256 public constant TARGETED_RATE = 2.9e18;

    function run() external {
        vm.startBroadcast();

        console.log("Deploying from:", msg.sender);

        MockERC20 target = new MockERC20("cUSDC", "cUSDC", 18);
        MockERC20 underlying = new MockERC20("USDC", "USDC", 18);
        MockERC20 stake = new MockERC20("STAKE", "ST", 18);

        console2.log("Target:", address(target));
        console2.log("Underlying:", address(underlying));
        console2.log("Stake:", address(stake));

        (BalancerVault balancerVault, SpaceFactoryLike spaceFactory) = (
            BalancerVault(AddressBook.BALANCER_VAULT),
            SpaceFactoryLike(AddressBook.SPACE_FACTORY_1_3_0)
        );
        Periphery periphery = Periphery(AddressBook.PERIPHERY_1_4_0);
        Divider divider = Divider(spaceFactory.divider());

        RollerUtils utils = new RollerUtils();

        RollerPeriphery rollerPeriphery = new RollerPeriphery();

        AutoRollerFactory arFactory = new AutoRollerFactory(
            DividerLike(address(divider)),
            address(balancerVault),
            address(periphery),
            address(rollerPeriphery),
            utils,
            type(AutoRoller).creationCode
        );

        console2.log("Auto Roller Factory:", address(arFactory));

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

        console2.log("Mock Adapter:", address(mockAdapter));

        mockAdapter.setIsTrusted(address(arFactory), true);

        AutoRoller autoRoller = arFactory.create(
            OwnedAdapterLike(address(mockAdapter)),
            REWARDS_RECIPIENT,
            TARGET_DURATION
        );

        console2.log("Auto Roller ", address(autoRoller));

        periphery.onboardAdapter(address(mockAdapter), true);
        divider.setGuard(address(mockAdapter), type(uint256).max);

        target.mint(msg.sender, 2e18);
        target.approve(address(autoRoller), 2e18);

        // Set protocol fees
        ProtocolFeesController protocolFeesCollector = ProtocolFeesController(balancerVault.getProtocolFeesCollector());
        Authentication authorizer = Authentication(balancerVault.getAuthorizer());
        bytes32 actionId = Authentication(address(protocolFeesCollector)).getActionId(protocolFeesCollector.setSwapFeePercentage.selector);
        authorizer.grantRole(actionId, msg.sender);
        protocolFeesCollector.setSwapFeePercentage(0.1e18);

        // Roll into the first Series
        autoRoller.roll();

        vm.stopBroadcast();
    }
}