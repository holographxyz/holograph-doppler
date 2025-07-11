// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../lib/LayerZero-v2/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "../lib/LayerZero-v2/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroReceiver.sol";
import "../lib/LayerZero-v2/packages/layerzero-v2/evm/messagelib/contracts/libs/ExecutorOptions.sol";
import "./interfaces/IHolographBridge.sol";
import "./HolographERC20.sol";
import "./HolographFactory.sol";
import "./structs/BridgeStructs.sol";

/**
 * @title HolographBridge
 * @notice Cross-chain expansion coordinator for HolographERC20 tokens using LayerZero V2
 * @dev Handles token deployment to new chains with automatic peer configuration
 * @author Holograph Protocol
 */
contract HolographBridge is IHolographBridge, ILayerZeroReceiver, Ownable, Pausable, ReentrancyGuard {

    /* -------------------------------------------------------------------------- */
    /*                                  Errors                                    */
    /* -------------------------------------------------------------------------- */
    error ZeroAddress();
    error ChainNotSupported();
    error TokenNotDeployed();
    error ChainAlreadyConfigured();
    error InvalidTokenData();
    error CrossChainCallFailed();
    error InsufficientFee();
    error InvalidEndpoint();
    error UntrustedSender();
    error InvalidSaltReuse();

    /* -------------------------------------------------------------------------- */
    /*                                 Storage                                    */
    /* -------------------------------------------------------------------------- */
    /// @notice LayerZero V2 endpoint for cross-chain messaging
    ILayerZeroEndpointV2 public immutable lzEndpoint;

    /// @notice Local HolographFactory for reference
    HolographFactory public immutable localFactory;

    /// @notice Current chain's LayerZero endpoint ID
    uint32 public immutable localEid;

    /// @notice Mapping of LayerZero peers for cross-chain messaging
    mapping(uint32 => bytes32) public peers;

    /// @notice Supported chain configurations
    mapping(uint32 => ChainConfig) public supportedChains;

    /// @notice Track which chains each token has been deployed to
    mapping(address => mapping(uint32 => address)) public tokenDeployments;

    /// @notice Track tokens deployed by this bridge
    mapping(address => bool) public bridgeDeployedTokens;

    /// @notice Track used salts to prevent reuse attacks
    mapping(bytes32 => bool) public usedSalts;

    /* -------------------------------------------------------------------------- */
    /*                                  Events                                    */
    /* -------------------------------------------------------------------------- */
    event TokenExpanded(
        address indexed sourceToken,
        uint32 indexed dstEid,
        address indexed dstToken,
        string chainName
    );

    event ChainConfigured(uint32 indexed eid, address factory, address bridge, string name);


    /* -------------------------------------------------------------------------- */
    /*                               Constructor                                  */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Initialize the HolographBridge
     * @param _lzEndpoint LayerZero V2 endpoint address
     * @param _factory Local HolographFactory address
     * @param _localEid Local chain's LayerZero endpoint ID
     */
    constructor(address _lzEndpoint, address _factory, uint32 _localEid) Ownable(msg.sender) {
        if (_lzEndpoint == address(0) || _factory == address(0)) revert ZeroAddress();
        if (_localEid == 0) revert ZeroAddress();
        
        lzEndpoint = ILayerZeroEndpointV2(_lzEndpoint);
        localFactory = HolographFactory(_factory);
        localEid = _localEid;
    }

    /* -------------------------------------------------------------------------- */
    /*                             Chain Management                              */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Configure a supported destination chain
     * @param eid Destination chain endpoint ID
     * @param factory HolographFactory address on destination chain
     * @param bridge HolographBridge address on destination chain
     * @param name Human readable chain name
     */
    function configureChain(
        uint32 eid,
        address factory,
        address bridge,
        string calldata name
    ) external onlyOwner {
        if (factory == address(0) || bridge == address(0)) revert ZeroAddress();
        
        supportedChains[eid] = ChainConfig({
            eid: eid,
            factory: factory,
            bridge: bridge,
            active: true,
            name: name
        });

        emit ChainConfigured(eid, factory, bridge, name);
    }

    /**
     * @notice Enable or disable a chain for deployments
     * @param eid Chain endpoint ID
     * @param active Whether the chain should be active
     */
    function setChainActive(uint32 eid, bool active) external onlyOwner {
        if (supportedChains[eid].eid == 0) revert ChainNotSupported();
        supportedChains[eid].active = active;
    }

    /* -------------------------------------------------------------------------- */
    /*                            Token Expansion                                */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Expand an existing token to a new chain with proper fee handling
     * @param sourceToken Token address on current chain
     * @param dstEid Destination chain endpoint ID
     * @return dstToken Address of deployed token on destination chain
     */
    function expandToChain(
        address sourceToken,
        uint32 dstEid
    ) external payable whenNotPaused nonReentrant returns (address dstToken) {
        // Validate inputs
        if (sourceToken == address(0)) revert ZeroAddress();
        if (!supportedChains[dstEid].active) revert ChainNotSupported();
        if (!localFactory.isDeployedToken(sourceToken)) revert TokenNotDeployed();
        if (tokenDeployments[sourceToken][dstEid] != address(0)) revert ChainAlreadyConfigured();

        // Only token owner can expand
        if (msg.sender != Ownable(sourceToken).owner()) revert TokenNotDeployed();

        ChainConfig memory dstChain = supportedChains[dstEid];

        // Get original deployment parameters from source token
        TokenParams memory params = _extractTokenParams(sourceToken);

        // Generate deterministic but unique salt
        bytes32 salt = _generateSecureSalt(params, dstEid);
        if (usedSalts[salt]) revert InvalidSaltReuse();
        usedSalts[salt] = true;

        // Deploy token on destination chain via cross-chain message
        dstToken = _deployOnDestination(dstEid, dstChain.factory, params, salt);

        // Configure peers on both sides
        _configurePeers(sourceToken, dstToken, dstEid);

        // Track the deployment
        tokenDeployments[sourceToken][dstEid] = dstToken;
        bridgeDeployedTokens[dstToken] = true;

        emit TokenExpanded(sourceToken, dstEid, dstToken, dstChain.name);
    }

    /* -------------------------------------------------------------------------- */
    /*                            Internal Functions                             */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Extract original deployment parameters from a deployed token
     */
    function _extractTokenParams(address token) internal view returns (TokenParams memory params) {
        HolographERC20 oft = HolographERC20(token);
        
        params.name = oft.name();
        params.symbol = oft.symbol();
        params.totalSupply = oft.totalSupply();
        params.owner = Ownable(token).owner();
        params.yearlyMintRate = oft.yearlyMintRate();
        params.vestingDuration = oft.vestingDuration();
        params.tokenURI = oft.tokenURI();
    }

    /**
     * @notice Generate secure CREATE2 salt to prevent collisions
     */
    function _generateSecureSalt(
        TokenParams memory params,
        uint32 dstEid
    ) internal view returns (bytes32 salt) {
        salt = keccak256(abi.encodePacked(
            params.name,
            params.symbol,
            params.owner,
            dstEid,
            localEid,
            block.timestamp,
            address(this)
        ));
    }

    /**
     * @notice Deploy token on destination chain via LayerZero message with proper fee handling
     */
    function _deployOnDestination(
        uint32 dstEid,
        address dstFactory,
        TokenParams memory params,
        bytes32 salt
    ) internal returns (address dstToken) {
        // Encode deployment message
        bytes memory tokenData = abi.encode(
            params.name,
            params.symbol,
            params.yearlyMintRate,
            params.vestingDuration,
            new address[](0),
            new uint256[](0),
            params.tokenURI
        );

        bytes memory payload = abi.encode(
            "DEPLOY_TOKEN",
            params.totalSupply,
            params.owner,
            params.owner,
            salt,
            tokenData
        );

        // Build proper LayerZero V2 options with sufficient gas for token deployment
        bytes memory options = _buildExecutorOptions(500000, 0);

        // Get messaging parameters
        MessagingParams memory msgParams = MessagingParams({
            dstEid: dstEid,
            receiver: peers[dstEid],
            message: payload,
            options: options,
            payInLzToken: false
        });

        // Quote and validate fee
        MessagingFee memory fee = lzEndpoint.quote(msgParams, address(this));
        if (msg.value < fee.nativeFee) revert InsufficientFee();

        // Send message
        lzEndpoint.send{value: fee.nativeFee}(msgParams, payable(msg.sender));

        // Predict destination token address
        dstToken = _predictTokenAddress(dstFactory, salt, params);
    }

    /**
     * @notice Predict token address using CREATE2
     */
    function _predictTokenAddress(
        address factory,
        bytes32 salt,
        TokenParams memory params
    ) internal pure returns (address predicted) {
        bytes memory bytecode = abi.encodePacked(
            type(HolographERC20).creationCode,
            abi.encode(
                params.name,
                params.symbol,
                params.totalSupply,
                params.owner,
                params.owner,
                address(0), // Will be replaced with destination endpoint
                params.yearlyMintRate,
                params.vestingDuration,
                new address[](0),
                new uint256[](0),
                params.tokenURI
            )
        );
        
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                factory,
                salt,
                keccak256(bytecode)
            )
        );
        
        predicted = address(uint160(uint256(hash)));
    }

    /**
     * @notice Configure LayerZero peers on both source and destination tokens
     */
    function _configurePeers(address sourceToken, address dstToken, uint32 dstEid) internal {
        bytes memory peerPayload = abi.encode(
            "SET_PEER",
            dstToken,
            localEid,
            _addressToBytes32(sourceToken)
        );

        bytes memory peerOptions = _buildExecutorOptions(200000, 0);

        MessagingParams memory msgParams = MessagingParams({
            dstEid: dstEid,
            receiver: peers[dstEid],
            message: peerPayload,
            options: peerOptions,
            payInLzToken: false
        });

        MessagingFee memory fee = lzEndpoint.quote(msgParams, address(this));
        if (address(this).balance >= fee.nativeFee) {
            lzEndpoint.send{value: fee.nativeFee}(msgParams, payable(address(this)));
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                           LayerZero V2 Integration                        */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Handle incoming cross-chain messages
     * @param _origin Message origin information
     * @param _guid Unique message identifier  
     * @param _message Encoded message data
     * @param _executor Executor address
     * @param _extraData Additional data
     */
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable override {
        if (msg.sender != address(lzEndpoint)) revert InvalidEndpoint();
        if (peers[_origin.srcEid] == bytes32(0)) revert UntrustedSender();
        
        (string memory msgType) = abi.decode(_message, (string));
        
        bytes32 deployHash = keccak256("DEPLOY_TOKEN");
        bytes32 peerHash = keccak256("SET_PEER");
        bytes32 msgHash = keccak256(abi.encodePacked(msgType));
        
        if (msgHash == deployHash) {
            _handleTokenDeployment(_message);
        } else if (msgHash == peerHash) {
            _handlePeerConfiguration(_message);
        }
    }

    /**
     * @notice Handle token deployment message
     */
    function _handleTokenDeployment(bytes calldata _message) internal {
        (
            string memory msgType,
            uint256 initialSupply,
            address recipient,
            address owner,
            bytes32 salt,
            bytes memory tokenData
        ) = abi.decode(_message, (string, uint256, address, address, bytes32, bytes));

        address token = localFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        bridgeDeployedTokens[token] = true;
    }

    /**
     * @notice Handle peer configuration message
     */
    function _handlePeerConfiguration(bytes calldata _message) internal {
        (
            string memory msgType,
            address token,
            uint32 srcEid,
            bytes32 peer
        ) = abi.decode(_message, (string, address, uint32, bytes32));

        if (bridgeDeployedTokens[token]) {
            HolographERC20(token).setPeer(srcEid, peer);
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                            LayerZero Receiver                             */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Check if initialization path is allowed
     */
    function allowInitializePath(Origin calldata _origin) external view override returns (bool) {
        return peers[_origin.srcEid] != bytes32(0);
    }

    /**
     * @notice Get next nonce for sender
     */
    function nextNonce(uint32 _eid, bytes32 _sender) external view override returns (uint64) {
        return lzEndpoint.inboundNonce(address(this), _eid, _sender) + 1;
    }

    /* -------------------------------------------------------------------------- */
    /*                               Utilities                                   */
    /* -------------------------------------------------------------------------- */
    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /**
     * @notice Build LayerZero V2 executor options with gas limit
     * @param gas Gas limit for lzReceive execution
     * @param value Native token value to send (0 for no native drop)
     * @return Properly encoded LayerZero V2 options
     */
    function _buildExecutorOptions(uint128 gas, uint128 value) internal pure returns (bytes memory) {
        bytes memory lzReceiveOption = ExecutorOptions.encodeLzReceiveOption(gas, value);
        return abi.encodePacked(
            ExecutorOptions.WORKER_ID,
            uint16(lzReceiveOption.length + 1), // +1 for option type
            ExecutorOptions.OPTION_TYPE_LZRECEIVE,
            lzReceiveOption
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                        IHolographBridge Implementation                    */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Set peer bridge address for a destination chain
     * @param eid Destination chain endpoint ID
     * @param peer Peer bridge address on destination chain (as bytes32)
     */
    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
        peers[eid] = peer;
        emit PeerSet(eid, peer);
    }

    /**
     * @notice Configure LayerZero OFT peer for a token on destination chain
     * @param token Token address to configure
     * @param dstEid Destination chain endpoint ID
     * @param peer Peer token address on destination chain (as bytes32)
     */
    function setTokenPeer(address token, uint32 dstEid, bytes32 peer) external {
        if (msg.sender != Ownable(token).owner()) revert TokenNotDeployed();
        HolographERC20(token).setPeer(dstEid, peer);
    }

    /**
     * @notice Register a token for cross-chain coordination
     * @param token Token address to register
     * @param supportedEids Array of supported chain endpoint IDs
     */
    function registerToken(address token, uint32[] calldata supportedEids) external {
        if (msg.sender != Ownable(token).owner()) revert TokenNotDeployed();
        bridgeDeployedTokens[token] = true;
    }

    /**
     * @notice Configure OFT settings for a token on multiple chains
     * @param token Token address to configure
     * @param eids Array of endpoint IDs to configure
     * @param peerAddresses Array of peer addresses (as bytes32)
     */
    function configureOFT(address token, uint32[] calldata eids, bytes32[] calldata peerAddresses) external {
        if (eids.length != peerAddresses.length) revert InvalidTokenData();
        if (msg.sender != Ownable(token).owner()) revert TokenNotDeployed();
        
        for (uint256 i = 0; i < eids.length; i++) {
            HolographERC20(token).setPeer(eids[i], peerAddresses[i]);
        }
    }

    function getPeer(uint32 eid) external view returns (bytes32) {
        return peers[eid];
    }

    function getTokenPeer(address token, uint32 eid) external view returns (bytes32) {
        return bytes32(uint256(uint160(tokenDeployments[token][eid])));
    }

    function isTokenRegistered(address token) external view returns (bool) {
        return bridgeDeployedTokens[token];
    }

    function getTokenChains(address token) external view returns (uint32[] memory) {
        uint32[] memory chains = new uint32[](0);
        return chains;
    }

    /* -------------------------------------------------------------------------- */
    /*                               View Functions                              */
    /* -------------------------------------------------------------------------- */
    function getChainConfig(uint32 eid) external view returns (ChainConfig memory) {
        return supportedChains[eid];
    }

    function getTokenDeployment(address sourceToken, uint32 eid) external view returns (address) {
        return tokenDeployments[sourceToken][eid];
    }

    function isDeployedToChain(address sourceToken, uint32 eid) external view returns (bool) {
        return tokenDeployments[sourceToken][eid] != address(0);
    }

    /* -------------------------------------------------------------------------- */
    /*                               Admin Functions                            */
    /* -------------------------------------------------------------------------- */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Accept ETH for LayerZero message fees
     * @dev Allows contract to receive ETH payments for cross-chain messaging fees.
     * ETH sent to this contract is used exclusively for LayerZero transaction costs.
     * Access is unrestricted as this is a standard payment mechanism.
     */
    receive() external payable {}
}