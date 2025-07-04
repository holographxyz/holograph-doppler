**Version:** 1.1

**Date:** 2025-05-27

## 1. Introduction

This document outlines the mechanism to manage and distribute fees generated by the Holograph Doppler Launchpad operating on the Base network, with HLG token staking and buy-and-burn operations occurring on the Ethereum network. The system implements the established fee model: 50% of fees to HLG stakers and 50% to HLG buy-and-burn.

Fees paid in ETH on Base are bridged to Ethereum via LayerZero V2, swapped to HLG on Uniswap V3, then split: 50% burned, 50% sent to stakers (as HLG). A single omnichain FeeRouter (same address on both chains) performs the bridge, swap, burn, and reward transfer.

## 2. Core Assumptions

- **Fee asset:** ETH on Base; wrapped to WETH on Ethereum when swapping.
- **Messaging:** LayerZero OApp `_lzSend` / `_lzReceive` for generic payload + value transfer.
- **DEX liquidity:** All HLG/WETH liquidity sits in Uniswap V3 0.3% fee tier (3000).
- **Rewards denomination:** Stakers deposit HLG and earn HLG.
- **Automation:** TBD

## 3. System Components

### 3.1 On Base

| Contract         | Role                                                             |
| ---------------- | ---------------------------------------------------------------- |
| HolographFactory | Mints Doppler token packages; forwards 1.5% ETH fee to FeeRouter |
| FeeRouter (OApp) | Aggregates fees, calls `bridge(minGas)` → `_lzSend`              |

### 3.2 Cross-Chain

LayerZero Endpoints hold the messaging channel; FeeRouter sets `trustedRemote` to its peer for auth.

### 3.3 On Ethereum

| Contract         | Role                                                                                                          |
| ---------------- | ------------------------------------------------------------------------------------------------------------- |
| FeeRouter (peer) | Receives ETH, wraps to WETH, executes `exactInputSingle` WETH→HLG, burns 50%, forwards 50% HLG to StakingPool |
| StakingPool      | Non-custodial HLG staking + proportional HLG reward accounting                                                |

_(A separate "Buy-and-Burn Executor" is no longer needed; logic lives in FeeRouter.)_

## 4. Process Flow

1. **Fee Collection (Base):**
   - Users interact with the HolographFactory on Base, paying fees in ETH
   - Factory forwards 1.5% ETH fee to FeeRouter via `receiveFee()`
2. **Fee Bridging (Base → Ethereum):**
   - Admin/keeper calls `bridge(minGas)` on FeeRouter(Base)
   - FeeRouter(Base) sends ETH via LayerZero `_lzSend` to peer on Ethereum
3. **Swap & Distribution (Ethereum):**
   - FeeRouter(Eth) receives ETH and executes the swap-and-split logic:

```solidity
_wrapETH();                              // WETH9
uint hlgOut = _swapExactInputSingle(wethBal, minHlg);  // Uniswap V3
uint stakeAmt = hlgOut / 2;
HLG.transfer(address(0), hlgOut - stakeAmt);           // burn 50%
HLG.transfer(address(stakingPool), stakeAmt);          // rewards 50%

```

1. **Reward Distribution:**
   - `StakingPool.addRewards(stakeAmt)` updates internal reward accounting
   - Uses standard `rewardPerTokenStored` pattern for proportional distribution
2. **User Actions:**
   - Users can `stake()` HLG tokens to earn rewards
   - Users call `claim()` or `unstake()` to receive their HLG rewards

## 5. Technical Considerations

The system addresses several potential issues that could impact operations:

**Bridge Security:** The LayerZero integration uses trusted remote addresses to ensure only authorized contracts can send messages between chains. The receive function is protected against reentrancy attacks to prevent malicious actors from draining funds during the bridging process.

**Price Impact Protection:** When swapping ETH for HLG tokens, we pass a minimum output parameter to the Uniswap router. This prevents the transaction from completing if slippage is too high, protecting against sandwich attacks and sudden price movements. The swap path can be upgraded if needed to handle different market conditions.

