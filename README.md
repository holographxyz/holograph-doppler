# Holograph Protocol v2

A protocol for deploying omnichain tokens with deterministic addresses across multiple blockchains. Built on Doppler Airlock technology and LayerZero V2 for secure cross-chain messaging.

## Overview

Holograph Protocol enables the creation of ERC-20 tokens with deterministic addresses across supported chains. The protocol integrates with Doppler's token factory system for secure token launches and automates fee collection through LayerZero V2 cross-chain messaging.

### Key Features

- **Deterministic Addresses**: CREATE2-based deployment ensures consistent addresses across chains
- **Doppler Integration**: Authorized token factory for Doppler Airlock launches
- **Fee Automation**: Automated fee collection and cross-chain distribution
- **LayerZero V2**: Cross-chain fee bridging infrastructure
- **HolographDeployer**: Deterministic contract deployment system with salt validation

### Architecture

```
Base Chain                   LayerZero V2              Ethereum Chain
┌─────────────────┐         ┌─────────────┐          ┌─────────────────┐
│ Doppler Airlock │────────▶│             │          │                 │
│       ↓         │         │   Message   │          │                 │
│ HolographFactory│         │   Passing   │          │                 │
│                 │         │             │          │                 │
│ FeeRouter       │────────▶│   (Fees)    │─────────▶│ Fee Processing  │
│                 │         │             │          │                 │
│ HolographERC20  │         │             │          │ StakingRewards  │
└─────────────────┘         └─────────────┘          └─────────────────┘
```

**Primary Chains**: Base (token creation) and Ethereum (fee processing/staking)  
**Additional Support**: Unichain deployment available for expanded reach

**Note**: Cross-chain token bridging is temporarily deferred. Currently, only fee bridging is supported through LayerZero V2.

## Development & Deployment

### Quick Start with Makefile

The project includes a streamlined Makefile for common development tasks. All deployment operations default to **dry-run mode** for safety - no real transactions are sent unless explicitly enabled.

#### Basic Commands

```bash
# Development
make build          # Compile all contracts
make test           # Run the full test suite
make fmt            # Format Solidity code
make clean          # Clean build artifacts

# View all available commands
make help

# Gas analysis for referral campaigns
make gas-analysis         # Cost analysis for 5,000 user campaign
```

#### Deployment Commands

**Dry-run mode (default - safe for testing):**

```bash
# Primary chains
make deploy-base        # Simulate Base deployment
make deploy-eth         # Simulate Ethereum deployment

# Additional chains
make deploy-unichain    # Simulate Unichain deployment

# Configuration
make configure-base     # Simulate Base configuration
make configure-eth      # Simulate Ethereum configuration
make configure-unichain # Simulate Unichain configuration

# Operations
make fee-ops            # Simulate fee operations
```

**Live deployment mode:**

```bash
# Set environment variables
export BROADCAST=true
export DEPLOYER_PK=0x...  # For deploy-* commands
export OWNER_PK=0x...     # For configure-* commands
export OWNER_PK=0x...      # For fee operations (owner-only)

# Required RPC URLs
export BASE_RPC_URL=https://mainnet.base.org
export ETHEREUM_RPC_URL=https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY
export UNICHAIN_RPC_URL=https://mainnet.unichain.org

# Required API keys for verification
export BASESCAN_API_KEY=your_basescan_key
export ETHERSCAN_API_KEY=your_etherscan_key
export UNISCAN_API_KEY=your_uniscan_key

# Deploy to primary chains
make deploy-base        # Deploy to Base mainnet  
make deploy-eth         # Deploy to Ethereum mainnet

# Optionally deploy to additional chains
make deploy-unichain    # Deploy to Unichain mainnet
```

#### Environment Variables

