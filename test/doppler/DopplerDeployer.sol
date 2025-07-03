// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Simplified DopplerDeployer interface for mining calculations
 * @dev This is used only for mining salt calculations, not actual deployment
 */
interface IDopplerDeployer {
    function deployer() external view returns (address);
}

/**
 * @notice Mock DopplerDeployer for testing
 */
contract MockDopplerDeployer is IDopplerDeployer {
    address private _deployer;
    
    constructor(address deployer_) {
        _deployer = deployer_;
    }
    
    function deployer() external view returns (address) {
        return _deployer;
    }
}
