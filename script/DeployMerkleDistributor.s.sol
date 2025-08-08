// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployMerkleDistributor
 * @notice Deploy and configure a MerkleDistributor for a campaign
 * @dev Example deployment script for future campaigns
 */
contract DeployMerkleDistributor is Script {
    // Example configuration - would be customized per campaign
    bytes32 constant EXAMPLE_MERKLE_ROOT = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    uint256 constant CAMPAIGN_DURATION_DAYS = 90; // 3 months to claim
    uint256 constant TOTAL_ALLOCATION = 1_000_000 ether; // 1M HLG budget

    function run() external {
        // Load environment variables
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address hlgAddress = vm.envAddress("HLG_TOKEN");
        address stakingRewardsAddress = vm.envAddress("STAKING_REWARDS");

        address deployer = vm.addr(deployerKey);

        console.log("\n== MERKLE DISTRIBUTOR DEPLOYMENT ==");
        console.log("Deployer:", deployer);
        console.log("HLG Token:", hlgAddress);
        console.log("StakingRewards:", stakingRewardsAddress);
        console.log("Campaign Duration:", CAMPAIGN_DURATION_DAYS, "days");
        console.log("Total Allocation:", TOTAL_ALLOCATION / 1e18, "HLG");

        vm.startBroadcast(deployerKey);

        // Deploy MerkleDistributor
        MerkleDistributor distributor = new MerkleDistributor(
            hlgAddress,
            stakingRewardsAddress,
            EXAMPLE_MERKLE_ROOT,
            TOTAL_ALLOCATION,
            CAMPAIGN_DURATION_DAYS,
            deployer // owner
        );

        console.log("\n== DEPLOYMENT COMPLETE ==");
        console.log("MerkleDistributor deployed at:", address(distributor));

        // Whitelist the distributor in StakingRewards
        StakingRewards stakingRewards = StakingRewards(payable(stakingRewardsAddress));
        stakingRewards.setDistributor(address(distributor), true);

        console.log("Distributor whitelisted in StakingRewards");

        // Transfer HLG budget to distributor
        IERC20 hlg = IERC20(hlgAddress);
        uint256 deployerBalance = hlg.balanceOf(deployer);

        console.log("\n== FUNDING DISTRIBUTOR ==");
        console.log("Deployer HLG balance:", deployerBalance / 1e18, "HLG");

        if (deployerBalance >= TOTAL_ALLOCATION) {
            hlg.transfer(address(distributor), TOTAL_ALLOCATION);
            console.log("Transferred", TOTAL_ALLOCATION / 1e18, "HLG to distributor");
        } else {
            console.log("WARNING: Insufficient HLG balance for full allocation");
            console.log("Need:", TOTAL_ALLOCATION / 1e18, "HLG");
            console.log("Have:", deployerBalance / 1e18, "HLG");
        }

        vm.stopBroadcast();

        console.log("\n== CAMPAIGN SETUP COMPLETE ==");
        console.log("Users can now claim rewards with Merkle proofs");
        console.log("Claimed HLG will be automatically staked in StakingRewards");
        console.log("Campaign ends at:", block.timestamp + (CAMPAIGN_DURATION_DAYS * 1 days));
    }
}

/**
 * @title GenerateMerkleTree
 * @notice Utility to generate sample Merkle tree data for testing
 */
contract GenerateMerkleTree is Script {
    struct Recipient {
        address user;
        uint256 amount;
    }

    function run() external {
        // Generate sample recipients
        Recipient[] memory recipients = new Recipient[](100);

        for (uint256 i = 0; i < 100; i++) {
            recipients[i] = Recipient({
                user: address(uint160(0x1000 + i)),
                amount: (10000 + i * 100) * 1e18 // 10k to 19.9k HLG
            });
        }

        console.log("Generated sample Merkle tree with", recipients.length, "recipients");
        console.log("Total allocation:", getTotalAllocation(recipients) / 1e18, "HLG");

        // Note: In practice, you'd use a library like murky or OpenZeppelin's MerkleTree
        // to generate the actual Merkle tree and proofs
        console.log("Use a Merkle tree library to generate root and proofs from this data");
    }

    function getTotalAllocation(Recipient[] memory recipients) internal pure returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < recipients.length; i++) {
            total += recipients[i].amount;
        }
        return total;
    }
}
