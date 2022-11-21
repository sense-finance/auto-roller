// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

interface BalancerOracle {
    enum Variable { PAIR_PRICE, BPT_PRICE, INVARIANT }

    function getTimeWeightedAverage(OracleAverageQuery[] memory queries)
        external
        view
        returns (uint256[] memory results);

    function getLatest(Variable variable) external view returns (uint256);

    struct OracleAverageQuery {
        Variable variable;
        uint256 secs;
        uint256 ago;
    }

    function getLargestSafeQueryWindow() external view returns (uint256);

    function getPastAccumulators(OracleAccumulatorQuery[] memory queries)
        external
        view
        returns (int256[] memory results);

    struct OracleAccumulatorQuery {
        Variable variable;
        uint256 ago;
    }
}
