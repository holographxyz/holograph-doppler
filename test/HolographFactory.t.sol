// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HolographFactory, CreateParams} from "src/HolographFactory.sol";

// Standalone imports for mining
import "./doppler/UniswapV4Types.sol";
import {DopplerMiner} from "./doppler/DopplerMiner.sol";
import {IDopplerDeployer} from "./doppler/DopplerDeployer.sol";
import {IGovernanceFactory} from "./doppler/interfaces/IGovernanceFactory.sol";
import {IPoolInitializer} from "./doppler/interfaces/IPoolInitializer.sol";
import {ILiquidityMigrator} from "./doppler/interfaces/ILiquidityMigrator.sol";
import {ITokenFactory} from "./doppler/interfaces/ITokenFactory.sol";

contract DopplerHookStub {
    fallback() external payable {}
}

library DopplerAddrBook {
    struct DopplerAddrs {
        address airlock;
        address tokenFactory;
        address governanceFactory;
        address v4Initializer;
        address migrator;
        address poolManager;
        address dopplerDeployer;
    }

    function get(bool useMainnet) internal pure returns (DopplerAddrs memory) {
        return useMainnet ? getMainnet() : getTestnet();
    }

    function getTestnet() internal pure returns (DopplerAddrs memory) {
        return
            DopplerAddrs({
                poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
                airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
                tokenFactory: 0xc69Ba223c617F7D936B3cf2012aa644815dBE9Ff,
                dopplerDeployer: 0x4Bf819DfA4066Bd7c9f21eA3dB911Bd8C10Cb3ca,
                governanceFactory: 0x9dBFaaDC8c0cB2c34bA698DD9426555336992e20,
                v4Initializer: 0xca2079706A4c2a4a1aA637dFB47d7f27Fe58653F,
                migrator: 0x04a898f3722c38F9Def707bD17DC78920EFA977C
            });
    }

    function getMainnet() internal pure returns (DopplerAddrs memory) {
        return
            DopplerAddrs({
                airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
                tokenFactory: 0xFAafdE6a5b658684cC5eb0C5c2c755B00A246F45,
                governanceFactory: 0xb4deE32EB70A5E55f3D2d861F49Fb3D79f7a14d9,
                v4Initializer: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254,
                migrator: 0x5F3bA43D44375286296Cb85F1EA2EBfa25dde731,
                poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
                dopplerDeployer: 0x5CadB034267751a364dDD4d321C99E07A307f915
            });
    }
}

/// @dev minimal stub for LayerZero
contract LZEndpointStub {
    event MessageSent(uint32 dstEid, bytes payload);

    function send(uint32 dstEid, bytes calldata payload, bytes calldata) external payable {
        emit MessageSent(dstEid, payload);
    }
}

/// @dev simple FeeRouter that just sums amounts
contract FeeRouterMock {
    uint256 public total;
    event FeeReceived(uint256 amount);

    function routeFeeETH() external payable {
        total += msg.value;
        emit FeeReceived(msg.value);
    }

    function receiveFee() external payable {
        total += msg.value;
        emit FeeReceived(msg.value);
    }

    // Add receive() fallback to handle direct ETH transfers
    receive() external payable {
        total += msg.value;
        emit FeeReceived(msg.value);
    }
}

contract V4InitializerStub {
    event Create(address poolOrHook, address asset, address numeraire);
    function deployer() external view returns (address) {
        return address(this);
    }
    function initialize(
        address asset,
        address numeraire,
        uint256 /*numTokensToSell*/,
        bytes32 /*salt*/,
        bytes calldata /*data*/
    ) external returns (address poolOrHook) {
        // deploy a minimal hook stub
        poolOrHook = address(new DopplerHookStub());
        emit Create(poolOrHook, asset, numeraire);
    }
    function exitLiquidity(
        address
    ) external pure returns (uint160, address, uint128, uint128, address, uint128, uint128) {
        return (0, address(0), 0, 0, address(0), 0, 0);
    }
}

