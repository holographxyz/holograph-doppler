// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockZeroSinkNoBurn} from "./mock/MockZeroSinkNoBurn.sol";
import {MockFeeOnTransfer} from "./mock/MockFeeOnTransfer.sol";
import {MockCorruptedStaking} from "./mock/MockCorruptedStaking.sol";

/**
 * @title StakingRewardsConsolidated
 * @notice Consolidated test suite for StakingRewards contract covering:
 * - Basic functionality (stake/unstake/emergency)
 * - Reward distribution and compounding
 * - Virtual compounding model tests
 * - Admin functions and security
 * - Edge cases and error conditions
 * - Fork tests with real HLG token
 */
contract StakingRewardsConsolidated is Test {
    StakingRewards public stakingRewards;
    MockERC20 public hlg;

    address public owner = address(0x1);
    address public feeRouter = address(0x2);
    address public alice = address(0x3);
    address public bob = address(0x4);
    address public charlie = address(0x5);
    address public distributor = address(0x6);

    uint256 public constant INITIAL_SUPPLY = 1000000 ether;
    uint256 public constant STAKE_AMOUNT = 1000 ether;
    uint256 public constant REWARD_AMOUNT = 100 ether;

    // Real HLG token address on Base for fork tests
    address constant HLG_ADDRESS = 0x740df024CE73f589ACD5E8756b377ef8C6558BaB;
    address constant HLG_HOLDER = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;

    /* -------------------------------------------------------------------------- */
    /*                                   Setup                                    */
    /* -------------------------------------------------------------------------- */

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock HLG token
        hlg = new MockERC20("Test HLG", "HLG");

        // Deploy staking contract
        stakingRewards = new StakingRewards(address(hlg), owner);
        stakingRewards.setFeeRouter(feeRouter);
        stakingRewards.unpause();

        vm.stopPrank();

        // Mint tokens for testing
        hlg.mint(alice, INITIAL_SUPPLY);
        hlg.mint(bob, INITIAL_SUPPLY);
        hlg.mint(charlie, INITIAL_SUPPLY);
        hlg.mint(owner, INITIAL_SUPPLY);
        hlg.mint(feeRouter, INITIAL_SUPPLY);
        hlg.mint(distributor, INITIAL_SUPPLY);
    }

    /* -------------------------------------------------------------------------- */
    /*                            Basic Staking Tests                            */
    /* -------------------------------------------------------------------------- */

    function testStakeAndWithdraw() public {
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), STAKE_AMOUNT);
        stakingRewards.stake(STAKE_AMOUNT);

        assertEq(stakingRewards.balanceOf(alice), STAKE_AMOUNT);
        assertEq(stakingRewards.totalStaked(), STAKE_AMOUNT);

        stakingRewards.unstake();
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.totalStaked(), 0);
        vm.stopPrank();
    }

    function testEmergencyExit() public {
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), STAKE_AMOUNT);
        stakingRewards.stake(STAKE_AMOUNT);

        uint256 balanceBefore = hlg.balanceOf(alice);
        stakingRewards.emergencyExit();

        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(hlg.balanceOf(alice), balanceBefore + STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testCannotStakeZeroAmount() public {
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), STAKE_AMOUNT);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        stakingRewards.stake(0);
        vm.stopPrank();
    }

    function testCannotUnstakeWithNoStake() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewards.NoStake.selector);
        stakingRewards.unstake();
    }

    /* -------------------------------------------------------------------------- */
    /*                         Reward Distribution Tests                         */
    /* -------------------------------------------------------------------------- */

    function testAutoCompoundingRewards() public {
        // Alice stakes
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), STAKE_AMOUNT);
        stakingRewards.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Distribute rewards (50% burn, 50% rewards)
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), REWARD_AMOUNT);
        stakingRewards.depositAndDistribute(REWARD_AMOUNT);
        vm.stopPrank();

        // Check pending rewards
        uint256 expectedRewards = REWARD_AMOUNT / 2; // 50% of 100 = 50
        assertEq(stakingRewards.earned(alice), expectedRewards);

        // Update user to compound
        stakingRewards.updateUser(alice);
        assertEq(stakingRewards.balanceOf(alice), STAKE_AMOUNT + expectedRewards);
        assertEq(stakingRewards.earned(alice), 0);
    }

    function testFeeRouterAddRewards() public {
        // Alice stakes
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), STAKE_AMOUNT);
        stakingRewards.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // FeeRouter distributes rewards
        vm.startPrank(feeRouter);
        hlg.approve(address(stakingRewards), REWARD_AMOUNT);
        stakingRewards.addRewards(REWARD_AMOUNT);
        vm.stopPrank();

        uint256 expectedRewards = REWARD_AMOUNT / 2;
        assertEq(stakingRewards.earned(alice), expectedRewards);
    }

    function testAddRewardsOnlyRouter() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewards.Unauthorized.selector);
        stakingRewards.addRewards(REWARD_AMOUNT);
    }

    function testMultipleUsersProportionalRewards() public {
        // Alice stakes 300, Bob stakes 200
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), 300 ether);
        stakingRewards.stake(300 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        hlg.approve(address(stakingRewards), 200 ether);
        stakingRewards.stake(200 ether);
        vm.stopPrank();

        // Distribute 100 HLG (50 rewards after 50% burn)
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), 100 ether);
        stakingRewards.depositAndDistribute(100 ether);
        vm.stopPrank();

        // Alice should get 60% (30 HLG), Bob should get 40% (20 HLG)
        assertEq(stakingRewards.earned(alice), 30 ether);
        assertEq(stakingRewards.earned(bob), 20 ether);

        // Update both users
        stakingRewards.updateUser(alice);
        stakingRewards.updateUser(bob);

        assertEq(stakingRewards.balanceOf(alice), 330 ether);
        assertEq(stakingRewards.balanceOf(bob), 220 ether);
    }

    /* -------------------------------------------------------------------------- */
    /*                      Virtual Compounding Model Tests                      */
    /* -------------------------------------------------------------------------- */

    function testNoDoubleCountingAcrossMultipleDistributions() public {
        // Two users stake 100 each
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), 100 ether);
        stakingRewards.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        hlg.approve(address(stakingRewards), 100 ether);
        stakingRewards.stake(100 ether);
        vm.stopPrank();

        // Distribute 60 HLG, don't call updateUser
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), 60 ether);
        stakingRewards.depositAndDistribute(60 ether);
        vm.stopPrank();

        // With 50% burn, reward amount should be 30 ether
        uint256 expectedReward = 30 ether;
        assertEq(stakingRewards.unallocatedRewards(), expectedReward);
        assertEq(stakingRewards.totalStaked(), 200 ether + expectedReward);

        // Distribute 40 HLG again, still no updates
        vm.startPrank(feeRouter);
        hlg.approve(address(stakingRewards), 40 ether);
        stakingRewards.addRewards(40 ether);
        vm.stopPrank();

        // Additional reward should be 20 ether (50% of 40)
        uint256 additionalReward = 20 ether;
        uint256 totalExpectedReward = expectedReward + additionalReward;
        assertEq(stakingRewards.unallocatedRewards(), totalExpectedReward);
        assertEq(stakingRewards.totalStaked(), 200 ether + totalExpectedReward);

        // Now updateUser both users
        stakingRewards.updateUser(alice);
        stakingRewards.updateUser(bob);

        // Each user should get exactly 25 ether in rewards (50 total rewards split equally)
        assertEq(stakingRewards.balanceOf(alice), 125 ether); // 100 original + 25 rewards
        assertEq(stakingRewards.balanceOf(bob), 125 ether); // 100 original + 25 rewards

        // unallocatedRewards should be 0
        assertEq(stakingRewards.unallocatedRewards(), 0);

        // Sum of balances should equal totalStaked
        uint256 sumBalances = stakingRewards.balanceOf(alice) + stakingRewards.balanceOf(bob);
        assertEq(sumBalances, stakingRewards.totalStaked());
    }

    function testDenominatorCorrectness() public {
        // Alice stakes 100, Bob stakes 200
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), 100 ether);
        stakingRewards.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        hlg.approve(address(stakingRewards), 200 ether);
        stakingRewards.stake(200 ether);
        vm.stopPrank();

        // Distribute 90 HLG (45 rewards)
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), 90 ether);
        stakingRewards.depositAndDistribute(90 ether);
        vm.stopPrank();

        // Now totalStaked = 345, unallocated = 45, active = 300
        assertEq(stakingRewards.totalStaked(), 345 ether);
        assertEq(stakingRewards.unallocatedRewards(), 45 ether);

        // Check pending rewards are based on active stake (300), not totalStaked (345)
        uint256 alicePending = stakingRewards.earned(alice);
        uint256 bobPending = stakingRewards.earned(bob);

        // Alice has 100/300 = 1/3 of active stake, should get 15 HLG
        // Bob has 200/300 = 2/3 of active stake, should get 30 HLG
        assertEq(alicePending, 15 ether, "Alice should get 15 HLG based on active stake");
        assertEq(bobPending, 30 ether, "Bob should get 30 HLG based on active stake");

        // Total pending should equal unallocated
        assertEq(alicePending + bobPending, stakingRewards.unallocatedRewards());
    }

    function testInsufficientUnallocatedReverts() public {
        // Deploy corrupted staking contract for this test
        MockCorruptedStaking corruptedStaking = new MockCorruptedStaking(address(hlg), owner);
        vm.prank(owner);
        corruptedStaking.setFeeRouter(feeRouter);
        vm.prank(owner);
        corruptedStaking.unpause();

        // Setup users
        vm.startPrank(alice);
        hlg.approve(address(corruptedStaking), 100 ether);
        corruptedStaking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        hlg.approve(address(corruptedStaking), 100 ether);
        corruptedStaking.stake(100 ether);
        vm.stopPrank();

        // Distribute rewards
        vm.startPrank(owner);
        hlg.approve(address(corruptedStaking), 80 ether);
        corruptedStaking.depositAndDistribute(80 ether); // 40 ether rewards
        vm.stopPrank();

        // Alice updates first, consuming some unallocated
        corruptedStaking.updateUser(alice);
        assertEq(corruptedStaking.balanceOf(alice), 120 ether);
        assertEq(corruptedStaking.unallocatedRewards(), 20 ether);

        // Corrupt unallocatedRewards to be less than Bob's pending
        corruptedStaking.corruptUnallocatedRewards(10 ether);
        assertEq(corruptedStaking.unallocatedRewards(), 10 ether);

        // Bob's updateUser should now revert NotEnoughRewardsAvailable
        vm.expectRevert(StakingRewards.NotEnoughRewardsAvailable.selector);
        corruptedStaking.updateUser(bob);
    }

    /* -------------------------------------------------------------------------- */
    /*                            Burn Functionality                             */
    /* -------------------------------------------------------------------------- */

    function testBurnHelperRevertsIfTransferToZeroDoesNotBurn() public {
        // Deploy zero-sink token that doesn't actually burn
        MockZeroSinkNoBurn noburn = new MockZeroSinkNoBurn();
        StakingRewards noBurnStaking = new StakingRewards(address(noburn), owner);

        noburn.mint(owner, 1000 ether);

        vm.startPrank(owner);
        noBurnStaking.setFeeRouter(feeRouter);
        noBurnStaking.setBurnPercentage(5000); // 50% burn to avoid RewardTooSmall
        // Note: stakeFor only works when paused, so don't unpause yet

        // Stake some tokens while paused
        noburn.approve(address(noBurnStaking), 500 ether);
        noBurnStaking.stakeFor(alice, 500 ether);

        // Now unpause for distribution
        noBurnStaking.unpause();

        // Try to distribute - should fail with BurnFailed (large enough amount to pass RewardTooSmall check)
        noburn.approve(address(noBurnStaking), 100 ether);
        vm.expectRevert(StakingRewards.BurnFailed.selector);
        noBurnStaking.depositAndDistribute(100 ether);
        vm.stopPrank();
    }

    function testZeroBurnPercentage() public {
        vm.prank(owner);
        stakingRewards.setBurnPercentage(0);

        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), STAKE_AMOUNT);
        stakingRewards.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // All rewards should go to stakers, nothing burned
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), REWARD_AMOUNT);
        stakingRewards.depositAndDistribute(REWARD_AMOUNT);
        vm.stopPrank();

        assertEq(stakingRewards.earned(alice), REWARD_AMOUNT);
    }

    function testDifferentBurnPercentages() public {
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), STAKE_AMOUNT);
        stakingRewards.stake(STAKE_AMOUNT);
        vm.stopPrank();

        // Test 25% burn (7500 rewards out of 10000)
        vm.prank(owner);
        stakingRewards.setBurnPercentage(2500);

        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), 100 ether);
        stakingRewards.depositAndDistribute(100 ether);
        vm.stopPrank();

        assertEq(stakingRewards.earned(alice), 75 ether);
    }

    /* -------------------------------------------------------------------------- */
    /*                            Fee-on-Transfer Tests                          */
    /* -------------------------------------------------------------------------- */

    function testFeeOnTransferRejection() public {
        // Deploy fee-on-transfer token
        MockFeeOnTransfer feeToken = new MockFeeOnTransfer();
        StakingRewards feeStaking = new StakingRewards(address(feeToken), owner);

        vm.prank(owner);
        feeStaking.unpause();

        feeToken.mint(alice, 1e18);

        // stake(1e18) reverts FeeOnTransferNotSupported()
        vm.startPrank(alice);
        feeToken.approve(address(feeStaking), 1e18);
        vm.expectRevert(StakingRewards.FeeOnTransferNotSupported.selector);
        feeStaking.stake(1e18);
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                              Admin Functions                              */
    /* -------------------------------------------------------------------------- */

    function testSetBurnPercentage() public {
        vm.prank(owner);
        stakingRewards.setBurnPercentage(7500);
        assertEq(stakingRewards.burnPercentage(), 7500);
    }

    function testSetBurnPercentageInvalidValue() public {
        vm.prank(owner);
        vm.expectRevert(StakingRewards.InvalidBurnPercentage.selector);
        stakingRewards.setBurnPercentage(10001);
    }

    function testSetBurnPercentageOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        stakingRewards.setBurnPercentage(7500);
    }

    function testPause() public {
        vm.prank(owner);
        stakingRewards.pause();
        assertTrue(stakingRewards.paused());

        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), STAKE_AMOUNT);
        vm.expectRevert();
        stakingRewards.stake(STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testStakeForOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        stakingRewards.stakeFor(bob, STAKE_AMOUNT);
    }

    function testStakeForOnlyWhenPaused() public {
        vm.prank(owner);
        vm.expectRevert();
        stakingRewards.stakeFor(alice, STAKE_AMOUNT);
    }

    function testDistributorWhitelist() public {
        vm.prank(owner);
        stakingRewards.setDistributor(distributor, true);
        assertTrue(stakingRewards.isDistributor(distributor));

        vm.prank(owner);
        stakingRewards.setDistributor(distributor, false);
        assertFalse(stakingRewards.isDistributor(distributor));
    }

    function testDistributorStake() public {
        vm.prank(owner);
        stakingRewards.setDistributor(distributor, true);

        vm.startPrank(distributor);
        hlg.approve(address(stakingRewards), STAKE_AMOUNT);
        stakingRewards.stakeFromDistributor(alice, STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(stakingRewards.balanceOf(alice), STAKE_AMOUNT);
    }

    function testDistributorStakeNotWhitelisted() public {
        vm.startPrank(distributor);
        hlg.approve(address(stakingRewards), STAKE_AMOUNT);
        vm.expectRevert(StakingRewards.NotWhitelistedDistributor.selector);
        stakingRewards.stakeFromDistributor(alice, STAKE_AMOUNT);
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                            Extra Token Recovery                           */
    /* -------------------------------------------------------------------------- */

    function testExtraTokenRecovery() public {
        // Directly transfer 100 HLG to the contract (not via functions)
        hlg.mint(address(this), 100 ether);
        hlg.transfer(address(stakingRewards), 100 ether);

        // getExtraTokens() equals 100 initially
        assertEq(stakingRewards.getExtraTokens(), 100 ether);

        // recoverExtraHLG(alice, 60) works
        uint256 aliceBalanceBefore = hlg.balanceOf(alice);
        vm.prank(owner);
        stakingRewards.recoverExtraHLG(alice, 60 ether);

        uint256 aliceBalanceAfter = hlg.balanceOf(alice);
        assertEq(aliceBalanceAfter, aliceBalanceBefore + 60 ether);

        // recoverExtraHLG(bob, 50) reverts NotEnoughExtraTokens()
        vm.prank(owner);
        vm.expectRevert(StakingRewards.NotEnoughExtraTokens.selector);
        stakingRewards.recoverExtraHLG(bob, 50 ether);

        // Remaining surplus equals 40
        assertEq(stakingRewards.getExtraTokens(), 40 ether);
    }

    function testReclaimUnallocatedRewards() public {
        // Setup: Alice stakes, rewards distributed, Alice uses emergency exit
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), 1000 ether);
        stakingRewards.stake(1000 ether);
        vm.stopPrank();

        // Distribute rewards
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), 200 ether);
        stakingRewards.depositAndDistribute(200 ether);
        vm.stopPrank();

        // Alice emergency exits (forfeits pending rewards)
        vm.prank(alice);
        stakingRewards.emergencyExit();

        // Now _activeStaked() == 0 but unallocatedRewards > 0
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertGt(stakingRewards.unallocatedRewards(), 0);
        assertEq(stakingRewards.totalStaked(), stakingRewards.unallocatedRewards());

        // Owner can reclaim unallocated rewards
        uint256 unallocatedAmount = stakingRewards.unallocatedRewards();
        uint256 treasuryBalanceBefore = hlg.balanceOf(owner);

        vm.prank(owner);
        stakingRewards.reclaimUnallocatedRewards(owner);

        // Verify rewards were reclaimed
        assertEq(stakingRewards.unallocatedRewards(), 0);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(hlg.balanceOf(owner), treasuryBalanceBefore + unallocatedAmount);
    }

    function testReclaimUnallocatedRewardsRevertsWithActiveStake() public {
        // Alice stakes
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), 1000 ether);
        stakingRewards.stake(1000 ether);
        vm.stopPrank();

        // Distribute rewards
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), 200 ether);
        stakingRewards.depositAndDistribute(200 ether);
        vm.stopPrank();

        // Should revert because Alice still has active stake
        vm.prank(owner);
        vm.expectRevert(StakingRewards.ActiveStakeExists.selector);
        stakingRewards.reclaimUnallocatedRewards(owner);
    }

    function testRewardTooSmall() public {
        // Large stake to make tiny rewards not move the index
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), 1000000 ether);
        stakingRewards.stake(1000000 ether);
        vm.stopPrank();

        // Try to distribute very small amount that won't move index
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), 1);
        vm.expectRevert(StakingRewards.RewardTooSmall.selector);
        stakingRewards.depositAndDistribute(1);
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                              Edge Cases                                   */
    /* -------------------------------------------------------------------------- */

    function testZeroStakerNoOp() public {
        // No one has staked, distributions should be no-ops
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), REWARD_AMOUNT);
        stakingRewards.depositAndDistribute(REWARD_AMOUNT);
        vm.stopPrank();

        // Contract should have no rewards allocated
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.unallocatedRewards(), 0);
    }

    function testEveryoneExitsThenNewStake() public {
        // Alice and Bob stake
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), 100 ether);
        stakingRewards.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        hlg.approve(address(stakingRewards), 200 ether);
        stakingRewards.stake(200 ether);
        vm.stopPrank();

        // Distribute rewards
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), 90 ether);
        stakingRewards.depositAndDistribute(90 ether);
        vm.stopPrank();

        // Both users compound and exit
        vm.prank(alice);
        stakingRewards.unstake();
        vm.prank(bob);
        stakingRewards.unstake();

        // totalStaked should be 0, but there might be dust in unallocatedRewards
        assertEq(stakingRewards.totalStaked(), stakingRewards.unallocatedRewards());

        // New user stakes - should work normally
        vm.startPrank(charlie);
        hlg.approve(address(stakingRewards), 500 ether);
        stakingRewards.stake(500 ether);
        vm.stopPrank();

        assertEq(stakingRewards.balanceOf(charlie), 500 ether);

        // System should work normally with new distributions
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), 100 ether);
        stakingRewards.depositAndDistribute(100 ether);
        vm.stopPrank();

        // Charlie should earn rewards normally
        uint256 charliePending = stakingRewards.earned(charlie);
        assertEq(charliePending, 50 ether); // 50% of 100 HLG distributed
    }

    /* -------------------------------------------------------------------------- */
    /*                               Fork Tests                                  */
    /* -------------------------------------------------------------------------- */

    function testForkBurnReducesSupply() public {
        // Skip if not forking
        if (block.chainid != 8453) return; // Base mainnet

        vm.createSelectFork("https://mainnet.base.org", 22_500_000);

        IERC20 realHLG = IERC20(HLG_ADDRESS);
        StakingRewards forkStaking = new StakingRewards(HLG_ADDRESS, owner);

        vm.startPrank(owner);
        forkStaking.setFeeRouter(feeRouter);
        forkStaking.setBurnPercentage(10000); // 100% burn
        forkStaking.unpause();
        vm.stopPrank();

        // Fund via deal if holder doesn't have enough
        deal(HLG_ADDRESS, alice, 1000 ether);
        deal(HLG_ADDRESS, owner, 1000 ether);

        // Alice stakes
        vm.startPrank(alice);
        realHLG.approve(address(forkStaking), 500 ether);
        forkStaking.stake(500 ether);
        vm.stopPrank();

        uint256 supplyBefore = realHLG.totalSupply();

        // Owner distributes with 100% burn
        vm.startPrank(owner);
        realHLG.approve(address(forkStaking), 100 ether);
        forkStaking.depositAndDistribute(100 ether);
        vm.stopPrank();

        uint256 supplyAfter = realHLG.totalSupply();
        assertEq(supplyBefore - supplyAfter, 100 ether, "Total supply should decrease by burned amount");
    }

    /* -------------------------------------------------------------------------- */
    /*                       Precision and Dust Handling Tests                  */
    /* -------------------------------------------------------------------------- */

    function testDustHandling() public {
        // Setup large active stake
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), 1000000 ether);
        stakingRewards.stake(1000000 ether);
        vm.stopPrank();

        uint256 rewardAmount = 500; // Tiny reward that would result in index delta == 0

        // Should revert with RewardTooSmall since the dust guard prevents it
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), rewardAmount);
        vm.expectRevert(StakingRewards.RewardTooSmall.selector);
        stakingRewards.depositAndDistribute(rewardAmount);
        vm.stopPrank();
    }

    function testFullRewardPreCredit() public {
        // Setup moderate stake
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), 100000 ether);
        stakingRewards.stake(100000 ether);
        vm.stopPrank();

        uint256 rewardAmount = 1000 ether;
        uint256 actualReward = rewardAmount / 2; // 500 ether after 50% burn

        // Record initial state
        uint256 initialUnallocated = stakingRewards.unallocatedRewards();
        uint256 initialSurplus = stakingRewards.getExtraTokens();

        // Distribute rewards
        vm.startPrank(owner);
        hlg.approve(address(stakingRewards), rewardAmount);
        stakingRewards.depositAndDistribute(rewardAmount);
        vm.stopPrank();

        // Assert unallocatedRewards increased by full actualReward
        assertEq(
            stakingRewards.unallocatedRewards(),
            initialUnallocated + actualReward,
            "Unallocated should equal full reward"
        );

        // Assert extra tokens stay the same (balance increased by actualReward, totalStaked also increased by actualReward)
        assertEq(stakingRewards.getExtraTokens(), initialSurplus, "Extra tokens should remain unchanged");

        // Verify user can claim the expected amount
        uint256 expectedEarned = actualReward; // Alice has 100% of stake
        assertEq(stakingRewards.earned(alice), expectedEarned, "Alice should earn full reward");
    }

    function testInvariantFuzzSequences(uint8 seed) public {
        // Initialize with some stake
        vm.startPrank(alice);
        hlg.approve(address(stakingRewards), 10000 ether);
        stakingRewards.stake(1000 ether);
        vm.stopPrank();

        // Use seed to create pseudo-random sequence
        uint256 rng = uint256(keccak256(abi.encode(seed)));

        for (uint256 i = 0; i < 5; i++) {
            uint256 action = rng % 4;
            rng = uint256(keccak256(abi.encode(rng)));

            if (action == 0) {
                // Stake
                uint256 amount = (rng % 1000) + 100; // 100-1099
                rng = uint256(keccak256(abi.encode(rng)));

                vm.startPrank(alice);
                hlg.approve(address(stakingRewards), amount);
                stakingRewards.stake(amount);
                vm.stopPrank();
            } else if (action == 1) {
                // Distribute (use larger amounts to avoid RewardTooSmall)
                uint256 amount = (rng % 1000) + 1000; // 1000-1999 to avoid dust guard
                rng = uint256(keccak256(abi.encode(rng)));

                vm.startPrank(owner);
                hlg.approve(address(stakingRewards), amount);
                try stakingRewards.depositAndDistribute(amount) {
                    // Distribution succeeded
                } catch {
                    // Skip if RewardTooSmall - this is expected behavior
                }
                vm.stopPrank();
            } else if (action == 2) {
                // Update user
                stakingRewards.updateUser(alice);
            } else if (action == 3 && stakingRewards.balanceOf(alice) > 0) {
                // Unstake (only if has balance)
                vm.prank(alice);
                stakingRewards.unstake();

                // Re-stake something to continue
                vm.startPrank(alice);
                hlg.approve(address(stakingRewards), 1000 ether);
                stakingRewards.stake(1000 ether);
                vm.stopPrank();
            }

            // Check invariants after each action
            _checkInvariants();
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                            Invariant Helpers                             */
    /* -------------------------------------------------------------------------- */

    function _checkInvariants() internal view {
        uint256 contractBalance = hlg.balanceOf(address(stakingRewards));
        uint256 totalStaked = stakingRewards.totalStaked();
        uint256 unallocated = stakingRewards.unallocatedRewards();

        // HLG.balanceOf(this) >= totalStaked
        assertGe(contractBalance, totalStaked, "Contract balance should be >= totalStaked");

        // sum(balanceOf) + unallocatedRewards == totalStaked
        uint256 aliceBalance = stakingRewards.balanceOf(alice);
        uint256 bobBalance = stakingRewards.balanceOf(bob);
        uint256 charlieBalance = stakingRewards.balanceOf(charlie);
        uint256 sumBalances = aliceBalance + bobBalance + charlieBalance;
        assertEq(sumBalances + unallocated, totalStaked, "Sum of balances + unallocated should equal totalStaked");

        // Extra tokens should be contractBalance - totalStaked
        uint256 extraTokens = stakingRewards.getExtraTokens();
        uint256 expectedExtra = contractBalance > totalStaked ? contractBalance - totalStaked : 0;
        assertEq(extraTokens, expectedExtra, "Extra tokens should be contractBalance - totalStaked");
    }
}
