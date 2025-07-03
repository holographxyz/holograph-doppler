// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockStakingRewards
 * @notice Mock StakingRewards contract for testing
 */
contract MockStakingRewards {
    using SafeERC20 for IERC20;

    IERC20 public immutable hlgToken;

    uint256 public totalRewardsAdded;
    mapping(address => uint256) public rewardsAddedBy;

    event RewardsAdded(address indexed from, uint256 amount);

    constructor(address _hlgToken) {
        hlgToken = IERC20(_hlgToken);
    }

    function addRewards(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");

        // Transfer HLG from caller
        hlgToken.safeTransferFrom(msg.sender, address(this), amount);

        // Track rewards
        totalRewardsAdded += amount;
        rewardsAddedBy[msg.sender] += amount;

        emit RewardsAdded(msg.sender, amount);
    }

    // View functions for testing
    function getTotalRewards() external view returns (uint256) {
        return totalRewardsAdded;
    }

    function getRewardsAddedBy(address account) external view returns (uint256) {
        return rewardsAddedBy[account];
    }

    function getBalance() external view returns (uint256) {
        return hlgToken.balanceOf(address(this));
    }
}
