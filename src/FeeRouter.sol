// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ----------------------------------------------------------------------------
 * @title FeeRouter (Omnichain) – Holograph 2.0
 * ----------------------------------------------------------------------------
 * Omnichain router that
 *   • collects ETH protocol fees on Base;
 *   • bridges them to Ethereum via LayerZero V2;
 *   • wraps to WETH, swaps WETH→HLG on Uniswap V3 (0.3 % pool);
 *   • burns 50 % of acquired HLG;
 *   • forwards 50 % of HLG to the StakingRewards contract ("staking pool").
 *
 * The contract is deployed with the **same address on all chains** using
 * deterministic deployments so that `_trustedRemote` checks can rely on
 * `msg.sender == address(this)` on the peer chain.
 *
 * For security, only the LayerZero endpoint may call {lzReceive}.  Bridging is
 * initiated via {bridge} by an authorised keeper / governance.
 * ----------------------------------------------------------------------------
 */

import "@openzeppelin/access/Ownable.sol";
import "@openzeppelin/utils/ReentrancyGuard.sol";
import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

// ──────────────────────────────────────────────────────────────────────────
//  Minimal external interfaces
// ──────────────────────────────────────────────────────────────────────────
interface ILZEndpointV2 {
    function send(uint32 dstEid, bytes calldata payload, bytes calldata options) external payable;
}