**Token Burning:** We follow the standard ERC-20 burn pattern by transferring tokens to the zero address. This permanently removes them from circulation and is recognized by most analytics tools and block explorers.

**Reward Distribution:** The staking pool uses a well-tested mathematical formula that calculates rewards efficiently regardless of how many users are staking. This avoids expensive loops and ensures the system can scale to thousands of participants.

## 6. System Architecture Diagram

```
[User on Base] --(ETH Fee)--> [HolographFactory (Base)]
                                     |
                                     v (1.5% fee)
                       [FeeRouter (Base)] --(ETH via LayerZero)--> [FeeRouter (Ethereum)]
                                                                           |
                                                                           v (wrap + swap)
                                                                  [Uniswap V3: WETH→HLG]
                                                                      /            \
                                                                     /              \
                                                               (50% burn)      (50% rewards)
                                                                   |                |
                                                                   v                v
                                                              [address(0)]    [StakingPool]
                                                                                    |
                                                                                    v
                                                                         [Users stake & claim HLG]

```

## 7. FeeRouter (EVM) – Key Interface

```solidity
event FeesBridged(uint256 ethAmt);
event Swapped(uint256 ethIn, uint256 hlgOut);
event RewardsSent(uint256 hlgAmt);
event Burned(uint256 hlgAmt);

function receiveFee() external payable;          // Factory -> Base only
function bridge(uint256 minGas) external;        // Base only

function _lzReceive(
  uint16, bytes calldata, uint64, bytes calldata /*payload*/
) external payable;                              // Eth only

//  Internal (Eth)
function swapAndDistribute(uint256 minHlg) external; // onlySelf

```

Uses Uniswap V3 `ISwapRouter.exactInputSingle` with fee tier 3000.

## 8. StakingPool – Key Interface

```solidity
event Staked(address indexed user, uint256 amt);
event Unstaked(address indexed user, uint256 amt);
event RewardAdded(uint256 amt);
event RewardClaimed(address indexed user, uint256 amt);

function stake(uint256 amt) external;
function unstake(uint256 amt) external;
function claim() external;

function addRewards(uint256 amt) external;   // only FeeRouter
function earned(address user) external view returns (uint256);

```

### Reward Distribution Examples

The staking contract uses a proven reward distribution mechanism where rewards are allocated proportionally based on staked amounts and timing. Here's how it works:

**Core Formula:**

```
rewardPerTokenStored += newRewards * 1e18 / totalStaked;   // when rewards added
earned(user) = userStake * (rewardPerTokenStored - userLastPaid) / 1e18;

```

**Example Scenario:**

- Alice stakes 100 HLG, Bob stakes 300 HLG (total: 400 HLG)
- 20 HLG rewards are added: `rewardPerTokenStored += 20 * 1e18 / 400 = 0.05e18`
- Alice's rewards: `100 * 0.05e18 / 1e18 = 5 HLG`
- Bob's rewards: `300 * 0.05e18 / 1e18 = 15 HLG`

This constant-time formula scales to any user count and there is precedence for it.

## 9. Security Recommendations

**Prevent Reentrancy Attacks:** All functions that handle external calls or token transfers should use reentrancy guards. This is especially important for the LayerZero receive function and any functions that interact with external contracts like Uniswap.

**Use Multisig for Critical Functions:** Important administrative functions like setting trusted remote addresses, updating the staking pool contract, changing router addresses, and modifying bridging thresholds should require multiple signatures. This prevents single points of failure and reduces the risk of admin key compromise.

**Audits:** We will need to plan and budget for an audit before going live.

### Open Questions

- How are gas fees (bridging, wrapping, swapping, burning, etc.) handled? Who pays gas? How much will this cost?
- How much do you estimate the audit will cost? Are these contracts complex?
- How do we plan to provision liquidity on Uniswap v3 (perhaps a pool 2 incentive?)? Who will market make to ensure a healthy pool? Will be manage liquidity bands for optimal efficiency? How do we protect against wild swings in volatility? Will this pool be private or public?
- How does Holograph make money?
