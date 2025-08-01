// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title StakingRewards
 * @notice Simplified HLG staking contract with auto-compounding rewards
 * @dev Supports both manual bootstrap operations and future automated FeeRouter integration
 */
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract StakingRewards is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /* -------------------------------------------------------------------------- */
    /*                                  Errors                                    */
    /* -------------------------------------------------------------------------- */
    error ZeroAmount();
    error ZeroAddress();
    error NoStake();
    error InsufficientBalance();
    error Unauthorized();
    error CannotRecoverStakeToken();
    error NoEtherAccepted();
    error InvalidCall();

    /* -------------------------------------------------------------------------- */
    /*                                 Storage                                    */
    /* -------------------------------------------------------------------------- */

    /// @notice HLG token that users stake and receive as rewards
    IERC20 public immutable HLG;

    /// @notice Total HLG staked in the contract
    uint256 public totalStaked;

    /// @notice User stake balances
    mapping(address => uint256) public balanceOf;

    /// @notice FeeRouter address (future automated rewards source)
    address public feeRouter;

    /// @notice Array of all stakers for reward distribution
    address[] public stakers;

    /// @notice Track if address is a staker
    mapping(address => bool) public isStaker;

    /* -------------------------------------------------------------------------- */
    /*                                  Events                                    */
    /* -------------------------------------------------------------------------- */
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsDistributed(uint256 totalAmount, uint256 burnAmount, uint256 rewardAmount);
    event FeeRouterUpdated(address indexed newFeeRouter);
    event TokensRecovered(address indexed token, uint256 amount, address indexed to);

    /* -------------------------------------------------------------------------- */
    /*                               Constructor                                  */
    /* -------------------------------------------------------------------------- */
    constructor(address _hlg, address _owner) Ownable(_owner) {
        if (_hlg == address(0)) revert ZeroAddress();
        HLG = IERC20(_hlg);
        _pause(); // Start paused until ready
    }

    /* -------------------------------------------------------------------------- */
    /*                              User Functions                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Stake HLG tokens
     * @param amount Amount of HLG to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Add to stakers array if first time staking
        if (!isStaker[msg.sender] && balanceOf[msg.sender] == 0) {
            stakers.push(msg.sender);
            isStaker[msg.sender] = true;
        }

        balanceOf[msg.sender] += amount;
        totalStaked += amount;

        HLG.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstake entire HLG balance including accumulated rewards
     * @dev Users must unstake their full balance, no partial unstaking
     */
    function unstake() external nonReentrant {
        uint256 userBalance = balanceOf[msg.sender];
        if (userBalance == 0) revert NoStake();

        balanceOf[msg.sender] = 0;
        totalStaked -= userBalance;

        HLG.safeTransfer(msg.sender, userBalance);
        emit Unstaked(msg.sender, userBalance);
    }

    /* -------------------------------------------------------------------------- */
    /*                           Bootstrap Operations                             */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Deposit HLG and distribute: 50% burn, 50% rewards
     * @dev Used for manual bootstrap operations
     * @param hlgAmount Total HLG to process
     */
    function depositAndDistribute(uint256 hlgAmount) external onlyOwner nonReentrant {
        if (hlgAmount == 0) revert ZeroAmount();

        // Transfer HLG from caller
        HLG.safeTransferFrom(msg.sender, address(this), hlgAmount);

        // Calculate 50/50 split
        uint256 burnAmount = hlgAmount / 2;
        uint256 rewardAmount = hlgAmount - burnAmount;

        // Burn 50% by sending to address(0)
        HLG.safeTransfer(address(0), burnAmount);

        // Distribute the remaining 50% proportionally to all stakers
        if (totalStaked > 0) {
            _distributeRewards(rewardAmount);
        }
        // If no stakers, rewards just accumulate in contract for future stakers

        emit RewardsDistributed(hlgAmount, burnAmount, rewardAmount);
    }

    /* -------------------------------------------------------------------------- */
    /*                      Future Automated Integration                          */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Add rewards from FeeRouter (future automated flow)
     * @dev FeeRouter will call this to add rewards directly
     * @param amount Amount of HLG rewards to add
     */
    function addRewards(uint256 amount) external nonReentrant {
        if (msg.sender != feeRouter) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();

        // Transfer rewards from FeeRouter
        HLG.safeTransferFrom(msg.sender, address(this), amount);

        // Calculate 50/50 split
        uint256 burnAmount = amount / 2;
        uint256 rewardAmount = amount - burnAmount;

        // Burn 50%
        HLG.safeTransfer(address(0), burnAmount);

        // Distribute the remaining 50% proportionally to all stakers
        if (totalStaked > 0) {
            _distributeRewards(rewardAmount);
        }
        // If no stakers, rewards just accumulate in contract for future stakers

        emit RewardsDistributed(amount, burnAmount, rewardAmount);
    }

    /* -------------------------------------------------------------------------- */
    /*                            Internal Functions                              */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Distribute rewards proportionally to all stakers
     * @dev Increases each staker's balance by their proportional share
     * @param rewardAmount Total rewards to distribute
     */
    function _distributeRewards(uint256 rewardAmount) internal {
        uint256 stakersLength = stakers.length;
        if (stakersLength == 0 || totalStaked == 0) return;

        // Calculate and distribute rewards to each staker
        for (uint256 i = 0; i < stakersLength; i++) {
            address staker = stakers[i];
            uint256 stakerBalance = balanceOf[staker];

            if (stakerBalance > 0) {
                // Calculate proportional reward: (userStake / totalStake) * rewardAmount
                uint256 stakerReward = (stakerBalance * rewardAmount) / totalStaked;

                // Add reward to staker's balance
                balanceOf[staker] += stakerReward;
            }
        }

        // Update totalStaked to include distributed rewards
        totalStaked += rewardAmount;
    }

    /* -------------------------------------------------------------------------- */
    /*                              View Functions                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Get user's share of total staked
     * @param user Address to check
     * @return User's percentage share (basis points)
     */
    function getUserShare(address user) external view returns (uint256) {
        if (totalStaked == 0) return 0;
        return (balanceOf[user] * 10000) / totalStaked;
    }

    /**
     * @notice Get total rewards in contract (excluding staked amounts)
     * @return Total reward balance
     */
    function getTotalRewards() external view returns (uint256) {
        uint256 totalBalance = HLG.balanceOf(address(this));
        return totalBalance > totalStaked ? totalBalance - totalStaked : 0;
    }

    /**
     * @notice Get total number of stakers
     * @return Number of unique stakers
     */
    function getStakersCount() external view returns (uint256) {
        return stakers.length;
    }

    /* -------------------------------------------------------------------------- */
    /*                              Admin Functions                               */
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
     * @dev Useful if someone accidentally sends wrong tokens to this contract
     * @param token Token address to recover
     * @param amount Amount to recover
     * @param to Address to send recovered tokens to
     */
    function recoverToken(address token, uint256 amount, address to) external onlyOwner {
        if (token == address(HLG)) revert CannotRecoverStakeToken();
        if (to == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(to, amount);
        emit TokensRecovered(token, amount, to);
    }

    /* -------------------------------------------------------------------------- */
    /*                            Fallback Functions                              */
    /* -------------------------------------------------------------------------- */

    /// @notice Reject direct ETH transfers
    receive() external payable {
        revert NoEtherAccepted();
    }

    /// @notice Reject fallback calls
    fallback() external payable {
        revert InvalidCall();
    }
}
