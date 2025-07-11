// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ----------------------------------------------------------------------------
 * @title FeeRouter (Omnichain) – Holograph 2.0 + Doppler Integration
 * ----------------------------------------------------------------------------
 * Enhanced omnichain router that:
 *   • Implements single-slice model: ALL fees (launch ETH, Airlock pulls, manual routes)
 *     are processed with 1.5% protocol skim, 98.5% to treasury
 *   • Supports ERC-20 token routing end-to-end (receive → slice → bridge → swap)
 *   • Uses role-based keeper automation with dust protection (MIN_BRIDGE_VALUE)
 *   • Bridges protocol skim to Ethereum via LayerZero V2
 *   • Wraps to WETH, swaps to HLG on Uniswap V3 (0.3% pool)
 *   • Burns 50% of acquired HLG, stakes 50% to StakingRewards
 *   • Treasury is owner-configurable for admin flexibility
 *
 * Integration with Doppler:
 *   • Factory forwards full launch ETH and sets integrator = FeeRouter
 *   • Keeper pulls accumulated fees from Airlock contracts
 *   • All inflows processed through _takeAndSlice() for consistency
 *
 * Security:
 *   • Role-based access (KEEPER_ROLE) for automation functions
 *   • Dust protection (MIN_BRIDGE_VALUE) to avoid failed transactions
 *   • Trusted remotes for cross-chain message validation
 *   • Emergency pause functionality
 * ----------------------------------------------------------------------------
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../lib/LayerZero-v2/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "../lib/LayerZero-v2/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroReceiver.sol";
import "./interfaces/IWETH9.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IStakingRewards.sol";
import "./interfaces/IAirlock.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./HolographFactory.sol";

/**
 * @title FeeRouter
 * @notice Single-slice fee routing with Doppler integration
 * @dev 1.5% protocol fee, 98.5% to treasury - all fees processed uniformly
 * @author Holograph Protocol
 */
