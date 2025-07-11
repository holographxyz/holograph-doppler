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
.PHONY: all help fmt build clean test deploy-base deploy-eth deploy-unichain configure-base configure-eth configure-unichain keeper abi

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

## deploy-base: Deploy FeeRouter + Factory + Bridge on Base.
deploy-base:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "$(RED)BASE_RPC_URL not set$(NC)"; exit 1; fi
	@if [ -z "$(BASESCAN_API_KEY)" ]; then echo "$(RED)BASESCAN_API_KEY not set$(NC)"; exit 1; fi
	$(call print-step,Deploying to Base…)
	forge script script/DeployBase.s.sol --rpc-url $(BASE_RPC_URL) $(FORGE_FLAGS) --verify --etherscan-api-key $(BASESCAN_API_KEY)
	$(call print-success,Base deploy)

## deploy-eth: Deploy StakingRewards + FeeRouter on Ethereum.
deploy-eth:
	@if [ -z "$(ETHEREUM_RPC_URL)" ]; then echo "$(RED)ETHEREUM_RPC_URL not set$(NC)"; exit 1; fi
	@if [ -z "$(ETHERSCAN_API_KEY)" ]; then echo "$(RED)ETHERSCAN_API_KEY not set$(NC)"; exit 1; fi
	$(call print-step,Deploying to Ethereum…)
	forge script script/DeployEthereum.s.sol --rpc-url $(ETHEREUM_RPC_URL) $(FORGE_FLAGS) --verify --etherscan-api-key $(ETHERSCAN_API_KEY)
	$(call print-success,Ethereum deploy)

## deploy-unichain: Deploy Factory + Bridge on Unichain.
deploy-unichain:
	@if [ -z "$(UNICHAIN_RPC_URL)" ]; then echo "$(RED)UNICHAIN_RPC_URL not set$(NC)"; exit 1; fi
	@if [ -z "$(UNISCAN_API_KEY)" ]; then echo "$(RED)UNISCAN_API_KEY not set$(NC)"; exit 1; fi
	$(call print-step,Deploying to Unichain…)
	forge script script/DeployUnichain.s.sol --rpc-url $(UNICHAIN_RPC_URL) $(FORGE_FLAGS) --verify --etherscan-api-key $(UNISCAN_API_KEY)
	$(call print-success,Unichain deploy)

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

## keeper: Execute KeeperPullAndBridge on Base.
keeper:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "$(RED)BASE_RPC_URL not set$(NC)"; exit 1; fi
	$(call print-step,Running keeper…)
	forge script script/KeeperPullAndBridge.s.sol --rpc-url $(BASE_RPC_URL) $(FORGE_FLAGS)
	$(call print-success,Keeper run)

## abi: Generate ABI JSON files from build artifacts.
abi: build
	$(call print-step,Generating ABIs…)
	bash script/generate_abis.sh
	$(call print-success,ABI generation) 