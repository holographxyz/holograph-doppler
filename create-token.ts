/**
 * Holograph Token Creation Script
 *
 * Environment Variables Required:
 * - PRIVATE_KEY: Private key for the account creating tokens
 * - BASESCAN_API_KEY: API key for contract verification on Base Sepolia
 *
 * Optional Environment Variables:
 * - BASE_SEPOLIA_RPC_URL: Custom RPC endpoint (uses public by default)
 */

import dotenv from "dotenv";
dotenv.config();

import {
  createWalletClient,
  createPublicClient,
  http,
  parseEther,
  encodeAbiParameters,
  parseAbiParameters,
  decodeAbiParameters,
  encodeFunctionData,
  Address,
  Hash,
  keccak256,
  concat,
  pad,
  toHex,
  decodeEventLog,
} from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "fs";
import { spawn } from "child_process";

// Contract addresses - Base Sepolia testnet
const HOLOGRAPH_FACTORY = "0x5290Bee84DC83AC667cF9573eC1edC6FE38eFe50" as const;

const DOPPLER_ADDRESSES = {
  airlock: "0x3411306cE66c9469BfF1535bA955503C4BdE1c6E",
  tokenFactory: "0xC69bA223C617F7d936B3cF2012AA644815dBE9fF",
  governanceFactory: "0x9DbfAAdc8C0cB2C34Ba698Dd9426555336992E20",
  v4Initializer: "0xCa2079706A4C2A4A1Aa637dFb47D7F27fE58653F",
  migrator: "0x04A898F3722C38F9Def707bD17dC78920eFa977C",
  poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
  dopplerDeployer: "0x4bF819DfA4066BD7C9F21ea3dB911bD8c10cB3Ca",
} as const;

const HOLOGRAPH_FACTORY_ABI = [
  {
    type: "function",
    name: "createToken",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "initialSupply", type: "uint256" },
          { name: "numTokensToSell", type: "uint256" },
          { name: "numeraire", type: "address" },
          { name: "tokenFactory", type: "address" },
          { name: "tokenFactoryData", type: "bytes" },
          { name: "governanceFactory", type: "address" },
          { name: "governanceFactoryData", type: "bytes" },
          { name: "poolInitializer", type: "address" },
          { name: "poolInitializerData", type: "bytes" },
          { name: "liquidityMigrator", type: "address" },
          { name: "liquidityMigratorData", type: "bytes" },
          { name: "integrator", type: "address" },
          { name: "salt", type: "bytes32" },
        ],
      },
    ],
    outputs: [{ name: "asset", type: "address" }],
    stateMutability: "nonpayable",
  },
  {
    type: "event",
    name: "TokenLaunched",
    inputs: [
      { name: "asset", type: "address", indexed: true },
      { name: "salt", type: "bytes32", indexed: false },
    ],
  },
] as const;

// Hook flags for salt mining
const HOOK_FLAGS = {
  BEFORE_INITIALIZE_FLAG: 1n << 13n,
  AFTER_INITIALIZE_FLAG: 1n << 12n,
  BEFORE_ADD_LIQUIDITY_FLAG: 1n << 11n,
  BEFORE_SWAP_FLAG: 1n << 7n,
  AFTER_SWAP_FLAG: 1n << 6n,
  BEFORE_DONATE_FLAG: 1n << 5n,
} as const;

const REQUIRED_FLAGS =
  HOOK_FLAGS.BEFORE_INITIALIZE_FLAG |
  HOOK_FLAGS.AFTER_INITIALIZE_FLAG |
  HOOK_FLAGS.BEFORE_ADD_LIQUIDITY_FLAG |
  HOOK_FLAGS.BEFORE_SWAP_FLAG |
  HOOK_FLAGS.AFTER_SWAP_FLAG |
  HOOK_FLAGS.BEFORE_DONATE_FLAG;

const FLAG_MASK = 0x3fffn;

function execCommand(command: string, args: string[], options: any = {}): Promise<string> {
  return new Promise((resolve, reject) => {
    const process = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
      ...options,
    });

    let stdout = "";
    let stderr = "";

    process.stdout?.on("data", (data) => {
      stdout += data.toString();
    });

    process.stderr?.on("data", (data) => {
      stderr += data.toString();
    });

    process.on("close", (code) => {
      if (code === 0) {
        resolve(stdout);
      } else {
        reject(new Error(`Command failed with code ${code}\nstdout: ${stdout}\nstderr: ${stderr}`));
      }
    });
  });
}

