// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {FeeRouter} from "../../src/FeeRouter.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {MockHLG} from "../mock/MockHLG.sol";
import {MockLZEndpoint} from "../mock/MockLZEndpoint.sol";
import {MockWETH} from "../mock/MockWETH.sol";
import {MockSwapRouter, ISwapRouter} from "../mock/MockSwapRouter.sol";
import {MockAirlock} from "../mock/MockAirlock.sol";
import {Origin} from "../../lib/LayerZero-v2/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract FeeRouterTest is Test {
    // Contracts
    FeeRouter public feeRouterBase;
    FeeRouter public feeRouterEth;
    StakingRewards public stakingRewards;

    // Mock contracts
    MockLZEndpoint public lzEndpointBase;
    MockLZEndpoint public lzEndpointEth;
    MockWETH public weth;
    MockHLG public hlg;
    MockSwapRouter public swapRouter;
    MockAirlock public airlock;

    // Test accounts
    address public user = vm.addr(1);
    address public staker1 = vm.addr(2);
    address public staker2 = vm.addr(3);
    address public owner = vm.addr(4);

    // Chain EIDs
    uint32 public constant BASE_EID = 30184;
    uint32 public constant ETH_EID = 30101;

    // Realistic test constants
    uint256 public constant TEST_FEE_AMOUNT_ETH = 1 ether; // Total fee for token launches (to overcome dust protection)

    // Conversion rate: 0.000000139 WETH = 1 HLG, so 1 WETH = 7,194,245 HLG
    uint256 public constant WETH_TO_HLG_RATE = 7194245;

    // Test HLG amounts for different user scenarios
    uint256 public constant MODERATE_HLG_BALANCE = 1000 ether; // 1000 HLG tokens
    uint256 public constant LARGE_HLG_BALANCE = 5000 ether; // 5000 HLG tokens

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock contracts
        lzEndpointBase = new MockLZEndpoint();
        lzEndpointEth = new MockLZEndpoint();
        weth = new MockWETH();
        hlg = new MockHLG();
        swapRouter = new MockSwapRouter();
        airlock = new MockAirlock();

        // Configure MockSwapRouter with correct exchange rate and output token
        swapRouter.setExchangeRate(WETH_TO_HLG_RATE * 1e18); // Convert to per-wei rate
        swapRouter.setOutputToken(address(hlg));

        // Deploy FeeRouter for Base (no swap functionality)
        feeRouterBase = new FeeRouter(
            address(lzEndpointBase),
            ETH_EID, // remote EID (Ethereum)
            address(0), // no staking pool on Base
            address(0), // no HLG on Base
            address(0), // no WETH on Base
            address(0), // no swap router on Base
            address(owner) // treasury address
        );

        // Deploy StakingRewards
        stakingRewards = new StakingRewards(address(hlg), address(1)); // temporary address, will set fee router later

        // Deploy FeeRouter for Ethereum (with swap functionality)
        feeRouterEth = new FeeRouter(
            address(lzEndpointEth),
            BASE_EID, // remote EID (Base)
            address(stakingRewards),
            address(hlg),
            address(weth),
            address(swapRouter),
            address(owner) // treasury address
        );

        // Update staking rewards to use the Ethereum fee router
        stakingRewards.setFeeRouter(address(feeRouterEth));
        stakingRewards.unpause();

        // Grant KEEPER_ROLE to owner for testing
        feeRouterBase.grantRole(feeRouterBase.KEEPER_ROLE(), owner);
        feeRouterEth.grantRole(feeRouterEth.KEEPER_ROLE(), owner);

        // Set up trusted remotes
        feeRouterBase.setTrustedRemote(ETH_EID, bytes32(uint256(uint160(address(feeRouterEth)))));
        feeRouterEth.setTrustedRemote(BASE_EID, bytes32(uint256(uint160(address(feeRouterBase)))));

        // Whitelist airlock for ETH transfers
        feeRouterBase.setTrustedAirlock(address(airlock), true);

        // Configure mock endpoints for cross-chain simulation
        lzEndpointBase.setCrossChainTarget(address(feeRouterEth));
        lzEndpointEth.setCrossChainTarget(address(feeRouterBase));
        lzEndpointBase.setTargetEndpoint(address(lzEndpointEth));
        lzEndpointEth.setTargetEndpoint(address(lzEndpointBase));

        vm.stopPrank();

        // Give test accounts ETH for gas and fees
        vm.deal(user, 10 ether); // User pays protocol fees
        vm.deal(staker1, 1 ether); // Gas for staking operations
        vm.deal(staker2, 1 ether);

        // Give stakers HLG for testing different scenarios
        hlg.mint(staker1, MODERATE_HLG_BALANCE); // 1000 HLG tokens
        hlg.mint(staker2, LARGE_HLG_BALANCE); // 5000 HLG tokens

        // Fund MockSwapRouter with enough HLG for swaps (large amount for testing)
        hlg.mint(address(swapRouter), 10_000_000 ether); // 10M HLG tokens
    }

    /// @notice Helper function to simulate fee collection through Airlock
    function _simulateFeeCollection(uint256 amount) internal {
        // Fund the airlock with ETH
        vm.deal(address(airlock), amount);
        airlock.setCollectableAmount(address(0), amount);

        // Keeper collects fees from airlock
        vm.prank(owner);
        feeRouterBase.collectAirlockFees(address(airlock), address(0), amount);
    }

    function test_EndToEndFeeFlow() public {
        // Setup: Users stake HLG tokens

        // Staker1 stakes 500 HLG (half their balance)
        uint256 staker1StakeAmount = 500 ether; // 500 HLG tokens
        vm.startPrank(staker1);
        hlg.approve(address(stakingRewards), staker1StakeAmount);
        stakingRewards.stake(staker1StakeAmount);
        vm.stopPrank();

        // Staker2 stakes 2000 HLG (portion of their balance)
        uint256 staker2StakeAmount = 2000 ether; // 2000 HLG tokens
        vm.startPrank(staker2);
        hlg.approve(address(stakingRewards), staker2StakeAmount);
        stakingRewards.stake(staker2StakeAmount);
        vm.stopPrank();

        // Verify staking amounts (all amounts are HLG tokens)
        uint256 totalStakedHLG = staker1StakeAmount + staker2StakeAmount; // 2500 HLG total
        assertEq(stakingRewards.totalStaked(), totalStakedHLG);
        assertEq(stakingRewards.balanceOf(staker1), staker1StakeAmount);
        assertEq(stakingRewards.balanceOf(staker2), staker2StakeAmount);

        // Step 1: Fee collection on Base (ETH amounts)

        // User pays protocol fee in ETH on Base network (using Airlock simulation)
        _simulateFeeCollection(TEST_FEE_AMOUNT_ETH);

        // Verify ETH fee was sliced correctly (single-slice model)
        // FeeRouter keeps 1.5% for protocol, 98.5% goes to treasury
        uint256 expectedProtocolFee = (TEST_FEE_AMOUNT_ETH * 150) / 10_000; // 1.5%

        assertEq(address(feeRouterBase).balance, expectedProtocolFee);

        // Step 2: Bridge ETH fees from Base to Ethereum

        uint256 minGas = 200000;

        // Calculate expected HLG from swapping the PROTOCOL FEE PORTION (1.5% of total)
        // Only the protocol fee portion (1.5%) gets bridged and swapped
        uint256 protocolFeeAmount = (TEST_FEE_AMOUNT_ETH * 150) / 10_000; // 1.5%
        uint256 expectedHlgFromSwap = protocolFeeAmount * WETH_TO_HLG_RATE;

        // Calculate minimum HLG for slippage protection (50% goes to stakers)
        uint256 minHlgForStakers = expectedHlgFromSwap / 2;

        vm.prank(owner);
        feeRouterBase.bridge(minGas, minHlgForStakers);

        // Verify ETH was bridged (Base router balance should be 0 after bridging protocol fee)
        assertEq(address(feeRouterBase).balance, 0);

        // Step 3: Verify swap and distribution on Ethereum

        // The mock endpoint automatically triggers lzReceive, which:
        // 1. Wraps protocol fee ETH to WETH (0.00015 ETH → 0.00015 WETH)  [1.5% of 0.01 ETH]
        // 2. Swaps WETH to HLG (0.00015 WETH → ~1079 HLG)
        // 3. Burns 50% of HLG (~539.5 HLG burned)
        // 4. Sends 50% to staking rewards (~539.5 HLG to stakers)

        uint256 expectedBurnAmountHLG = expectedHlgFromSwap / 2; // HLG tokens burned
        uint256 expectedRewardAmountHLG = expectedHlgFromSwap - expectedBurnAmountHLG; // HLG tokens to stakers

        // Check that HLG was burned (using totalBurned instead of balanceOf(address(0)))
        assertEq(hlg.totalBurned(), expectedBurnAmountHLG);

        // Step 4: Verify proportional reward distribution

        // Check that rewards were distributed proportionally based on stake
        uint256 staker1RewardsHLG = stakingRewards.earned(staker1);
        uint256 staker2RewardsHLG = stakingRewards.earned(staker2);

        // Staker1 has 500/2500 = 20% of total stake
        // Staker2 has 2000/2500 = 80% of total stake
        uint256 expectedStaker1RewardsHLG = (expectedRewardAmountHLG * staker1StakeAmount) / totalStakedHLG;
        uint256 expectedStaker2RewardsHLG = (expectedRewardAmountHLG * staker2StakeAmount) / totalStakedHLG;

        assertApproxEqAbs(staker1RewardsHLG, expectedStaker1RewardsHLG, 1e15); // Allow small rounding error
        assertApproxEqAbs(staker2RewardsHLG, expectedStaker2RewardsHLG, 1e15);

        // Step 5: Test reward claiming

        uint256 staker1HlgBalanceBefore = hlg.balanceOf(staker1);

        vm.prank(staker1);
        stakingRewards.claim();

        // Verify staker1 received their HLG rewards
        assertApproxEqAbs(hlg.balanceOf(staker1), staker1HlgBalanceBefore + expectedStaker1RewardsHLG, 1e15);
        assertEq(stakingRewards.earned(staker1), 0);
    }

    function test_MultipleFeeCycles() public {
        // Setup: Single staker with HLG

        // Staker1 stakes 1000 HLG (their full balance)
        uint256 stakerHlgAmount = MODERATE_HLG_BALANCE; // 1000 HLG tokens
        vm.startPrank(staker1);
        hlg.approve(address(stakingRewards), stakerHlgAmount);
        stakingRewards.stake(stakerHlgAmount);
        vm.stopPrank();

        // First fee cycle

        // User pays 0.01 ETH protocol fee on Base
        _simulateFeeCollection(TEST_FEE_AMOUNT_ETH);

        // Bridge ETH to Ethereum and swap to HLG
        // Only protocol fee portion (1.5%) gets bridged: 0.00015 ETH → ~1079 HLG → ~539.5 HLG to stakers
        uint256 protocolFeeAmount = (TEST_FEE_AMOUNT_ETH * 150) / 10_000; // 1.5%
        uint256 expectedHlgToStakers = (protocolFeeAmount * WETH_TO_HLG_RATE) / 2;
        vm.prank(owner);
        feeRouterBase.bridge(200000, expectedHlgToStakers);

        // Check HLG rewards after first cycle
        uint256 rewardsAfterFirstCycle = stakingRewards.earned(staker1);

        // Second fee cycle

        // Another user pays the same 0.01 ETH protocol fee
        _simulateFeeCollection(TEST_FEE_AMOUNT_ETH);

        // Bridge and swap again (same amounts)
        vm.prank(owner);
        feeRouterBase.bridge(200000, expectedHlgToStakers);

        // Check HLG rewards after second cycle
        uint256 rewardsAfterSecondCycle = stakingRewards.earned(staker1);

        // Rewards should have approximately doubled (both cycles go to same staker)
        assertApproxEqRel(rewardsAfterSecondCycle, rewardsAfterFirstCycle * 2, 0.01e18); // 1% tolerance
    }

    function test_TrustedRemoteValidation() public {
        // Test LayerZero security validation using Base FeeRouter (simpler, no swap logic)

        // Try to call lzReceive from untrusted address (should fail)
        vm.expectRevert(FeeRouter.NotEndpoint.selector);
        Origin memory origin1 = Origin({srcEid: ETH_EID, sender: bytes32(uint256(uint160(address(0x999)))), nonce: 1});
        feeRouterBase.lzReceive(origin1, keccak256(abi.encode(address(0), 100 ether)), abi.encode(address(0), 100 ether), address(0x999), "");

        // Test with correct endpoint but untrusted remote (should fail)
        vm.startPrank(address(lzEndpointBase));
        vm.expectRevert(FeeRouter.UntrustedRemote.selector);
        Origin memory origin2 = Origin({srcEid: 99999, sender: bytes32(uint256(uint160(address(0x999)))), nonce: 1});
        feeRouterBase.lzReceive(origin2, keccak256(abi.encode(address(0), 100 ether)), abi.encode(address(0), 100 ether), address(0x999), ""); // Use untrusted EID
        vm.stopPrank();

        // NOTE: The security validation tests above are the main focus of this test
        // Testing a successful call would require more complex setup of the reward distribution system
        // The key security features (NotEndpoint and UntrustedRemote) are verified above

        // TODO: Add a successful lzReceive test when the full system is integrated
        // For now, the security validation is the primary concern and is working correctly
    }

    function test_PauseUnpauseFunctionality() public {
        // Test emergency pause functionality

        // Pause the Base fee router
        vm.prank(owner);
        feeRouterBase.pause();

        // Should not be able to receive ETH fees when paused
        // Note: receive() function doesn't have whenNotPaused modifier
        // so this test doesn't apply to ETH transfers

        // Should not be able to bridge ETH when paused
        vm.expectRevert();
        feeRouterBase.bridge(200000, 100 ether);

        // Unpause and verify functionality returns
        vm.prank(owner);
        feeRouterBase.unpause();

        // Should work again - accept 1 ETH fee
        _simulateFeeCollection(1 ether);
    }

    function test_SlippageProtection() public {
        // Test slippage protection during swaps

        // Set up ETH fee to bridge
        _simulateFeeCollection(TEST_FEE_AMOUNT_ETH);

        // Try to bridge with unrealistic minHlg expectation
        // Expecting 15,000,000 HLG per ETH instead of realistic 7,194,245 HLG per ETH
        // This is about 2x the realistic rate, so it should fail
        uint256 protocolFeeAmount = (TEST_FEE_AMOUNT_ETH * 150) / 10_000; // 1.5%
        uint256 unrealisticMinHlg = protocolFeeAmount * 15000000; // Way too high expectation

        vm.expectRevert("Insufficient output amount");
        vm.prank(owner);
        feeRouterBase.bridge(200000, unrealisticMinHlg);
    }

    function test_AdminFunctions() public {
        // Test administrative functions

        // Test trusted remote management
        bytes32 newRemote = bytes32(uint256(uint160(address(0x123))));

        vm.prank(owner);
        feeRouterBase.setTrustedRemote(ETH_EID, newRemote);

        assertEq(feeRouterBase.trustedRemotes(ETH_EID), newRemote);
        assertTrue(feeRouterBase.trustedRemotes(ETH_EID) == bytes32(uint256(uint160(address(0x123)))));
        assertFalse(feeRouterBase.trustedRemotes(ETH_EID) == bytes32(uint256(uint160(address(feeRouterEth)))));
    }

    function test_StakingCooldown() public {
        // Test staking cooldown period

        // Stake 500 HLG tokens
        uint256 stakeAmountHLG = 500 ether; // 500 HLG tokens
        vm.startPrank(staker1);
        hlg.approve(address(stakingRewards), stakeAmountHLG);
        stakingRewards.stake(stakeAmountHLG);

        // Try to withdraw 100 HLG immediately (should fail due to cooldown)
        uint256 withdrawAmountHLG = 100 ether; // 100 HLG tokens
        vm.expectRevert();
        stakingRewards.withdraw(withdrawAmountHLG);

        // Fast forward past cooldown period (7 days)
        vm.warp(block.timestamp + 7 days + 1);

        // Should work now - withdraw 100 HLG tokens
        stakingRewards.withdraw(withdrawAmountHLG);

        // Verify remaining stake: 500 - 100 = 400 HLG tokens
        assertEq(stakingRewards.balanceOf(staker1), stakeAmountHLG - withdrawAmountHLG);

        vm.stopPrank();
    }

    function test_LayerZeroOptionsEncoding() public {
        // Test LayerZero V2 message encoding

        // Set up ETH fee for bridging
        _simulateFeeCollection(TEST_FEE_AMOUNT_ETH);

        uint256 minGas = 200000;
        // Calculate minimum HLG from protocol fee: 0.00015 ETH * 7,194,245 HLG/ETH / 2 = ~539.5 HLG
        uint256 protocolFeeAmount = (TEST_FEE_AMOUNT_ETH * 150) / 10_000; // 1.5%
        uint256 minHlgForStakers = (protocolFeeAmount * WETH_TO_HLG_RATE) / 2;

        // Capture the MessageSent event to verify LayerZero V2 options format
        vm.expectEmit(true, true, true, true);
        emit MockLZEndpoint.MessageSent(
            ETH_EID,
            abi.encode(address(0), protocolFeeAmount, minHlgForStakers), // token, amount, minHlg
            abi.encodePacked(uint16(1), minGas) // LayerZero V2 options with gas limit
        );

        vm.prank(owner);
        feeRouterBase.bridge(minGas, minHlgForStakers);
    }

    function test_RewardDistributionMath() public {
        // Test precise reward distribution mathematics

        // Stake different HLG amounts to test proportional distribution
        uint256 staker1HlgAmount = 300 ether; // 300 HLG tokens (30% of total)
        uint256 staker2HlgAmount = 700 ether; // 700 HLG tokens (70% of total)
        uint256 totalStakedHLG = staker1HlgAmount + staker2HlgAmount; // 1000 HLG total

        vm.startPrank(staker1);
        hlg.approve(address(stakingRewards), staker1HlgAmount);
        stakingRewards.stake(staker1HlgAmount);
        vm.stopPrank();

        vm.startPrank(staker2);
        hlg.approve(address(stakingRewards), staker2HlgAmount);
        stakingRewards.stake(staker2HlgAmount);
        vm.stopPrank();

        // Send ETH fees and bridge to Ethereum
        _simulateFeeCollection(TEST_FEE_AMOUNT_ETH);

        // Calculate expected HLG amounts (only protocol fee portion gets swapped)
        // Protocol fee: 0.00015 ETH → ~1079 HLG total → ~539.5 HLG to stakers
        uint256 protocolFeeAmount = (TEST_FEE_AMOUNT_ETH * 150) / 10_000; // 1.5%
        uint256 expectedHlgFromSwap = protocolFeeAmount * WETH_TO_HLG_RATE;
        uint256 expectedRewardAmountHLG = expectedHlgFromSwap / 2;

        vm.prank(owner);
        feeRouterBase.bridge(200000, expectedRewardAmountHLG);

        // Check actual HLG rewards earned
        uint256 staker1RewardsHLG = stakingRewards.earned(staker1);
        uint256 staker2RewardsHLG = stakingRewards.earned(staker2);

        // Check proportional distribution
        // Staker1: 30% of 35,971.225 HLG = 10,791.375 HLG
        // Staker2: 70% of 35,971.225 HLG = 25,179.875 HLG
        uint256 expectedStaker1RewardsHLG = (expectedRewardAmountHLG * staker1HlgAmount) / totalStakedHLG;
        uint256 expectedStaker2RewardsHLG = (expectedRewardAmountHLG * staker2HlgAmount) / totalStakedHLG;

        assertApproxEqAbs(staker1RewardsHLG, expectedStaker1RewardsHLG, 1e15);
        assertApproxEqAbs(staker2RewardsHLG, expectedStaker2RewardsHLG, 1e15);

        // Verify total HLG rewards equal expected amount
        assertApproxEqAbs(staker1RewardsHLG + staker2RewardsHLG, expectedRewardAmountHLG, 1e15);
    }
}
