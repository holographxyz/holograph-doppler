// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {StakingRewards} from "./StakingRewards.sol";

/**
 * @title MerkleDistributor
 * @notice Distributes HLG tokens via Merkle proof verification with automatic staking
 * @dev Merkle proof verification → approve → stakeFromDistributor. Single-use claims via claimed mapping, whitelist preflight, allocation cap check. Uses safeIncreaseAllowance to avoid non-zero allowance issue per OpenZeppelin guidance.
 */
contract MerkleDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* -------------------------------------------------------------------------- */
    /*                                  Errors                                    */
    /* -------------------------------------------------------------------------- */
    error InvalidProof();
    error AlreadyClaimed();
    error ZeroAmount();
    error ZeroAddress();
    error CampaignNotActive();
    error CampaignNotEnded();
    error DistributorNotWhitelisted();
    error ExceedsAllocation();

    /* -------------------------------------------------------------------------- */
    /*                                 Storage                                    */
    /* -------------------------------------------------------------------------- */

    /// @notice The HLG token
    IERC20 public immutable HLG;

    /// @notice The StakingRewards contract where tokens get staked
    StakingRewards public immutable stakingRewards;

    /// @notice Merkle root for this campaign
    bytes32 public immutable merkleRoot;

    /// @notice Campaign end timestamp (for unclaimed token recovery)
    uint256 public immutable campaignEndTime;

    /// @notice Total HLG allocated for this campaign
    uint256 public immutable totalAllocation;

    /// @notice Track claimed addresses
    mapping(address => bool) public claimed;

    /// @notice Track claimed amounts per address (prevents double-claiming)
    mapping(address => uint256) public amountClaimed;

    /// @notice Total amount claimed so far
    uint256 public totalClaimed;

    /* -------------------------------------------------------------------------- */
    /*                                  Events                                    */
    /* -------------------------------------------------------------------------- */
    event Claimed(address indexed user, uint256 amount);
    event TokensRecovered(uint256 amount);

    /* -------------------------------------------------------------------------- */
    /*                               Constructor                                  */
    /* -------------------------------------------------------------------------- */
    constructor(
        address _hlg,
        address _stakingRewards,
        bytes32 _merkleRoot,
        uint256 _totalAllocation,
        uint256 _campaignDurationDays,
        address _owner
    ) Ownable(_owner) {
        if (_hlg == address(0)) revert ZeroAddress();
        if (_stakingRewards == address(0)) revert ZeroAddress();
        if (_totalAllocation == 0) revert ZeroAmount();

        HLG = IERC20(_hlg);
        stakingRewards = StakingRewards(payable(_stakingRewards));
        merkleRoot = _merkleRoot;
        totalAllocation = _totalAllocation;
        campaignEndTime = block.timestamp + (_campaignDurationDays * 1 days);
    }

    /* -------------------------------------------------------------------------- */
    /*                              User Functions                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Claim HLG allocation with Merkle proof and auto-stake
     * @param amount Amount of HLG to claim (must match Merkle leaf)
     * @param merkleProof Array of Merkle proof hashes
     * @dev Reverts while StakingRewards is paused; users may retry after unpause
     */
    function claim(uint256 amount, bytes32[] calldata merkleProof) external nonReentrant {
        if (block.timestamp > campaignEndTime) revert CampaignNotActive();
        if (amount == 0) revert ZeroAmount();
        if (claimed[msg.sender]) revert AlreadyClaimed();

        // Preflight check: ensure this distributor is whitelisted (saves user gas)
        if (!stakingRewards.isDistributor(address(this))) revert DistributorNotWhitelisted();
        if (totalClaimed + amount > totalAllocation) revert ExceedsAllocation();

        // Verify Merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        if (!MerkleProof.verify(merkleProof, merkleRoot, leaf)) revert InvalidProof();

        // Mark as claimed and track amount
        claimed[msg.sender] = true;
        amountClaimed[msg.sender] = amount;
        totalClaimed += amount;

        // Approve and stake tokens (uses safeIncreaseAllowance to avoid non-zero allowance issue)
        HLG.safeIncreaseAllowance(address(stakingRewards), amount);
        stakingRewards.stakeFromDistributor(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    /* -------------------------------------------------------------------------- */
    /*                              Admin Functions                               */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Recover unclaimed tokens after campaign ends
     * @dev Only callable after campaign end time
     */
    function recoverUnclaimedTokens() external onlyOwner {
        if (block.timestamp <= campaignEndTime) revert CampaignNotEnded();

        uint256 unclaimedAmount = HLG.balanceOf(address(this));
        if (unclaimedAmount == 0) revert ZeroAmount();

        HLG.safeTransfer(owner(), unclaimedAmount);
        emit TokensRecovered(unclaimedAmount);
    }

    /* -------------------------------------------------------------------------- */
    /*                              View Functions                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Check if campaign is still active
     */
    function isActive() external view returns (bool) {
        return block.timestamp <= campaignEndTime;
    }

    /**
     * @notice Get unclaimed amount
     */
    function getUnclaimedAmount() external view returns (uint256) {
        return totalAllocation - totalClaimed;
    }

    /**
     * @notice Get campaign info
     */
    function getCampaignInfo()
        external
        view
        returns (bytes32 root, uint256 endTime, uint256 total, uint256 claimedSoFar, bool active)
    {
        return (merkleRoot, campaignEndTime, totalAllocation, totalClaimed, block.timestamp <= campaignEndTime);
    }

    /**
     * @notice Check if user has claimed and how much
     */
    function getClaimStatus(address user) external view returns (bool hasClaimed, uint256 amount) {
        return (claimed[user], amountClaimed[user]);
    }
}