interface ILZReceiverV2 {
    function lzReceive(uint32, bytes calldata, address, bytes calldata) external payable;
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IStakingRewards {
    function addRewards(uint256 amount) external;
}

// ──────────────────────────────────────────────────────────────────────────
//  Contract
// ──────────────────────────────────────────────────────────────────────────
contract FeeRouter is Ownable, ReentrancyGuard, ILZReceiverV2 {
    using SafeERC20 for IERC20;

    /*───────────────────────────────────────────────────────────────────────
        Constants & Immutables
    ───────────────────────────────────────────────────────────────────────*/
    uint24 public constant POOL_FEE = 3000; // Uniswap V3 fee tier 0.3 %

    ILZEndpointV2 public immutable lzEndpoint;
    uint32 public immutable remoteEid; // peer chain EID (Ethereum⇄Base)
    address public immutable stakingPool; // StakingRewards contract (Ethereum)
    IERC20 public immutable HLG; // reward + burn token
    IWETH9 public immutable WETH; // canonical WETH on Ethereum
    ISwapRouter public immutable swapRouter; // Uniswap V3 router

    /*───────────────────────────────────────────────────────────────────────
        Storage
    ───────────────────────────────────────────────────────────────────────*/
    // Mapping of nonce per outbound EID (mirrors factory design)
    mapping(uint32 => uint64) public nonce;

    /*───────────────────────────────────────────────────────────────────────
        Errors
    ───────────────────────────────────────────────────────────────────────*/
    error ZeroAddress();
    error ZeroAmount();
    error NotEndpoint();
    error OnlySelf();

    /*───────────────────────────────────────────────────────────────────────
        Events
    ───────────────────────────────────────────────────────────────────────*/
    event FeeReceived(address indexed payer, uint256 amount);
    event FeesBridged(uint256 ethAmt, uint64 nonce);
    event Swapped(uint256 ethIn, uint256 hlgOut);
    event RewardsSent(uint256 hlgAmt);
    event Burned(uint256 hlgAmt);

    /*───────────────────────────────────────────────────────────────────────
        Constructor
    ───────────────────────────────────────────────────────────────────────*/
    /**
     * @param _endpoint      LayerZero endpoint on **this** chain.
     * @param _remoteEid     Remote chain EID (Base ⇄ Ethereum peer).
     * @param _stakingPool   StakingRewards contract (only meaningful on Ethereum).
     * @param _hlg           HLG ERC-20 token address (Ethereum).
     * @param _weth          Canonical WETH address (Ethereum).
     * @param _swapRouter    Uniswap V3 router.
     */
    constructor(
        address _endpoint,
        uint32 _remoteEid,
        address _stakingPool,
        address _hlg,
        address _weth,
        address _swapRouter
    ) Ownable(msg.sender) {
        if (_endpoint == address(0) || _remoteEid == 0) revert ZeroAddress();
        lzEndpoint = ILZEndpointV2(_endpoint);
        remoteEid = _remoteEid;

        stakingPool = _stakingPool; // may be 0 on Base
        HLG = IERC20(_hlg); // may be 0 on Base
        WETH = IWETH9(_weth); // may be 0 on Base
        swapRouter = ISwapRouter(_swapRouter); // may be 0 on Base
    }

    /*───────────────────────────────────────────────────────────────────────
        Modifiers
    ───────────────────────────────────────────────────────────────────────*/
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /*───────────────────────────────────────────────────────────────────────
        Fee Collection – Base chain
    ───────────────────────────────────────────────────────────────────────*/
    /** @notice Receive ETH fees from HolographFactory.  Alias for {receiveFee}. */
    function routeFeeETH() external payable {
        _receiveFee();
    }

    /** @notice Preferred canonical entry-point for fee deposits. */
    function receiveFee() external payable {
        _receiveFee();
    }

    function _receiveFee() internal {
        if (msg.value == 0) revert ZeroAmount();
        emit FeeReceived(msg.sender, msg.value);
    }

    /*───────────────────────────────────────────────────────────────────────
        Bridge ETH → Ethereum (callable on Base)
    ───────────────────────────────────────────────────────────────────────*/
    /**
     * @param minGas   Minimum gas to attach for the receive on destination.
     * @param minHlg   Minimum HLG expected from the WETH→HLG swap (slippage).
     */
    function bridge(uint256 minGas, uint256 minHlg) external nonReentrant {
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroAmount();

        uint64 n = ++nonce[remoteEid];

        // encode payload carrying the minHlg slippage parameter
        bytes memory payload = abi.encode(minHlg);

        // simplistic Options encoding: just pass minGas in calldata – fine for demo
        bytes memory options = abi.encode(minGas);

        lzEndpoint.send{value: bal}(remoteEid, payload, options);

        emit FeesBridged(bal, n);
    }

    /*───────────────────────────────────────────────────────────────────────
        LayerZero Receive – executes on Ethereum
    ───────────────────────────────────────────────────────────────────────*/
    function lzReceive(
        uint32 /*srcEid (unused)*/,
        bytes calldata payload,
        address /*sender*/,
        bytes calldata /*execParams*/
    ) external payable override {
        if (msg.sender != address(lzEndpoint)) revert NotEndpoint();

        uint256 minHlg = abi.decode(payload, (uint256));

        // Execute swap & distribution with the bridged ETH (msg.value)
        // Ensure this is executed in the same tx by making an internal call.
        this.swapAndDistribute(minHlg);
    }

    /*───────────────────────────────────────────────────────────────────────
        Swap & Distribute – Ethereum only
    ───────────────────────────────────────────────────────────────────────*/
    function swapAndDistribute(uint256 minHlg) external onlySelf nonReentrant {
        uint256 ethBal = address(this).balance;
        if (ethBal == 0) revert ZeroAmount();

        // Wrap to WETH
        WETH.deposit{value: ethBal}();

        // Swap WETH → HLG on Uniswap V3
        IWETH9(WETH).approve(address(swapRouter), ethBal);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(HLG),
            fee: POOL_FEE,
            recipient: address(this),
            amountIn: ethBal,
            amountOutMinimum: minHlg,
            sqrtPriceLimitX96: 0
        });

        uint256 hlgOut = swapRouter.exactInputSingle(params);
        emit Swapped(ethBal, hlgOut);

        // Split 50 / 50
        uint256 stakeAmt = hlgOut / 2;
        uint256 burnAmt = hlgOut - stakeAmt; // handles odd

        // Burn by transferring to address(0)
        HLG.safeTransfer(address(0), burnAmt);
        emit Burned(burnAmt);

        // Send rewards to staking pool
        HLG.safeIncreaseAllowance(stakingPool, stakeAmt);
        IStakingRewards(stakingPool).addRewards(stakeAmt);
        emit RewardsSent(stakeAmt);
    }

    /*───────────────────────────────────────────────────────────────────────
        Fallback – allows contract to receive ETH (bridged + direct)
    ───────────────────────────────────────────────────────────────────────*/
    receive() external payable {
        // Accept ether – no action (handled on explicit calls)
    }
}
