// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.13;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { Trust } from "sense-v1-utils/Trust.sol";

import { AutoRoller, DividerLike, OwnedAdapterLike, RollerUtils, PeripheryLike } from "./AutoRoller.sol";
import { BaseSplitCodeFactory } from "./BaseSplitCodeFactory.sol";

interface RollerPeripheryLike {
    function approve(ERC20,address,uint256) external;
}

contract AutoRollerFactory is Trust, BaseSplitCodeFactory {
    DividerLike internal immutable divider;
    address     internal immutable balancerVault;

    PeripheryLike       public periphery;
    RollerPeripheryLike public rollerPeriphery;
    RollerUtils         public utils;

    mapping(address => AutoRoller[]) public rollers;

    /// @dev `_creationCode` should equal `type(AutoRoller).creationCode`
    constructor(
        DividerLike _divider,
        address _balancerVault,
        address _periphery,
        address _rollerPeriphery,
        RollerUtils _utils,
        bytes memory _creationCode
    ) Trust(msg.sender) BaseSplitCodeFactory(_creationCode) {
        divider         = _divider;
        balancerVault   = _balancerVault;
        periphery       = PeripheryLike(_periphery);
        rollerPeriphery = RollerPeripheryLike(_rollerPeriphery);
        utils           = _utils;
    }

    function create(
        OwnedAdapterLike adapter,
        address rewardRecipient,
        uint256 targetDuration
    ) external returns (AutoRoller autoRoller) {
        address target = adapter.target();

        bytes memory constructorArgs = abi.encode(
            ERC20(target),
            divider,
            address(periphery),
            address(periphery.spaceFactory()),
            address(balancerVault),
            adapter,
            utils,
            rewardRecipient
        );
        bytes32 salt = keccak256(abi.encode(constructorArgs, rollers[address(adapter)].length));

        autoRoller = AutoRoller(super._create(constructorArgs, salt));

        // Factory must have adapter auth so that it can give auth to the roller
        adapter.setIsTrusted(address(autoRoller), true);

        autoRoller.setParam("TARGET_DURATION", targetDuration);
        autoRoller.setParam("OWNER", msg.sender);

        // Allow the new roller to move the roller periphery's target
        rollerPeriphery.approve(ERC20(target), address(autoRoller), type(uint256).max);

        rollers[address(adapter)].push(autoRoller);

        emit RollerCreated(address(adapter), address(autoRoller));
    }

    /// @notice Update the address for the Periphery
    /// @param newPeriphery The Periphery addresss to set
    function setPeriphery(address newPeriphery) external requiresTrust {
        emit PeripheryChanged(address(periphery), newPeriphery);
        periphery = PeripheryLike(newPeriphery);
    }

    /// @notice Update the address for the Roller Periphery
    /// @param newRollerPeriphery The Roller Periphery addresss to set
    function setRollerPeriphery(address newRollerPeriphery) external requiresTrust {
        emit RollerPeripheryChanged(address(rollerPeriphery), newRollerPeriphery);
        rollerPeriphery = RollerPeripheryLike(newRollerPeriphery);
    }

    /// @notice Update the address for the Utils
    /// @param newUtils The Utils addresss to set
    function setUtils(address newUtils) external requiresTrust {
        emit UtilsChanged(address(utils), newUtils);
        utils = RollerUtils(newUtils);
    }

    event PeripheryChanged(address indexed adapter, address autoRoller);
    event RollerPeripheryChanged(address indexed adapter, address autoRoller);
    event UtilsChanged(address indexed adapter, address autoRoller);
    event RollerCreated(address indexed adapter, address autoRoller);
}