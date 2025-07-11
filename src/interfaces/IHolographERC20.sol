// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IHolographERC20
 * @notice Interface for HolographERC20 omnichain tokens
 * @dev Combines IOFT and IERC20 interfaces with additional Holograph-specific functions
 */
interface IHolographERC20 is IOFT, IERC20 {
    /* -------------------------------------------------------------------------- */
    /*                                  Events                                    */
    /* -------------------------------------------------------------------------- */
    /// @notice Emitted when tokens are minted to an address
    event TokensMinted(address indexed to, uint256 amount);

    /* -------------------------------------------------------------------------- */
    /*                              Token Functions                              */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Mint new tokens to a specified address
     * @param to Address to receive the minted tokens
     * @param amount Number of tokens to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Get the LayerZero endpoint address
     * @return The LayerZero endpoint address used for cross-chain messaging
     */
    function getEndpoint() external view returns (address);

    /* -------------------------------------------------------------------------- */
    /*                              ERC20 Metadata                              */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Get the token name
     * @return The token name
     */
    function name() external view returns (string memory);

    /**
     * @notice Get the token symbol
     * @return The token symbol
     */
    function symbol() external view returns (string memory);

    /* -------------------------------------------------------------------------- */
    /*                              DERC20 Features                             */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Get the yearly mint rate
     * @return The yearly mint rate
     */
    function yearlyMintRate() external view returns (uint256);

    /**
     * @notice Get the vesting duration
     * @return The vesting duration
     */
    function vestingDuration() external view returns (uint256);

    /**
     * @notice Get the token URI
     * @return The token URI
     */
    function tokenURI() external view returns (string memory);

    /* -------------------------------------------------------------------------- */
    /*                              LayerZero OFT                               */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Set a peer for cross-chain communication
     * @param eid Endpoint ID of the destination chain
     * @param peer Peer address on the destination chain (as bytes32)
     */
    function setPeer(uint32 eid, bytes32 peer) external;
}