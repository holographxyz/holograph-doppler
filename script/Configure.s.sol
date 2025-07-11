// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Configure
 * @notice Post-deployment configuration for FeeRouter contracts.
 *
 * Functions performed:
 *   • setTrustedRemote on the active FeeRouter (points to the remote FeeRouter)
 *   • grantRole(KEEPER_ROLE) to keeper automation address
 *   • setTrustedAirlock() for Doppler Airlock contracts
 *
 * Usage (example for Base chain):
 *   forge script script/Configure.s.sol \
 *       --rpc-url $BASE_RPC \
 *       --broadcast \
 *       --private-key $OWNER_PK
 *
 * Required ENV (executed per-chain):
 *   FEE_ROUTER         – address of FeeRouter on the chain this script is run against
 *   REMOTE_FEE_ROUTER  – address of the FeeRouter on the opposite chain
 *   REMOTE_EID         – uint of remote chain LayerZero endpoint ID
 *   KEEPER_ADDRESS     – address receiving KEEPER_ROLE
 *   DOPPLER_AIRLOCK    – address of trusted Doppler Airlock contract (add more via code)
 */

import "forge-std/Script.sol";
import "../src/FeeRouter.sol";
import "forge-std/console.sol";

contract Configure is Script {
    function run() external {
        /* ------------------------------ env vars ----------------------------- */
        bool shouldBroadcast = vm.envOr("BROADCAST", false);

        // OWNER_PK only required if we intend to broadcast real transactions
        uint256 ownerPk = shouldBroadcast ? vm.envUint("OWNER_PK") : uint256(0);

        address payable feeRouterAddr = payable(vm.envAddress("FEE_ROUTER"));
        address remoteRouter = vm.envAddress("REMOTE_FEE_ROUTER");
        uint32 remoteEid = uint32(vm.envUint("REMOTE_EID"));
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        address dopplerAirlock = vm.envAddress("DOPPLER_AIRLOCK");

        // Validation
        require(feeRouterAddr != address(0), "FEE_ROUTER env missing");
        require(remoteRouter != address(0), "REMOTE_FEE_ROUTER env missing");
        require(remoteEid != 0, "REMOTE_EID env missing");
        require(keeper != address(0), "KEEPER_ADDRESS env missing");
        require(dopplerAirlock != address(0), "DOPPLER_AIRLOCK env missing");

        FeeRouter router = FeeRouter(feeRouterAddr);

        console.log("Configuring FeeRouter at", feeRouterAddr);

        if (shouldBroadcast) {
            vm.startBroadcast(ownerPk);
        } else {
            console.log("Running in dry-run mode (no broadcast)");
            vm.startBroadcast();
        }

        /* ------------------------- Trusted Remote -------------------------- */
        bytes32 remoteBytes32 = bytes32(uint256(uint160(remoteRouter)));
        router.setTrustedRemote(remoteEid, remoteBytes32);
        console.log("Trusted remote set (eid -> addr):", remoteEid, remoteRouter);

        /* ---------------------------- KEEPER ------------------------------- */
        bytes32 keeperRole = router.KEEPER_ROLE();
        try router.grantRole(keeperRole, keeper) {
            console.log("Granted KEEPER_ROLE to", keeper);
        } catch {
            console.log("[WARN] grantRole failed - maybe already set");
        }

        /* ------------------------- Trusted Airlocks ------------------------ */
        try router.setTrustedAirlock(dopplerAirlock, true) {
            console.log("Whitelisted Doppler Airlock", dopplerAirlock);
        } catch {
            console.log("[WARN] setTrustedAirlock failed - perhaps already trusted");
        }

        vm.stopBroadcast();
    }
}
