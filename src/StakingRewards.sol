// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ----------------------------------------------------------------------------
 * @title StakingRewards – Holograph 2.0
 * ----------------------------------------------------------------------------
 * @notice   Single–token staking contract for **HLG** that distributes rewards
 *           deposited by the FeeRouter.  Users may stake / withdraw at any
 *           time, subject to an optional cooldown period, and claim their
 *           accrued rewards.  Reward distribution follows a standard
 *           *reward‑per‑token* model for O(1) gas‑efficiency.
 *
 * Mechanics
 * ---------
 * • **Stake**   – User deposits HLG → increases their stake + updates rewards.
 * • **Withdraw**– User removes a portion/all of their stake; guarded by an
 *                 optional cooldown (default 7 days).
 * • **Claim**   – User collects their accumulated HLG rewards.
 * • **addRewards** – Called by FeeRouter when fresh HLG fees arrive; reward
 *                     is distributed pro-rata to all stakers instantly.
 * • **Owner**   – May pause/unpause, change cooldown length, set a new
 *                 FeeRouter, or recover non‑HLG tokens.
 *
 * Safety
 * ------
 * • Custom errors used over string reverts.
 * • OpenZeppelin Ownable, Pausable, ReentrancyGuard.
 * • Funds stored are ERC‑20 only; no ETH held.
 * ----------------------------------------------------------------------------
 */

import "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/access/Ownable.sol";
import "@openzeppelin/utils/ReentrancyGuard.sol";
import "@openzeppelin/utils/Pausable.sol";

contract StakingRewards is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────────
    //  Custom Errors
    // ──────────────────────────────────────────────────────────────────────────
    error ZeroAmount(); // parameter is zero
    error CooldownActive(uint256 remaining); // stake still cooling down
    error FeeRouterOnly(); // caller ≠ feeRouter
    error ZeroAddress(); // address(0)
    error ExceedsBalance(); // withdraw > staked
    error RecoverHLG(); // attempted to recover the stake token

    // ──────────────────────────────────────────────────────────────────────────
    //  Immutable & Storage
    // ──────────────────────────────────────────────────────────────────────────
    /// @notice The HLG ERC‑20 token that users stake and that rewards are paid in.
    IERC20 public immutable HLG;

    /// @notice Address of the FeeRouter that is authorised to call
    ///         {addRewards}.
    address public feeRouter;

    /// @notice Cooldown (in seconds) required between last stake and withdraw.
    uint256 public cooldownPeriod = 7 days; // 0 ⇒ disabled

    /// @notice Total HLG currently staked in the contract.
    uint256 public totalStaked;

    /// @dev User → HLG staked balance.
    mapping(address => uint256) public balanceOf;

    // ---------- reward‑per‑token accounting ----------
    uint256 public rewardPerTokenStored; // scaled by 1e18
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards; // accrued, unclaimed
    // --------------------------------------------------

    /// @dev Timestamp of the last stake for cooldown checks.
    mapping(address => uint256) public lastStakeTimestamp;

    // ──────────────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────────────
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardAdded(uint256 amount);
    event CooldownUpdated(uint256 seconds_);
    event FeeRouterUpdated(address feeRouter);

    // ──────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────────────
    /**
     * @param _hlg        Address of the immutable HLG token.
     * @param _feeRouter  Initial FeeRouter address authorised to call
     *                    {addRewards}.
     */
    constructor(address _hlg, address _feeRouter) Ownable(msg.sender) {
        if (_hlg == address(0) || _feeRouter == address(0)) revert ZeroAddress();
        HLG = IERC20(_hlg);
        feeRouter = _feeRouter;
        _pause(); // begin paused until governance enables
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Modifier – updates user reward accounting
    // ──────────────────────────────────────────────────────────────────────────
    modifier updateReward(address account) {
        // credit pending rewards before mutating balances
        if (account != address(0)) {
            rewards[account] += _earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  User Functions
    // ──────────────────────────────────────────────────────────────────────────
    /**
     * @notice Stake `amount` HLG.
     * @param amount Quantity to stake.
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        lastStakeTimestamp[msg.sender] = block.timestamp;
        HLG.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Withdraw `amount` HLG after cooldown.
     * @param amount Quantity to withdraw.
     */
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = balanceOf[msg.sender];
        if (staked < amount) revert ExceedsBalance();

        // cooldown enforcement (if enabled)
        if (cooldownPeriod != 0) {
            uint256 unlockTime = lastStakeTimestamp[msg.sender] + cooldownPeriod;
            if (block.timestamp < unlockTime) revert CooldownActive(unlockTime - block.timestamp);
        }

        totalStaked -= amount;
        balanceOf[msg.sender] = staked - amount;
        HLG.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Claim any accumulated HLG rewards.
     */
    function claim() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            HLG.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @notice Convenience: withdraw **all** stake and claim rewards in one tx.
     */
    function exit() external {
        withdraw(balanceOf[msg.sender]);
        claim();
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  FeeRouter Interaction
    // ──────────────────────────────────────────────────────────────────────────
    /**
     * @notice Called by the FeeRouter when HLG protocol fees are sent here.
     * @dev    Distributes the reward immediately by updating
     *         `rewardPerTokenStored`.
     * @param  amount Amount of HLG transferred from the FeeRouter.
     */
    function addRewards(uint256 amount) external nonReentrant updateReward(address(0)) {
        if (msg.sender != feeRouter) revert FeeRouterOnly();
        if (amount == 0) revert ZeroAmount();
        HLG.safeTransferFrom(msg.sender, address(this), amount);

        if (totalStaked > 0) {
            rewardPerTokenStored += (amount * 1e18) / totalStaked;
        }
        emit RewardAdded(amount);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  View Helpers
    // ──────────────────────────────────────────────────────────────────────────
    /** @return pending HLG reward for `account` (includes stored rewards). */
    function earned(address account) external view returns (uint256) {
        return _earned(account) + rewards[account];
    }

    /** @dev Internal view function. */
    function _earned(address account) internal view returns (uint256) {
        return (balanceOf[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account])) / 1e18;
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Governance / Owner Functions
    // ──────────────────────────────────────────────────────────────────────────
    /**
     * @notice Update the cooldown length (set to 0 to disable).
     */
    function setCooldown(uint256 seconds_) external onlyOwner {
        cooldownPeriod = seconds_;
        emit CooldownUpdated(seconds_);
    }

    /**
     * @notice Change the authorised FeeRouter.
     */
    function setFeeRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        feeRouter = _router;
        emit FeeRouterUpdated(_router);
    }

    /** Pause / unpause staking & withdrawing (claim still allowed). */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Recover tokens sent here by mistake (anything except the stake
     *         token itself).
     */
    function recoverToken(address token, uint256 amount) external onlyOwner {
        if (token == address(HLG)) revert RecoverHLG();
        IERC20(token).safeTransfer(owner(), amount);
    }
}
