// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.11;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { Trust } from "sense-v1-utils/Trust.sol";

import { AutoRoller, DividerLike, OwnedAdapterLike, RollerUtils, PeripheryLike } from "./AutoRoller.sol";
import { BaseSplitCodeFactory } from "./BaseSplitCodeFactory.sol";

// immutable target date
// compute address vs registry

contract AutoRollerFactory is Trust, BaseSplitCodeFactory {
    DividerLike internal immutable divider;
    address     internal immutable balancerVault;

    address     public periphery;
    RollerUtils public utils;

    /// @dev `_creationCode` should equal `type(AutoRoller).creationCode`
    constructor(
        DividerLike _divider,
        address _balancerVault,
        address _periphery,
        RollerUtils _utils,
        bytes memory _creationCode
    ) Trust(msg.sender) BaseSplitCodeFactory(_creationCode) {
        divider       = _divider;
        balancerVault = _balancerVault;
        periphery    = _periphery;
        utils        = _utils;
    }

    function create(
        OwnedAdapterLike adapter,
        address rewardRecipient,
        uint256 targetDuration,
        uint256 targetedRate
    ) external returns (AutoRoller autoRoller) {
        bytes memory constructorArgs = abi.encode(
            ERC20(adapter.target()),
            divider,
            address(periphery),
            address(PeripheryLike(periphery).spaceFactory()),
            address(balancerVault),
            adapter,
            utils,
            rewardRecipient
        );
        bytes32 salt = keccak256(constructorArgs);

        autoRoller = AutoRoller(super._create(constructorArgs, salt));

        // Factory must have adapter auth
        adapter.setIsTrusted(address(autoRoller), true);

        autoRoller.setParam("TARGET_DURATION", targetDuration);
        autoRoller.setParam("TARGETED_RATE", targetedRate);
        autoRoller.setParam("OWNER", msg.sender);

        emit RollerCreated(address(adapter), address(autoRoller));
    }

    function addRoller(address adapter, address autoRoller) public requiresTrust {
        emit RollerCreated(adapter, autoRoller);
    }

    event RollerCreated(address indexed adapter, address autoRoller);
}