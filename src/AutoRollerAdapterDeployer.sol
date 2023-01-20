// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;
import { AutoRoller, PeripheryLike, OwnedAdapterLike } from "./AutoRoller.sol";

interface OwnableFactoryLike {
    function rlvFactory() external view returns (address);
    function deployAdapter(address, bytes memory) external returns (address);
}

interface AutoRollerFactoryLike {
    function create(
        OwnedAdapterLike,
        address rewardRecipient,
        uint256 targetDuration
    ) external returns (AutoRoller);
}

contract AutoRollerAdapterDeployer {
    PeripheryLike internal immutable periphery;

    constructor(address _periphery) {
        periphery = PeripheryLike(_periphery);
    }

    /// @notice Deploys an OwnableERC4626Adapter contract
    /// @param factory The factory
    /// @param target The target address
    /// @param data ABI encoded reward tokens address array
    /// @param rewardRecipient The address of the reward recipient
    /// @param targetDuration The duration of each series
    function deploy(address factory, address target, bytes memory data, address rewardRecipient, uint256 targetDuration) external returns (address adapter, AutoRoller autoRoller) {
        adapter = periphery.deployAdapter(factory, target, data);
        autoRoller = AutoRollerFactoryLike(OwnableFactoryLike(factory).rlvFactory()).create(OwnedAdapterLike(adapter), rewardRecipient, targetDuration);
    }
}