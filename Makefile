# ---------------------------------------------------------------------------- #
#                          Holograph Protocol Makefile                         #
# ---------------------------------------------------------------------------- #

GREEN := \033[0;32m
YELLOW := \033[0;33m
RED   := \033[0;31m
NC    := \033[0m

# Load environment variables
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

# ---------------------------------------------------------------------------- #
#                                   Helpers                                   #
# ---------------------------------------------------------------------------- #

# Optional BROADCAST=true to actually send txs
ifeq ($(BROADCAST),true)
    FORGE_FLAGS := --broadcast --private-key $(DEPLOYER_PK)
else
    FORGE_FLAGS :=
endif

print-success = @echo "$(GREEN)✅ $1 completed$(NC)\n"
print-step    = @echo "$(YELLOW)$1$(NC)"

# ---------------------------------------------------------------------------- #
#                                   Targets                                   #
# ---------------------------------------------------------------------------- #
.PHONY: all help fmt build clean test deploy-base deploy-base-sepolia deploy-eth deploy-eth-sepolia deploy-unichain deploy-unichain-sepolia configure-base configure-eth configure-unichain configure-dvn-base configure-dvn-eth fee-ops abi verify-addresses gas-analysis

## all: Build and test (default target)
all: build test

## help: Show this help.
help:
	@grep -E '^##' $(MAKEFILE_LIST) | sed -E 's/##[ ]*//g'

## fmt: Format Solidity code with forge fmt.
fmt:
	$(call print-step,Formatting sources...)
	forge fmt
	$(call print-success,Format)

## build: Compile the project.
build:
	$(call print-step,Building…)
	forge build
	$(call print-success,Build)

## clean: Remove forge artifacts.
clean:
	$(call print-step,Cleaning artifacts…)
	forge clean
	$(call print-success,Clean)

## test: Run all Forge tests.
test: build
	$(call print-step,Running tests…)
	forge test -vvv
	$(call print-success,Tests)

## deploy-base-sepolia: Deploy FeeRouter + Factory on Base Sepolia (testnet).
deploy-base-sepolia:
	@if [ -z "$(BASE_SEPOLIA_RPC_URL)" ]; then echo "$(RED)BASE_SEPOLIA_RPC_URL not set$(NC)"; exit 1; fi
	@if [ -z "$(BASESCAN_API_KEY)" ]; then echo "$(RED)BASESCAN_API_KEY not set$(NC)"; exit 1; fi
	$(call print-step,Deploying to Base Sepolia…)
	forge script script/DeployBase.s.sol --rpc-url $(BASE_SEPOLIA_RPC_URL) $(FORGE_FLAGS) --verify --etherscan-api-key $(BASESCAN_API_KEY)
	$(call print-success,Base Sepolia deploy)

## deploy-base: Deploy FeeRouter + Factory on Base mainnet.
deploy-base:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "$(RED)BASE_RPC_URL not set$(NC)"; exit 1; fi
	@if [ -z "$(BASESCAN_API_KEY)" ]; then echo "$(RED)BASESCAN_API_KEY not set$(NC)"; exit 1; fi
	$(call print-step,Deploying to Base mainnet…)
	forge script script/DeployBase.s.sol --rpc-url $(BASE_RPC_URL) $(FORGE_FLAGS) --verify --etherscan-api-key $(BASESCAN_API_KEY)
	$(call print-success,Base mainnet deploy)

## deploy-eth-sepolia: Deploy StakingRewards + FeeRouter on Ethereum Sepolia (testnet).
deploy-eth-sepolia:
	@if [ -z "$(ETHEREUM_SEPOLIA_RPC_URL)" ]; then echo "$(RED)ETHEREUM_SEPOLIA_RPC_URL not set$(NC)"; exit 1; fi
	@if [ -z "$(ETHERSCAN_API_KEY)" ]; then echo "$(RED)ETHERSCAN_API_KEY not set$(NC)"; exit 1; fi
	$(call print-step,Deploying to Ethereum Sepolia…)
	forge script script/DeployEthereum.s.sol --rpc-url $(ETHEREUM_SEPOLIA_RPC_URL) $(FORGE_FLAGS) --verify --etherscan-api-key $(ETHERSCAN_API_KEY)
	$(call print-success,Ethereum Sepolia deploy)

## deploy-eth: Deploy StakingRewards + FeeRouter on Ethereum mainnet.
deploy-eth:
	@if [ -z "$(ETHEREUM_RPC_URL)" ]; then echo "$(RED)ETHEREUM_RPC_URL not set$(NC)"; exit 1; fi
	@if [ -z "$(ETHERSCAN_API_KEY)" ]; then echo "$(RED)ETHERSCAN_API_KEY not set$(NC)"; exit 1; fi
	$(call print-step,Deploying to Ethereum mainnet…)
	forge script script/DeployEthereum.s.sol --rpc-url $(ETHEREUM_RPC_URL) $(FORGE_FLAGS) --verify --etherscan-api-key $(ETHERSCAN_API_KEY)
	$(call print-success,Ethereum mainnet deploy)

## deploy-unichain-sepolia: Deploy Factory on Unichain Sepolia (testnet).
deploy-unichain-sepolia:
	@if [ -z "$(UNICHAIN_SEPOLIA_RPC_URL)" ]; then echo "$(RED)UNICHAIN_SEPOLIA_RPC_URL not set$(NC)"; exit 1; fi
	@if [ -z "$(UNISCAN_API_KEY)" ]; then echo "$(RED)UNISCAN_API_KEY not set$(NC)"; exit 1; fi
	$(call print-step,Deploying to Unichain Sepolia…)
	forge script script/DeployUnichain.s.sol --rpc-url $(UNICHAIN_SEPOLIA_RPC_URL) $(FORGE_FLAGS) --verify --etherscan-api-key $(UNISCAN_API_KEY)
	$(call print-success,Unichain Sepolia deploy)

## deploy-unichain: Deploy Factory on Unichain mainnet.
deploy-unichain:
	@if [ -z "$(UNICHAIN_RPC_URL)" ]; then echo "$(RED)UNICHAIN_RPC_URL not set$(NC)"; exit 1; fi
	@if [ -z "$(UNISCAN_API_KEY)" ]; then echo "$(RED)UNISCAN_API_KEY not set$(NC)"; exit 1; fi
	$(call print-step,Deploying to Unichain mainnet…)
	forge script script/DeployUnichain.s.sol --rpc-url $(UNICHAIN_RPC_URL) $(FORGE_FLAGS) --verify --etherscan-api-key $(UNISCAN_API_KEY)
	$(call print-success,Unichain mainnet deploy)

## configure-base: Run Configure.s.sol against Base.
configure-base:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "$(RED)BASE_RPC_URL not set$(NC)"; exit 1; fi
	$(call print-step,Configuring Base FeeRouter…)
	forge script script/Configure.s.sol --rpc-url $(BASE_RPC_URL) $(FORGE_FLAGS)
	$(call print-success,Base config)

## configure-eth: Run Configure.s.sol against Ethereum.
configure-eth:
	@if [ -z "$(ETHEREUM_RPC_URL)" ]; then echo "$(RED)ETHEREUM_RPC_URL not set$(NC)"; exit 1; fi
	$(call print-step,Configuring Ethereum FeeRouter…)
	forge script script/Configure.s.sol --rpc-url $(ETHEREUM_RPC_URL) $(FORGE_FLAGS)
	$(call print-success,Ethereum config)

## configure-unichain: Run Configure.s.sol against Unichain.
configure-unichain:
	@if [ -z "$(UNICHAIN_RPC_URL)" ]; then echo "$(RED)UNICHAIN_RPC_URL not set$(NC)"; exit 1; fi
	$(call print-step,Configuring Unichain Factory + Bridge…)
	forge script script/Configure.s.sol --rpc-url $(UNICHAIN_RPC_URL) $(FORGE_FLAGS)
	$(call print-success,Unichain config)

## configure-dvn-base: Configure LayerZero V2 DVN security stack on Base.
configure-dvn-base:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "$(RED)BASE_RPC_URL not set$(NC)"; exit 1; fi
	@if [ ! -f "deployments/base/FeeRouter.txt" ]; then echo "$(RED)Base FeeRouter not deployed (run deploy-base first)$(NC)"; exit 1; fi
	$(call print-step,Configuring Base DVN security stack…)
	@echo "$(YELLOW)Using FeeRouter: $$(cat deployments/base/FeeRouter.txt)$(NC)"
	FEE_ROUTER=$$(cat deployments/base/FeeRouter.txt) \
	LZ_ENDPOINT=$(BASE_LZ_ENDPOINT) \
	REMOTE_EID=$(ETH_EID) \
	forge script script/ConfigureDVN.s.sol --rpc-url $(BASE_RPC_URL) $(FORGE_FLAGS)
	$(call print-success,Base DVN config)

## configure-dvn-eth: Configure LayerZero V2 DVN security stack on Ethereum.
configure-dvn-eth:
	@if [ -z "$(ETHEREUM_RPC_URL)" ]; then echo "$(RED)ETHEREUM_RPC_URL not set$(NC)"; exit 1; fi
	@if [ ! -f "deployments/ethereum/FeeRouter.txt" ]; then echo "$(RED)Ethereum FeeRouter not deployed (run deploy-eth first)$(NC)"; exit 1; fi
	$(call print-step,Configuring Ethereum DVN security stack…)
	@echo "$(YELLOW)Using FeeRouter: $$(cat deployments/ethereum/FeeRouter.txt)$(NC)"
	FEE_ROUTER=$$(cat deployments/ethereum/FeeRouter.txt) \
	LZ_ENDPOINT=$(ETH_LZ_ENDPOINT) \
	REMOTE_EID=$(BASE_EID) \
	forge script script/ConfigureDVN.s.sol --rpc-url $(ETHEREUM_RPC_URL) $(FORGE_FLAGS)
	$(call print-success,Ethereum DVN config)

## fee-ops: Execute fee collection and bridging operations on Base.
fee-ops:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "$(RED)BASE_RPC_URL not set$(NC)"; exit 1; fi
	$(call print-step,Running fee operations…)
	forge script script/FeeOperations.s.sol --sig "fullFeeProcessing()" --rpc-url $(BASE_RPC_URL) $(FORGE_FLAGS)
	$(call print-success,Fee operations completed)

## fee-collect: Collect fees from Doppler Airlocks.
fee-collect:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "$(RED)BASE_RPC_URL not set$(NC)"; exit 1; fi
	$(call print-step,Collecting fees from Airlocks…)
	forge script script/FeeOperations.s.sol --sig "collectFees()" --rpc-url $(BASE_RPC_URL) $(FORGE_FLAGS)
	$(call print-success,Fee collection completed)

## fee-bridge: Bridge accumulated fees to Ethereum.
fee-bridge:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "$(RED)BASE_RPC_URL not set$(NC)"; exit 1; fi
	$(call print-step,Bridging fees to Ethereum…)
	forge script script/FeeOperations.s.sol --sig "bridgeToEthereum()" --rpc-url $(BASE_RPC_URL) $(FORGE_FLAGS)
	$(call print-success,Fee bridging completed)

## fee-status: Check FeeRouter system status and balances.
fee-status:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "$(RED)BASE_RPC_URL not set$(NC)"; exit 1; fi
	$(call print-step,Checking FeeRouter status…)
	forge script script/FeeOperations.s.sol --sig "checkSystemStatus()" --rpc-url $(BASE_RPC_URL)

## fee-setup: Setup trusted Airlocks (run once after deployment).
fee-setup:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "$(RED)BASE_RPC_URL not set$(NC)"; exit 1; fi
	$(call print-step,Setting up trusted Airlocks…)
	forge script script/FeeOperations.s.sol --sig "setupTrustedAirlocks()" --rpc-url $(BASE_RPC_URL) $(FORGE_FLAGS)
	$(call print-success,Airlock setup completed)

## verify-addresses: Verify deployed contract addresses are consistent across chains.
verify-addresses:
	$(call print-step,Verifying deployment addresses…)
	forge script script/VerifyAddresses.s.sol
	$(call print-success,Address verification)

## abi: Generate ABI JSON files from build artifacts.
abi: build
	$(call print-step,Generating ABIs…)
	bash script/_generate_abis.sh
	$(call print-success,ABI generation)

## gas-analysis: Run gas cost analysis for referral campaign (5,000 users).
gas-analysis:
	$(call print-step,Analyzing gas costs for referral campaign…)
	forge script script/GasAnalysis.s.sol:GasAnalysis --fork-url https://ethereum-rpc.publicnode.com -vv
	$(call print-success,Gas analysis)

## deploy-merkle-distributor: Deploy MerkleDistributor for future campaigns.
deploy-merkle-distributor:
	$(call print-step,Deploying MerkleDistributor for campaign…)
	forge script script/DeployMerkleDistributor.s.sol:DeployMerkleDistributor --fork-url $(ETHEREUM_RPC_URL) $(BROADCAST_FLAG) --verify
	$(call print-success,MerkleDistributor deployment) 