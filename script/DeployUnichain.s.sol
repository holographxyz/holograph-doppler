// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title DeployUnichain
 * @notice Foundry script to deploy HolographFactory and HolographBridge on Unichain
 * @dev Focuses on Base-Unichain integration for omnichain token expansion
 *
 * Usage examples (from repository root):
 *   // Dry-run against a live fork
 *   forge script script/DeployUnichain.s.sol \
 *       --fork-url $UNICHAIN_RPC
 *
 *   // Broadcast real transactions (requires DEPLOYER_PK)
 *   forge script script/DeployUnichain.s.sol \
 *       --rpc-url $UNICHAIN_RPC \
 *       --broadcast \
 *       --private-key $DEPLOYER_PK
 *
 *   // Verify on explorer (after propagation)
 *   # factory
 *   forge verify-contract --chain-id 1301 $(cat deployments/unichain/HolographFactory.txt) src/HolographFactory.sol:HolographFactory $UNISCAN_API_KEY
 *   # bridge
 *   forge verify-contract --chain-id 1301 $(cat deployments/unichain/HolographBridge.txt) src/HolographBridge.sol:HolographBridge $UNISCAN_API_KEY
 */

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/HolographFactory.sol";
import "../src/HolographBridge.sol";

contract DeployUnichain is Script {
    /* -------------------------------------------------------------------------- */
    /*                                Constants                                   */
    /* -------------------------------------------------------------------------- */
    uint256 internal constant UNICHAIN_MAINNET = 1301;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;  // Update when Unichain Sepolia is available
    
    // LayerZero V2 Endpoint IDs
    uint32 internal constant UNICHAIN_MAINNET_EID = 30338;

    /* -------------------------------------------------------------------------- */
    /*                                   Run                                      */
    /* -------------------------------------------------------------------------- */
    function run() external {
        /* -------------------------------- Env --------------------------------- */
        // Toggle on-chain broadcasting via env var so we don't need to pass `--broadcast` every run
        bool shouldBroadcast = vm.envOr("BROADCAST", false);

        // Only require / read the private key if we intend to broadcast
        uint256 deployerPk = shouldBroadcast ? vm.envUint("DEPLOYER_PK") : uint256(0);

        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");

        // Quick sanity checks
        require(lzEndpoint != address(0), "LZ_ENDPOINT not set");

        /* ----------------------------- Chain guard ---------------------------- */
        if (block.chainid != UNICHAIN_MAINNET && block.chainid != UNICHAIN_SEPOLIA) {
            console.log("[WARNING] Chain ID does not match known Unichain chains");
        }

        console.log("Deploying to chainId", block.chainid);
        if (shouldBroadcast) {
            console.log("Broadcasting TXs as", vm.addr(deployerPk));
            vm.startBroadcast(deployerPk);
        } else {
            console.log("Running in dry-run mode (no broadcast)");
            vm.startBroadcast();
        }

        uint256 gasStart = gasleft();
        // Deploy HolographFactory with LayerZero endpoint
        HolographFactory factory = new HolographFactory(lzEndpoint);
        uint256 gasFactory = gasStart - gasleft();

        gasStart = gasleft();
        // Deploy HolographBridge for cross-chain token expansion
        HolographBridge bridge = new HolographBridge(lzEndpoint, address(factory), UNICHAIN_MAINNET_EID);
        uint256 gasBridge = gasStart - gasleft();

        vm.stopBroadcast();

        console.log("---------------- Deployment Complete ----------------");
        console.log("HolographFactory deployed at:", address(factory));
        console.log("Gas used:", gasFactory);
        console.log("HolographBridge deployed at:", address(bridge));
        console.log("Gas used:", gasBridge);

        /* ----------------------- Persist addresses locally -------------------- */
        // Creates simple text files with addresses under deployments/unichain/
        string memory dir = "deployments/unichain";
        vm.createDir(dir, true);
        vm.writeFile(string.concat(dir, "/HolographFactory.txt"), vm.toString(address(factory)));
        vm.writeFile(string.concat(dir, "/HolographBridge.txt"), vm.toString(address(bridge)));
    }
}