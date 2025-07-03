// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockHLG
 * @notice Mock HLG token contract for testing
 */
contract MockHLG is ERC20 {
    uint256 private _burned;

    constructor() ERC20("Holograph Token", "HLG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
        _burned += amount;
    }

    function totalBurned() external view returns (uint256) {
        return _burned;
    }

    // Override transfer to track burns to address(0)
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == address(0)) {
            _burn(msg.sender, amount);
            _burned += amount;
            return true;
        }
        return super.transfer(to, amount);
    }

    // Override transferFrom to track burns to address(0)
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (to == address(0)) {
            address spender = _msgSender();
            uint256 currentAllowance = allowance(from, spender);
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            _approve(from, spender, currentAllowance - amount);
            _burn(from, amount);
            _burned += amount;
            return true;
        }
        return super.transferFrom(from, to, amount);
    }
}
