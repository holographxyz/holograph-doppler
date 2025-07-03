// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../src/interfaces/ISwapRouter.sol";
import "../../src/interfaces/IUniswapV3Factory.sol";

/**
 * @title MockSwapRouter
 * @notice Mock Uniswap V3 SwapRouter for testing
 */
contract MockSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    address private _outputToken;
    uint256 private _exchangeRate = 1000; // 1 ETH = 1000 tokens

    MockFactory public immutable mockFactory;

    constructor() {
        mockFactory = new MockFactory();
    }

    function setOutputToken(address token) external {
        _outputToken = token;
    }

    function setExchangeRate(uint256 rate) external {
        _exchangeRate = rate;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable override returns (uint256 amountOut) {
        // Transfer input token from caller
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        // Calculate output amount based on exchange rate
        amountOut = (params.amountIn * _exchangeRate) / 1e18;

        // Ensure minimum output
        require(amountOut >= params.amountOutMinimum, "Insufficient output amount");

        // Transfer output token to recipient
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        return amountOut;
    }

    function exactInput(ExactInputParams calldata params) external payable override returns (uint256 amountOut) {
        // For simplicity, assume first token in path is input and last is output
        address tokenIn = _extractTokenFromPath(params.path, 0);
        address tokenOut = _outputToken;

        // Transfer input token from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        // Calculate output amount based on exchange rate
        amountOut = (params.amountIn * _exchangeRate) / 1e18;

        // Ensure minimum output
        require(amountOut >= params.amountOutMinimum, "Insufficient output amount");

        // Transfer output token to recipient
        IERC20(tokenOut).safeTransfer(params.recipient, amountOut);

        return amountOut;
    }

    function factory() external view override returns (IUniswapV3Factory) {
        return IUniswapV3Factory(address(mockFactory));
    }

    function _extractTokenFromPath(bytes memory path, uint256 position) internal pure returns (address token) {
        assembly {
            token := div(mload(add(add(path, 0x20), mul(position, 0x20))), 0x1000000000000000000000000)
        }
    }
}

/**
 * @title MockFactory
 * @notice Mock Uniswap V3 Factory for testing
 */
contract MockFactory is IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external pure override returns (address pool) {
        // Return a non-zero address to indicate pool exists for any pair
        return address(0x1234567890123456789012345678901234567890);
    }
}
