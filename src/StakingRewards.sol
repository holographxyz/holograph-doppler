// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title StakingRewards
 * @notice HLG staking with automatic reward compounding and configurable burn/reward split.
 * @dev
 * - Rewards automatically compound using a reward tracking system with high precision math.
 * - When paused, users can still withdraw but cannot stake; reward distributors are also blocked.
 * - When rewards are distributed, they're immediately tracked for all stakers proportionally.
 * - Extra HLG tokens sent directly to the contract can be recovered with `recoverExtraHLG`.
 * - If no one is staking, reward distributions are skipped to save gas.
 * - Token burning works by transferring to address(0). The HLG token at
 *   0x740dF024Ce73F589AcD5E8756B377eF8C6558BaB reduces its total supply when tokens are burned.
 */
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract StakingRewards is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /* -------------------------------------------------------------------------- */
    /*                                  Errors                                    */
    /* -------------------------------------------------------------------------- */
    error ZeroAmount();
    error ZeroAddress();
    error NoStake();
    error Unauthorized();
    error CannotRecoverStakeToken();
    error NoEtherAccepted();
    error InvalidCall();
    error FeeOnTransferNotSupported();
    error InsufficientToken();
    error EthTransferFailed();
    error InvalidBurnPercentage();
    error ArrayLengthMismatch();
    error EndIndexOutOfBounds();
    error InvalidIndexRange();
    error NoTokensReceived();
    error NotWhitelistedDistributor();
    error BurnFailed();
    error NotEnoughExtraTokens();
    error NotEnoughRewardsAvailable();
    error ActiveStakeExists();
    error RewardTooSmall();

    /* -------------------------------------------------------------------------- */
    /*                                  Storage                                   */
    /* -------------------------------------------------------------------------- */

    /// @notice Precision multiplier for reward calculations (1e12 scaling)
    uint256 private constant INDEX_PRECISION = 1e12;

    /// @notice Maximum percentage value in basis points (100%)
    uint256 public constant MAX_PERCENTAGE = 10000;

    /// @notice HLG token that users stake and receive as rewards
    IERC20 public immutable HLG;

    /// @notice Total HLG staked in the contract (includes compounded rewards)
    uint256 public totalStaked;

    /// @notice User stake balances (includes original stake + compounded rewards)
    mapping(address => uint256) public balanceOf;

    /// @notice FeeRouter address (future automated rewards source)
    address public feeRouter;

    /// @notice Percentage of rewards that get burned (in basis points, 10000 = 100%)
    uint256 public burnPercentage;

    /// @notice Global cumulative reward index (scaled by INDEX_PRECISION for precision)
    uint256 public globalRewardIndex;

    /// @notice Tracks each user's reward snapshot to prevent double-claiming
    mapping(address => uint256) public userIndexSnapshot;

    /// @notice Rewards that have been distributed but not yet claimed by users
    uint256 public unallocatedRewards;

    /// @notice Registry of approved distributors (Merkle drop contracts, quest engines, etc.)
    mapping(address => bool) public isDistributor;

    /* -------------------------------------------------------------------------- */
    /*                                  Events                                    */
    /* -------------------------------------------------------------------------- */
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event EmergencyExit(address indexed user, uint256 amount);
    event RewardsCompounded(address indexed user, uint256 rewardAmount);
    event RewardsDistributed(uint256 totalAmount, uint256 burnAmount, uint256 rewardAmount);
    event FeeRouterUpdated(address indexed newFeeRouter);
    event BurnPercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event TokensRecovered(address indexed token, uint256 amount, address indexed to);
    event EthSwept(uint256 amount, address indexed to);
    event DistributorUpdated(address indexed distributor, bool status);
    event BoostedStake(address indexed distributor, address indexed user, uint256 amount);

    /* -------------------------------------------------------------------------- */
    /*                               Constructor                                  */
    /* -------------------------------------------------------------------------- */
    constructor(address _hlg, address _owner) Ownable(_owner) {
        if (_hlg == address(0)) revert ZeroAddress();
        HLG = IERC20(_hlg);
        burnPercentage = 5000; // Default to 50% burn, 50% rewards
        _pause(); // Start paused until ready
    }

    /* -------------------------------------------------------------------------- */
    /*                                    User                                    */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Stake HLG tokens to earn auto-compounding rewards
     * @param amount Amount of HLG to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        uint256 actualAmount = _pullHLG(msg.sender, amount);
        updateUser(msg.sender);
        balanceOf[msg.sender] += actualAmount;
        totalStaked += actualAmount;

        emit Staked(msg.sender, actualAmount);
    }

    /**
     * @notice Unstake entire HLG balance including all accumulated rewards
     * @dev Auto-compounds first, then transfers full balance. Can be called while paused.
     */
    function unstake() external nonReentrant {
        updateUser(msg.sender);

        uint256 userBalance = balanceOf[msg.sender];
        if (userBalance == 0) revert NoStake();

        balanceOf[msg.sender] = 0;
        userIndexSnapshot[msg.sender] = 0;
        unchecked {
            totalStaked -= userBalance;
        }
        HLG.safeTransfer(msg.sender, userBalance);
        emit Unstaked(msg.sender, userBalance);
    }

    /**
     * @notice Emergency exit without compounding pending rewards
     * @dev Does not call updateUser; returns current recorded balance. Can be called while paused.
     */
    function emergencyExit() external nonReentrant {
        uint256 userBalance = balanceOf[msg.sender];
        if (userBalance == 0) revert NoStake();

        balanceOf[msg.sender] = 0;
        userIndexSnapshot[msg.sender] = 0;
        unchecked {
            totalStaked -= userBalance;
        }
        HLG.safeTransfer(msg.sender, userBalance);
        emit EmergencyExit(msg.sender, userBalance);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Funding                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Deposit HLG and distribute according to burn/reward split.
     * @param hlgAmount HLG to pull from caller
     * @dev Splits burn/reward and updates the index. If there are no stakers,
     *      this call is a no-op.
     */
    function depositAndDistribute(uint256 hlgAmount) external onlyOwner nonReentrant {
        if (_activeStaked() == 0) return;
        if (hlgAmount == 0) revert ZeroAmount();

        uint256 active = _activeStaked();
        uint256 netReward = (hlgAmount * (MAX_PERCENTAGE - burnPercentage)) / MAX_PERCENTAGE;
        if ((netReward * INDEX_PRECISION) / active == 0) revert RewardTooSmall();

        uint256 received = _pullHLG(msg.sender, hlgAmount); // exact amount enforced
        uint256 burnAmount = (received * burnPercentage) / MAX_PERCENTAGE;
        uint256 rewardAmount = received - burnAmount;

        _burnHLG(burnAmount);
        _addRewards(rewardAmount);

        emit RewardsDistributed(received, burnAmount, rewardAmount);
    }

    /**
     * @notice Add rewards from FeeRouter (automated flow).
     * @param amount HLG to pull from FeeRouter
     * @dev Splits burn/reward and updates the index. If there are no stakers,
     *      this call is a no-op.
     */
    function addRewards(uint256 amount) external nonReentrant {
        if (msg.sender != feeRouter) revert Unauthorized();
        if (_activeStaked() == 0) return;
        if (amount == 0) revert ZeroAmount();

        uint256 active = _activeStaked();
        uint256 netReward = (amount * (MAX_PERCENTAGE - burnPercentage)) / MAX_PERCENTAGE;
        if ((netReward * INDEX_PRECISION) / active == 0) revert RewardTooSmall();

        uint256 received = _pullHLG(msg.sender, amount);
        uint256 burnAmount = (received * burnPercentage) / MAX_PERCENTAGE;
        uint256 rewardAmount = received - burnAmount;

        _burnHLG(burnAmount);
        _addRewards(rewardAmount);

        emit RewardsDistributed(received, burnAmount, rewardAmount);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Internals                                 */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Get active staked amount (excluding unallocated rewards)
     * @return Amount of HLG actively staked by users
     */
    function _activeStaked() internal view returns (uint256) {
        return totalStaked - unallocatedRewards;
    }

    /**
     * @notice Internal helper to pull HLG tokens with safety checks
     * @dev Rejects fee-on-transfer tokens; requires exact amount received
     * @param from Address to pull tokens from
     * @param amount Expected amount to receive
     * @return actualAmount Amount actually received (equals amount or reverts)
     */
    function _pullHLG(address from, uint256 amount) internal returns (uint256 actualAmount) {
        uint256 balanceBefore = HLG.balanceOf(address(this));
        HLG.safeTransferFrom(from, address(this), amount);
        uint256 balanceAfter = HLG.balanceOf(address(this));
        actualAmount = balanceAfter - balanceBefore;
        if (actualAmount == 0) revert NoTokensReceived();
        if (actualAmount != amount) revert FeeOnTransferNotSupported();
    }

    /**
     * @notice Updates reward state for an account, compounding any pending amount.
     * @dev Sets the snapshot to the current index after compounding.
     * @param account Address to update rewards for
     */
    function updateUser(address account) public {
        uint256 userBalance = balanceOf[account];
        uint256 currentIndex = globalRewardIndex;
        uint256 snapshot = userIndexSnapshot[account];

        if (userBalance > 0) {
            uint256 indexDelta = currentIndex - snapshot;
            if (indexDelta != 0) {
                uint256 pendingRewards = (userBalance * indexDelta) / INDEX_PRECISION;
                if (pendingRewards > 0) {
                    // Make sure we have enough rewards available to give to the user
                    uint256 unalloc = unallocatedRewards;
                    if (pendingRewards > unalloc) revert NotEnoughRewardsAvailable();

                    balanceOf[account] = userBalance + pendingRewards;
                    unallocatedRewards = unalloc - pendingRewards;
                    emit RewardsCompounded(account, pendingRewards);
                }
            }
        }
        userIndexSnapshot[account] = currentIndex;
    }

    /**
     * @notice Safely burn HLG tokens with supply reduction verification
     * @param amount Amount of HLG to burn
     */
    function _burnHLG(uint256 amount) internal {
        if (amount == 0) return;

        // Assert that transfer-to-zero actually burns supply on HLG
        uint256 supplyBefore = HLG.totalSupply();
        HLG.safeTransfer(address(0), amount);
        uint256 supplyAfter = HLG.totalSupply();

        // If supply did not decrease by exactly amount, revert and revert the transfer
        if (supplyBefore != supplyAfter + amount) revert BurnFailed();
    }

    /**
     * @notice Add rewards to the pool for immediate distribution
     * @param rewardAmount Amount of HLG rewards to distribute to stakers
     */
    function _addRewards(uint256 rewardAmount) internal {
        if (rewardAmount == 0) return;

        uint256 active = _activeStaked();
        // index bump uses active stake
        globalRewardIndex += (rewardAmount * INDEX_PRECISION) / active;

        // Track the full reward amount for distribution to users
        unallocatedRewards += rewardAmount;
        totalStaked += rewardAmount;
    }

    /* -------------------------------------------------------------------------- */
    /*                                    Views                                   */
    /* -------------------------------------------------------------------------- */

    function _pendingRewards(address account) internal view returns (uint256) {
        uint256 userBalance = balanceOf[account];
        if (userBalance == 0) return 0;
        return (userBalance * (globalRewardIndex - userIndexSnapshot[account])) / INDEX_PRECISION;
    }

    /**
     * @notice Calculate pending rewards for a user (not yet compounded)
     * @param account Address to check pending rewards for
     * @return Amount of pending auto-compound rewards
     */
    function earned(address account) external view returns (uint256) {
        return _pendingRewards(account);
    }

    /**
     * @notice Get current global reward index
     * @return Current global reward index (1e12 scaling)
     */
    function rewardPerToken() external view returns (uint256) {
        return globalRewardIndex;
    }

    /**
     * @notice Get user's share of active staked pool (excluding unallocated rewards)
     * @param user Address to check
     * @return User's percentage share in basis points (10000 = 100%)
     */
    function getUserShare(address user) external view returns (uint256) {
        uint256 active = _activeStaked();
        if (active == 0) return 0;
        return (balanceOf[user] * MAX_PERCENTAGE) / active;
    }

    /**
     * @notice Calculate user's total balance including pending rewards
     * @param user Address to check
     * @return Total balance (current stake + pending compounded rewards)
     */
    function balanceWithPendingRewards(address user) external view returns (uint256) {
        return balanceOf[user] + _pendingRewards(user);
    }

    /**
     * @notice Returns extra HLG tokens that can be recovered
     * @dev Shows HLG.balanceOf(this) - totalStaked
     * @return Amount of extra HLG tokens available for recovery
     */
    function getExtraTokens() external view returns (uint256) {
        uint256 contractBalance = HLG.balanceOf(address(this));
        return contractBalance > totalStaked ? contractBalance - totalStaked : 0;
    }

    /* -------------------------------------------------------------------------- */
    /*                                    Admin                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Set FeeRouter address for future automation
     * @param _feeRouter New FeeRouter address
     */
    function setFeeRouter(address _feeRouter) external onlyOwner {
        if (_feeRouter == address(0)) revert ZeroAddress();
        feeRouter = _feeRouter;
        emit FeeRouterUpdated(_feeRouter);
    }

    /**
     * @notice Set burn percentage for reward distribution
     * @param _burnPercentage Percentage of rewards to burn (in basis points, 10000 = 100%)
     */
    function setBurnPercentage(uint256 _burnPercentage) external onlyOwner {
        if (_burnPercentage > MAX_PERCENTAGE) revert InvalidBurnPercentage();

        uint256 oldPercentage = burnPercentage;
        burnPercentage = _burnPercentage;

        emit BurnPercentageUpdated(oldPercentage, _burnPercentage);
    }

    /**
     * @notice Pause staking operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause staking operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency function to recover tokens (not HLG)
     * @param token Token address to recover
     * @param to Address to send recovered tokens to
     * @param amountMinimum Minimum amount that must be available to recover
     */
    function recoverToken(address token, address to, uint256 amountMinimum) external onlyOwner nonReentrant {
        if (token == address(HLG)) revert CannotRecoverStakeToken();
        if (to == address(0)) revert ZeroAddress();

        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount < amountMinimum) revert InsufficientToken();

        IERC20(token).safeTransfer(to, amount);
        emit TokensRecovered(token, amount, to);
    }

    /**
     * @notice Recover extra HLG tokens that were sent directly to contract
     * @param to Address to send extra HLG to
     * @param amount Amount of extra HLG to recover
     */
    function recoverExtraHLG(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = HLG.balanceOf(address(this));
        uint256 free = bal > totalStaked ? bal - totalStaked : 0;
        if (amount > free) revert NotEnoughExtraTokens();
        HLG.safeTransfer(to, amount);
        emit TokensRecovered(address(HLG), amount, to);
    }

    /**
     * @notice Reclaim unallocated rewards when there are no active stakers
     * @param to Address to send unallocated rewards to
     */
    function reclaimUnallocatedRewards(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (_activeStaked() != 0) revert ActiveStakeExists();

        uint256 u = unallocatedRewards;
        if (u == 0) revert ZeroAmount();

        unallocatedRewards = 0;
        unchecked {
            totalStaked -= u;
        }
        HLG.safeTransfer(to, u);

        emit TokensRecovered(address(HLG), u, to);
    }

    /**
     * @notice Sweep ETH that may have been force-sent to the contract
     * @param to Address to send the ETH to
     */
    function sweepETH(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 balance = address(this).balance;
        if (balance == 0) revert ZeroAmount();

        (bool success,) = to.call{value: balance}("");
        if (!success) revert EthTransferFailed();

        emit EthSwept(balance, to);
    }

    /**
     * @notice Credit HLG stake on behalf of a user (owner-only, paused-only)
     * @param user Address to receive the stake credit
     * @param amount Amount of HLG to stake
     */
    function stakeFor(address user, uint256 amount) public nonReentrant onlyOwner whenPaused {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _pullHLG(msg.sender, amount);
        updateUser(user);
        balanceOf[user] += amount;
        totalStaked += amount;

        emit Staked(user, amount);
    }

    /**
     * @notice Batch stake HLG tokens for multiple users (gas optimized)
     * @param users Array of user addresses to stake for
     * @param amounts Array of amounts to stake for each user
     * @param startIndex Starting index in the arrays to process
     * @param endIndex Ending index (exclusive) in the arrays to process
     */
    function batchStakeFor(address[] calldata users, uint256[] calldata amounts, uint256 startIndex, uint256 endIndex)
        external
        onlyOwner
        whenPaused
        nonReentrant
    {
        if (users.length != amounts.length) revert ArrayLengthMismatch();
        if (endIndex > users.length) revert EndIndexOutOfBounds();
        if (startIndex >= endIndex) revert InvalidIndexRange();

        // Validate all inputs and calculate total amount
        uint256 totalAmount;
        for (uint256 i = startIndex; i < endIndex;) {
            if (users[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert ZeroAmount();
            totalAmount += amounts[i];
            unchecked {
                ++i;
            }
        }

        _pullHLG(msg.sender, totalAmount);

        // Process each user: compound existing rewards, add new stake
        for (uint256 i = startIndex; i < endIndex;) {
            address user = users[i];
            uint256 amount = amounts[i];

            updateUser(user);
            balanceOf[user] += amount;
            totalStaked += amount;

            emit Staked(user, amount);
            unchecked {
                ++i;
            }
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                Distributors                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Whitelist/delist a distributor contract for future campaigns
     * @param distributor Address of the distributor contract
     * @param status True to whitelist, false to delist
     */
    function setDistributor(address distributor, bool status) external onlyOwner {
        if (distributor == address(0)) revert ZeroAddress();
        isDistributor[distributor] = status;
        emit DistributorUpdated(distributor, status);
    }

    /**
     * @notice Credit stake on behalf of user (called by whitelisted distributors)
     * @param user Wallet to receive the staked HLG
     * @param amount HLG amount to stake (pulled from distributor)
     */
    function stakeFromDistributor(address user, uint256 amount) external nonReentrant whenNotPaused {
        if (!isDistributor[msg.sender]) revert NotWhitelistedDistributor();
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _pullHLG(msg.sender, amount);
        updateUser(user);
        balanceOf[user] += amount;
        totalStaked += amount;

        emit Staked(user, amount);
        emit BoostedStake(msg.sender, user, amount);
    }

    /* -------------------------------------------------------------------------- */
    /*                                    Fallback                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Reject ETH sent to the contract
     * @dev Prevents accidental ETH transfers to the contract
     */
    receive() external payable {
        revert NoEtherAccepted();
    }

    /**
     * @notice Reject calls to the contract
     * @dev Prevents accidental calls to the contract
     */
    fallback() external payable {
        revert InvalidCall();
    }
}
