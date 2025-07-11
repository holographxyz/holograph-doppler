// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IHolographBridge
 * @notice Interface for HolographBridge cross-chain coordination contract
 * @dev Manages LayerZero OFT peer relationships and cross-chain configuration
 */
interface IHolographBridge {
    /* -------------------------------------------------------------------------- */
    /*                                  Events                                    */
    /* -------------------------------------------------------------------------- */
    /// @notice Emitted when a peer bridge is set for a chain
    event PeerSet(uint32 indexed eid, bytes32 peer);

    /// @notice Emitted when trusted remote is configured for a token
    event TrustedRemoteSet(address indexed token, uint32 indexed eid, bytes32 remote);

    /// @notice Emitted when OFT configuration is applied to a token
    event OFTConfigured(address indexed token, uint32 indexed eid);

    /// @notice Emitted when a token is registered for cross-chain coordination
    event TokenRegistered(address indexed token, uint32[] eids);

    /* -------------------------------------------------------------------------- */
    /*                              Core Functions                               */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Set peer bridge address for a destination chain
     * @param eid Destination chain endpoint ID
     * @param peer Peer bridge address on destination chain (as bytes32)
     */
    function setPeer(uint32 eid, bytes32 peer) external;

    /**
     * @notice Configure LayerZero OFT peer for a token on destination chain
     * @param token Token address to configure
     * @param dstEid Destination chain endpoint ID
     * @param peer Peer token address on destination chain (as bytes32)
     */
    function setTokenPeer(address token, uint32 dstEid, bytes32 peer) external;

    /**
     * @notice Register a token for cross-chain coordination
     * @param token Token address to register
     * @param supportedEids Array of supported chain endpoint IDs
     */
    function registerToken(address token, uint32[] calldata supportedEids) external;

    /**
     * @notice Configure OFT settings for a token on multiple chains
     * @param token Token address to configure
     * @param eids Array of endpoint IDs to configure
     * @param peers Array of peer addresses (as bytes32)
     */
    function configureOFT(address token, uint32[] calldata eids, bytes32[] calldata peers) external;

    /* -------------------------------------------------------------------------- */
    /*                               View Functions                              */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Get peer bridge address for a chain
     * @param eid Chain endpoint ID
     * @return Peer bridge address
     */
    function getPeer(uint32 eid) external view returns (bytes32);

    /**
     * @notice Get peer token address for a token on destination chain
     * @param token Token address
     * @param eid Destination chain endpoint ID
     * @return Peer token address
     */
    function getTokenPeer(address token, uint32 eid) external view returns (bytes32);

    /**
     * @notice Check if a token is registered for cross-chain coordination
     * @param token Token address to check
     * @return True if token is registered
     */
    function isTokenRegistered(address token) external view returns (bool);

    /**
     * @notice Get supported chains for a token
     * @param token Token address
     * @return Array of supported endpoint IDs
     */
    function getTokenChains(address token) external view returns (uint32[] memory);
}