| Variable            | Required For           | Description                                 |
| ------------------- | ---------------------- | ------------------------------------------- |
| `BROADCAST`         | Live deployments       | Set to `true` to send real transactions     |
| `DEPLOYER_PK`       | `deploy-*` commands    | Private key for contract deployment         |
| `OWNER_PK`          | `configure-*` commands | Private key for contract administration     |
| `OWNER_PK`          | `fee-*` commands       | Private key for fee operations (owner-only) |
| `BASE_RPC_URL`      | Base operations        | RPC endpoint for Base network               |
| `ETHEREUM_RPC_URL`  | Ethereum operations    | RPC endpoint for Ethereum network           |
| `UNICHAIN_RPC_URL`  | Unichain operations    | RPC endpoint for Unichain network           |
| `BASESCAN_API_KEY`  | Base verification      | API key for Basescan contract verification  |
| `ETHERSCAN_API_KEY` | Ethereum verification  | API key for Etherscan contract verification |
| `UNISCAN_API_KEY`   | Unichain verification  | API key for Uniscan contract verification   |

#### Typical Deployment Flow

1. **Test everything in dry-run mode first:**

   ```bash
   # Primary chains (required)
   make deploy-base deploy-eth
   make configure-base configure-eth
   
   # Additional chains (optional)
   make deploy-unichain configure-unichain
   ```

2. **Deploy to mainnet:**

   ```bash
   export BROADCAST=true
   export DEPLOYER_PK=0x...
   
   # Primary chains
   make deploy-base deploy-eth
   
   # Additional chains (optional)  
   make deploy-unichain
   ```

3. **Verify deployment consistency:**

   ```bash
   make verify-addresses  # Check addresses match across chains
   ```

4. **Configure the deployed contracts:**

   ```bash
   export OWNER_PK=0x...  # Different key for admin operations
   
   # Primary chains
   make configure-base configure-eth
   
   # Additional chains (if deployed)
   make configure-unichain
   ```

5. **Configure LayerZero V2 DVN security:**

   ```bash
   # Required for cross-chain fee bridging
   make configure-dvn-base configure-dvn-eth
   ```

6. **Set up automation:**
   ```bash
   export OWNER_PK=0x...
   make fee-ops  # Test fee operations
   ```

#### Contract Verification

Contracts are automatically verified during deployment when `BROADCAST=true` and the appropriate API keys are set. If verification fails during deployment, you can retry later:

```bash
# Re-run deployment with --resume --verify
forge script script/DeployBase.s.sol --rpc-url $BASE_RPC_URL --resume --verify --etherscan-api-key $BASESCAN_API_KEY
```

#### Deployment Artifacts

Deployed contract addresses are automatically saved to:

- `deployments/base/` - Base network deployments
- `deployments/ethereum/` - Ethereum network deployments
- `deployments/unichain/` - Unichain network deployments
- `broadcast/` - Complete transaction logs and artifacts

Each deployment directory contains:
- `deployment.json` - Complete deployment information
- Individual `.txt` files for each contract address

#### Safety Features

- **Dry-run by default**: Scripts never broadcast without explicit `BROADCAST=true`
- **Environment validation**: Scripts check for required environment variables
- **Chain validation**: Scripts warn when deploying to unexpected networks
- **Role separation**: Different private keys for deployment vs. administration
- **Colored output**: Clear visual feedback on operation status

## Core Contracts

### HolographDeployer

Deterministic contract deployment system using CREATE2 for cross-chain address consistency.

```solidity
function deploy(bytes memory creationCode, bytes32 salt) external returns (address deployed);
function deployAndInitialize(bytes memory creationCode, bytes32 salt, bytes memory initData) external returns (address deployed);
function computeAddress(bytes memory creationCode, bytes32 salt) external view returns (address);
```

### HolographFactory

Doppler-authorized token factory implementing ITokenFactory for omnichain token creation.

```solidity
// Called by Doppler Airlock contracts only
function create(
    uint256 initialSupply,
    address recipient,
    address owner,
    bytes32 salt,
    bytes calldata tokenData
) external returns (address token);

function setAirlockAuthorization(address airlock, bool authorized) external; // Owner only
function isTokenCreator(address token, address user) external view returns (bool);
```

### FeeRouter