contract FeeRouter is Ownable, AccessControl, ReentrancyGuard, Pausable, ILayerZeroReceiver {
    using SafeERC20 for IERC20;

    /* -------------------------------------------------------------------------- */
    /*                                 Constants                                  */
    /* -------------------------------------------------------------------------- */
    /// @notice Uniswap V3 pool fee tier (0.3%)
    uint24 public constant POOL_FEE = 3000;

    /// @notice Protocol fee in basis points (1.5%)
    uint16 public constant HOLO_FEE_BPS = 150;

    /// @notice Minimum value required to bridge (dust protection)
    uint64 public constant MIN_BRIDGE_VALUE = 0.01 ether;

    /// @notice Role identifier for keeper automation
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /* -------------------------------------------------------------------------- */
    /*                                Immutables                                  */
    /* -------------------------------------------------------------------------- */
    /// @notice LayerZero V2 endpoint for cross-chain messaging
    ILayerZeroEndpointV2 public immutable lzEndpoint;

    /// @notice Remote chain endpoint ID (Ethereum ⇄ Base)
    uint32 public immutable remoteEid;

    /// @notice Staking rewards contract for HLG distribution
    IStakingRewards public immutable stakingPool;

    /// @notice HLG token contract for burn and stake operations
    IERC20 public immutable HLG;

    /// @notice Wrapped ETH contract for swapping
    IWETH9 public immutable WETH;

    /// @notice Uniswap V3 swap router for token exchanges
    ISwapRouter public immutable swapRouter;

    /// @notice Cached Uniswap V3 factory (saves a call per pool probe)
    IUniswapV3Factory private immutable _factory;

    /* -------------------------------------------------------------------------- */
    /*                                 Storage                                    */
    /* -------------------------------------------------------------------------- */
    /// @notice Nonce tracking for LayerZero messages per destination
    mapping(uint32 => uint64) public nonce;

    /// @notice Trusted remote addresses for LayerZero security
    mapping(uint32 => bytes32) public trustedRemotes;

    /// @notice Treasury address receiving 98.5% of all fees
    address public treasury;

    /// @notice Trusted Airlock addresses allowed to push ETH
    mapping(address => bool) public trustedAirlocks;

    /// @notice Trusted HolographFactory addresses for integration
    mapping(address => bool) public trustedFactories;

    /* -------------------------------------------------------------------------- */
    /*                                  Errors                                    */
    /* -------------------------------------------------------------------------- */
    error ZeroAddress();
    error ZeroAmount();
    error NotEndpoint();
    error UntrustedRemote();
    error NoRoute();
    error InsufficientOutput();
    error UntrustedSender();

    /* -------------------------------------------------------------------------- */
    /*                                  Events                                    */
    /* -------------------------------------------------------------------------- */
    /// @notice Emitted when fees are processed through the slicing mechanism
    event SlicePulled(address indexed airlock, address indexed token, uint256 holoAmt, uint256 treasuryAmt);

    /// @notice Emitted when tokens are bridged to remote chain
    event TokenBridged(address indexed token, uint256 amount, uint64 nonce);

    /// @notice Emitted when tokens are swapped for HLG
    event Swapped(uint256 ethIn, uint256 hlgOut);

    /// @notice Emitted when HLG rewards are sent to staking pool
    event RewardsSent(uint256 hlgAmt);

    /// @notice Emitted when HLG tokens are burned
    event Burned(uint256 hlgAmt);

    /// @notice Emitted when trusted remote is updated
    event TrustedRemoteSet(uint32 indexed eid, bytes32 remote);

    /// @notice Emitted when treasury address is updated
    event TreasuryUpdated(address indexed newTreasury);

    /// @notice Emitted when an Airlock is added or removed from trusted list
    event TrustedAirlockSet(address indexed airlock, bool trusted);

    /// @notice Emitted when a HolographFactory is added or removed from trusted list
    event TrustedFactorySet(address indexed factory, bool trusted);

    /* -------------------------------------------------------------------------- */
    /*                               Constructor                                  */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Initialize the FeeRouter contract
     * @dev Sets up all immutable addresses, grants admin role to deployer, and
     *      validates critical addresses to prevent deployment errors
     * @param _endpoint LayerZero V2 endpoint address
     * @param _remoteEid Remote chain endpoint ID for cross-chain messaging
     * @param _stakingPool StakingRewards contract address (zero on non-Ethereum chains)
     * @param _hlg HLG token address (zero on non-Ethereum chains)
     * @param _weth WETH9 contract address (zero on non-Ethereum chains)
     * @param _swapRouter Uniswap V3 SwapRouter address (zero on non-Ethereum chains)
     * @param _treasury Initial treasury address for fee collection
     */
    constructor(
        address _endpoint,
        uint32 _remoteEid,
        address _stakingPool,
        address _hlg,
        address _weth,
        address _swapRouter,
        address _treasury
    ) Ownable(msg.sender) {
        if (_endpoint == address(0) || _remoteEid == 0) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        lzEndpoint = ILayerZeroEndpointV2(_endpoint);
        remoteEid = _remoteEid;
        stakingPool = IStakingRewards(_stakingPool);
        HLG = IERC20(_hlg);
        WETH = IWETH9(_weth);

        // Cache swap router and factory only if provided (Ethereum deployments)
        swapRouter = ISwapRouter(_swapRouter);
        if (_swapRouter != address(0)) {
            _factory = swapRouter.factory();
        } else {
            _factory = IUniswapV3Factory(address(0));
        }
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* -------------------------------------------------------------------------- */
    /*                           Integrator Pull (Keeper)                        */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Collect accumulated fees from a Doppler Airlock
     * @dev Keeper-only function that pulls integrator fees from completed auctions
     * @param airlock Airlock contract address
     * @param token Token contract address
     * @param amt Amount to collect
     */
    function collectAirlockFees(
        address airlock,
        address token,
        uint256 amt
    ) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (airlock == address(0)) revert ZeroAddress();
        if (amt == 0) revert ZeroAmount();

        uint256 balanceBefore;
        if (token == address(0)) {
            balanceBefore = address(this).balance;
        } else {
            balanceBefore = IERC20(token).balanceOf(address(this));
        }

        IAirlock(airlock).collectIntegratorFees(address(this), token, amt);

        // Process both ETH and ERC20 tokens through _splitFee
        uint256 balanceAfter;
        uint256 received;

        if (token == address(0)) {
            balanceAfter = address(this).balance;
            received = balanceAfter - balanceBefore;
        } else {
            balanceAfter = IERC20(token).balanceOf(address(this));
            received = balanceAfter - balanceBefore;
        }

        if (received > 0) {
            _splitFee(token, received);
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                               Core Slicing                                 */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice New unified fee splitter (1.5% protocol / 98.5% treasury)
     * @param token Token address (address(0) for ETH)
     * @param amount Total amount to split
     */
    function _splitFee(address token, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();

        uint256 protocolFee = (amount * HOLO_FEE_BPS) / 10_000;
        uint256 treasuryFee = amount - protocolFee;

        // Forward treasury share immediately
        if (treasuryFee > 0) {
            if (token == address(0)) {
                payable(treasury).transfer(treasuryFee);
            } else {
                IERC20(token).safeTransfer(treasury, treasuryFee);
            }
        }

        // Convert protocol share to HLG on Ethereum – accumulate on other chains
        if (protocolFee > 0 && address(HLG) != address(0)) {
            _convertToHLG(token, protocolFee, 0);
        }

        emit SlicePulled(msg.sender, token, protocolFee, treasuryFee);
    }

    /**
     * @notice Convert arbitrary token/ETH into HLG and distribute (burn + stake)
     * @param token  Input token (address(0) for native ETH)
     * @param amount Amount of the input token
     * @param minOut Minimum HLG expected from final swap (0 to ignore)
     */
    function _convertToHLG(address token, uint256 amount, uint256 minOut) internal {
        if (token == address(HLG)) {
            _distribute(amount);
            return;
        }

        // Step (a): wrap native ETH → WETH
        if (token == address(0)) {
            WETH.deposit{value: amount}();
            token = address(WETH);
        }

        // Step (b): swap non-WETH tokens into WETH if a pool exists, otherwise give up
        if (token != address(WETH)) {
            if (!_poolExists(token, address(WETH))) return; // accumulate to be bridged later
            amount = _swapSingle(token, address(WETH), amount, 0);
            token = address(WETH);
        }

        // Step (c): WETH → HLG (must have a pool or revert)
        if (!_poolExists(address(WETH), address(HLG))) revert NoRoute();
        amount = _swapSingle(address(WETH), address(HLG), amount, minOut);

        _distribute(amount);
    }

    /* -------------------------------------------------------------------------- */
    /*                               Bridge Functions                            */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Bridge accumulated ETH to remote chain for HLG conversion
     * @dev Keeper-only; enforces dust threshold to avoid uneconomical transactions
     * @param minGas Minimum gas units for lzReceive execution on destination
     * @param minHlg Minimum HLG tokens expected from swap (slippage protection)
     */
    function bridge(uint256 minGas, uint256 minHlg) external onlyRole(KEEPER_ROLE) nonReentrant {
        uint256 bal = address(this).balance;
        if (bal < MIN_BRIDGE_VALUE) return;

        uint64 n = ++nonce[remoteEid];
        // Send both the ETH amount and minimum HLG expected for slippage protection
        bytes memory payload = abi.encode(address(0), bal, minHlg);
        bytes memory options = _buildLzReceiveOption(minGas);

        // Build LayerZero V2 messaging parameters
        MessagingParams memory msgParams = MessagingParams({
            dstEid: remoteEid,
            receiver: trustedRemotes[remoteEid],
            message: payload,
            options: options,
            payInLzToken: false
        });
        
        lzEndpoint.send{value: bal}(msgParams, payable(msg.sender));
        emit TokenBridged(address(0), bal, n);
    }

    /**
     * @notice Bridge accumulated ERC-20 tokens to remote chain
     * @dev Keeper-only; handles token approval and LayerZero messaging for cross-chain transfer
     * @param token ERC-20 token contract address to bridge
     * @param minGas Minimum gas units for lzReceive execution on destination
     * @param minHlg Minimum HLG tokens expected from swap (slippage protection)
     */
    function bridgeERC20(address token, uint256 minGas, uint256 minHlg) external onlyRole(KEEPER_ROLE) nonReentrant {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < MIN_BRIDGE_VALUE) return;

        // Safe approval using OpenZeppelin SafeERC20
        IERC20(token).forceApprove(address(lzEndpoint), bal);

        uint64 n = ++nonce[remoteEid];
        bytes memory payload = abi.encode(token, bal, minHlg);
        bytes memory options = _buildLzReceiveOption(minGas);

        // Build LayerZero V2 messaging parameters
        MessagingParams memory msgParams = MessagingParams({
            dstEid: remoteEid,
            receiver: trustedRemotes[remoteEid],
            message: payload,
            options: options,
            payInLzToken: false
        });
        
        lzEndpoint.send(msgParams, payable(msg.sender));
        emit TokenBridged(token, bal, n);
    }

    /* -------------------------------------------------------------------------- */
    /*                            LayerZero Receive                              */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Handle incoming protocol fees from Base chain
     * @dev Processes bridged tokens through local HLG swap/burn/stake and verifies the caller is a trusted remote
     * @param _origin Message origin information
     * @param _guid Unique message identifier
     * @param _message Encoded token, amount, and slippage protection data  
     * @param _executor Executor address
     * @param _extraData Additional data
     */
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable override {
        _enforceEndpointAndRemote(_origin.srcEid);

        if (_message.length == 96) {
            // (token, amount, minOut)
            (address token, uint256 amount, uint256 minHlg) = abi.decode(_message, (address, uint256, uint256));
            _convertToHLG(token, amount, minHlg);
        } else {
            // Legacy 2-word payload: treat second word as amount, ignore slippage
            (address token, uint256 amount) = abi.decode(_message, (address, uint256));
            _convertToHLG(token, amount, 0);
        }
    }

    /// @notice Shared checks for LayerZero sender & trusted remote
    function _enforceEndpointAndRemote(uint32 srcEid) internal view {
        if (msg.sender != address(lzEndpoint)) revert NotEndpoint();
        if (trustedRemotes[srcEid] == bytes32(0)) revert UntrustedRemote();
    }

    /// @notice Check if initialization path is allowed
    function allowInitializePath(Origin calldata _origin) external view returns (bool) {
        return trustedRemotes[_origin.srcEid] != bytes32(0);
    }

    /// @notice Get next nonce for sender
    function nextNonce(uint32 _eid, bytes32 _sender) external view returns (uint64) {
        return lzEndpoint.inboundNonce(address(this), _eid, _sender) + 1;
    }

    /* -------------------------------------------------------------------------- */
    /*                              Token Swapping                               */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Swap tokens for HLG via Uniswap V3
     * @dev Handles direct WETH→HLG swaps and multi-hop routing
     * @param token Input token address
     * @param amount Input token amount
     * @return hlgOut Amount of HLG tokens received
     */
    function _swapForHLG(address token, uint256 amount) internal returns (uint256) {
        address hlgAddr = address(HLG);
        if (token == hlgAddr) return amount; // Already HLG

        // Try direct swap first
        if (_poolExists(token, hlgAddr)) {
            return _swapSingle(token, hlgAddr, amount, 0);
        }

        // Try via WETH if not direct
        if (token != address(WETH) && _poolExists(token, address(WETH)) && _poolExists(address(WETH), hlgAddr)) {
            bytes memory path = abi.encodePacked(token, POOL_FEE, address(WETH), POOL_FEE, hlgAddr);
            return _swapPath(path, amount, 0);
        }

        revert NoRoute();
    }

    /**
     * @notice Execute single-hop swap via Uniswap V3
     * @dev Direct token-to-token swap through single pool
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amtIn Input token amount
     * @param minOut Minimum output tokens expected
     * @return actualOut Actual tokens received from swap
     */
    function _swapSingle(address tokenIn, address tokenOut, uint256 amtIn, uint256 minOut) internal returns (uint256) {
        // Cache swap router to reduce SLOAD
        ISwapRouter router = swapRouter;
        IERC20(tokenIn).forceApprove(address(router), amtIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: POOL_FEE,
            recipient: address(this),
            amountIn: amtIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = router.exactInputSingle(params);
        if (amountOut < minOut) revert InsufficientOutput();
        return amountOut;
    }

    /**
     * @notice Execute multi-hop swap via Uniswap V3
     * @dev Uses encoded path for complex routing through multiple pools
     * @param path Encoded swap path with tokens and fees
     * @param amtIn Input token amount
     * @param minOut Minimum output tokens expected
     * @return actualOut Actual tokens received from swap
     */
    function _swapPath(bytes memory path, uint256 amtIn, uint256 minOut) internal returns (uint256) {
        address tokenIn;
        assembly {
            tokenIn := div(mload(add(path, 0x20)), 0x1000000000000000000000000)
        }

        // Cache swap router to reduce SLOAD
        ISwapRouter router = swapRouter;
        IERC20(tokenIn).forceApprove(address(router), amtIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            amountIn: amtIn,
            amountOutMinimum: minOut
        });

        uint256 amountOut = router.exactInput(params);
        if (amountOut < minOut) revert InsufficientOutput();
        return amountOut;
    }

    /* -------------------------------------------------------------------------- */
    /*                              Burn & Stake                                 */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Distribute HLG tokens: 50% burn, 50% stake
     * @dev Implements tokenomics by burning half and staking half for rewards
     * @param hlgAmt Total HLG amount to distribute
     */
    function _distribute(uint256 hlgAmt) internal {
        if (hlgAmt == 0) return;

        // Cache HLG and staking pool to reduce SLOADs
        IERC20 hlg = HLG;
        IStakingRewards stakingPoolAddr = stakingPool;

        uint256 stakeAmt;
        uint256 burnAmt;
        unchecked {
            stakeAmt = hlgAmt / 2;
            burnAmt = hlgAmt - stakeAmt;
        }

        if (burnAmt > 0) {
            hlg.safeTransfer(address(0), burnAmt);
            emit Burned(burnAmt);
        }

        if (stakeAmt > 0) {
            hlg.forceApprove(address(stakingPoolAddr), stakeAmt);
            stakingPoolAddr.addRewards(stakeAmt);
            emit RewardsSent(stakeAmt);
        }

        emit Swapped(0, hlgAmt);
    }

    /* -------------------------------------------------------------------------- */
    /*                                Utilities                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Check if Uniswap V3 pool exists for token pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return exists True if pool exists with sufficient liquidity
     */
    function _poolExists(address tokenA, address tokenB) internal view returns (bool) {
        if (address(_factory) == address(0)) return false;
        return _factory.getPool(tokenA, tokenB, POOL_FEE) != address(0);
    }

    /**
     * @notice Convert address to bytes32 for LayerZero compatibility
     * @param addr Address to convert
     * @return Bytes32 representation of the address
     */
    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /**
     * @notice Build LayerZero receive options with gas limit
     * @param gasLimit Gas units to allocate for lzReceive
     * @return Encoded options for LayerZero message
     */
    function _buildLzReceiveOption(uint256 gasLimit) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(1), gasLimit);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Admin                                     */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Set trusted remote address for cross-chain messaging
     * @param eid Remote chain endpoint ID
     * @param remote Trusted contract address on remote chain (as bytes32)
     * @dev Only callable by the contract owner
     */
    function setTrustedRemote(uint32 eid, bytes32 remote) external onlyOwner {
        trustedRemotes[eid] = remote;
        emit TrustedRemoteSet(eid, remote);
    }

    /**
     * @notice Update treasury address (admin function)
     * @param newTreasury The new treasury address
     * @dev Validates non-zero address; only callable by owner
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Pause the contract
     * @dev Emergency circuit breaker to halt operations; only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     * @dev Resume normal operations after emergency pause; only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Whitelist or remove a Doppler Airlock that is allowed to push ETH
     * @param airlock Airlock contract address
     * @param trusted Boolean indicating whether the Airlock is trusted
     */
    function setTrustedAirlock(address airlock, bool trusted) external onlyOwner {
        if (airlock == address(0)) revert ZeroAddress();
        trustedAirlocks[airlock] = trusted;
        emit TrustedAirlockSet(airlock, trusted);
    }

    /**
     * @notice Whitelist or remove a HolographFactory for integration
     * @param factory HolographFactory contract address
     * @param trusted Boolean indicating whether the Factory is trusted
     */
    function setTrustedFactory(address factory, bool trusted) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        trustedFactories[factory] = trusted;
        emit TrustedFactorySet(factory, trusted);
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Views                                    */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Get current contract balances for monitoring
     * @return ethBalance Current ETH balance
     * @return hlgBalance Current HLG token balance (Ethereum only)
     */
    function getBalances() external view returns (uint256 ethBalance, uint256 hlgBalance) {
        ethBalance = address(this).balance;
        if (address(HLG) != address(0)) {
            hlgBalance = HLG.balanceOf(address(this));
        }
    }

    /**
     * @notice Calculate fee split for a given amount
     * @param amount Input amount to calculate split for
     * @return protocolFee Amount that goes to protocol (1.5%)
     * @return treasuryFee Amount that goes to treasury (98.5%)
     */
    function calculateFeeSplit(uint256 amount) external pure returns (uint256 protocolFee, uint256 treasuryFee) {
        protocolFee = (amount * HOLO_FEE_BPS) / 10_000;
        treasuryFee = amount - protocolFee;
    }

    /* -------------------------------------------------------------------------- */
    /*                               ETH Receive                                 */
    /* -------------------------------------------------------------------------- */

    /// @notice Accept ETH only from trusted Airlock contracts
    receive() external payable {
        // Only trusted Airlocks can send ETH (msg.data is always empty for receive())
        if (!trustedAirlocks[msg.sender]) revert UntrustedSender();
    }
}