async function verifyContract(
  contractAddress: string,
  contractPath: string,
  constructorArgs: string,
  chainId: number,
  apiKey: string,
): Promise<void> {
  console.log(`🔍 Verifying contract at ${contractAddress}...`);

  try {
    const args = [
      "verify-contract",
      "--chain-id",
      chainId.toString(),
      "--constructor-args",
      constructorArgs,
      "--etherscan-api-key",
      apiKey,
      contractAddress,
      contractPath,
    ];

    const result = await execCommand("forge", args, {
      cwd: process.cwd(),
    });

    console.log("✅ Contract verification successful!");
  } catch (error: any) {
    if (error.message.includes("already verified") || error.message.includes("Contract source code already verified")) {
      console.log("ℹ️  Contract was already verified.");
      return;
    }
    throw error;
  }
}

function extractTokenAddress(logs: any[]): string | null {
  for (const log of logs) {
    try {
      if (log.address.toLowerCase() === HOLOGRAPH_FACTORY.toLowerCase()) {
        const decoded = decodeEventLog({
          abi: HOLOGRAPH_FACTORY_ABI,
          data: log.data,
          topics: log.topics,
        });

        if (decoded.eventName === "TokenLaunched") {
          return decoded.args.asset as string;
        }
      }
    } catch (error) {
      continue;
    }
  }
  return null;
}

async function verifyTokenContract(tokenAddress: string, createParams: any, config: any): Promise<void> {
  console.log("🔍 Preparing DERC20 contract verification...");

  try {
    const apiKey = process.env.BASESCAN_API_KEY || process.env.ETHERSCAN_API_KEY;
    if (!apiKey) {
      console.log("⚠️  BASESCAN_API_KEY not found - skipping contract verification");
      console.log("💡 Add BASESCAN_API_KEY to your .env file to enable contract verification");
      return;
    }

    const [name, symbol, yearlyMintCap, vestingDuration, recipients, amounts, tokenURI] = decodeAbiParameters(
      parseAbiParameters("string, string, uint256, uint256, address[], uint256[], string"),
      createParams.tokenFactoryData,
    );

    const constructorArgs = encodeAbiParameters(
      parseAbiParameters("string, string, uint256, address, address, uint256, uint256, address[], uint256[], string"),
      [
        name,
        symbol,
        createParams.initialSupply,
        DOPPLER_ADDRESSES.airlock as Address,
        DOPPLER_ADDRESSES.airlock as Address,
        yearlyMintCap,
        vestingDuration,
        recipients,
        amounts,
        tokenURI,
      ],
    );

    await verifyContract(tokenAddress, "lib/doppler/src/DERC20.sol:DERC20", constructorArgs, 84532, apiKey);

    console.log("🎉 Token contract verification completed!");
    console.log(`🔗 View verified contract: https://sepolia.basescan.org/address/${tokenAddress}#code`);
    console.log("");
    console.log("🎊 DEPLOYMENT SUMMARY:");
    console.log(`📍 Token Address: ${tokenAddress}`);
    console.log(`📛 Token Name: ${name}`);
    console.log(`🏷️  Token Symbol: ${symbol}`);
    console.log(`💰 Initial Supply: ${createParams.initialSupply.toString()}`);
    console.log(`✅ Contract Status: Verified on Basescan`);
    console.log(`🌐 Explorer: https://sepolia.basescan.org/address/${tokenAddress}`);
    console.log(`📄 Contract Code: https://sepolia.basescan.org/address/${tokenAddress}#code`);
  } catch (error: any) {
    console.error("❌ Token contract verification failed:");
    console.error(error.message);
    console.log("💡 You can manually verify the contract later using the displayed constructor arguments");
  }
}

function computeCreate2Address(salt: `0x${string}`, initCodeHash: `0x${string}`, deployer: Address): Address {
  const packed = concat(["0xff", deployer, salt, initCodeHash]);
  const hash = keccak256(packed);
  return `0x${hash.slice(-40)}` as Address;
}

function getDopplerCreationCode(): `0x${string}` {
  try {
    const bytecode = readFileSync("lib/doppler/out/Doppler.sol/Doppler.bin", "utf8").trim();
    return `0x${bytecode}` as `0x${string}`;
  } catch (error) {
    throw new Error(`Could not load Doppler bytecode: ${error}`);
  }
}

