// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreateParams} from "./interfaces/DopplerStructs.sol";
import "./interfaces/IAirlock.sol";
import "./interfaces/IFeeRouter.sol";
import "./interfaces/ILZEndpointV2.sol";
import "./interfaces/ILZReceiverV2.sol";
import "./interfaces/IMintableERC20.sol";

/**
 * @title HolographFactory
 * @notice Token launch factory with Doppler integration
 * @dev Entry point for creating omnichain tokens via Doppler Airlock
 * @author Holograph Protocol
 */
contract HolographFactory is Ownable, Pausable, ReentrancyGuard, ILZReceiverV2 {
    using SafeERC20 for IERC20;

    /* -------------------------------------------------------------------------- */
    /*                                  Errors                                    */
    /* -------------------------------------------------------------------------- */
    error ZeroAddress();
    error ZeroAmount();
    error NotEndpoint();

    /* -------------------------------------------------------------------------- */
    /*                                 Storage                                    */
    /* -------------------------------------------------------------------------- */
    /// @notice LayerZero V2 endpoint for cross-chain messaging
    ILZEndpointV2 public immutable lzEndpoint;

    /// @notice Doppler Airlock contract for token creation
    IAirlock public immutable dopplerAirlock;

    /// @notice FeeRouter contract for fee processing
    IFeeRouter public immutable feeRouter;

    /// @notice Nonce tracking for cross-chain message ordering
    mapping(uint32 => uint64) public nonce;

    /* -------------------------------------------------------------------------- */
    /*                                  Events                                    */
    /* -------------------------------------------------------------------------- */
    /// @notice Emitted when a new token is successfully launched
    event TokenLaunched(address indexed asset, bytes32 salt);

    /// @notice Emitted when tokens are bridged to destination chain
    event CrossChainMint(uint32 indexed dstEid, address token, address to, uint256 amount, uint64 nonce);

    /* -------------------------------------------------------------------------- */
    /*                               Constructor                                  */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Initialize the HolographFactory with required contract addresses
     * @dev Validates all provided addresses to ensure the factory is deployed with valid dependencies
     * @param _endpoint LayerZero V2 endpoint for cross-chain messaging
     * @param _airlock Doppler Airlock contract for token creation
     * @param _feeRouter FeeRouter contract for fee processing and distribution
     */
    constructor(address _endpoint, address _airlock, address _feeRouter) Ownable(msg.sender) {
        if (_endpoint == address(0) || _airlock == address(0) || _feeRouter == address(0)) revert ZeroAddress();
        lzEndpoint = ILZEndpointV2(_endpoint);
        dopplerAirlock = IAirlock(_airlock);
        feeRouter = IFeeRouter(_feeRouter);
    }

    /* -------------------------------------------------------------------------- */
    /*                               Token Launch                                 */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Launch a new omnichain token via Doppler Airlock
     * @dev Aligns with Doppler's free token creation model – no launch fees required; guarded by nonReentrant and whenNotPaused modifiers
     * @param params Doppler CreateParams containing token configuration
     * @return asset Address of the newly created token
     */
    function createToken(CreateParams calldata params) external nonReentrant whenNotPaused returns (address asset) {
        // Set FeeRouter as integrator for Doppler trading fee collection
        CreateParams memory modifiedParams = params;
        modifiedParams.integrator = address(feeRouter);

        (asset, , , , ) = dopplerAirlock.create(modifiedParams);
        emit TokenLaunched(asset, params.salt);
    }

    /* -------------------------------------------------------------------------- */
    /*                             Cross-Chain Bridge                             */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Bridge tokens to destination chain and mint to recipient
     * @dev Sends LayerZero message with mint instruction to destination factory; nonReentrant to block re-entrancy attacks
     * @param dstEid Destination chain endpoint ID
     * @param token Token contract address to mint on destination
     * @param recipient Address to receive minted tokens on destination
     * @param amount Amount of tokens to mint on destination
     * @param options LayerZero execution options (gas limits, etc.)
     */
    function bridgeToken(
        uint32 dstEid,
        address token,
        address recipient,
        uint256 amount,
        bytes calldata options
    ) external payable nonReentrant {
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint64 n = ++nonce[dstEid];
        bytes memory payload = abi.encodeWithSelector(
            bytes4(keccak256("mintERC20(address,uint256,address)")),
            token,
            recipient,
            amount
        );
        lzEndpoint.send{value: msg.value}(dstEid, payload, options);
        emit CrossChainMint(dstEid, token, recipient, amount, n);
    }

    /* -------------------------------------------------------------------------- */
    /*                            LayerZero Receive                              */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Handle incoming LayerZero messages for token minting
     * @dev Decodes message and mints tokens to specified recipient; rejects calls from any address other than the configured LayerZero endpoint
     * @param msg_ Encoded message containing mint instruction and parameters
     */
    function lzReceive(uint32, bytes calldata msg_, address, bytes calldata) external payable override {
        if (msg.sender != address(lzEndpoint)) revert NotEndpoint();
        (bytes4 sel, address token, address to, uint256 amt) = abi.decode(msg_, (bytes4, address, address, uint256));
        if (sel == bytes4(keccak256("mintERC20(address,uint256,address)"))) {
            IMintableERC20(token).mint(to, amt);
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Admin                                     */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Emergency circuit breaker to halt token launches and bridging; only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resumes normal operations after emergency pause; only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
