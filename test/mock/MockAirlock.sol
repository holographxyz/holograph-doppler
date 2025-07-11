// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../src/interfaces/IAirlock.sol";
import {CreateParams} from "../../src/interfaces/DopplerStructs.sol";

/**
 * @title MockAirlock
 * @notice Mock implementation of Doppler Airlock for testing
 * @dev Simulates fee collection and transfer behavior
 */
contract MockAirlock is IAirlock {
    using SafeERC20 for IERC20;

    /// @notice Mapping to track collectable amounts per token
    mapping(address => uint256) private _collectableAmounts;

    /// @notice Mapping for token balances per integrator
    mapping(address => mapping(address => uint256)) private _tokenAmounts;

    event IntegratorFeesCollected(address indexed to, address indexed token, uint256 amount);

    /**
     * @notice Mock implementation of create function
     * @dev Returns zero addresses for testing purposes
     */
    function create(
        CreateParams calldata params
    )
        external
        override
        returns (address asset, address pool, address governance, address timelock, address migrationPool)
    {
        // Mock implementation - returns zero addresses
        return (address(0), address(0), address(0), address(0), address(0));
    }

    /**
     * @notice Collect integrator fees and transfer to recipient
     * @dev Transfers tokens/ETH to integrator, matching IAirlock interface
     * @param to Address to receive the fees (FeeRouter)
     * @param token Token address (address(0) for ETH)
     * @param amount Amount to collect and transfer
     */
    function collectIntegratorFees(address to, address token, uint256 amount) external override {
        require(_collectableAmounts[token] >= amount, "MockAirlock: Insufficient collectable amount");

        _collectableAmounts[token] -= amount;

        if (token == address(0)) {
            // ETH case - call FeeRouter.receiveFee{value:amount}()
            require(address(this).balance >= amount, "MockAirlock: Insufficient ETH");

            // Direct transfer; FeeRouter has a receive() fallback that accepts ETH
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "MockAirlock: ETH transfer failed");
        } else {
            // ERC-20 case
            require(IERC20(token).balanceOf(address(this)) >= amount, "MockAirlock: Insufficient token balance");
            IERC20(token).transfer(to, amount);
        }

        emit IntegratorFeesCollected(to, token, amount);
    }

    /**
     * @notice Set collectable amount for testing
     */
    function setCollectableAmount(address token, uint256 amount) external {
        _collectableAmounts[token] = amount;
    }

    /**
     * @notice Set token balance for a specific integrator (for testing)
     */
    function setTokenBalance(address token, address integrator, uint256 amount) external {
        _tokenAmounts[token][integrator] = amount;
    }

    /**
     * @notice Get collectable amount
     */
    function getCollectableAmount(address token) external view returns (uint256) {
        return _collectableAmounts[token];
    }

    /**
     * @notice Get token balance for integrator
     */
    function getTokenBalance(address token, address integrator) external view returns (uint256) {
        return _tokenAmounts[token][integrator];
    }

    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {}

    /**
     * @notice Create token through factory for testing
     * @dev Simulates Doppler Airlock calling the HolographFactory
     */
    function createTokenThroughFactory(
        address factory,
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata tokenData
    ) external returns (address token) {
        // Call the factory's create function
        return ITokenFactory(factory).create(initialSupply, recipient, owner, salt, tokenData);
    }
    /**
     * @notice Fund contract with tokens for testing
     */
    function fundWithToken(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
}

interface ITokenFactory {
    function create(
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata tokenData
    ) external returns (address token);
}
