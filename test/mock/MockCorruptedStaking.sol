// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/StakingRewards.sol";

/**
 * @notice Mock staking contract that allows direct manipulation of unallocatedRewards for testing
 */
contract MockCorruptedStaking is StakingRewards {
    constructor(address _hlg, address _owner) StakingRewards(_hlg, _owner) {}

    /**
     * @notice Allows direct manipulation of unallocatedRewards for testing error conditions
     */
    function corruptUnallocatedRewards(uint256 newAmount) external {
        unallocatedRewards = newAmount;
    }
}
