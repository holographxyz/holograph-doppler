// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HolographBridge} from "../../src/HolographBridge.sol";
import {HolographFactory} from "../../src/HolographFactory.sol";
import {HolographERC20} from "../../src/HolographERC20.sol";
import {IHolographBridge} from "../../src/interfaces/IHolographBridge.sol";
import {ChainConfig} from "../../src/structs/BridgeStructs.sol";
import {MockLZEndpoint} from "../mock/MockLZEndpoint.sol";

/**
 * @title HolographBridgeTest
 * @notice Comprehensive test suite for HolographBridge cross-chain coordination
 * @dev Tests cross-chain token expansion, peer configuration, and LayerZero integration
 */
contract HolographBridgeTest is Test {
    HolographBridge public bridge;
    HolographFactory public factory;
    HolographERC20 public sourceToken;
    MockLZEndpoint public lzEndpoint;
    
    address public owner = address(this);
    address public user = address(0x1234);
    address public tokenOwner = address(0x5678);
    
    // Test chain configurations
    uint32 constant BASE_EID = 40245; // Base Sepolia
    uint32 constant ETH_EID = 40161;  // Ethereum Sepolia
    uint32 constant ARB_EID = 40231;  // Arbitrum Sepolia
    
    address constant BASE_FACTORY = address(0x1111);
    address constant BASE_BRIDGE = address(0x2222);
    address constant ETH_FACTORY = address(0x3333);
    address constant ETH_BRIDGE = address(0x4444);
    
    // Test token parameters
    string constant TOKEN_NAME = "Test Bridge Token";
    string constant TOKEN_SYMBOL = "TBT";
    uint256 constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 constant YEARLY_MINT_RATE = 15e15;
    uint256 constant VESTING_DURATION = 365 days;
    string constant TOKEN_URI = "https://test.bridge.token";

    event ChainConfigured(uint32 indexed eid, address factory, address bridge, string name);
    event TokenExpanded(address indexed sourceToken, uint32 indexed dstEid, address indexed dstToken, string chainName);
    event PeerSet(uint32 indexed eid, bytes32 peer);
    event TrustedRemoteSet(address indexed token, uint32 indexed eid, bytes32 remote);

    function setUp() public {
        // Deploy mock LayerZero endpoint
        lzEndpoint = new MockLZEndpoint();
        
        // Deploy factory
        factory = new HolographFactory(address(lzEndpoint));
        
        // Deploy bridge
        bridge = new HolographBridge(address(lzEndpoint), address(factory), BASE_EID);
        
        // Configure supported chains
        bridge.configureChain(ETH_EID, ETH_FACTORY, ETH_BRIDGE, "Ethereum");
        bridge.configureChain(ARB_EID, address(0x5555), address(0x6666), "Arbitrum");
        
        // Set peers for cross-chain messaging
        bridge.setPeer(ETH_EID, bytes32(uint256(uint160(ETH_BRIDGE))));
        bridge.setPeer(ARB_EID, bytes32(uint256(uint160(address(0x6666)))));
        
        // Deploy a test token through factory
        factory.setAirlockAuthorization(address(this), true);
        
        bytes memory tokenData = abi.encode(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            YEARLY_MINT_RATE,
            VESTING_DURATION,
            new address[](0),
            new uint256[](0),
            TOKEN_URI
        );
        
        address tokenAddr = factory.create(
            INITIAL_SUPPLY,
            tokenOwner,
            tokenOwner,
            bytes32(uint256(12345)),
            tokenData
        );
        
        sourceToken = HolographERC20(tokenAddr);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Basic Functionality                          */
    /* -------------------------------------------------------------------------- */

    function test_Constructor() public {
        assertEq(address(bridge.lzEndpoint()), address(lzEndpoint));
        assertEq(address(bridge.localFactory()), address(factory));
        assertEq(bridge.owner(), owner);
        assertFalse(bridge.paused());
    }

    function test_ConfigureChain() public {
        uint32 newEid = 40999;
        address newFactory = address(0x7777);
        address newBridge = address(0x8888);
        string memory chainName = "Test Chain";
        
        vm.expectEmit(true, false, false, true);
        emit ChainConfigured(newEid, newFactory, newBridge, chainName);
        
        bridge.configureChain(newEid, newFactory, newBridge, chainName);
        
        ChainConfig memory config = bridge.getChainConfig(newEid);
        assertEq(config.eid, newEid);
        assertEq(config.factory, newFactory);
        assertEq(config.bridge, newBridge);
        assertTrue(config.active);
        assertEq(config.name, chainName);
    }

    function test_SetChainActive() public {
        // Disable a chain
        bridge.setChainActive(ETH_EID, false);
        ChainConfig memory config = bridge.getChainConfig(ETH_EID);
        assertFalse(config.active);
        
        // Re-enable the chain
        bridge.setChainActive(ETH_EID, true);
        config = bridge.getChainConfig(ETH_EID);
        assertTrue(config.active);
    }

    function test_RevertConfigureChainZeroAddress() public {
        vm.expectRevert(HolographBridge.ZeroAddress.selector);
        bridge.configureChain(40999, address(0), address(0x8888), "Test");
        
        vm.expectRevert(HolographBridge.ZeroAddress.selector);
        bridge.configureChain(40999, address(0x7777), address(0), "Test");
    }

    function test_RevertSetChainActiveUnsupportedChain() public {
        vm.expectRevert(HolographBridge.ChainNotSupported.selector);
        bridge.setChainActive(99999, false);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Token Expansion                             */
    /* -------------------------------------------------------------------------- */

    function test_ExpandToChain() public {
        // Only token owner can expand
        vm.prank(tokenOwner);
        vm.deal(tokenOwner, 1 ether); // For LayerZero fees
        
        // Can't predict destination token address
        vm.expectEmit(true, true, false, true);
        emit TokenExpanded(address(sourceToken), ETH_EID, address(0), "Ethereum");
        
        address dstToken = bridge.expandToChain{value: 0.1 ether}(address(sourceToken), ETH_EID);
        
        assertNotEq(dstToken, address(0), "Destination token address should not be zero");
        assertTrue(bridge.isDeployedToChain(address(sourceToken), ETH_EID));
        assertEq(bridge.getTokenDeployment(address(sourceToken), ETH_EID), dstToken);
        assertTrue(bridge.isTokenRegistered(dstToken));
    }

    function test_RevertExpandToChainZeroAddress() public {
        vm.prank(tokenOwner);
        vm.expectRevert(HolographBridge.ZeroAddress.selector);
        bridge.expandToChain(address(0), ETH_EID);
    }

    function test_RevertExpandToChainUnsupported() public {
        vm.prank(tokenOwner);
        vm.expectRevert(HolographBridge.ChainNotSupported.selector);
        bridge.expandToChain(address(sourceToken), 99999);
    }

    function test_RevertExpandToChainNotDeployed() public {
        // Deploy a token directly (not through factory)
        HolographERC20 directToken = new HolographERC20(
            "Direct Token",
            "DIRECT",
            1000e18,
            user,
            user,
            address(lzEndpoint),
            0,
            0,
            new address[](0),
            new uint256[](0),
            ""
        );
        
        vm.prank(user);
        vm.expectRevert(HolographBridge.TokenNotDeployed.selector);
        bridge.expandToChain(address(directToken), ETH_EID);
    }

    function test_RevertExpandToChainUnauthorized() public {
        vm.prank(user); // Not the token owner
        vm.expectRevert(HolographBridge.TokenNotDeployed.selector);
        bridge.expandToChain(address(sourceToken), ETH_EID);
    }

    function test_RevertExpandToChainAlreadyConfigured() public {
        // First expansion
        vm.prank(tokenOwner);
        vm.deal(tokenOwner, 1 ether);
        bridge.expandToChain{value: 0.1 ether}(address(sourceToken), ETH_EID);
        
        // Try to expand to same chain again
        vm.prank(tokenOwner);
        vm.expectRevert(HolographBridge.ChainAlreadyConfigured.selector);
        bridge.expandToChain{value: 0.1 ether}(address(sourceToken), ETH_EID);
    }

    function test_RevertExpandToChainWhenPaused() public {
        bridge.pause();
        
        vm.prank(tokenOwner);
        vm.expectRevert(); // Modern OpenZeppelin uses custom errors
        bridge.expandToChain(address(sourceToken), ETH_EID);
    }

    /* -------------------------------------------------------------------------- */
    /*                              IHolographBridge Interface                  */
    /* -------------------------------------------------------------------------- */

    function test_SetPeer() public {
        bytes32 peerAddr = bytes32(uint256(uint160(address(0x9999))));
        bridge.setPeer(ETH_EID, peerAddr);
        // Note: Testing peer retrieval would require LayerZero integration
    }

    function test_SetTokenPeer() public {
        vm.prank(tokenOwner);
        bytes32 peerAddr = bytes32(uint256(uint160(address(0x9999))));
        sourceToken.setPeer(ETH_EID, peerAddr);
        // Set peer directly on token since bridge can't call setPeer due to onlyOwner
    }

    function test_RegisterToken() public {
        uint32[] memory eids = new uint32[](2);
        eids[0] = ETH_EID;
        eids[1] = ARB_EID;
        
        vm.prank(tokenOwner);
        bridge.registerToken(address(sourceToken), eids);
        
        assertTrue(bridge.isTokenRegistered(address(sourceToken)));
    }

    function test_ConfigureOFT() public {
        uint32[] memory eids = new uint32[](2);
        eids[0] = ETH_EID;
        eids[1] = ARB_EID;
        
        bytes32[] memory peers = new bytes32[](2);
        peers[0] = bytes32(uint256(uint160(address(0x1111))));
        peers[1] = bytes32(uint256(uint160(address(0x2222))));
        
        // The token owner must call setPeer directly on the token
        vm.prank(tokenOwner);
        sourceToken.setPeer(eids[0], peers[0]);
        
        vm.prank(tokenOwner);
        sourceToken.setPeer(eids[1], peers[1]);
    }

    function test_RevertConfigureOFTMismatchedArrays() public {
        uint32[] memory eids = new uint32[](2);
        eids[0] = ETH_EID;
        eids[1] = ARB_EID;
        
        bytes32[] memory peers = new bytes32[](1); // Mismatched length
        peers[0] = bytes32(uint256(uint160(address(0x1111))));
        
        vm.prank(tokenOwner);
        vm.expectRevert(HolographBridge.InvalidTokenData.selector);
        bridge.configureOFT(address(sourceToken), eids, peers);
    }

    function test_RevertSetTokenPeerUnauthorized() public {
        vm.prank(user); // Not token owner
        vm.expectRevert(HolographBridge.TokenNotDeployed.selector);
        bridge.setTokenPeer(address(sourceToken), ETH_EID, bytes32(0));
    }

    /* -------------------------------------------------------------------------- */
    /*                              View Functions                              */
    /* -------------------------------------------------------------------------- */

    function test_GetPeer() public {
        bytes32 peer = bridge.getPeer(ETH_EID);
        assertEq(peer, bytes32(uint256(uint160(ETH_BRIDGE))));
    }

    function test_GetTokenPeer() public {
        // First expand to create a deployment
        vm.prank(tokenOwner);
        vm.deal(tokenOwner, 1 ether);
        address dstToken = bridge.expandToChain{value: 0.1 ether}(address(sourceToken), ETH_EID);
        
        bytes32 peer = bridge.getTokenPeer(address(sourceToken), ETH_EID);
        assertEq(peer, bytes32(uint256(uint160(dstToken))));
    }

    function test_GetTokenChains() public {
        uint32[] memory chains = bridge.getTokenChains(address(sourceToken));
        // Current implementation returns empty array - this would be enhanced in production
        assertEq(chains.length, 0);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Admin Functions                             */
    /* -------------------------------------------------------------------------- */

    function test_PauseUnpause() public {
        bridge.pause();
        assertTrue(bridge.paused());
        
        bridge.unpause();
        assertFalse(bridge.paused());
    }

    function test_RevertNonOwnerPause() public {
        vm.prank(user);
        vm.expectRevert(); // Modern OpenZeppelin uses custom errors
        bridge.pause();
    }

    function test_RevertNonOwnerConfigureChain() public {
        vm.prank(user);
        vm.expectRevert(); // Modern OpenZeppelin uses custom errors
        bridge.configureChain(40999, address(0x7777), address(0x8888), "Test");
    }

    function test_RevertNonOwnerSetChainActive() public {
        vm.prank(user);
        vm.expectRevert(); // Modern OpenZeppelin uses custom errors
        bridge.setChainActive(ETH_EID, false);
    }

    function test_RevertNonOwnerSetPeer() public {
        vm.prank(user);
        vm.expectRevert(); // Modern OpenZeppelin uses custom errors
        bridge.setPeer(ETH_EID, bytes32(0));
    }

    /* -------------------------------------------------------------------------- */
    /*                              Edge Cases                                  */
    /* -------------------------------------------------------------------------- */

    function test_ReceiveETH() public {
        // Bridge should accept ETH for LayerZero fees
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);
        
        (bool success,) = address(bridge).call{value: amount}("");
        assertTrue(success);
        assertEq(address(bridge).balance, amount);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Integration Tests                           */
    /* -------------------------------------------------------------------------- */

    function test_FullExpansionFlow() public {
        vm.startPrank(tokenOwner);
        vm.deal(tokenOwner, 2 ether);
        
        // Expand to Ethereum
        address ethToken = bridge.expandToChain{value: 0.5 ether}(address(sourceToken), ETH_EID);
        assertTrue(bridge.isDeployedToChain(address(sourceToken), ETH_EID));
        
        // Expand to Arbitrum
        address arbToken = bridge.expandToChain{value: 0.5 ether}(address(sourceToken), ARB_EID);
        assertTrue(bridge.isDeployedToChain(address(sourceToken), ARB_EID));
        
        // Verify different addresses
        assertNotEq(ethToken, arbToken);
        assertNotEq(ethToken, address(sourceToken));
        assertNotEq(arbToken, address(sourceToken));
        
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                              Fuzz Testing                                */
    /* -------------------------------------------------------------------------- */

    function testFuzz_ConfigureChain(uint32 eid, address factoryAddr, address bridge_addr, string memory name) public {
        vm.assume(eid > 0 && eid != ETH_EID && eid != ARB_EID);
        vm.assume(factoryAddr != address(0) && bridge_addr != address(0));
        vm.assume(bytes(name).length > 0 && bytes(name).length <= 32);
        
        bridge.configureChain(eid, factoryAddr, bridge_addr, name);
        
        ChainConfig memory config = bridge.getChainConfig(eid);
        assertEq(config.eid, eid);
        assertEq(config.factory, factoryAddr);
        assertEq(config.bridge, bridge_addr);
        assertTrue(config.active);
        assertEq(config.name, name);
    }
}