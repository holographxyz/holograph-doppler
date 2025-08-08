// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/StdInvariant.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../mock/MockERC20.sol";

/// @title StakingRewardsInvariants
/// @notice Invariant tests for StakingRewards to ensure critical properties hold
contract StakingRewardsInvariants is StdInvariant, Test {
    StakingRewards public stakingRewards;
    MockERC20 public hlg;

    // Handler contract to perform valid operations
    StakingRewardsHandler public handler;

    function setUp() public {
        // Deploy contracts
        hlg = new MockERC20("HLG", "HLG");
        stakingRewards = new StakingRewards(address(hlg), address(this));

        // Set up staking rewards
        stakingRewards.setFeeRouter(address(this));
        stakingRewards.unpause();

        // Deploy handler
        handler = new StakingRewardsHandler(stakingRewards, hlg);

        // Set handler as target for invariant testing
        targetContract(address(handler));

        // Give handler some initial HLG for operations
        hlg.mint(address(handler), 1_000_000 ether);
    }

    /// @notice Core invariant: sum of all user balances equals totalStaked
    function invariant_totalStakedEqualsSumOfBalances() public view {
        uint256 sumOfBalances = 0;
        address[] memory users = handler.getUsers();

        for (uint256 i = 0; i < users.length; i++) {
            sumOfBalances += stakingRewards.balanceOf(users[i]);
        }

        assertEq(stakingRewards.totalStaked(), sumOfBalances, "Invariant violated: totalStaked != sum(balanceOf)");
    }

    /// @notice Global reward index should never decrease
    function invariant_globalRewardIndexNeverDecreases() public view {
        uint256 currentIndex = stakingRewards.globalRewardIndex();
        uint256 lastIndex = handler.lastGlobalRewardIndex();

        assertGe(currentIndex, lastIndex, "Invariant violated: globalRewardIndex decreased");
    }
}

/// @title StakingRewardsHandler
/// @notice Handler contract that performs valid operations on StakingRewards
contract StakingRewardsHandler is Test {
    StakingRewards public immutable stakingRewards;
    MockERC20 public immutable hlg;

    address[] public users;
    mapping(address => bool) public isUser;

    uint256 public lastGlobalRewardIndex;

    constructor(StakingRewards _stakingRewards, MockERC20 _hlg) {
        stakingRewards = _stakingRewards;
        hlg = _hlg;
    }

    /// @notice Stake tokens for a random user
    function stake(uint256 userSeed, uint256 amount) public {
        // Bound inputs
        amount = bound(amount, 1 ether, 100 ether);
        address user = _getOrCreateUser(userSeed);

        // Record state before
        lastGlobalRewardIndex = stakingRewards.globalRewardIndex();

        // Give user tokens and stake
        hlg.mint(user, amount);
        vm.startPrank(user);
        hlg.approve(address(stakingRewards), amount);
        stakingRewards.stake(amount);
        vm.stopPrank();
    }

    /// @notice Unstake for a random existing user
    function unstake(uint256 userSeed) public {
        if (users.length == 0) return;

        address user = users[userSeed % users.length];
        if (stakingRewards.balanceOf(user) == 0) return;

        // Record state before
        lastGlobalRewardIndex = stakingRewards.globalRewardIndex();

        vm.prank(user);
        stakingRewards.unstake();
    }

    /// @notice Add rewards to the pool
    function addRewards(uint256 amount) public {
        amount = bound(amount, 1 ether, 100 ether);

        // Record state before
        lastGlobalRewardIndex = stakingRewards.globalRewardIndex();

        hlg.approve(address(stakingRewards), amount);
        stakingRewards.addRewards(amount);
    }

    /// @notice Update rewards for a random user
    function updateUser(uint256 userSeed) public {
        if (users.length == 0) return;

        address user = users[userSeed % users.length];

        // Record state before
        lastGlobalRewardIndex = stakingRewards.globalRewardIndex();

        stakingRewards.updateUser(user);
    }

    /// @notice Emergency exit for a random user
    function emergencyExit(uint256 userSeed) public {
        if (users.length == 0) return;

        address user = users[userSeed % users.length];
        if (stakingRewards.balanceOf(user) == 0) return;

        // Record state before
        lastGlobalRewardIndex = stakingRewards.globalRewardIndex();

        vm.prank(user);
        stakingRewards.emergencyExit();
    }

    /// @notice Get all users
    function getUsers() public view returns (address[] memory) {
        return users;
    }

    /// @notice Get or create a user based on seed
    function _getOrCreateUser(uint256 seed) internal returns (address) {
        // Use a small set of users for better coverage
        address user = address(uint160(1 + (seed % 10)));

        if (!isUser[user]) {
            users.push(user);
            isUser[user] = true;
        }

        return user;
    }
}
