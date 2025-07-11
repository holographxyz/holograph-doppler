// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HolographFactory} from "../../src/HolographFactory.sol";
import {HolographERC20} from "../../src/HolographERC20.sol";
import {HolographBridge} from "../../src/HolographBridge.sol";
import {FeeRouter} from "../../src/FeeRouter.sol";
import {MockLZEndpoint} from "../mock/MockLZEndpoint.sol";
import {MockAirlock} from "../mock/MockAirlock.sol";

/**
 * @title FullProtocolWorkflowTest
 * @notice End-to-end integration tests for the complete Holograph protocol
 * @dev Tests the full workflow: Doppler Airlock -> Factory -> Token -> Bridge -> Cross-chain
 * @dev Uses Base and Unichain networks with correct LayerZero endpoint IDs
 */
contract FullProtocolWorkflowTest is Test {
    // Core contracts
    HolographFactory public factory;
    HolographBridge public bridge;
    FeeRouter public feeRouter;
    MockLZEndpoint public lzEndpoint;
    MockAirlock public airlock;
    
    // Test addresses
    address public owner = address(this);
    address public treasury = address(0x1111);
    address public tokenOwner = address(0x2222);
    address public user = address(0x3333);
    
    // LayerZero endpoint IDs for Base and Unichain
    uint32 constant BASE_MAINNET_EID = 30184;    // Base Mainnet
    uint32 constant BASE_SEPOLIA_EID = 40245;    // Base Sepolia (testnet)
    uint32 constant UNICHAIN_SEPOLIA_EID = 40328; // Unichain Sepolia (testnet)
    
    // Using testnets for testing
    uint32 constant SOURCE_EID = BASE_SEPOLIA_EID;    // Deploy on Base Sepolia
    uint32 constant DEST_EID = UNICHAIN_SEPOLIA_EID;  // Expand to Unichain Sepolia
    
    // Mock factory and bridge addresses on destination chain
    address constant UNICHAIN_FACTORY = address(0x1111);
    address constant UNICHAIN_BRIDGE = address(0x2222);
    
    // Token parameters
    string constant TOKEN_NAME = "Base to Unichain Token";
    string constant TOKEN_SYMBOL = "B2U";
    uint256 constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 constant YEARLY_MINT_RATE = 15e15; // 1.5% yearly inflation
    uint256 constant VESTING_DURATION = 365 days;
    string constant TOKEN_URI = "https://base-unichain.token";
    
    bytes32 constant TEST_SALT = bytes32(uint256(54321));

    event TokenDeployed(address indexed token, string name, string symbol, uint256 initialSupply, address indexed recipient, address indexed owner);
    event TokenExpanded(address indexed sourceToken, uint32 indexed dstEid, address indexed dstToken, string chainName);
    event SlicePulled(address indexed airlock, address indexed token, uint256 holoAmt, uint256 treasuryAmt);

    function setUp() public {
        // Deploy LayerZero endpoint
        lzEndpoint = new MockLZEndpoint();
        
        // Deploy core contracts on Base Sepolia
        factory = new HolographFactory(address(lzEndpoint));
        bridge = new HolographBridge(address(lzEndpoint), address(factory), SOURCE_EID);
        
        // Deploy FeeRouter with Unichain as remote chain for fee bridging
        feeRouter = new FeeRouter(
            address(lzEndpoint),  // endpoint
            DEST_EID,            // remote EID (Unichain for fee bridging)
            address(0),          // staking pool (not needed for this test)
            address(0),          // HLG (not needed)
            address(0),          // WETH (not needed)
            address(0),          // swap router (not needed)
            treasury             // treasury
        );
        
        // Deploy mock Doppler Airlock
        airlock = new MockAirlock();
        
        // Set up permissions
        factory.setAirlockAuthorization(address(airlock), true);
        feeRouter.setTrustedFactory(address(factory), true);
        feeRouter.setTrustedAirlock(address(airlock), true);
        
        // Grant keeper role to test contract for fee collection
        bytes32 keeperRole = feeRouter.KEEPER_ROLE();
        feeRouter.grantRole(keeperRole, address(this));
        
        // Configure bridge for Unichain
        bridge.configureChain(
            DEST_EID,
            UNICHAIN_FACTORY,
            UNICHAIN_BRIDGE,
            "Unichain Sepolia"
        );
        
        // Fund test accounts
        vm.deal(tokenOwner, 10 ether);
        vm.deal(user, 5 ether);
        vm.deal(address(airlock), 10 ether);
    }

    /* -------------------------------------------------------------------------- */
    /*                          End-to-End Token Creation                       */
    /* -------------------------------------------------------------------------- */

    function test_CompleteTokenCreationFlow() public {
        // Step 1: Create token through Doppler Airlock (simulated) on Base
        bytes memory tokenData = _encodeTokenData(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            TOKEN_URI
        );
        
        // We can't predict the exact token address, so don't check it
        vm.expectEmit(false, true, true, true);
        emit TokenDeployed(address(0), TOKEN_NAME, TOKEN_SYMBOL, INITIAL_SUPPLY, tokenOwner, tokenOwner);
        
        address tokenAddr = airlock.createTokenThroughFactory(
            address(factory),
            INITIAL_SUPPLY,
            tokenOwner,
            tokenOwner,
            TEST_SALT,
            tokenData
        );
        
        // Step 2: Verify token deployment on Base
        HolographERC20 token = HolographERC20(tokenAddr);
        assertEq(token.name(), TOKEN_NAME);
        assertEq(token.symbol(), TOKEN_SYMBOL);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(tokenOwner), INITIAL_SUPPLY);
        assertEq(token.owner(), tokenOwner);
        assertTrue(factory.isDeployedToken(tokenAddr));
        
        // Step 3: Test fee collection integration
        uint256 feeAmount = 1 ether;
        vm.deal(address(airlock), feeAmount * 2); // Fund with enough for both transfers
        
        // Simulate fee collection through airlock receive() function
        vm.prank(address(airlock));
        (bool success,) = address(feeRouter).call{value: feeAmount}("");
        require(success, "Fee transfer failed");
        
        // Set collectable amount in MockAirlock and collect the fees
        airlock.setCollectableAmount(address(0), feeAmount);
        feeRouter.collectAirlockFees(address(airlock), address(0), feeAmount);
        
        // Verify fee split (1.5% protocol, 98.5% treasury) 
        uint256 expectedProtocolFee = (feeAmount * 150) / 10000;
        uint256 expectedTreasuryFee = feeAmount - expectedProtocolFee;
        assertGe(treasury.balance, expectedTreasuryFee);
    }

    /* -------------------------------------------------------------------------- */
    /*                          Base to Unichain Expansion                      */
    /* -------------------------------------------------------------------------- */

    function test_BaseToUnichainExpansion() public {
        // Step 1: Create initial token on Base
        address baseToken = _createTestToken();
        HolographERC20 sourceToken = HolographERC20(baseToken);
        
        console.log("Base token deployed at:", baseToken);
        console.log("Token name:", sourceToken.name());
        console.log("Token symbol:", sourceToken.symbol());
        
        // Step 2: Expand from Base to Unichain (must be called by token owner)
        vm.deal(tokenOwner, 1 ether); // Fund the token owner
        vm.prank(tokenOwner);
        // We can't predict the destination token address
        vm.expectEmit(true, true, false, true);
        emit TokenExpanded(baseToken, DEST_EID, address(0), "Unichain Sepolia");
        
        address unichainToken = bridge.expandToChain{value: 0.5 ether}(baseToken, DEST_EID);
        
        console.log("Unichain token will be deployed at:", unichainToken);
        
        // Step 3: Verify expansion
        assertTrue(bridge.isDeployedToChain(baseToken, DEST_EID));
        assertEq(bridge.getTokenDeployment(baseToken, DEST_EID), unichainToken);
        assertTrue(bridge.isTokenRegistered(unichainToken));
        
        // Step 4: Verify tokens have different addresses
        assertNotEq(baseToken, unichainToken);
        
        console.log("Successfully expanded from Base to Unichain");
    }

    /* -------------------------------------------------------------------------- */
    /*                          Token Functionality on Base                     */
    /* -------------------------------------------------------------------------- */

    function test_BaseTokenFunctionality() public {
        address tokenAddr = _createTestToken();
        HolographERC20 token = HolographERC20(tokenAddr);
        
        // Test basic transfers on Base
        uint256 transferAmount = 100_000e18;
        vm.prank(tokenOwner);
        token.transfer(user, transferAmount);
        
        assertEq(token.balanceOf(user), transferAmount);
        assertEq(token.balanceOf(tokenOwner), INITIAL_SUPPLY - transferAmount);
        
        // Test governance functionality
        vm.prank(user);
        token.delegate(user);
        assertEq(token.getVotes(user), transferAmount);
        
        // Unlock pool to enable minting
        vm.prank(tokenOwner);
        token.unlockPool();
        
        // Test minting after time passes (using inflation mechanism)
        vm.warp(block.timestamp + 30 days);
        uint256 balanceBefore = token.balanceOf(tokenOwner);
        
        vm.prank(tokenOwner);
        token.mintInflation(); // This mints to owner
        
        uint256 balanceAfter = token.balanceOf(tokenOwner);
        assertGt(balanceAfter, balanceBefore, "Should have minted some tokens");
        
        console.log("SUCCESS: Base token functionality working correctly");
    }

    /* -------------------------------------------------------------------------- */
    /*                          LayerZero Base-Unichain Setup                   */
    /* -------------------------------------------------------------------------- */

    function test_LayerZeroBaseUnichainConfiguration() public {
        address tokenAddr = _createTestToken();
        HolographERC20 token = HolographERC20(tokenAddr);
        
        // Expand to Unichain first
        vm.deal(tokenOwner, 1 ether);
        vm.prank(tokenOwner);
        address unichainToken = bridge.expandToChain{value: 0.5 ether}(tokenAddr, DEST_EID);
        
        // Test direct peer setting for cross-chain communication
        bytes32 unichainPeer = bytes32(uint256(uint160(unichainToken)));
        vm.prank(tokenOwner);
        token.setPeer(DEST_EID, unichainPeer);
        
        console.log("Base EID:", SOURCE_EID);
        console.log("Unichain EID:", DEST_EID);
        console.log("SUCCESS: LayerZero Base-Unichain configuration complete");
    }

    /* -------------------------------------------------------------------------- */
    /*                          Fee Router Base-Unichain                        */
    /* -------------------------------------------------------------------------- */

    function test_FeeRouterBaseToUnichain() public {
        // Verify factory is trusted
        assertTrue(feeRouter.trustedFactories(address(factory)));
        
        // Test fee collection from airlock on Base
        uint256 feeAmount = 2 ether;
        vm.deal(address(airlock), feeAmount * 2); // Fund with enough for both transfers
        
        // Simulate airlock sending fees to FeeRouter
        vm.prank(address(airlock));
        (bool success,) = address(feeRouter).call{value: feeAmount}("");
        require(success, "Fee transfer failed");
        
        // Collect fees from airlock
        airlock.setCollectableAmount(address(0), feeAmount);
        feeRouter.collectAirlockFees(address(airlock), address(0), feeAmount);
        
        // Verify fee split calculation
        (uint256 protocolFee, uint256 treasuryFee) = feeRouter.calculateFeeSplit(feeAmount);
        assertEq(protocolFee, (feeAmount * 150) / 10000); // 1.5%
        assertEq(treasuryFee, feeAmount - protocolFee);   // 98.5%
        
        // Check that treasury received the fees
        assertGe(treasury.balance, treasuryFee);
        
        console.log("Treasury fee:", treasuryFee);
        console.log("Protocol fee:", protocolFee);
        console.log("SUCCESS: Fee routing from Base configured correctly");
    }

    /* -------------------------------------------------------------------------- */
    /*                          Error Handling                                  */
    /* -------------------------------------------------------------------------- */

    function test_UnauthorizedUnichainExpansion() public {
        address tokenAddr = _createTestToken();
        
        // User who doesn't own the token tries to expand it
        vm.prank(user);
        vm.expectRevert(HolographBridge.TokenNotDeployed.selector); // The bridge checks if caller is token owner
        bridge.expandToChain(tokenAddr, DEST_EID);
    }

    function test_DoubleExpansionToUnichain() public {
        address tokenAddr = _createTestToken();
        
        // First expansion to Unichain
        vm.deal(tokenOwner, 1 ether);
        vm.prank(tokenOwner);
        bridge.expandToChain{value: 0.5 ether}(tokenAddr, DEST_EID);
        
        // Second expansion to same chain should fail
        vm.prank(tokenOwner);
        vm.expectRevert(HolographBridge.ChainAlreadyConfigured.selector);
        bridge.expandToChain{value: 0.5 ether}(tokenAddr, DEST_EID);
    }

    /* -------------------------------------------------------------------------- */
    /*                          Base-Unichain Ecosystem                         */
    /* -------------------------------------------------------------------------- */

    function test_BaseUnichainEcosystem() public {
        // Create token on Base
        address baseToken = _createTestToken();
        
        console.log("=== Base-Unichain Ecosystem Test ===");
        console.log("Base token address:", baseToken);
        
        // Expand to Unichain
        vm.deal(tokenOwner, 1 ether);
        vm.prank(tokenOwner);
        address unichainToken = bridge.expandToChain{value: 0.5 ether}(baseToken, DEST_EID);
        
        console.log("Unichain token address:", unichainToken);
        
        // Configure cross-chain peer directly on token
        bytes32 unichainPeer = bytes32(uint256(uint160(unichainToken)));
        vm.prank(tokenOwner);
        HolographERC20(baseToken).setPeer(DEST_EID, unichainPeer);
        
        // Verify deployment state
        assertTrue(bridge.isDeployedToChain(baseToken, DEST_EID));
        assertTrue(bridge.isTokenRegistered(unichainToken));
        
        // Verify token properties
        HolographERC20 baseTokenContract = HolographERC20(baseToken);
        
        assertEq(baseTokenContract.name(), TOKEN_NAME);
        assertEq(baseTokenContract.symbol(), TOKEN_SYMBOL);
        assertEq(baseTokenContract.totalSupply(), INITIAL_SUPPLY);
        
        console.log("Token name:", baseTokenContract.name());
        console.log("Token symbol:", baseTokenContract.symbol());
        console.log("SUCCESS: Base-Unichain ecosystem configured successfully");
    }

    /* -------------------------------------------------------------------------- */
    /*                          Performance & Gas Tests                         */
    /* -------------------------------------------------------------------------- */

    function test_GasConsumptionBaseTokenCreation() public {
        bytes memory tokenData = _encodeTokenData(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            TOKEN_URI
        );
        
        uint256 gasBefore = gasleft();
        
        address tokenAddr = airlock.createTokenThroughFactory(
            address(factory),
            INITIAL_SUPPLY,
            tokenOwner,
            tokenOwner,
            TEST_SALT,
            tokenData
        );
        
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for Base token creation:", gasUsed);
        
        // Verify creation was successful
        assertTrue(tokenAddr != address(0));
        assertTrue(factory.isDeployedToken(tokenAddr));
    }

    function test_GasConsumptionBaseToUnichainExpansion() public {
        address tokenAddr = _createTestToken();
        
        vm.deal(tokenOwner, 1 ether);
        vm.prank(tokenOwner);
        uint256 gasBefore = gasleft();
        
        bridge.expandToChain{value: 0.5 ether}(tokenAddr, DEST_EID);
        
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for Base->Unichain expansion:", gasUsed);
    }

    /* -------------------------------------------------------------------------- */
    /*                          Network Information                             */
    /* -------------------------------------------------------------------------- */

    function test_DisplayNetworkInfo() public {
        console.log("=== Network Configuration ===");
        console.log("Base Mainnet EID:", BASE_MAINNET_EID);
        console.log("Base Sepolia EID:", BASE_SEPOLIA_EID);
        console.log("Unichain Sepolia EID:", UNICHAIN_SEPOLIA_EID);
        console.log("Source Chain (Base Sepolia):", SOURCE_EID);
        console.log("Destination Chain (Unichain Sepolia):", DEST_EID);
        console.log("Factory address:", address(factory));
        console.log("Bridge address:", address(bridge));
        console.log("FeeRouter address:", address(feeRouter));
    }

    /* -------------------------------------------------------------------------- */
    /*                          Helper Functions                                */
    /* -------------------------------------------------------------------------- */

    function _createTestToken() internal returns (address) {
        bytes memory tokenData = _encodeTokenData(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            TOKEN_URI
        );
        
        return airlock.createTokenThroughFactory(
            address(factory),
            INITIAL_SUPPLY,
            tokenOwner,
            tokenOwner,
            TEST_SALT,
            tokenData
        );
    }

    function _encodeTokenData(
        string memory name,
        string memory symbol,
        uint256 yearlyMintCap,
        uint256 vestingDuration,
        address[] memory recipients,
        uint256[] memory amounts,
        string memory tokenURI
    ) internal pure returns (bytes memory) {
        return abi.encode(
            name,
            symbol,
            yearlyMintCap,
            vestingDuration,
            recipients,
            amounts,
            tokenURI
        );
    }
}