// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice Configuration for supported destination chains
 * @param eid LayerZero endpoint ID
 * @param factory HolographFactory address on that chain
 * @param bridge HolographBridge address on that chain
 * @param active Whether chain is active for deployments
 * @param name Human readable chain name
 */
struct ChainConfig {
    uint32 eid;
    address factory;
    address bridge;
    bool active;
    string name;
}

/**
 * @notice Token deployment parameters extracted from existing tokens
 * @param name Token name
 * @param symbol Token symbol
 * @param totalSupply Total token supply
 * @param owner Token owner address
 * @param yearlyMintRate Maximum yearly mint rate
 * @param vestingDuration Duration for token vesting
 * @param tokenURI Token metadata URI
 */
struct TokenParams {
    string name;
    string symbol;
    uint256 totalSupply;
    address owner;
    uint256 yearlyMintRate;
    uint256 vestingDuration;
    string tokenURI;
}