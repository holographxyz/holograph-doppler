// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/HolographFactory.sol";
import {CreateParams} from "../src/interfaces/DopplerStructs.sol";
import {ITokenFactory} from "../test/doppler/interfaces/ITokenFactory.sol";
import {IGovernanceFactory} from "../test/doppler/interfaces/IGovernanceFactory.sol";
import {IPoolInitializer} from "../test/doppler/interfaces/IPoolInitializer.sol";
import {ILiquidityMigrator} from "../test/doppler/interfaces/ILiquidityMigrator.sol";

contract TestTokenCreation is Script {
    function run() external {
        // Use Base Sepolia testnet
        vm.createSelectFork("https://sepolia.base.org");

        // Deployed HolographFactory address
        HolographFactory factory = HolographFactory(0x5290Bee84DC83AC667cF9573eC1edC6FE38eFe50);

        // Test account (replace with your actual account)
        address testAccount = 0x5f5C3548f96C7DA33A18E5F2F2f13519e1c8bD0d;

        // Prepare test data similar to the script
        bytes memory tokenFactoryData = abi.encode(
            "Standard Token",
            "STD",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "TOKEN_URI"
        );

        bytes memory governanceData = abi.encode("Standard Token DAO", 7200, 50_400, 0);

        uint256 currentTime = block.timestamp;
        bytes memory poolInitializerData = abi.encode(
            100 ether, // minProceeds
            10000 ether, // maxProceeds
            currentTime,
            currentTime + 3 days,
            6000, // startTick
            60000, // endTick
            400, // epochLength
            800, // gamma
            false, // isToken0
            8, // numPDSlugs
            3000, // fee
            8 // tickSpacing
        );

        CreateParams memory params;
        params.initialSupply = 100000 ether;
        params.numTokensToSell = 100000 ether;
        params.numeraire = address(0);
        params.tokenFactoryData = tokenFactoryData;
        params.governanceFactoryData = governanceData;
        params.poolInitializerData = poolInitializerData;
        params.liquidityMigratorData = "";
        params.integrator = address(0);
        params.salt = bytes32(uint256(10422));
        
        // Use assembly to set interface fields to avoid type conflicts
        // These are the same interfaces but from different import paths
        address tokenFactoryAddr = 0xc69Ba223c617F7D936B3cf2012aa644815dBE9Ff;
        address governanceFactoryAddr = 0x9dBFaaDC8c0cB2c34bA698DD9426555336992e20;
        address poolInitializerAddr = 0xca2079706A4c2a4a1aA637dFB47d7f27Fe58653F;
        address liquidityMigratorAddr = 0x04a898f3722c38F9Def707bD17DC78920EFA977C;
        
        assembly {
            // tokenFactory at offset 0x60 (96 decimal) - field #4
            mstore(add(params, 0x60), tokenFactoryAddr)
            // governanceFactory at offset 0xA0 (160 decimal) - field #6
            mstore(add(params, 0xA0), governanceFactoryAddr)
            // poolInitializer at offset 0xE0 (224 decimal) - field #8
            mstore(add(params, 0xE0), poolInitializerAddr)
            // liquidityMigrator at offset 0x120 (288 decimal) - field #10
            mstore(add(params, 0x120), liquidityMigratorAddr)
        }

        vm.startPrank(testAccount);

        try factory.createToken(params) returns (address asset) {
            console.log("Token created successfully at:", asset);
        } catch Error(string memory reason) {
            console.log("Error:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Low level error data:");
            console.logBytes(lowLevelData);
        }

        vm.stopPrank();
    }
}
