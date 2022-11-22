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

import { MockOwnableAdapter, BaseAdapter } from "../src/test/utils/MockOwnedAdapter.sol";
import { AddressBook } from "../src/test/utils/AddressBook.sol";
import { AutoRoller, RollerUtils, SpaceFactoryLike, DividerLike, PeripheryLike, OwnedAdapterLike } from "../src/AutoRoller.sol";
import { RollerPeriphery } from "../src/RollerPeriphery.sol";
import { AutoRollerFactory } from "../src/AutoRollerFactory.sol";
import { ProtocolFeesController, Authentication } from "../src/test/AutoRoller.t.sol";

contract MainnetDeploymentScript is Script {
    function run() external {
        vm.startBroadcast();

        console.log("Deploying from:", msg.sender);

        (BalancerVault balancerVault, SpaceFactoryLike spaceFactory) = (
            BalancerVault(AddressBook.BALANCER_VAULT),
            SpaceFactoryLike(AddressBook.SPACE_FACTORY_1_3_0)
        );
        Periphery periphery = Periphery(AddressBook.PERIPHERY_1_4_0);
        Divider divider = Divider(spaceFactory.divider());

        RollerUtils utils = RollerUtils(AddressBook.ROLLER_UTILS);

        RollerPeriphery rollerPeriphery = RollerPeriphery(AddressBook.ROLLER_PERIPHERY);

        AutoRollerFactory arFactory = new AutoRollerFactory(
            DividerLike(address(divider)),
            address(balancerVault),
            address(periphery),
            address(rollerPeriphery),
            utils,
            type(AutoRoller).creationCode
        );

        console2.log("Auto Roller Factory:", address(arFactory));

        arFactory.setIsTrusted(AddressBook.SENSE_MULTISIG, true);
        arFactory.setIsTrusted(msg.sender, false);

        vm.stopBroadcast();
    }
}