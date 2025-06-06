// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {MockERC20} from "./mock/MockERC20.sol";

contract StakingRewardsTest is Test {
    MockERC20 public hlg;
    StakingRewards public staking;
    address feeRouter = vm.addr(1);

    address alice = vm.addr(2);
    address bob = vm.addr(3);

    function setUp() public {
        hlg = new MockERC20();
        staking = new StakingRewards(address(hlg), feeRouter);
        staking.unpause();

        // distribute some HLG
        hlg.mint(alice, 1e24); // 1,000 HLG
        hlg.mint(bob, 1e24);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Stake / Withdraw / Claim
    // ──────────────────────────────────────────────────────────────────────────
    function testStakeAndWithdraw() public {
        uint256 amt = 100 ether;
        vm.startPrank(alice);
        hlg.approve(address(staking), amt);
        staking.stake(amt);
        assertEq(staking.totalStaked(), amt);
        assertEq(staking.balanceOf(alice), amt);

        vm.warp(block.timestamp + 7 days + 1);
        staking.withdraw(amt);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function testClaimRewards() public {
        uint256 stakeAmt = 100 ether;
        vm.startPrank(alice);
        hlg.approve(address(staking), stakeAmt);
        staking.stake(stakeAmt);
        vm.stopPrank();

        uint256 rewardAmt = 50 ether;
        hlg.mint(feeRouter, rewardAmt);
        vm.prank(feeRouter);
        hlg.approve(address(staking), rewardAmt);
        vm.prank(feeRouter);
        staking.addRewards(rewardAmt);

        uint256 earned = staking.earned(alice);
        assertApproxEqAbs(earned, rewardAmt, 1); // allow 1-wei rounding

        vm.prank(alice);
        staking.claim();
        assertApproxEqAbs(hlg.balanceOf(alice), 1e24 - stakeAmt + rewardAmt, 1);
        assertEq(staking.earned(alice), 0);
    }

    function testWithdrawBeforeCooldownReverts() public {
        uint256 amt = 10 ether;
        vm.startPrank(alice);
        hlg.approve(address(staking), amt);
        staking.stake(amt);
        vm.expectRevert(abi.encodeWithSignature("CooldownActive(uint256)", 604800));
        staking.withdraw(amt);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Pause / Unpause
    // ──────────────────────────────────────────────────────────────────────────
    function testPause() public {
        staking.pause();
        vm.startPrank(alice);
        hlg.approve(address(staking), 1 ether);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        staking.stake(1 ether);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  FeeRouter only addRewards
    // ──────────────────────────────────────────────────────────────────────────
    function testAddRewardsOnlyRouter() public {
        uint256 amt = 1 ether;
        hlg.mint(alice, amt);
        vm.prank(alice);
        hlg.approve(address(staking), amt);
        vm.prank(alice);
        vm.expectRevert(StakingRewards.FeeRouterOnly.selector);
        staking.addRewards(amt);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Fuzz
    // ──────────────────────────────────────────────────────────────────────────
    function testFuzz_StakeThenReward(uint128 stakeAmt, uint128 rewardAmt) public {
        stakeAmt = uint128(bound(uint256(stakeAmt), 1e18, 1e24));
        rewardAmt = uint128(bound(uint256(rewardAmt), 1e18, 1e24));
        hlg.mint(alice, stakeAmt);
        hlg.mint(feeRouter, rewardAmt);

        vm.prank(alice);
        hlg.approve(address(staking), stakeAmt);
        vm.prank(alice);
        staking.stake(stakeAmt);

        vm.prank(feeRouter);
        hlg.approve(address(staking), rewardAmt);
        vm.prank(feeRouter);
        staking.addRewards(rewardAmt);

        uint256 earned = staking.earned(alice);
        assertApproxEqAbs(earned, rewardAmt, 1000000); // Allow reasonable delta for precision
    }
}