contract HolographFactoryTest is Test {
    // ── constants ─────────────────────────────────────────────────────────
    uint256 private constant DEFAULT_NUM_TOKENS_TO_SELL = 100_000e18;
    uint256 private constant DEFAULT_MINIMUM_PROCEEDS = 100e18;
    uint256 private constant DEFAULT_MAXIMUM_PROCEEDS = 10_000e18;
    uint256 private constant DEFAULT_EPOCH_LENGTH = 400 seconds;
    int24 private constant DEFAULT_GAMMA = 800;
    int24 private constant DEFAULT_START_TICK = 6_000;
    int24 private constant DEFAULT_END_TICK = 60_000;
    uint24 private constant DEFAULT_FEE = 3000;
    int24 private constant DEFAULT_TICK_SPACING = 8;

    DopplerAddrBook.DopplerAddrs private doppler;
    HolographFactory private factory;
    FeeRouterMock private feeRouter;
    LZEndpointStub private lzEndpoint;
    address private creator = address(0xCAFE);

    function setUp() public {
        // Choose network based on MAINNET environment variable (defaults to testnet)
        bool useMainnet = vm.envOr("MAINNET", false);
        doppler = DopplerAddrBook.get(useMainnet);

        if (useMainnet) {
            // Base mainnet has chain ID 8453
            vm.chainId(8453);
            vm.createSelectFork(vm.rpcUrl("base"));
            console.log("=== USING BASE MAINNET ===");
        } else {
            // Base Sepolia testnet has chain ID 84532
            vm.chainId(84532);
            vm.createSelectFork(vm.rpcUrl("baseSepolia"));
            console.log("=== USING BASE SEPOLIA TESTNET ===");
        }

        console.log("Doppler addresses:");
        console.log("  Airlock: %s", doppler.airlock);
        console.log("  PoolManager: %s", doppler.poolManager);
        console.log("  V4Initializer: %s", doppler.v4Initializer);

        lzEndpoint = new LZEndpointStub();
        feeRouter = new FeeRouterMock();
        factory = new HolographFactory(address(lzEndpoint), doppler.airlock, address(feeRouter));
        vm.deal(creator, 1 ether);
    }

    function test_tokenLaunch_endToEnd() public {
        // 1) tokenFactory data
        bytes memory tokenFactoryData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "TOKEN_URI"
        );

        // 2) governanceFactory data
        bytes memory governanceData = abi.encode("DAO", 7200, 50_400, 0);

        // Use a fixed timestamp to ensure mining and deployment use the same values
        // This prevents discrepancies caused by block.timestamp changing between mining and deployment
        uint256 fixedTime = block.timestamp + 1 hours; // Start auction 1 hour from now

        // 12-field blob expected by UniswapV4Initializer & DopplerDeployer
        bytes memory poolInitializerData = abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            fixedTime, // Use fixed timestamp
            fixedTime + 3 days, // Use fixed timestamp
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            false, // isToken0
            8, // numPDSlugs
            3000,
            8
        );

        uint256 initialSupply = 1e23;
        uint256 numTokensToSell = 1e23;

        // Mine for a valid salt with proper hook flags
        DopplerMiner.MineV4Params memory params = DopplerMiner.MineV4Params({
            airlock: doppler.airlock,
            poolManager: doppler.poolManager,
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: address(0),
            tokenFactory: ITokenFactory(doppler.tokenFactory),
            tokenFactoryData: tokenFactoryData,
            poolInitializer: IDopplerDeployer(doppler.v4Initializer),
            poolInitializerData: poolInitializerData
        });

        // Use the doppler mineV4 function
        (bytes32 salt, address hook, address asset) = DopplerMiner.mineV4(params);

        console.log("=== MINING RESULTS ===");
        console.log("Mined salt: %s", uint256(salt));
        console.log("Calculated hook: %s", hook);
        console.log("Calculated asset: %s", asset);

        // 4) assemble CreateParams
        CreateParams memory createParams;
        createParams.initialSupply = DEFAULT_NUM_TOKENS_TO_SELL;
        createParams.numTokensToSell = DEFAULT_NUM_TOKENS_TO_SELL;
        createParams.numeraire = address(0);
        // createParams.tokenFactory = ITokenFactory(doppler.tokenFactory); // Type conflict - set via assembly
        createParams.tokenFactoryData = tokenFactoryData;
        createParams.governanceFactoryData = governanceData;
        createParams.poolInitializerData = poolInitializerData;
        createParams.liquidityMigratorData = "";
        createParams.integrator = address(0);
        createParams.salt = salt;

        // Use inline assembly for the interface fields that have type conflicts
        //
        // WHY ASSEMBLY IS NEEDED:
        // The CreateParams struct expects interface types imported from doppler's internal "src/interfaces/" path,
        // but we import the same interfaces from "lib/doppler/src/interfaces/". Even though these are identical files,
        // Solidity's type system treats them as incompatible types. Assembly bypasses this type checking by directly
        // manipulating memory addresses.
        //
        // CREATEPARAMS STRUCT MEMORY LAYOUT:
        // Each field occupies 32 bytes (0x20) in memory, regardless of actual size
        // 0x00: initialSupply        (uint256)       ✓ Set normally
        // 0x20: numTokensToSell      (uint256)       ✓ Set normally
        // 0x40: numeraire            (address)       ✓ Set normally
        // 0x60: tokenFactory         (ITokenFactory) ✓ Set normally (no conflict)
        // 0x80: tokenFactoryData     (bytes)         ✓ Set normally
        // 0xA0: governanceFactory    (IGovernanceFactory) ❌ TYPE CONFLICT → Use assembly
        // 0xC0: governanceFactoryData(bytes)         ✓ Set normally
        // 0xE0: poolInitializer      (IPoolInitializer)   ❌ TYPE CONFLICT → Use assembly
        // 0x100: poolInitializerData (bytes)         ✓ Set normally
        // 0x120: liquidityMigrator   (ILiquidityMigrator) ❌ TYPE CONFLICT → Use assembly
        // 0x140: liquidityMigratorData(bytes)        ✓ Set normally
        // 0x160: integrator          (address)       ✓ Set normally
        // 0x180: salt                (bytes32)       ✓ Set normally
        address tokenFact = doppler.tokenFactory;
        address govFactory = doppler.governanceFactory;
        address poolInit = doppler.v4Initializer;
        address liquidityMig = doppler.migrator;

        assembly {
            // mstore(memoryLocation, value) stores 32 bytes at the specified memory location

            // Store tokenFactory at offset 0x60 (96 decimal)
            // Calculation: 0x60 = 3 fields × 32 bytes = field #4 (tokenFactory)
            mstore(add(createParams, 0x60), tokenFact)

            // Store governanceFactory at offset 0xA0 (160 decimal)
            // Calculation: 0xA0 = 5 fields × 32 bytes = field #6 (governanceFactory)
            mstore(add(createParams, 0xa0), govFactory)

            // Store poolInitializer at offset 0xE0 (224 decimal)
            // Calculation: 0xE0 = 7 fields × 32 bytes = field #8 (poolInitializer)
            mstore(add(createParams, 0xe0), poolInit)

            // Store liquidityMigrator at offset 0x120 (288 decimal)
            // Calculation: 0x120 = 9 fields × 32 bytes = field #10 (liquidityMigrator)
            mstore(add(createParams, 0x120), liquidityMig)
        }

        // 5) Execute the token creation - no fee required as per Doppler's free token creation model
        bytes memory callData = abi.encodeWithSelector(factory.createToken.selector, createParams);
        vm.prank(creator);
        (bool ok, bytes memory returndata) = address(factory).call(callData);

        console.log("createToken success? ", ok);
        if (!ok) {
            console.logBytes(returndata);
        }

        assertTrue(ok, "createToken reverted; see console above for selector/data");
    }
}