Handles fee collection from Doppler Airlock contracts and cross-chain fee distribution.

```solidity
function collectAirlockFees(address airlock, address token, uint256 amt) external; // Owner only
function bridge(uint256 minGas, uint256 minHlg) external; // Owner only
function setTrustedAirlock(address airlock, bool trusted) external; // Owner only
```

### StakingRewards

Single-token HLG staking with configurable burn/reward distribution, emergency controls, and auto-compounding. Supports batch operations for referral reward distribution.

```solidity
function stake(uint256 amount) external; // Stake HLG tokens
function unstake() external; // Withdraw full balance (auto-compounded rewards)
function setBurnPercentage(uint256 _burnPercentage) external; // Owner only
function depositAndDistribute(uint256 hlgAmount) external; // Owner only, manual funding
function addRewards(uint256 amount) external; // FeeRouter only, automated funding
function batchStakeFor(address[] calldata users, uint256[] calldata amounts, uint256 startIndex, uint256 endIndex) external; // Owner only, batch referral rewards

// Extra token management
function getExtraTokens() external view returns (uint256); // View extra HLG available for recovery
function recoverExtraHLG(address to, uint256 amount) external; // Owner only, recover extra HLG tokens

// Distributor System (for future campaigns)
function setDistributor(address distributor, bool status) external; // Owner only, whitelist campaign distributors
function stakeFromDistributor(address user, uint256 amount) external; // Distributor only, credit stakes with automatic token pull
```

## Token Launch Process

1. Create token through Doppler Airlock (which calls HolographFactory.create())
2. Airlock handles auction mechanics and initial distribution
3. HolographFactory deploys HolographERC20 with deterministic CREATE2 address
4. FeeRouter automatically set as integrator for trading fee collection
5. Token address consistent across supported chains (primarily Base and Ethereum)

## Fee Model

- **Source**: Trading fees from Doppler auctions (collected by Airlock contracts)
- **Protocol Split**: 50% of collected fees (HOLO_FEE_BPS = 5000)
- **Treasury Split**: 50% of collected fees forwarded to treasury address
- **HLG Distribution**: Protocol fees bridged to Ethereum, swapped WETH→HLG, configurable burn/stake split (default 50% burned / 50% staked)
- **Security**: Trusted Airlock whitelist prevents unauthorized ETH transfers to FeeRouter

## Integration

### Token Launch via TypeScript

Use the provided TypeScript utility in the `script/` directory to create tokens through Doppler:

```bash
# Set environment variables
export PRIVATE_KEY=0x...
export BASESCAN_API_KEY=your_api_key

# Create a token
npm run create-token
```

Or programmatically:

```typescript
import { createToken, TokenConfig } from './script/create-token.js'
import { parseEther } from 'viem'

const config: TokenConfig = {
  name: "MyToken",
  symbol: "MTK",
  initialSupply: parseEther("1000000"),
  minProceeds: parseEther("100"),
  maxProceeds: parseEther("10000"),
  auctionDurationDays: 3
}

const result = await createToken(config, process.env.PRIVATE_KEY)
```

### Direct Factory Authorization

For authorized Airlock contracts:

```solidity
// Only callable by authorized Doppler Airlock contracts
bytes memory tokenData = abi.encode(
    name,
    symbol,
    yearlyMintCap,
    vestingDuration,
    recipients,
    amounts,
    tokenURI
);

address token = holographFactory.create(
    initialSupply,
    recipient,
    owner,
    salt,
    tokenData
);
```

### Owner Operations

```solidity
// Collect fees from Doppler Airlock (Owner only)
feeRouter.collectAirlockFees(airlockAddress, tokenAddress, amount);

// Bridge accumulated fees (Owner only)
feeRouter.bridge(minGas, minHlgOut);
```

## Security

### Access Control

- **Owner**: Contract administration, trusted remote management, treasury updates
- **Owner-Only Operations**: All fee operations now require owner permissions (no keeper role)
- **FeeRouter Authorization**: Only designated FeeRouter can add rewards to StakingRewards
- **Airlock Authorization**: Only whitelisted Doppler Airlock contracts can create tokens

