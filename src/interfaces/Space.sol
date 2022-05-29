// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.11;

import { ERC20 } from "solmate/tokens/ERC20.sol";

import { BalancerVault } from "./BalancerVault.sol";

interface Space {
    function getTimeWeightedAverage(OracleAverageQuery[] memory queries)
        external
        view
        returns (uint256[] memory results);

    enum Variable {
        PAIR_PRICE,
        BPT_PRICE,
        INVARIANT
    }
    struct OracleAverageQuery {
        Variable variable;
        uint256 secs;
        uint256 ago;
    }

    function getSample(uint256 index)
        external
        view
        returns (
            int256 logPairPrice,
            int256 accLogPairPrice,
            int256 logBptPrice,
            int256 accLogBptPrice,
            int256 logInvariant,
            int256 accLogInvariant,
            uint256 timestamp
        );

    function getPoolId() external view returns (bytes32);
    function getVault() external view returns (address);
    function totalSupply() external view returns (uint256);
    function pti() external view returns (uint256);
    function ts() external view returns (uint256);
    function g1() external view returns (uint256);
    function g2() external view returns (uint256);
    function maturity() external view returns (uint256);
    
    struct SwapRequest {
        BalancerVault.SwapKind kind;
        ERC20 tokenIn;
        ERC20 tokenOut;
        uint256 amount;
        // Misc data
        bytes32 poolId;
        uint256 lastChangeBlock;
        address from;
        address to;
        bytes userData;
    }

    function onSwap(
        SwapRequest memory swapRequest,
        uint256 currentBalanceTokenIn,
        uint256 currentBalanceTokenOut
    ) 
    external 
    view // This is a lie. But it indeed will only mutate storage if called by the Balancer Vault, so it's true for our purposes here.
    returns (uint256);

    function getIndices() external view returns (uint256 pti, uint256 targeti);
    function balanceOf(address user) external view returns (uint256 amount);
    function getPriceFromImpliedRate(uint256 impliedRate) external view returns (uint256 pTPriceInTarget);
    
    function getTotalSamples() external view returns (uint256);
    function getLargestSafeQueryWindow() external view returns (uint256);
}