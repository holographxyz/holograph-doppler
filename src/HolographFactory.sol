// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITokenFactory} from "./interfaces/external/doppler/ITokenFactory.sol";
import {HolographERC20} from "./HolographERC20.sol";
import "./interfaces/ILZEndpointV2.sol";

/**
 * @title HolographFactory
 * @notice Custom token factory for deploying HolographERC20 omnichain tokens via Doppler Airlock
 * @dev Implements ITokenFactory interface to integrate with Doppler ecosystem
 * @author Holograph Protocol
 */
contract HolographFactory is ITokenFactory, Ownable, Pausable, ReentrancyGuard {
    /* -------------------------------------------------------------------------- */
    /*                                  Errors                                    */
    /* -------------------------------------------------------------------------- */
    error ZeroAddress();
    error UnauthorizedCaller();
    error InvalidTokenData();
    error SaltAlreadyUsed();

    /* -------------------------------------------------------------------------- */
    /*                                 Storage                                    */
    /* -------------------------------------------------------------------------- */
    /// @notice LayerZero V2 endpoint for cross-chain messaging
    ILZEndpointV2 public immutable lzEndpoint;

    /// @notice Authorized Doppler Airlock contracts allowed to call create()
    mapping(address => bool) public authorizedAirlocks;

    /// @notice Mapping to track deployed tokens
    mapping(address => bool) public deployedTokens;

    /// @notice Mapping to track used CREATE2 salts to prevent reuse attacks
    mapping(bytes32 => bool) public usedSalts;

    /* -------------------------------------------------------------------------- */
    /*                                  Events                                    */
    /* -------------------------------------------------------------------------- */
    /// @notice Emitted when a new HolographERC20 token is deployed
    event TokenDeployed(
        address indexed token,
        string name,
        string symbol,
        uint256 initialSupply,
        address indexed recipient,
        address indexed owner
    );

    /// @notice Emitted when an Airlock is authorized or deauthorized
    event AirlockAuthorizationSet(address indexed airlock, bool authorized);

    /* -------------------------------------------------------------------------- */
    /*                               Constructor                                  */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Initialize the HolographFactory with LayerZero endpoint
     * @param _lzEndpoint LayerZero V2 endpoint address for omnichain messaging
     */
    constructor(address _lzEndpoint) Ownable(msg.sender) {
        if (_lzEndpoint == address(0)) revert ZeroAddress();
        lzEndpoint = ILZEndpointV2(_lzEndpoint);
    }

    /* -------------------------------------------------------------------------- */
    /*                            ITokenFactory Implementation                   */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Deploy a new HolographERC20 token via CREATE2
     * @dev Called by authorized Doppler Airlock contracts during token creation
     * @param initialSupply Initial supply of tokens to mint
     * @param recipient Address to receive the initial token supply
     * @param owner Address that will own the deployed token contract
     * @param salt CREATE2 salt for deterministic address generation
     * @param tokenData Encoded token metadata (matches DERC20 format)
     * @return token Address of the newly deployed HolographERC20 token
     */
    function create(
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata tokenData
    ) external override whenNotPaused nonReentrant returns (address token) {
        // Verify caller is an authorized Airlock
        if (!authorizedAirlocks[msg.sender]) revert UnauthorizedCaller();
        
        // Prevent salt reuse attacks
        if (usedSalts[salt]) revert SaltAlreadyUsed();
        usedSalts[salt] = true;
        
        // Decode token metadata from tokenData (matches Doppler DERC20 format)
        (
            string memory name,
            string memory symbol,
            uint256 yearlyMintCap,
            uint256 vestingDuration,
            address[] memory recipients,
            uint256[] memory amounts,
            string memory tokenURI
        ) = _decodeTokenData(tokenData);
        
        // Deploy HolographERC20 with CREATE2 for deterministic address
        token = address(
            new HolographERC20{salt: salt}(
                name,
                symbol,
                initialSupply,
                recipient,
                owner,
                address(lzEndpoint),
                yearlyMintCap,
                vestingDuration,
                recipients,
                amounts,
                tokenURI
            )
        );

        // Track the deployed token
        deployedTokens[token] = true;

        emit TokenDeployed(token, name, symbol, initialSupply, recipient, owner);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Token Metadata Decoding                      */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Decode token metadata from tokenData bytes (matches Doppler DERC20 format)
     * @dev Expects tokenData format: (string, string, uint256, uint256, address[], uint256[], string)
     * @param tokenData Encoded token metadata
     * @return name Token name
     * @return symbol Token symbol  
     * @return yearlyMintCap Yearly mint cap
     * @return vestingDuration Vesting duration
     * @return recipients Vesting recipients
     * @return amounts Vesting amounts
     * @return tokenURI Token URI
     */
    function _decodeTokenData(bytes calldata tokenData) internal pure returns (
        string memory name,
        string memory symbol,
        uint256 yearlyMintCap,
        uint256 vestingDuration,
        address[] memory recipients,
        uint256[] memory amounts,
        string memory tokenURI
    ) {
        if (tokenData.length == 0) revert InvalidTokenData();
        
        (name, symbol, yearlyMintCap, vestingDuration, recipients, amounts, tokenURI) = 
            abi.decode(tokenData, (string, string, uint256, uint256, address[], uint256[], string));
    }

    /* -------------------------------------------------------------------------- */
    /*                                Admin Functions                            */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Authorize or deauthorize a Doppler Airlock contract
     * @param airlock Address of the Airlock contract
     * @param authorized Whether the Airlock is authorized to deploy tokens
     */
    function setAirlockAuthorization(address airlock, bool authorized) external onlyOwner {
        if (airlock == address(0)) revert ZeroAddress();
        authorizedAirlocks[airlock] = authorized;
        emit AirlockAuthorizationSet(airlock, authorized);
    }

    /**
     * @notice Emergency pause token deployments
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resume token deployments after pause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /* -------------------------------------------------------------------------- */
    /*                                View Functions                             */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Check if an address is a token deployed by this factory
     * @param token Address to check
     * @return True if the token was deployed by this factory
     */
    function isDeployedToken(address token) external view returns (bool) {
        return deployedTokens[token];
    }

    /**
     * @notice Check if an Airlock is authorized to deploy tokens
     * @param airlock Address to check
     * @return True if the Airlock is authorized
     */
    function isAuthorizedAirlock(address airlock) external view returns (bool) {
        return authorizedAirlocks[airlock];
    }

    /**
     * @notice Predict the address of a token deployment using CREATE2
     * @param salt CREATE2 salt
     * @param name Token name
     * @param symbol Token symbol
     * @param initialSupply Initial token supply
     * @param recipient Initial token recipient
     * @param owner Token owner
     * @param yearlyMintCap Yearly mint cap
     * @param vestingDuration Vesting duration
     * @param recipients Vesting recipients
     * @param amounts Vesting amounts
     * @param tokenURI Token URI
     * @return predicted Predicted token address
     */
    function predictTokenAddress(
        bytes32 salt,
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        address owner,
        uint256 yearlyMintCap,
        uint256 vestingDuration,
        address[] memory recipients,
        uint256[] memory amounts,
        string memory tokenURI
    ) external view returns (address predicted) {
        bytes memory bytecode = abi.encodePacked(
            type(HolographERC20).creationCode,
            abi.encode(
                name, 
                symbol, 
                initialSupply, 
                recipient, 
                owner, 
                address(lzEndpoint),
                yearlyMintCap,
                vestingDuration,
                recipients,
                amounts,
                tokenURI
            )
        );
        
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )
        );
        
        predicted = address(uint160(uint256(hash)));
    }
}