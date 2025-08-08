// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Mock token with fee-on-transfer behavior
 * @dev Used to test FeeOnTransferNotSupported() error in StakingRewards
 */
contract MockFeeOnTransfer is IERC20 {
    string public name = "FeeOnTransfer";
    string public symbol = "FEE";
    uint8 public decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor() {
        totalSupply = 1e30;
        balanceOf[msg.sender] = totalSupply;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        unchecked {
            balanceOf[msg.sender] -= amount;
        }
        // Fee: recipient gets amount - 1
        uint256 received = amount > 0 ? amount - 1 : 0;
        balanceOf[to] += received;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        unchecked {
            balanceOf[from] -= amount;
        }
        // Fee: recipient gets amount - 1
        uint256 received = amount > 0 ? amount - 1 : 0;
        balanceOf[to] += received;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}