function getDERC20CreationCode(): `0x${string}` {
  try {
    const bytecode = readFileSync("lib/doppler/out/DERC20.sol/DERC20.bin", "utf8").trim();
    return `0x${bytecode}` as `0x${string}`;
  } catch (error) {
    throw new Error(`Could not load DERC20 bytecode: ${error}`);
  }
}

/**
 * Mine valid salt for Doppler deployment
 * Ensures hook address has correct flags and token ordering
 */
async function mineValidSalt(
  tokenFactoryData: `0x${string}`,
  poolInitializerData: `0x${string}`,
  initialSupply: bigint,
  numTokensToSell: bigint,
  numeraire: Address,
  publicClient: any,
): Promise<`0x${string}`> {
  console.log("⛏️  Mining valid salt...");

  const [
    minimumProceeds,
    maximumProceeds,
    startingTime,
    endingTime,
    startingTick,
    endingTick,
    epochLength,
    gamma,
    isToken0,
    numPDSlugs,
    lpFee,
    tickSpacing,
  ] = decodeAbiParameters(
    parseAbiParameters(
      "uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256, uint24, int24",
    ),
    poolInitializerData,
  );

  const dopplerConstructorArgs = encodeAbiParameters(
    parseAbiParameters(
      "address, uint256, uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256, address, uint24",
    ),
    [
      DOPPLER_ADDRESSES.poolManager as Address,
      numTokensToSell,
      minimumProceeds,
      maximumProceeds,
      startingTime,
      endingTime,
      startingTick,
      endingTick,
      epochLength,
      gamma,
      isToken0,
      numPDSlugs,
      DOPPLER_ADDRESSES.v4Initializer as Address,
      lpFee,
    ],
  );

  const dopplerBytecode = getDopplerCreationCode();
  const dopplerInitHash = keccak256(concat([dopplerBytecode, dopplerConstructorArgs]));

  const [name, symbol, yearlyMintCap, vestingDuration, recipients, amounts, tokenURI] = decodeAbiParameters(
    parseAbiParameters("string, string, uint256, uint256, address[], uint256[], string"),
    tokenFactoryData,
  );

  const tokenConstructorArgs = encodeAbiParameters(
    parseAbiParameters("string, string, uint256, address, address, uint256, uint256, address[], uint256[], string"),
    [
      name,
      symbol,
      initialSupply,
      DOPPLER_ADDRESSES.airlock as Address,
      DOPPLER_ADDRESSES.airlock as Address,
      yearlyMintCap,
      vestingDuration,
      recipients,
      amounts,
      tokenURI,
    ],
  );

  const derc20Bytecode = getDERC20CreationCode();
  const tokenInitHash = keccak256(concat([derc20Bytecode, tokenConstructorArgs]));

  for (let saltNum = 0; saltNum < 200_000; saltNum++) {
    if (saltNum % 10000 === 0) {
      console.log(`⛏️  Mining progress: ${saltNum}/200,000`);
    }

    const salt = pad(toHex(saltNum), { size: 32 }) as `0x${string}`;
    const hookAddress = computeCreate2Address(salt, dopplerInitHash, DOPPLER_ADDRESSES.dopplerDeployer as Address);
    const assetAddress = computeCreate2Address(salt, tokenInitHash, DOPPLER_ADDRESSES.tokenFactory as Address);

    const hookFlags = BigInt(hookAddress) & FLAG_MASK;
    if (hookFlags !== REQUIRED_FLAGS) {
      continue;
    }

    try {
      const code = await publicClient.getBytecode({ address: hookAddress });
      if (code && code !== "0x") {
        continue;
      }
    } catch {
      continue;
    }

    const assetBigInt = BigInt(assetAddress);
    const numeraireBigInt = BigInt(numeraire);
    const correctOrdering = isToken0 ? assetBigInt < numeraireBigInt : assetBigInt > numeraireBigInt;

    if (!correctOrdering) {
      continue;
    }

    console.log(`✅ Found valid salt: ${saltNum}`);
    console.log(`📍 Hook address: ${hookAddress}`);
    console.log(`📍 Asset address: ${assetAddress}`);
    return salt;
  }

  throw new Error("Could not find valid salt");
}