### Deployment Security

- **Salt Validation**: HolographDeployer requires first 20 bytes of salt to match sender address
- **Deterministic Addresses**: CREATE2 ensures consistent addresses, preventing address confusion
- **Griefing Protection**: Salt validation prevents malicious actors from front-running deployments
- **Signed Deployments**: Support for gasless deployment with signature verification

### Cross-Chain Security

- **Trusted Remotes**: Per-endpoint whitelist of authorized cross-chain message senders
- **Endpoint Validation**: LayerZero V2 endpoint verification for all cross-chain messages
- **Trusted Airlocks**: Whitelist preventing unauthorized ETH transfers to FeeRouter
- **Replay Protection**: Nonce-based system preventing message replay attacks

### Economic Security

- **Dust Protection**: MIN_BRIDGE_VALUE (0.01 ETH) prevents uneconomical bridging
- **Slippage Protection**: Configurable minimum HLG output for swaps
- **Cooldown Period**: 7-day default withdrawal cooldown prevents staking manipulation
- **Emergency Controls**: Owner can pause all major contract functions

## Gas Analysis

Simple gas cost analysis for referral reward distribution campaigns.

### Usage

```bash
# Analyze costs for distributing rewards to 5,000 users
make gas-analysis
```

### What It Provides

**Essential Information:**
- Current ETH price (live from Chainlink oracle)
- Gas cost per user (measured via mainnet fork testing)
- Total costs in USD and ETH across different gas price scenarios
- Optimal batch size and execution plan
- Best timing for execution

**Sample Output:**
```
Current ETH Price: $3,669 (live via Chainlink)
Gas per user: 1,139 (measured on mainnet fork)
Optimal batch size: 500 users

== COST BREAKDOWN (ETH Gas Fees Only) ==
+--------------+---------------+---------------+--------------+
| Gas Price    | Total Cost    | Cost/User     | ETH Cost     |
+--------------+---------------+---------------+--------------+
| 0.2 gwei     | $4.18         | $0.0008       | 0.001 ETH    |
| 0.5 gwei     | $10.45        | $0.002        | 0.003 ETH    |
| 1 gwei       | $20.89        | $0.004        | 0.006 ETH    |
| 2 gwei       | $41.79        | $0.008        | 0.011 ETH    |
| 5 gwei       | $104.48       | $0.02         | 0.028 ETH    |
| 10 gwei      | $208.96       | $0.04         | 0.057 ETH    |
+--------------+---------------+---------------+--------------+

NOTE: These are ETH gas costs only. HLG tokens must be provided separately.
```

### Key Points

- **Very low costs** due to current gas environment (0.2-2 gwei typical)
- **Best timing**: Weekends 2-6 AM UTC for lowest gas prices  
- **Gas costs only**: HLG tokens for rewards must be provided separately
- **Monitor gas prices**: Use https://etherscan.io/gastracker before execution
- **Current efficiency**: ~1,139 gas per user with optimized batch operations

## Testing

```bash
# Run all tests
forge test

# Unit tests
forge test --match-path test/unit/

# Integration tests
forge test --match-path test/integration/

# Gas reports
forge test --gas-report
```

## Environment Setup

Set up the following environment variables for deployment and operations:

```bash
# Network RPCs
export BASE_RPC="https://mainnet.base.org"
export ETH_RPC="https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY"

# Private Keys
export DEPLOYER_PK="0x..."      # Contract deployment
export OWNER_PK="0x..."         # Contract administration
export KEEPER_PK="0x..."        # Automation operations

# LayerZero Endpoint IDs
export BASE_EID=30184           # Base mainnet
export ETH_EID=30101            # Ethereum mainnet

# Contract Addresses (update after deployment)
export DOPPLER_AIRLOCK="0x..."
export LZ_ENDPOINT="0x..."      # LayerZero V2 endpoint
export TREASURY="0x..."         # Treasury multisig
export HLG="0x..."              # HLG token address
export WETH="0x..."             # WETH address
export SWAP_ROUTER="0x..."      # Uniswap V3 SwapRouter
export STAKING_REWARDS="0x..."  # StakingRewards contract

# Addresses (set after deployment)
export FEE_ROUTER="0x..."
export HOLOGRAPH_FACTORY="0x..."
export KEEPER_ADDRESS="0x..."
```

