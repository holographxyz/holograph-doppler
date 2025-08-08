# StakingRewards Contract - Technical Documentation

## Overview

The StakingRewards contract is the core component of Holograph's HLG tokenomics, implementing an auto-compounding staking mechanism with configurable burn/reward distribution (default 50% burn, 50% rewards). Unlike traditional staking contracts where users must claim rewards separately, this contract automatically compounds rewards into user balances.

The contract implements a configurable burn/reward split: when HLG tokens are received, a percentage is permanently burned (sent to address(0)) and the remainder is distributed proportionally to current stakers. The burn percentage is configurable by the contract owner (default 50%). Built on the proven MasterChef V2 algorithm, it provides O(1) gas efficiency regardless of the number of users.

**Key Features:**

- **Auto-Compounding**: Rewards automatically increase stake balances without claiming
- **O(1) Gas Efficiency**: Constant gas costs regardless of user count
- **Configurable Tokenomics**: Every HLG token is split between burning (deflationary) and rewards based on owner-configurable percentage
- **Extra Token Recovery**: Recovers HLG tokens sent directly to contract outside funding operations
- **Dual Operational Flows**: Supports both bootstrap manual operations and automated integration
- **Security Features**: Reentrancy protection, emergency functions, and access controls

> **Note**: Throughout this documentation, `100 ether` in code examples refers to 100 HLG tokens (both use 18 decimals). The contract only handles HLG tokens, never ETH directly.

## Table of Contents