async function createToken() {
  const privateKey = process.env.PRIVATE_KEY as `0x${string}`;
  if (!privateKey) {
    throw new Error("PRIVATE_KEY environment variable is required");
  }

  const account = privateKeyToAccount(privateKey);

  const publicClient = createPublicClient({
    chain: baseSepolia,
    transport: http(),
  });

  const walletClient = createWalletClient({
    account,
    chain: baseSepolia,
    transport: http(),
  });

  const config = {
    name: "Test Token",
    symbol: "TEST",
    initialSupply: parseEther("100000"),
    minProceeds: parseEther("100"),
    maxProceeds: parseEther("10000"),
    auctionDurationDays: 3,
  };

  console.log("🚀 Creating token:", config.name);

  const tokenFactoryData = encodeAbiParameters(
    parseAbiParameters("string, string, uint256, uint256, address[], uint256[], string"),
    [config.name, config.symbol, 0n, 0n, [], [], ""],
  );

  const governanceData = encodeAbiParameters(parseAbiParameters("string, uint256, uint256, uint256"), [
    `${config.name} DAO`,
    7200n,
    50400n,
    0n,
  ]);

  // Set auction timing with buffer to avoid InvalidStartTime()
  const latestBlock = await publicClient.getBlock();
  const blockTime = Number(latestBlock.timestamp);
  const auctionStart = blockTime + 300;
  const auctionEnd = auctionStart + config.auctionDurationDays * 24 * 60 * 60;

  console.log("⏰ Auction timing:", {
    auctionStart: new Date(auctionStart * 1000).toISOString(),
    auctionEnd: new Date(auctionEnd * 1000).toISOString(),
    duration: config.auctionDurationDays + " days",
  });

  const poolInitializerData = encodeAbiParameters(
    parseAbiParameters(
      "uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256, uint24, int24",
    ),
    [
      config.minProceeds,
      config.maxProceeds,
      BigInt(auctionStart),
      BigInt(auctionEnd),
      6000,
      60000,
      400n,
      800,
      false,
      8n,
      3000,
      8,
    ],
  );

  const salt = await mineValidSalt(
    tokenFactoryData,
    poolInitializerData,
    config.initialSupply,
    config.initialSupply,
    "0x0000000000000000000000000000000000000000" as Address,
    publicClient,
  );

  const createParams = {
    initialSupply: config.initialSupply,
    numTokensToSell: config.initialSupply,
    numeraire: "0x0000000000000000000000000000000000000000" as Address,
    tokenFactory: DOPPLER_ADDRESSES.tokenFactory as Address,
    tokenFactoryData,
    governanceFactory: DOPPLER_ADDRESSES.governanceFactory as Address,
    governanceFactoryData: governanceData,
    poolInitializer: DOPPLER_ADDRESSES.v4Initializer as Address,
    poolInitializerData,
    liquidityMigrator: DOPPLER_ADDRESSES.migrator as Address,
    liquidityMigratorData: "0x" as `0x${string}`,
    integrator: "0x0000000000000000000000000000000000000000" as Address,
    salt,
  };

  try {
    console.log("⛽ Estimating gas...");
    const gasEstimate = await publicClient.estimateContractGas({
      address: HOLOGRAPH_FACTORY,
      abi: HOLOGRAPH_FACTORY_ABI,
      functionName: "createToken",
      args: [createParams],
      account: account.address,
    });

    console.log(`📊 Gas estimated: ${gasEstimate.toString()}`);

    console.log("📤 Submitting transaction...");
    const hash = await walletClient.writeContract({
      address: HOLOGRAPH_FACTORY,
      abi: HOLOGRAPH_FACTORY_ABI,
      functionName: "createToken",
      args: [createParams],
      gas: gasEstimate * 2n,
    });

    console.log("🧾 Transaction hash:", hash);
    console.log("🔗 Explorer:", `https://sepolia.basescan.org/tx/${hash}`);

    console.log("⏳ Waiting for transaction confirmation...");
    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    if (receipt.status === "success") {
      console.log("✅ Token creation successful!");
      console.log(`💰 Gas used: ${receipt.gasUsed.toString()}`);

      const tokenAddress = extractTokenAddress(receipt.logs);
      if (tokenAddress) {
        console.log("🎉 Token address:", tokenAddress);
        console.log("🔗 Basescan:", `https://sepolia.basescan.org/address/${tokenAddress}`);
        await verifyTokenContract(tokenAddress, createParams, config);
      } else {
        console.log("⚠️  Could not extract token address from transaction logs");
      }

      return hash;
    } else {
      throw new Error("Transaction reverted");
    }
  } catch (error) {
    console.error("❌ Token creation failed:", error);
    throw error;
  }
}

createToken().catch(console.error);
