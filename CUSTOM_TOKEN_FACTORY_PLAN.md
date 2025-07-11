# Custom Token Factory Implementation Plan

## ⚠️ DISCLAIMER FOR CLAUDE CODE

**This plan is a high-level architectural guide. Before implementing, Claude Code MUST:**

1. **Validate against actual codebase**: Review the current `/src`, `/test`, and `/script` directories to understand existing implementations, patterns, and dependencies
2. **Cross-reference Doppler documentation**: Verify integration patterns and requirements against [Doppler V4 SDK docs](https://docs.doppler.lol/v4-sdk/overview) and the `/lib/doppler` codebase
3. **Confirm LayerZero OFT implementation**: Validate OFT integration approach against [LayerZero V2 OFT documentation](https://docs.layerzero.network/v2/developers/evm/oft/quickstart)
4. **Adjust implementation details**: Modify contracts, interfaces, and test patterns based on actual code structure and existing conventions
5. **Update dependencies**: Ensure all required imports, interfaces, and dependencies are correctly identified from the actual codebase

**This plan provides direction, not implementation details. Adapt as needed based on code analysis.**

---

## Overview

This plan outlines the implementation of a custom token factory that integrates with the Doppler Airlock system. The goal is to deploy custom omnichain tokens using LayerZero's OFT (Omnichain Fungible Token) standard through the Doppler ecosystem while maintaining compatibility with our existing FeeRouter architecture.

## Current Architecture Analysis

### Existing Components

- **HolographFactory**: Currently acts as a wrapper around Doppler Airlock
- **FeeRouter**: Processes fees from Doppler integrations (1.5% protocol, 98.5% treasury)
- **StakingRewards**: Distributes HLG rewards to stakers
- **Doppler Integration**: Uses standard DERC20 tokens via Doppler's TokenFactory

### Current Flow

```
User → HolographFactory.createToken() → Airlock.create() → DERC20 Token
                                     ↓
                              FeeRouter (as integrator)
```

## Proposed Architecture

### New Flow

```
User → Airlock.create() → HolographFactory.create() → HolographERC20 (LayerZero OFT)
                       ↓
              FeeRouter (as integrator) → Fee Processing
                       ↓
              Automatic omnichain bridging via LayerZero OFT
```

## Implementation Requirements

### Core Components

#### 1. **HolographERC20 Token Contract**

- **File**: `src/HolographERC20.sol`
- **Requirement**: Extend LayerZero's OFT standard for omnichain functionality
- **Documentation**: [LayerZero OFT Foundry Implementation](https://docs.layerzero.network/v2/developers/evm/oft/quickstart)
- **Instructions**: Claude Code should read the LayerZero documentation and implement the Foundry version of OFT

#### 2. **HolographFactory as Token Factory**

- **File**: `src/HolographFactory.sol` (refactor existing)
- **Requirement**: Implement `ITokenFactory` interface for Doppler compatibility
- **Functionality**: Deploy HolographERC20 instances when called by Airlock
- **Integration**: Remove current wrapper logic, implement direct token factory pattern

#### 3. **FeeRouter as Integrator**

- **File**: `src/FeeRouter.sol` (minimal changes)
- **Role**: Act as the direct integrator receiving fees from Airlock
- **Configuration**: Maintain existing fee processing logic (1.5%/98.5% split)

#### 4. **HolographBridge Contract**

- **File**: `src/HolographBridge.sol` (new contract)
- **Purpose**: Abstract cross-chain coordination and LayerZero messaging logic
- **Integration**: Works with HolographERC20 tokens for omnichain operations
- **Functionality**: Handle cross-chain peer management, configuration, and coordination

### Integration Patterns

#### Doppler Airlock Integration

- **CreateParams Structure**: Reference [Doppler V4 SDK Examples](https://docs.doppler.lol/v4-sdk/examples#example-2-no-op-governance-launch-100-locked-liquidity)
- **Pattern**: Users call `Airlock.create()` directly with `HolographFactory` as the `tokenFactory`
- **Fee Flow**: `FeeRouter` specified as `integrator` in CreateParams

#### LayerZero Cross-Chain Setup

- **Deployment**: Deploy `HolographFactory` and `HolographBridge` on each target chain
- **Peer Configuration**: Use `HolographBridge` to manage LayerZero OFT peer relationships
- **Coordination**: `HolographBridge` handles cross-chain configuration and messaging
- **Token Bridging**: Automatic via LayerZero OFT standard integrated with HolographBridge

## Technical References

### LayerZero OFT Implementation

- **Documentation**: [LayerZero OFT Foundry Quickstart](https://docs.layerzero.network/v2/developers/evm/oft/quickstart)
- **Requirement**: Claude Code must read and implement the Foundry-specific OFT pattern
- **Benefits**: Automatic omnichain capabilities, unified supply management, proven security

### Doppler Integration

- **CreateParams Reference**: [Doppler V4 SDK Examples](https://docs.doppler.lol/v4-sdk/examples#example-2-no-op-governance-launch-100-locked-liquidity)
- **Requirement**: Claude Code must structure CreateParams according to Doppler documentation
- **Integration**: HolographFactory as tokenFactory, FeeRouter as integrator

## Action Plan for Claude Code

**Claude Code should create a comprehensive implementation plan by:**

1. **Analyzing Current Codebase**
   - Review existing `/src`, `/test`, and `/script` directories
   - Understand current HolographFactory implementation patterns
   - Identify existing interfaces and dependencies

2. **Reading Documentation**
   - Study [LayerZero OFT Foundry Implementation](https://docs.layerzero.network/v2/developers/evm/oft/quickstart)
   - Review [Doppler V4 SDK Examples](https://docs.doppler.lol/v4-sdk/examples#example-2-no-op-governance-launch-100-locked-liquidity) for CreateParams structure
   - Examine `/lib/doppler` codebase for integration patterns

3. **Creating Implementation Strategy**
   - Design HolographERC20 contract extending LayerZero OFT
   - Plan HolographFactory refactor as ITokenFactory implementation
   - Determine required test updates and new test files
   - Plan script updates for deployment and configuration

4. **Defining Deployment Approach**
   - Outline deployment sequence across target chains
   - Plan LayerZero peer configuration strategy
   - Define Doppler whitelisting requirements

## File Structure

**Claude Code should organize contracts and interfaces as follows:**

```
src/
├── HolographERC20.sol              # LayerZero OFT-based omnichain token
├── HolographFactory.sol            # Custom token factory (refactored)
├── HolographBridge.sol             # Cross-chain coordination and messaging
├── FeeRouter.sol                   # Existing fee routing (integrator)
├── StakingRewards.sol              # Existing staking rewards
└── interfaces/
    ├── IHolographERC20.sol         # Custom token interface
    ├── IHolographBridge.sol        # Bridge interface
    └── external/doppler/           # Doppler interfaces (existing)

test/
├── HolographERC20.t.sol            # Token unit tests
├── HolographFactory.t.sol          # Factory tests (updated)
├── HolographBridge.t.sol           # Bridge tests
├── FeeRouter.t.sol                 # Existing fee router tests
├── StakingRewards.t.sol            # Existing staking tests
└── integration/
    ├── HolographTokenFlow.t.sol    # End-to-end token creation and bridging
    └── CrossChainFlow.t.sol        # Cross-chain transfer tests

script/
├── DeployBase.s.sol                # Updated Base deployment
├── DeployEthereum.s.sol            # Updated Ethereum deployment
├── CreateHolographToken.s.sol      # Token creation via Airlock
├── ConfigureBridge.s.sol           # Cross-chain bridge configuration
└── TestTokenCreation.s.sol         # Updated test script
```
