// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HolographOrchestrator} from "src/HolographOrchestrator.sol";
import {ITokenFactory} from "src/interfaces/ITokenFactory.sol";
import {IPoolInitializer} from "src/interfaces/IPoolInitializer.sol";
import {ILiquidityMigrator} from "src/interfaces/ILiquidityMigrator.sol";
import {IGovernanceFactory} from "src/interfaces/IGovernanceFactory.sol";
import {CreateParams} from "lib/doppler/src/Airlock.sol";

// Import additional v4-core dependencies not included in AirlockMiner.sol
import {TickMath} from "lib/doppler/lib/v4-core/src/libraries/TickMath.sol";
import {Hooks as HooksLib} from "lib/doppler/lib/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "lib/doppler/lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "lib/doppler/lib/v4-core/src/interfaces/IHooks.sol";

// Import AirlockMiner which includes Hooks, PoolManager, DERC20, Doppler, Airlock, and UniswapV4Initializer
import "lib/doppler/test/shared/AirlockMiner.sol";

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

    function get() internal pure returns (DopplerAddrs memory) {
        return
            DopplerAddrs({
                poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
                airlock: 0x0d2f38d807bfAd5C18e430516e10ab560D300caF,
                tokenFactory: 0x4B0EC16Eb40318Ca5A4346f20F04A2285C19675B,
                dopplerDeployer: 0x40Bcb4dDA3BcF7dba30C5d10c31EE2791ed9ddCa,
                governanceFactory: 0x65dE470Da664A5be139A5D812bE5FDa0d76CC951,
                v4Initializer: 0xA36715dA46Ddf4A769f3290f49AF58bF8132ED8E,
                migrator: 0xC541FBddfEEf798E50d257495D08efe00329109A
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
    function exitLiquidity(address) external returns (uint160, address, uint128, uint128, address, uint128, uint128) {
        return (0, address(0), 0, 0, address(0), 0, 0);
    }
}

contract OrchestratorLaunchTest is Test {
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
    HolographOrchestrator private orchestrator;
    FeeRouterMock private feeRouter;
    LZEndpointStub private lzEndpoint;
    address private creator = address(0xCAFE);

    function setUp() public {
        doppler = DopplerAddrBook.get();
        vm.createSelectFork(vm.rpcUrl("baseSepolia"));

        lzEndpoint = new LZEndpointStub();
        feeRouter = new FeeRouterMock();
        orchestrator = new HolographOrchestrator(address(lzEndpoint), doppler.airlock, address(feeRouter));
        orchestrator.setLaunchFee(LAUNCH_FEE);
        vm.deal(creator, 1 ether);

        bool useV4Stub = vm.envOr("USE_V4_STUB", true);
        if (useV4Stub) {
            // patch initializer itself to stub implementation eliminating internal PoolManager logic
            V4InitializerStub initStub = new V4InitializerStub();
            vm.etch(doppler.v4Initializer, address(initStub).code);
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

        // 12-field blob expected by UniswapV4Initializer & DopplerDeployer
        bytes memory poolInitializerData = abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            block.timestamp,
            block.timestamp + 3 days,
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

        (bytes32 salt, address hook, address asset, bytes memory minedPoolInitData) = mineV4Silent(params);
        poolInitializerData = minedPoolInitData; // use the exact blob that matches the mined salt
        console.log("hook: ", hook);
        console.log("asset: ", asset);
        console.log("salt: ");
        console.logBytes32(salt);

        // 4) assemble CreateParams
        CreateParams memory createParams = CreateParams({
            initialSupply: DEFAULT_NUM_TOKENS_TO_SELL,
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            numeraire: address(0),
            tokenFactory: ITokenFactory(doppler.tokenFactory),
            tokenFactoryData: tokenFactoryData,
            governanceFactory: IGovernanceFactory(doppler.governanceFactory),
            governanceFactoryData: governanceData,
            poolInitializer: IPoolInitializer(doppler.v4Initializer),
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(doppler.migrator),
            liquidityMigratorData: "",
            integrator: address(0),
            salt: salt
        });

        // DopplerAirlock airlock = DopplerAirlock(payable(doppler.airlock));

        // airlock.create(createParams);

        // 5) low-level call to see revert reason
        bytes memory callData = abi.encodeWithSelector(orchestrator.createToken.selector, createParams);
        vm.prank(creator);
        (bool ok, bytes memory returndata) = address(orchestrator).call{value: LAUNCH_FEE}(callData);

        console.log("createToken success? ", ok);
        console.logBytes(returndata);

        assertTrue(ok, "createToken reverted; see console above for selector/data");
    }

    function mineV4Silent(
        MineV4Params memory params
    ) public view returns (bytes32 salt, address hook, address asset, bytes memory poolInitData) {
        for (uint256 i = 0; i < 1_000_000; ++i) {
            (salt, hook, asset) = mineV4(params);
            if (HooksLib.isValidHookAddress(IHooks(hook), LPFeeLibrary.DYNAMIC_FEE_FLAG)) {
                return (salt, hook, asset, params.poolInitializerData);
            }
            // tweak one field (startingTime) to change the init-code hash while keeping length constant
            (
                uint256 minP,
                uint256 maxP,
                uint256 startT,
                uint256 endT,
                int24 startTick,
                int24 endTick,
                uint256 epochLen,
                int24 g,
                bool isTok0,
                uint256 numSlugs,
                uint24 lpFee,
                int24 tSpacing
            ) = abi.decode(
                    params.poolInitializerData,
                    (uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256, uint24, int24)
                );
            params.poolInitializerData = abi.encode(
                minP,
                maxP,
                startT + 1,
                endT + 1,
                startTick,
                endTick,
                epochLen,
                g,
                isTok0,
                numSlugs,
                lpFee,
                tSpacing
            );
        }
        revert("could-not-find-valid-salt");
    }
}