## Deployment Infrastructure

### HolographDeployer

All Holograph contracts are deployed through the HolographDeployer system, which ensures deterministic addresses across chains:

- **CREATE2 Deployment**: Contracts have identical addresses on all chains
- **Salt Validation**: First 20 bytes of salt must match deployer address to prevent griefing
- **Batch Operations**: Deploy and initialize contracts in a single transaction
- **Signed Deployments**: Support for gasless deployment via signed messages

### Deployment Process

> **💡 Quick Start**: Use the simplified Makefile commands documented in the [Development & Deployment](#development--deployment) section above for streamlined deployment.

#### Using Makefile (Recommended)

```bash
# Set up environment
export BROADCAST=true
export DEPLOYER_PK=0x...
export BASE_RPC_URL=https://mainnet.base.org
export ETHEREUM_RPC_URL=https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY
export UNICHAIN_RPC_URL=https://mainnet.unichain.org

# Deploy to primary chains
make deploy-base deploy-eth

# Optionally add Unichain
make deploy-unichain
```

### Manual Deployment (Advanced)

For advanced users who need more control over deployment parameters:

#### Base Chain

```bash
# Deploy using deployment script
forge script script/DeployBase.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast --private-key $DEPLOYER_PK \
  --verify --etherscan-api-key $BASESCAN_API_KEY
```

#### Ethereum Chain

```bash
# Deploy using deployment script
forge script script/DeployEthereum.s.sol \
  --rpc-url $ETHEREUM_RPC_URL \
  --broadcast --private-key $DEPLOYER_PK \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

#### Unichain

```bash
# Deploy using deployment script
forge script script/DeployUnichain.s.sol \
  --rpc-url $UNICHAIN_RPC_URL \
  --broadcast --private-key $DEPLOYER_PK \
  --verify --etherscan-api-key $UNISCAN_API_KEY
```

## Operations

### Initial Setup

After deployment, configure the system using the fee operations script:

```bash
# 1. Update script/FeeOperations.s.sol with actual Airlock addresses
# 2. Whitelist Airlock contracts (Owner only)
make fee-setup BROADCAST=true

# Note: All operations are owner-only (no keeper role needed)

# 4. Configure LayerZero trusted remotes
cast send $FEE_ROUTER "setTrustedRemote(uint32,bytes32)" \
  $ETH_EID $(cast address-to-bytes32 $ETH_FEE_ROUTER) \
  --rpc-url $BASE_RPC --private-key $OWNER_PK

cast send $FEE_ROUTER "setTrustedRemote(uint32,bytes32)" \
  $BASE_EID $(cast address-to-bytes32 $BASE_FEE_ROUTER) \
  --rpc-url $ETH_RPC --private-key $OWNER_PK
```

### Keeper Automation

```bash
# Monitor system status
make fee-status

# Run fee collection and bridging (automated/cron)
make fee-ops BROADCAST=true

# Set up automated execution (example cron)
echo "*/10 * * * * cd /path/to/holograph && make fee-ops BROADCAST=true" | crontab -
```

### Emergency Controls

```bash
# Emergency treasury redirection (Owner only)
forge script script/FeeOperations.s.sol \
  --sig "emergencyRedirect(address)" $EMERGENCY_TREASURY \
  --rpc-url $BASE_RPC --broadcast --private-key $OWNER_PK

# Unpause operations (Owner only)
cast send $FEE_ROUTER "unpause()" \
  --rpc-url $BASE_RPC --private-key $OWNER_PK

# Update treasury address (Owner only)
cast send $FEE_ROUTER "setTreasury(address)" $NEW_TREASURY \
  --rpc-url $BASE_RPC --private-key $OWNER_PK
```

## Dependencies

- **LayerZero V2**: Cross-chain messaging protocol
- **Doppler Airlock**: Token launch mechanism
- **OpenZeppelin**: Access control and security utilities
- **Uniswap V3**: WETH/HLG swapping on Ethereum

## Quick Reference

### Common Tasks

```bash
# Check system status
make fee-status

# Manual fee collection
make fee-collect BROADCAST=true

# Emergency treasury redirect
forge script script/FeeOperations.s.sol --sig "emergencyRedirect(address)" $EMERGENCY_TREASURY --rpc-url $BASE_RPC --broadcast --private-key $OWNER_PK

# Check FeeRouter ETH balance
cast balance $FEE_ROUTER --rpc-url $BASE_RPC
```

### Future Campaign System

The StakingRewards contract includes a **distributor system** for future campaigns without requiring pauses or owner gas costs:

**Distributor Benefits**:
- **User-pays-gas**: Claimants pay their own gas, not the treasury
- **No pause required**: Works while the pool is live 24/7
- **Multiple campaigns**: Deploy separate distributors for each campaign
- **Unclaimed recovery**: Distributors can recover unclaimed tokens
- **Flexible mechanics**: Supports Merkle drops, quests, bug bounties, etc.

**Campaign Flow**:
```solidity
// 1. Deploy campaign distributor (e.g., MerkleDistributor)
MerkleDistributor distributor = new MerkleDistributor(
    hlg, stakingRewards, merkleRoot, allocation, duration, owner
);

// 2. Whitelist distributor in StakingRewards
stakingRewards.setDistributor(address(distributor), true);

// 3. Fund distributor with HLG budget
hlg.transfer(address(distributor), totalAllocation);

// 4. Users claim via distributor (gas paid by user)
distributor.claim(amount, merkleProof); // Automatically stakes in StakingRewards
```

**Example Use Cases**:
- **Merkle Airdrops**: Users claim with proofs, tokens auto-stake
- **Trading Quests**: Complete tasks, claim rewards that auto-stake  
- **Bug Bounties**: Submit reports, receive staked HLG rewards
- **Liquidity Mining**: Provide liquidity, claim periodic staked rewards

**Deploy Campaign Distributor**:
```bash
make deploy-merkle-distributor  # Example Merkle campaign deployment

# Check if Airlock is whitelisted
cast call $FEE_ROUTER "trustedAirlocks(address)" $AIRLOCK_ADDRESS --rpc-url $BASE_RPC

# Setup trusted Airlocks
make fee-setup BROADCAST=true
```

### Monitoring

- **FeeRouter Balance**: Should accumulate fees between fee operations
- **Trusted Airlocks**: Must be whitelisted before fee collection
- **LayerZero Messages**: Monitor cross-chain message delivery
- **HLG Distribution**: Verify burn/stake operations on Ethereum

### Troubleshooting

- **"UntrustedSender" Error**: Airlock not whitelisted - run `setupTrustedAirlocks()`
- **"AccessControl" Error**: Address missing owner permissions (all operations are owner-only)
- **Bridge Failures**: Check LayerZero trusted remotes configuration
- **Low HLG Output**: Adjust slippage protection or check Uniswap liquidity

## Documentation

Additional technical documentation is available in the [`docs/`](docs/) directory:

- **[Scripts Overview](docs/SCRIPTS_OVERVIEW.md)** - Deployment and operational scripts guide
- **[Token Creation](docs/CREATE_TOKEN.md)** - TypeScript utility for creating tokens
- **[DVN Configuration](docs/DVN_CONFIGURATION.md)** - LayerZero V2 security setup  
- **[Operations Guide](docs/OPERATIONS.md)** - System monitoring and management
- **[Upgrade Guide](docs/UPGRADE_GUIDE.md)** - Contract upgrade procedures

## License

MIT
