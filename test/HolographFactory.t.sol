// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HolographFactory, CreateParams} from "src/HolographFactory.sol";
import {CreateParams} from "lib/doppler/src/Airlock.sol";

// Import additional v4-core dependencies not included in AirlockMiner.sol
import {TickMath} from "lib/doppler/lib/v4-core/src/libraries/TickMath.sol";
import {Hooks as HooksLib} from "lib/doppler/lib/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "lib/doppler/lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "lib/doppler/lib/v4-core/src/interfaces/IHooks.sol";

// Import AirlockMiner which includes Hooks, PoolManager, DERC20, Doppler, Airlock, and UniswapV4Initializer
// This also imports ITokenFactory, but we need to import the other interfaces separately
import "lib/doppler/test/shared/AirlockMiner.sol";
import {IGovernanceFactory} from "lib/doppler/src/interfaces/IGovernanceFactory.sol";
import {IPoolInitializer} from "lib/doppler/src/interfaces/IPoolInitializer.sol";
import {ILiquidityMigrator} from "lib/doppler/src/interfaces/ILiquidityMigrator.sol";
import {IPoolManager} from "lib/doppler/lib/v4-core/src/interfaces/IPoolManager.sol";

// Import DopplerDeployer specifically to avoid conflicts
import {DopplerDeployer} from "lib/doppler/src/UniswapV4Initializer.sol";

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
                airlock: 0x7E6cF695a8BeA4b2bF94FbB5434a7da3f39A2f8D,
                tokenFactory: 0xAd62fc9eEbbDC2880c0d4499B0660928d13405cE,
                dopplerDeployer: 0x7980Be665C8011A413c598F82fa6f95feACa2e1e,
                governanceFactory: 0xff02a43A90c25941f8c5f4917eaD79EB33C3011C,
                v4Initializer: 0x511b44b4cC8Cb80223F203E400309b010fEbFAec,
                migrator: 0x8f4814999D2758ffA69689A37B0ce225C1eEcBFf
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
    uint256 private constant LAUNCH_FEE = 0.1 ether;
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
        factory.setLaunchFee(LAUNCH_FEE);
        vm.deal(creator, 1 ether);

        bool useV4Stub = vm.envOr("USE_V4_STUB", false);
        if (useV4Stub) {
            // patch initializer itself to stub implementation eliminating internal PoolManager logic
            V4InitializerStub initStub = new V4InitializerStub();
            vm.etch(doppler.v4Initializer, address(initStub).code);
            console.log("=== USING V4 STUB MODE ===");
        }
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

        // Store current timestamp to ensure mining and deployment use the same values
        uint256 currentTime = block.timestamp;

        // 12-field blob expected by UniswapV4Initializer & DopplerDeployer
        bytes memory poolInitializerData = abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            currentTime, // Use stored timestamp
            currentTime + 3 days, // Use stored timestamp
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

        // Check if we're using the V4 stub mode
        bool useV4Stub = vm.envOr("USE_V4_STUB", false);

        bytes32 salt;
        address hook;
        address asset;

        if (useV4Stub) {
            // In stub mode, we don't need to mine for hook flags since the stub bypasses validation
            // Use a simple fixed salt
            salt = bytes32(uint256(1));
            console.log("=== USING V4 STUB MODE ===");
            console.log("Using fixed salt: %s", uint256(salt));
        } else {
            // In real mode, mine for a valid salt with proper hook flags
            MineV4Params memory params = MineV4Params({
                airlock: doppler.airlock,
                poolManager: doppler.poolManager,
                initialSupply: initialSupply,
                numTokensToSell: numTokensToSell,
                numeraire: address(0),
                tokenFactory: ITokenFactory(doppler.tokenFactory),
                tokenFactoryData: tokenFactoryData,
                poolInitializer: UniswapV4Initializer(doppler.v4Initializer),
                poolInitializerData: poolInitializerData
            });

            // Use the doppler mineV4 function
            (salt, hook, asset) = mineV4(params);

            console.log("=== MINING RESULTS ===");
            console.log("Mined salt: %s", uint256(salt));
            console.log("Calculated hook: %s", hook);
            console.log("Calculated asset: %s", asset);
        }

        // 4) assemble CreateParams
        CreateParams memory createParams;
        createParams.initialSupply = DEFAULT_NUM_TOKENS_TO_SELL;
        createParams.numTokensToSell = DEFAULT_NUM_TOKENS_TO_SELL;
        createParams.numeraire = address(0);
        createParams.tokenFactory = ITokenFactory(doppler.tokenFactory);
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
        address govFactory = doppler.governanceFactory;
        address poolInit = doppler.v4Initializer;
        address liquidityMig = doppler.migrator;

        assembly {
            // mstore(memoryLocation, value) stores 32 bytes at the specified memory location

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

        // 5) Execute the token creation
        bytes memory callData = abi.encodeWithSelector(factory.createToken.selector, createParams);
        vm.prank(creator);
        (bool ok, bytes memory returndata) = address(factory).call{value: LAUNCH_FEE}(callData);

        console.log("createToken success? ", ok);
        if (!ok) {
            console.logBytes(returndata);
        }

        assertTrue(ok, "createToken reverted; see console above for selector/data");
    }
}
