// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Minimal Hooks library for flag calculations
 * @dev Extracted from Uniswap V4 for mining purposes only
 */
library Hooks {
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;
    uint160 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 internal constant AFTER_DONATE_FLAG = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0;
}

/**
 * @notice Stub contracts for type creation in mining calculations
 */
contract DERC20Stub {
    constructor(
        string memory,  // name
        string memory,  // symbol
        uint256,        // initialSupply
        address,        // recipient
        address,        // owner
        uint256,        // yearlyMintCap
        uint256,        // vestingDuration
        address[] memory,  // recipients
        uint256[] memory,  // amounts
        string memory   // tokenURI
    ) {}
}

contract DopplerStub {
    constructor(
        address,  // poolManager
        uint256,  // numTokensToSell
        uint256,  // minimumProceeds
        uint256,  // maximumProceeds
        uint256,  // startingTime
        uint256,  // endingTime
        int24,    // startingTick
        int24,    // endingTick
        uint256,  // epochLength
        int24,    // gamma
        bool,     // isToken0
        uint256,  // numPDSlugs
        address,  // poolInitializer
        uint24    // lpFee
    ) {}
}
