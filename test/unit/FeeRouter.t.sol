// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {FeeRouter} from "../../src/FeeRouter.sol";
import {HolographFactory} from "../../src/HolographFactory.sol";
import {MockLZEndpoint} from "../mock/MockLZEndpoint.sol";
import {MockAirlock} from "../mock/MockAirlock.sol";
import {MockStakingRewards} from "../mock/MockStakingRewards.sol";
import {MockHLG} from "../mock/MockHLG.sol";
import {MockWETH} from "../mock/MockWETH.sol";
import {MockSwapRouter} from "../mock/MockSwapRouter.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {Origin} from "../../lib/LayerZero-v2/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";

/**
 * @title FeeRouterTest
 * @notice Comprehensive test suite for FeeRouter contract
 * @dev Tests fee collection, splitting, bridging, HLG distribution, and new architecture integration
 * @dev Consolidates tests from FeeRouterSlice.t.sol with new architecture features
 */
contract FeeRouterTest is Test {
    // Core contracts
    FeeRouter public feeRouter;
    HolographFactory public factory;
    MockLZEndpoint public lzEndpoint;
    MockAirlock public airlock;
    MockStakingRewards public stakingPool;
    MockHLG public hlg;
    MockWETH public weth;
    MockSwapRouter public swapRouter;
    
    // Test addresses
    address public owner = address(0x1234567890123456789012345678901234567890);
    address public keeper = address(0x0987654321098765432109876543210987654321);
    address public treasury = address(0x1111111111111111111111111111111111111111);
    address public alice = address(0x2222222222222222222222222222222222222222);
    address public bob = address(0x3333333333333333333333333333333333333333);
    
    // Network configuration - Base and Unichain
    uint32 constant BASE_EID = 40245;        // Base Sepolia
    uint32 constant UNICHAIN_EID = 40328;    // Unichain Sepolia
    uint32 constant ETHEREUM_EID = 30101;    // For legacy compatibility
    
    // Protocol constants
    uint24 constant POOL_FEE = 3000;
    uint16 constant HOLO_FEE_BPS = 150;      // 1.5%
    uint64 constant MIN_BRIDGE_VALUE = 0.01 ether;

    // Events
    event SlicePulled(address indexed airlock, address indexed token, uint256 holoAmt, uint256 treasuryAmt);
    event TokenBridged(address indexed token, uint256 amount, uint64 nonce);
    event TrustedRemoteSet(uint32 indexed eid, bytes32 remote);
    event TreasuryUpdated(address indexed newTreasury);
    event TrustedAirlockSet(address indexed airlock, bool trusted);
    event TrustedFactorySet(address indexed factory, bool trusted);

    function setUp() public {
        // Deploy mocks
        lzEndpoint = new MockLZEndpoint();
        weth = new MockWETH();
        hlg = new MockHLG();
        swapRouter = new MockSwapRouter();
        stakingPool = new MockStakingRewards(address(hlg));
        airlock = new MockAirlock();
        
        // Deploy factory for new architecture integration
        factory = new HolographFactory(address(lzEndpoint));
        
        // Deploy FeeRouter with Unichain as remote chain
        vm.startPrank(owner);
        feeRouter = new FeeRouter(
            address(lzEndpoint),
            UNICHAIN_EID,           // Remote EID (Unichain)
            address(stakingPool),
            address(hlg),
            address(weth),
            address(swapRouter),
            treasury
        );
        
        // Grant keeper role
        feeRouter.grantRole(feeRouter.KEEPER_ROLE(), keeper);
        
        // Set up trusted contracts for new architecture
        feeRouter.setTrustedAirlock(address(airlock), true);
        feeRouter.setTrustedFactory(address(factory), true);
        feeRouter.setTrustedRemote(BASE_EID, bytes32(uint256(uint160(address(0x4444)))));
        
        vm.stopPrank();
        
        // Fund test accounts
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(address(feeRouter), 1 ether);
        vm.deal(address(airlock), 10 ether);
        
        // Setup MockSwapRouter for token swaps
        swapRouter.setOutputToken(address(hlg));
        
        // Mint tokens to MockSwapRouter for swap operations
        hlg.mint(address(swapRouter), 1_000_000e18);
        weth.mint(address(swapRouter), 1_000_000e18);
        hlg.mint(address(stakingPool), 1_000_000e18);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Basic Functionality                          */
    /* -------------------------------------------------------------------------- */

    function test_Constructor() public {
        assertEq(address(feeRouter.lzEndpoint()), address(lzEndpoint));
        assertEq(feeRouter.remoteEid(), UNICHAIN_EID);
        assertEq(address(feeRouter.stakingPool()), address(stakingPool));
        assertEq(address(feeRouter.HLG()), address(hlg));
        assertEq(address(feeRouter.WETH()), address(weth));
        assertEq(address(feeRouter.swapRouter()), address(swapRouter));
        assertEq(feeRouter.treasury(), treasury);
        assertEq(feeRouter.HOLO_FEE_BPS(), HOLO_FEE_BPS);
        assertEq(feeRouter.MIN_BRIDGE_VALUE(), MIN_BRIDGE_VALUE);
    }

    function test_FeeCalculation() public {
        uint256 amount = 1 ether;
        (uint256 protocolFee, uint256 treasuryFee) = feeRouter.calculateFeeSplit(amount);
        
        assertEq(protocolFee, (amount * HOLO_FEE_BPS) / 10_000); // 1.5%
        assertEq(treasuryFee, amount - protocolFee); // 98.5%
        assertEq(protocolFee + treasuryFee, amount);
    }

    /* -------------------------------------------------------------------------- */
    /*                          Airlock Fee Collection                          */
    /* -------------------------------------------------------------------------- */

    function test_CollectAirlockFeesETH() public {
        uint256 amount = 0.5 ether;
        
        // Setup: fund the airlock to simulate fees
        vm.deal(address(airlock), amount);
        airlock.setCollectableAmount(address(0), amount);
        
        uint256 holoAmt = (amount * HOLO_FEE_BPS) / 10_000; // 1.5%
        uint256 treasuryAmt = amount - holoAmt; // 98.5%
        
        vm.expectEmit(true, true, false, true);
        emit SlicePulled(keeper, address(0), holoAmt, treasuryAmt);
        
        vm.prank(keeper);
        feeRouter.collectAirlockFees(address(airlock), address(0), amount);
        
        // Verify treasury received the correct amount
        assertEq(treasury.balance, treasuryAmt);
    }

    function test_CollectAirlockFeesERC20() public {
        MockERC20 token = new MockERC20("Test Token", "TEST");
        uint256 amount = 1000e18;
        
        // Setup airlock with ERC20 tokens
        token.mint(address(airlock), amount);
        airlock.setCollectableAmount(address(token), amount);
        
        vm.prank(keeper);
        feeRouter.collectAirlockFees(address(airlock), address(token), amount);
        
        // Verify treasury received 98.5%
        uint256 expectedTreasuryFee = (amount * 9850) / 10_000;
        assertEq(token.balanceOf(treasury), expectedTreasuryFee);
    }

    function test_CollectAirlockFeesOnlyKeeper() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.collectAirlockFees(address(airlock), address(0), 0.1 ether);
    }

    function test_RevertCollectAirlockFeesZeroAddress() public {
        vm.prank(keeper);
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        feeRouter.collectAirlockFees(address(0), address(0), 1 ether);
    }

    function test_RevertCollectAirlockFeesZeroAmount() public {
        vm.prank(keeper);
        vm.expectRevert(FeeRouter.ZeroAmount.selector);
        feeRouter.collectAirlockFees(address(airlock), address(0), 0);
    }

    /* -------------------------------------------------------------------------- */
    /*                              ETH Bridging                                */
    /* -------------------------------------------------------------------------- */

    function test_BridgeETH() public {
        uint256 bridgeAmount = 0.05 ether; // Above MIN_BRIDGE_VALUE
        vm.deal(address(feeRouter), bridgeAmount);
        
        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit TokenBridged(address(0), bridgeAmount, 1);
        
        feeRouter.bridge(200_000, 0);
        
        // Verify nonce incremented and LayerZero was called
        assertEq(feeRouter.nonce(UNICHAIN_EID), 1);
        assertTrue(lzEndpoint.sendCalled());
        assertEq(lzEndpoint.lastValue(), bridgeAmount);
    }

    function test_BridgeDustProtection() public {
        // Set balance below MIN_BRIDGE_VALUE
        vm.deal(address(feeRouter), 0.005 ether);
        
        vm.prank(keeper);
        feeRouter.bridge(200_000, 0);
        
        // Should not bridge or increment nonce
        assertEq(feeRouter.nonce(UNICHAIN_EID), 0);
        assertEq(address(feeRouter).balance, 0.005 ether);
    }

    function test_BridgeOnlyKeeper() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.bridge(200_000, 0);
    }

    /* -------------------------------------------------------------------------- */
    /*                              ERC20 Bridging                              */
    /* -------------------------------------------------------------------------- */

    function test_BridgeERC20() public {
        MockERC20 token = new MockERC20("Test Token", "TEST");
        uint256 amount = 100e18;
        
        token.mint(address(feeRouter), amount);
        
        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit TokenBridged(address(token), amount, 1);
        
        feeRouter.bridgeERC20(address(token), 200_000, 0);
        
        assertEq(feeRouter.nonce(UNICHAIN_EID), 1);
    }

    function test_BridgeERC20OnlyKeeper() public {
        MockERC20 token = new MockERC20("Test", "TEST");
        
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.bridgeERC20(address(token), 200_000, 0);
    }

    /* -------------------------------------------------------------------------- */
    /*                          Trusted Contract Management                     */
    /* -------------------------------------------------------------------------- */

    function test_SetTrustedAirlock() public {
        address newAirlock = address(0x5555);
        
        vm.expectEmit(true, false, false, true);
        emit TrustedAirlockSet(newAirlock, true);
        
        vm.prank(owner);
        feeRouter.setTrustedAirlock(newAirlock, true);
        assertTrue(feeRouter.trustedAirlocks(newAirlock));
        
        // Test removal
        vm.prank(owner);
        feeRouter.setTrustedAirlock(newAirlock, false);
        assertFalse(feeRouter.trustedAirlocks(newAirlock));
    }

    function test_SetTrustedFactory() public {
        address newFactory = address(0x6666);
        
        vm.expectEmit(true, false, false, true);
        emit TrustedFactorySet(newFactory, true);
        
        vm.prank(owner);
        feeRouter.setTrustedFactory(newFactory, true);
        assertTrue(feeRouter.trustedFactories(newFactory));
        
        // Test removal
        vm.prank(owner);
        feeRouter.setTrustedFactory(newFactory, false);
        assertFalse(feeRouter.trustedFactories(newFactory));
    }

    function test_SetTrustedRemote() public {
        bytes32 remoteAddr = bytes32(uint256(uint160(address(0x7777))));
        
        vm.expectEmit(true, false, false, true);
        emit TrustedRemoteSet(BASE_EID, remoteAddr);
        
        vm.prank(owner);
        feeRouter.setTrustedRemote(BASE_EID, remoteAddr);
        assertEq(feeRouter.trustedRemotes(BASE_EID), remoteAddr);
    }

    function test_SetTreasury() public {
        address newTreasury = address(0x8888);
        
        vm.expectEmit(true, false, false, true);
        emit TreasuryUpdated(newTreasury);
        
        vm.prank(owner);
        feeRouter.setTreasury(newTreasury);
        assertEq(feeRouter.treasury(), newTreasury);
    }

    function test_RevertSetTreasuryZeroAddress() public {
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        vm.prank(owner);
        feeRouter.setTreasury(address(0));
    }

    function test_RevertSetTreasuryOnlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.setTreasury(alice);
    }

    /* -------------------------------------------------------------------------- */
    /*                              LayerZero Receive                           */
    /* -------------------------------------------------------------------------- */

    function test_LzReceiveETH() public {
        uint256 amount = 1 ether;
        bytes memory message = abi.encode(address(0), amount, uint256(0));
        
        // Mock LayerZero receive call from trusted remote
        vm.prank(address(lzEndpoint));
        Origin memory origin = Origin({srcEid: BASE_EID, sender: bytes32(uint256(uint160(address(this)))), nonce: 1});
        feeRouter.lzReceive(origin, keccak256(message), message, address(0), "");
        
        // Should process the received ETH through HLG conversion
    }

    function test_LzReceiveLegacyMessage() public {
        uint256 amount = 1 ether;
        bytes memory legacyMessage = abi.encode(address(0), amount); // 2-word payload
        
        vm.prank(address(lzEndpoint));
        Origin memory origin2 = Origin({srcEid: BASE_EID, sender: bytes32(uint256(uint160(address(this)))), nonce: 1});
        feeRouter.lzReceive(origin2, keccak256(legacyMessage), legacyMessage, address(0), "");
    }

    function test_RevertLzReceiveNotEndpoint() public {
        bytes memory message = abi.encode(address(0), 1 ether, uint256(0));
        
        vm.prank(alice);
        vm.expectRevert(FeeRouter.NotEndpoint.selector);
        Origin memory origin = Origin({srcEid: BASE_EID, sender: bytes32(uint256(uint160(address(this)))), nonce: 1});
        feeRouter.lzReceive(origin, keccak256(message), message, address(0), "");
    }

    function test_RevertLzReceiveUntrustedRemote() public {
        bytes memory message = abi.encode(address(0), 1 ether, uint256(0));
        
        vm.prank(address(lzEndpoint));
        vm.expectRevert(FeeRouter.UntrustedRemote.selector);
        Origin memory origin3 = Origin({srcEid: 99999, sender: bytes32(uint256(uint160(address(this)))), nonce: 1});
        feeRouter.lzReceive(origin3, keccak256(message), message, address(0), ""); // Untrusted EID
    }

    /* -------------------------------------------------------------------------- */
    /*                              Pause Functionality                         */
    /* -------------------------------------------------------------------------- */

    function test_PauseUnpause() public {
        vm.prank(owner);
        feeRouter.pause();
        assertTrue(feeRouter.paused());
        
        vm.prank(owner);
        feeRouter.unpause();
        assertFalse(feeRouter.paused());
    }

    function test_RevertPauseOnlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        feeRouter.pause();
    }

    /* -------------------------------------------------------------------------- */
    /*                              ETH Receive Security                        */
    /* -------------------------------------------------------------------------- */

    function test_ReceiveETHFromTrustedAirlock() public {
        uint256 amount = 1 ether;
        vm.deal(address(airlock), amount);
        
        vm.prank(address(airlock));
        (bool success,) = address(feeRouter).call{value: amount}("");
        
        assertTrue(success);
        // ETH is processed through fee splitting in receive()
    }

    function test_RevertReceiveETHFromUntrusted() public {
        vm.expectRevert(FeeRouter.UntrustedSender.selector);
        vm.prank(alice);
        payable(address(feeRouter)).transfer(0.1 ether);
    }

    /* -------------------------------------------------------------------------- */
    /*                              View Functions                              */
    /* -------------------------------------------------------------------------- */

    function test_GetBalances() public {
        uint256 ethAmount = 2 ether;
        uint256 hlgAmount = 1000e18;
        
        vm.deal(address(feeRouter), ethAmount);
        hlg.mint(address(feeRouter), hlgAmount);
        
        (uint256 ethBalance, uint256 hlgBalance) = feeRouter.getBalances();
        
        assertEq(ethBalance, ethAmount);
        assertEq(hlgBalance, hlgAmount);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Integration Tests                           */
    /* -------------------------------------------------------------------------- */

    function test_FullFeeProcessingFlowWithNewArchitecture() public {
        // Step 1: Verify new architecture components are trusted
        assertTrue(feeRouter.trustedFactories(address(factory)));
        assertTrue(feeRouter.trustedAirlocks(address(airlock)));
        
        // Step 2: Simulate Doppler Airlock fee collection
        uint256 feeAmount = 2 ether;
        vm.deal(address(airlock), feeAmount);
        airlock.setCollectableAmount(address(0), feeAmount);
        
        // Step 3: Keeper collects fees from airlock
        vm.prank(keeper);
        feeRouter.collectAirlockFees(address(airlock), address(0), feeAmount);
        
        // Step 4: Verify fee split (1.5% protocol, 98.5% treasury)
        uint256 expectedTreasuryFee = (feeAmount * 9850) / 10_000;
        assertEq(treasury.balance, expectedTreasuryFee);
        
        // Step 5: Bridge accumulated protocol fees if above threshold
        if (address(feeRouter).balance >= MIN_BRIDGE_VALUE) {
            vm.prank(keeper);
            feeRouter.bridge(200_000, 0);
            assertGt(feeRouter.nonce(UNICHAIN_EID), 0);
        }
    }

    function test_BaseToUnichainFeeRouting() public {
        console.log("=== Base to Unichain Fee Routing ===");
        console.log("Base EID:", BASE_EID);
        console.log("Unichain EID (Remote):", UNICHAIN_EID);
        console.log("FeeRouter configured for Base -> Unichain bridging");
        
        // Simulate fee collection on Base
        uint256 feeAmount = 1 ether;
        vm.deal(address(airlock), feeAmount);
        airlock.setCollectableAmount(address(0), feeAmount);
        
        vm.prank(keeper);
        feeRouter.collectAirlockFees(address(airlock), address(0), feeAmount);
        
        // Verify treasury received fees
        uint256 expectedTreasuryFee = (feeAmount * 9850) / 10_000;
        assertEq(treasury.balance, expectedTreasuryFee);
        
        console.log("Base fee collection and treasury distribution successful");
    }

    /* -------------------------------------------------------------------------- */
    /*                              Fuzz Testing                                */
    /* -------------------------------------------------------------------------- */

    function testFuzz_FeeSplit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= type(uint128).max);
        
        (uint256 protocolFee, uint256 treasuryFee) = feeRouter.calculateFeeSplit(amount);
        
        assertEq(protocolFee + treasuryFee, amount);
        assertEq(protocolFee, (amount * 150) / 10_000);
        assertGe(treasuryFee, (amount * 9800) / 10_000); // At least 98%
    }

    function testFuzz_BridgeAmount(uint256 amount) public {
        vm.assume(amount >= MIN_BRIDGE_VALUE && amount <= 100 ether);
        
        vm.deal(address(feeRouter), amount);
        
        vm.prank(keeper);
        feeRouter.bridge(200_000, 0);
        
        assertEq(feeRouter.nonce(UNICHAIN_EID), 1);
        assertTrue(lzEndpoint.sendCalled());
    }

    function testFuzz_AirlockFeeCollection(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 10 ether);
        
        vm.deal(address(airlock), amount);
        airlock.setCollectableAmount(address(0), amount);
        
        vm.prank(keeper);
        feeRouter.collectAirlockFees(address(airlock), address(0), amount);
        
        // Verify treasury receives the correct amount (amount - protocolFee)
        uint256 expectedProtocolFee = (amount * 150) / 10_000; // 1.5%
        uint256 expectedTreasuryFee = amount - expectedProtocolFee;
        assertEq(treasury.balance, expectedTreasuryFee);
    }
}