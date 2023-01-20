// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { AddressBook } from "./utils/AddressBook.sol";

import { MockERC20 } from "solmate/test/utils/mocks/MockERC20.sol";
import { MockERC4626 } from "solmate/test/utils/mocks/MockERC4626.sol";
import { AutoRollerAdapterDeployer } from "../AutoRollerAdapterDeployer.sol";
import { AutoRoller, OwnedAdapterLike } from "../AutoRoller.sol";
import { OwnableERC4626Factory } from "sense-v1-core/adapters/abstract/factories/OwnableERC4626Factory.sol";
import { Periphery } from "sense-v1-core/Periphery.sol";

contract AutoRollerAdapterDeployerTest is Test {
    MockERC4626 target;
    MockERC20 underlying;

    address public constant REWARDS_RECIPIENT = address(0x1);
    uint256 public constant TARGET_DURATION = 3;

    AutoRollerAdapterDeployer deployer;
    address adapterFactory;

    function setUp() public {
        underlying = new MockERC20("Underlying", "Underlying", 18);
        target = new MockERC4626(underlying, "Target", "Target");

        adapterFactory = address(AddressBook.OWNABLE_ERC4626_FACTORY);
        
        vm.prank(address(AddressBook.SENSE_MULTISIG));
        Periphery periphery = Periphery(address(AddressBook.PERIPHERY_1_4_0));
        if (!periphery.factories(adapterFactory)) {
            periphery.setFactory(adapterFactory, true);
        }

        vm.prank(address(AddressBook.SENSE_MULTISIG));
        OwnableERC4626Factory(adapterFactory).supportTarget(address(target), true);

        deployer = new AutoRollerAdapterDeployer(address(AddressBook.PERIPHERY_1_4_0));
    }

    function testDeployAdapterAndRoller() public {
        (address adapter, AutoRoller ar) = deployer.deploy(address(adapterFactory), address(target), "", REWARDS_RECIPIENT, TARGET_DURATION);
        assertEq(address(ar.adapter()), adapter);
        
        // quick test that the adapter has the expected interface.
        vm.expectRevert("UNTRUSTED");
        OwnedAdapterLike(adapter).openSponsorWindow();
    }
}