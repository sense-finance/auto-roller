// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.11;

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
import { AutoRoller, RollerUtils, SpaceFactoryLike, DividerLike, AdapterLike } from "../src/AutoRoller.sol";
import { ProtocolFeesController, Authentication } from "../src/test/AutoRoller.t.sol";

contract TestnetDeploymentScript is Script {
    function run() external {
        vm.startBroadcast();

        MockERC20 target = new MockERC20("cUSDC", "cUSDC", 18);
        MockERC20 underlying = new MockERC20("USDC", "USDC", 18);

        (BalancerVault balancerVault, SpaceFactoryLike spaceFactory) = (
            BalancerVault(AddressBook.BALANCER_VAULT),
            SpaceFactoryLike(AddressBook.SPACE_FACTORY_1_3_0)
        );
        Periphery periphery = Periphery(AddressBook.PERIPHERY_1_3_0);
        Divider divider = Divider(spaceFactory.divider());

        RollerUtils utils = new RollerUtils();

        BaseAdapter.AdapterParams memory mockAdapterParams = BaseAdapter.AdapterParams({
            oracle: address(0),
            stake: address(new MockERC20("Stake", "ST", 18)), // stake size is 0, so the we don't actually need any stake token
            stakeSize: 0,
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

        AutoRoller autoRoller = new AutoRoller(
            target,
            DividerLike(address(divider)),
            address(periphery),
            address(spaceFactory),
            address(balancerVault),
            AdapterLike(address(mockAdapter)),
            utils,
            msg.sender
        );

        mockAdapter.setIsTrusted(address(autoRoller), true);
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