1. [Economic Model](#economic-model)
2. [MasterChef V2 Algorithm](#masterchef-v2-algorithm)
3. [Dual Operational Flows](#dual-operational-flows)
4. [Stray Token Handling](#stray-token-handling)
5. [User Journey & State Transitions](#user-journey--state-transitions)
6. [Security Features](#security-features)
7. [Technical Implementation](#technical-implementation)
8. [Integration Patterns](#integration-patterns)
9. [Code Examples & Scenarios](#code-examples--scenarios)
10. [Deployment & Operations](#deployment--operations)
11. [Mathematical Appendix](#mathematical-appendix)

---

## Economic Model

### Configurable Burn/Reward Tokenomics

Every HLG token that enters the StakingRewards contract follows a configurable split:

```
Incoming HLG → [X% Burn] → address(0) (permanently removed)
            → [(100-X)% Rewards] → Auto-compound to stakers
```

Where X is the `burnPercentage` (default 50%, configurable by owner).

This creates two economic forces:

- **Deflationary**: Continuous token burning reduces total supply
- **Incentive Alignment**: Stakers are rewarded for long-term commitment

### Burn Percentage Configuration

The burn percentage is configurable by the contract owner, providing flexibility to adjust tokenomics based on market conditions and protocol needs:

```solidity
function setBurnPercentage(uint256 _burnPercentage) external onlyOwner {
    // _burnPercentage in basis points (0-10000, where 10000 = 100%)
}
```

**Examples:**
- `burnPercentage = 5000` → 50% burn, 50% rewards (default)
- `burnPercentage = 3000` → 30% burn, 70% rewards (more rewards to stakers)
- `burnPercentage = 7000` → 70% burn, 30% rewards (more deflationary pressure)
- `burnPercentage = 0` → 0% burn, 100% rewards (all rewards to stakers)

**Important Notes:**
- Changes only affect future reward distributions, not existing balances
- Only the contract owner can modify the burn percentage
- All changes emit `BurnPercentageUpdated` events for transparency

### Auto-Compounding vs Traditional Staking

Traditional staking requires multiple transactions and gas costs for claiming and restaking rewards. The StakingRewards contract eliminates this friction through automatic compounding.

| Traditional Staking      | StakingRewards Auto-Compounding    |
| ------------------------ | ---------------------------------- |
| Stake 100 tokens         | Stake 100 tokens                   |
| Earn 10 reward tokens    | Rewards auto-compound into balance |
| Pay gas to claim rewards | Balance automatically becomes 110  |
| Pay gas to restake       | Single growing balance             |
| Multiple transactions    | Set and forget                     |

The auto-compounding works by using the MasterChef algorithm that's been used across DeFi for years. When rewards come in, your stake balance just grows automatically based on your share of the total pool.

---

## MasterChef V2 Algorithm

### Core Concept

The contract tracks a global reward index that represents cumulative rewards per staked token. Each user maintains a snapshot of this index from their last interaction, so calculating rewards is always fast regardless of how many users there are.

```solidity
uint256 public globalRewardIndex;              // Cumulative rewards per token (scaled by 1e12)
mapping(address => uint256) userIndexSnapshot; // User's last seen global index
mapping(address => uint256) balanceOf;         // User's stake balance (includes compounded rewards)
uint256 public totalStaked;                    // Sum of all user balances
```

### The Algorithm

When rewards are added to the pool:

```solidity
globalRewardIndex += (newRewards * INDEX_PRECISION) / totalStaked;
```

When a user interacts with the contract:

```solidity
pendingRewards = userBalance * (globalRewardIndex - userIndexSnapshot) / INDEX_PRECISION;
userBalance += pendingRewards;  // Auto-compound
userIndexSnapshot = globalRewardIndex;  // Update snapshot
```

### Precision Handling

The contract uses `INDEX_PRECISION = 1e12` following the MasterChef V2 standard. While this provides less precision than 1e18, it offers significant gas savings with negligible precision loss. The rounding always favors the protocol, with users potentially losing wei-level amounts.

### Mathematical Invariant

The fundamental invariant that ensures correctness:

```
totalStaked == sum(balanceOf[user] for all users)
```

We test this constantly to make sure the math always works correctly.

---

## Dual Operational Flows

The contract supports two operational modes: manual bootstrap operations for immediate launch and automated integration for long-term scaling. Both can run at the same time and users get the same rewards either way.

### Bootstrap Flow (Phase 1)

Manual operations for initial launch:

```solidity
function depositAndDistribute(uint256 hlgAmount) external onlyOwner {
    // Owner manually deposits HLG from weekly operations
    // Split according to burnPercentage (default 50% burned, 50% distributed)
}
```

**Weekly Process:**

1. Collect fees from 0x Protocol trading
2. Swap ETH → HLG on Uniswap V3
3. Call `depositAndDistribute()` with acquired HLG
4. Contract automatically splits and distributes

**Benefits:**

- Immediate deployment with minimal complexity
- Test tokenomics with real users
- Validate product-market fit
- Reduced audit scope

### Automated Flow (Phase 2)

Full cross-chain automation via FeeRouter integration:

```solidity
function addRewards(uint256 amount) external {
    require(msg.sender == feeRouter);
    // FeeRouter automatically sends HLG from cross-chain operations
}
```

**Automated Process:**

1. Doppler Airlock fees collected on Base
2. LayerZero V2 bridge to Ethereum
3. ETH → HLG swap via Uniswap V3
4. `addRewards()` called by FeeRouter
5. No manual intervention required

**Benefits:**

- Fully automated operations
- Scales to handle any volume
- Battle-tested cross-chain infrastructure

### Migration Strategy

The contract supports both flows simultaneously, so we can gradually move from manual to automated without losing any user data.

---

## Extra Token Recovery

### The Problem

When HLG tokens arrive through unexpected means (accidental transfers, leftover rewards from previous operations), traditional contracts either ignore them or require complex recovery mechanisms. The StakingRewards contract provides a clean recovery system for these "extra" tokens.

### The Solution: Virtual Compounding with Recovery

The contract uses a virtual compounding model that immediately tracks rewards upon distribution. Extra tokens that arrive outside normal funding operations can be safely recovered by the owner without affecting user rewards.

```solidity
uint256 public unallocatedRewards;  // Rewards distributed but not yet claimed by users
```

### Extra Token Detection

The contract can identify extra tokens by comparing its HLG balance to the amount needed for user stakes:

```solidity
function getExtraTokens() external view returns (uint256) {
    uint256 contractBalance = HLG.balanceOf(address(this));
    return contractBalance > totalStaked ? contractBalance - totalStaked : 0;
}

function recoverExtraHLG(address to, uint256 amount) external onlyOwner {
    // Only recover tokens beyond what's needed for user stakes
    uint256 available = getExtraTokens();
    if (amount > available) revert NotEnoughExtraTokens();
    HLG.safeTransfer(to, amount);
}
```

### Key Benefits

- **Safe Recovery**: Only allows recovery of truly extra tokens, never affects user stakes
- **Clear Accounting**: Easy to see exactly how much can be safely recovered
- **Owner Control**: Only contract owner can initiate recovery operations
- **No-Op Safety**: When no stakers exist, funding becomes a no-op to prevent unnecessary gas costs

---

## User Journey & State Transitions

### Typical Flow

1. **User stakes 100 HLG**

   ```solidity
   stake(100 ether);
   // balanceOf[user] = 100, userSnapshot = current globalIndex
   ```

2. **Rewards come in (say 100 HLG total)**

   ```solidity
   addRewards(100 ether);  // 100 HLG tokens: split according to burnPercentage
   // globalRewardIndex increases
   // User now has pending rewards but balance unchanged
   ```

3. **User does anything (stake more, check balance, whatever)**

   ```solidity
   // Auto-compounding triggers
   pending = calculate_pending_rewards(user);
   balanceOf[user] += pending;  // Balance grows automatically
   ```

4. **Rinse and repeat**
   - User's balance keeps growing with each reward distribution
   - No manual claiming needed
   - Compound growth over time

### Exit Options

**Normal exit:**

```solidity
unstake();  // Get your full balance (original stake + all compounded rewards)
```

**Emergency exit:**

```solidity
emergencyExit();  // Get current balance only, forfeit pending rewards
```

The emergency exit is for during a critical incident when you need to exit immediately, even if it means forfeiting pending rewards.

---

## Security Features

### Standard Protections

**Reentrancy guards** on all external functions:

```solidity
function stake(uint256 amount) external nonReentrant whenNotPaused
```

**Fee-on-transfer protection** (some tokens take fees on transfers):

```solidity
uint256 before = HLG.balanceOf(address(this));
HLG.safeTransferFrom(msg.sender, address(this), amount);
uint256 after = HLG.balanceOf(address(this));
if (after - before != amount) revert FeeOnTransferNotSupported();
```

**Ownable2Step** for safe ownership transfers (two-step process prevents accidents).

### Emergency Functions

**Pause everything:**

```solidity
pause();  // Stops all staking, but unstaking still works
```

**Emergency exit** (works even when paused):

```solidity
emergencyExit();  // Get out fast if needed
```

**Token recovery** (for tokens accidentally sent to contract):

```solidity
recoverToken(address token, address to, uint256 minimum);
// Sweeps full balance of any token except HLG

recoverExtraHLG(address to, uint256 amount);
// Safely recovers extra HLG tokens beyond user stakes
```

**ETH sweep** (protection against selfdestruct attacks):

```solidity
sweepETH(address to);
// Removes any ETH that got forced into the contract
```

### Access Control

- Owner can pause/unpause and do emergency operations
- Only FeeRouter can call `addRewards()`
- Users can always unstake (even when paused)
- Clear separation between admin and user functions

---

## Technical Implementation

### Contract Structure

```solidity
contract StakingRewards is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Core stuff
    IERC20 public immutable HLG;
    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;

    // Virtual compounding state
    uint256 public globalRewardIndex;
    mapping(address => uint256) public userIndexSnapshot;
    uint256 public unallocatedRewards;

    // Config
    address public feeRouter;
    uint256 public burnPercentage;
}
```

### Gas Optimizations

- **_O(1)_ everything**: Doesn't matter if you have 1 user or 1 million, gas stays constant
- **1e12 precision**: Less precision than 1e18 but way more gas efficient
- **Custom errors**: Instead of strings (saves gas on reverts)
- **Packed storage**: Related vars grouped together

### Events

We emit events for everything important:

```solidity
event Staked(address indexed user, uint256 amount);
event Unstaked(address indexed user, uint256 amount);
event RewardsCompounded(address indexed user, uint256 rewardAmount);
event RewardsDistributed(uint256 totalAmount, uint256 burnAmount, uint256 rewardAmount);
```

The `indexed` parameters make it easy to filter events by user address.

---

## Integration Patterns

### FeeRouter Integration

The FeeRouter is our automated reward source. It handles cross-chain fee collection and swaps, then calls us:

```solidity
function addRewards(uint256 amount) external {
    require(msg.sender == feeRouter);
    // Split according to burnPercentage and distribute
}
```

The flow: Base fees → LayerZero bridge → Ethereum FeeRouter → our contract.

### Manual Operations

For bootstrap phase:

```solidity
function depositAndDistribute(uint256 amount) external onlyOwner {
    // Owner manually deposits HLG from weekly operations
}
```

### Configuration

```solidity
function setFeeRouter(address router) external onlyOwner {
    // Point to the FeeRouter contract
}

function setBurnPercentage(uint256 _burnPercentage) external onlyOwner {
    // Configure burn/reward split (0-10000 basis points)
}

function pause() / unpause() external onlyOwner {
    // Emergency controls
}
```

---

## Code Examples & Scenarios

### Single User Example

```solidity
// User stakes 100 HLG tokens
stake(100 ether);  // 100 HLG (ether = 10^18, same as HLG decimals)
// balanceOf[user] = 100, totalStaked = 100

// 100 HLG tokens arrive as rewards (split according to burnPercentage)
addRewards(100 ether);  // 100 HLG tokens
// globalRewardIndex increases by (50 * 1e12) / 100

// User stakes 25 more HLG tokens (auto-compound triggers)
stake(25 ether);  // 25 HLG tokens
// Pending: 100 * (newIndex - oldIndex) / 1e12 = 50 HLG
// Final balance: 100 + 50 + 25 = 175 HLG tokens
```

### Multiple Users

```solidity
// Alice stakes 100 HLG, Bob stakes 200 HLG
// totalStaked = 300

// 120 HLG tokens arrive as rewards (60 burned, 60 distributed)
addRewards(120 ether);  // 120 HLG tokens

// Proportional split:
// Alice gets: 100/300 * 60 = 20 HLG tokens
// Bob gets: 200/300 * 60 = 40 HLG tokens
```

### Extra Token Recovery

```solidity
// Someone accidentally sends HLG to the contract
HLG.transfer(stakingContract, 50 ether);  // 50 extra HLG tokens

// Owner can recover the extra tokens safely
uint256 available = stakingRewards.getExtraTokens();  // Returns 50 ether
stakingRewards.recoverExtraHLG(treasury, 50 ether);  // Recover to treasury

// No stakers scenario - funding becomes no-op
depositAndDistribute(100 ether);  // totalStaked == 0, returns early, no gas wasted
```

### Emergency Scenarios

```solidity
// Contract paused due to emergency
owner.pause();

// Users can still exit safely
user.emergencyExit();  // Withdraws current balance, forfeits pending rewards
user.unstake();        // Normal exit (works even when paused)

// New staking is blocked
user.stake(100 ether);  // Reverts: contract paused
```

---

## Deployment & Operations

### Deployment

```solidity
constructor(address _hlg, address _owner) {
    HLG = IERC20(_hlg);
    _pause();  // Starts paused for safety
}
```

**Setup steps:**

1. Deploy with HLG token address and owner
2. `setFeeRouter(address)` if using automated flow
3. `unpause()` when ready to accept staking
4. Transfer ownership to multisig (two-step process)

### Operations

**Bootstrap weekly process:**

1. Collect 0x Protocol fees
2. Swap ETH → HLG on Uniswap
3. Call `depositAndDistribute(hlgAmount)`
4. Check events, monitor growth

**Monitoring:**

```solidity
// Critical invariant (must always be true)
totalStaked == sum(all user balances)

// Solvency check
HLG.balanceOf(contract) >= totalStaked

// Extra tokens tracking (operational metric)
extraTokens = HLG.balanceOf(contract) - totalStaked
// Check for extra tokens available for recovery
uint256 extraTokens = stakingRewards.getExtraTokens();
```

**Emergency Procedures:**

- **Pause Contract**: `pause()` stops new staking if critical issue discovered
- **Allow Exits**: Users can still `unstake()` and `emergencyExit()` when paused
- **Token Recovery**: `recoverToken()` for accidentally sent tokens (except HLG)
- **ETH Sweep**: `sweepETH()` removes ETH that may have been force-sent via selfdestruct

### Future Upgrades

Contract is not upgradeable (by design). To upgrade:

1. **Deploy New Contract**: With enhanced features
2. **Migrate State**: Transfer all user balances and rewards
3. **Update Integrations**: Point FeeRouter to new contract
4. **Preserve History**: Maintain all staking and reward history

---

## Mathematical Appendix

### The Core Formula

```
pending = userBalance * (globalIndex - userSnapshot) / 1e12
```

That's it. Everything else is just implementation details.

**When rewards come in:**

```
globalIndex += (newRewards * 1e12) / totalStaked
```

### Precision Stuff

We use 1e12 instead of 1e18 for gas efficiency. Precision loss is minimal:

```
// Worst case: 1 wei balance, 1 wei reward
pending = 1 * (someIndex - otherIndex) / 1e12 = 0 (rounds down)
```

In practice, this never matters because HLG has 18 decimals and real balances are much larger.

### The Critical Invariant

```
totalStaked == sum(all user balances)
```

If this breaks, the contract state is invalid. We test it constantly.

### Performance Characteristics

All operations are _O(1)_ regardless of user count, thanks to the MasterChef algorithm's cumulative index approach. Gas costs scale with transaction complexity, not the number of stakers.

---

## MasterChef V2 Comparison

While StakingRewards builds on the proven MasterChef V2 algorithm, several key differences optimize it for HLG tokenomics:

| Aspect                   | MasterChef V2              | StakingRewards                      |
| ------------------------ | -------------------------- | ----------------------------------- |
| **Reward Source**        | Pre-funded token emissions | Dynamic fee-based rewards           |
| **Reward Cadence**       | Fixed emission schedule    | Variable based on protocol activity |
| **Asset Custody**        | Multiple LP tokens         | Single HLG token only               |
| **User Experience**      | Manual harvest required    | Auto-compounding rewards            |
| **Zero-Staker Handling** | Rewards wasted/delayed     | Genesis bonus buffer system         |
| **Burn Mechanism**       | No burning                 | Configurable % of rewards burned   |
| **Security Additions**   | Basic protections          | Enhanced with emergency exits       |
| **Precision/Arithmetic** | Standard 1e12              | Optimized 1e12 with gas savings     |
| **Pool Design**          | Multiple pools/farms       | Single unified pool                 |
| **Emission Governance**  | DAO-controlled rates       | Market-driven via protocol fees     |

The core mathematical algorithm remains identical, keeping the proven reliability while adding features we need for Holograph's cross-chain setup.

---

## Conclusion

The StakingRewards contract provides a robust foundation for Holograph's tokenomics through auto-compounding staking with configurable burn/reward distribution (default 50/50). By building on the proven MasterChef V2 algorithm and adding innovative features like zero-staker buffers, it balances simplicity with sophistication.

**Key Strengths:**

- **Proven Algorithm**: MasterChef V2 has been used across DeFi for years
- **Auto-Compounding**: Maximizes user rewards without gas overhead
- **Dual Operation Support**: Seamless transition from bootstrap to full automation
- **Solid Security**: Protection against the usual smart contract attacks
- **Economic Alignment**: Configurable burn/reward model creates sustainable tokenomics

---

_For technical questions or contributions to this documentation, please reach out to the Holograph development team._
