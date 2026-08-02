// Launch a new Flap tax token + buyback vault via VaultPortal.newTokenV6WithVault.
// Usage: node launch.js <name> [buyTaxBps] [sellTaxBps] [xHandle] [xId]
// Example: node launch.js KOPI 300 300 mattrenggana 145621088
//
// Token address must end in "7777" (Flap vanity suffix for TOKEN_TAXED_V3).
// Salt is mined locally before submission via CREATE2 prediction.
//
// Required env vars (set in Railway / OpenClaw):
//   X_AGENT_PRIVATE_KEY, RPC_URL, CHAIN_ID, BUYBACK_VAULT_FACTORY,
//   ORACLE_URL, ORACLE_API_KEY, X_API_*, X_BOT_USER_ID, X_BOT_HANDLE

import {
  getWallet,
  VAULT_PORTAL_ABI,
  ADDRESSES,
  ok,
  fail,
  getFactoryAddress,
  AbiCoder,
} from "./shared.js";

// Flap constants (chain-specific, Robinhood = 4663)
const FLAP_PORTAL = "0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09";
const TOKEN_IMPL_TAXED_V3 = "0x7777C8743C88B3aff3cf262135bef2c8b2e83333";
const VANITY_SUFFIX = "7777";
const TOKEN_VERSION_TAXED_V3 = 6;
const MIGRATOR_TYPE_V2 = 1; // V2_MIGRATOR (UniV2)
const DEX_ID_UNIV2 = 1;      // UniV2
const DEFAULT_BUY_TAX_BPS = 300;   // 3%
const DEFAULT_SELL_TAX_BPS = 300;  // 3%
const MAX_TAX_BPS = 2000;          // 20% hard cap

// EIP-1167 minimal proxy pointing at TOKEN_IMPL_TAXED_V3.
// 55 bytes: 0x3d602d80...<impl>...5af43d82...
const MINIMAL_PROXY_BYTECODE =
  "0x3d602d80600a3d3981f3363d3d373d3d3d363d73" +
  TOKEN_IMPL_TAXED_V3.slice(2).toLowerCase() +
  "5af43d82803e903d91602b57fd5bf3";

// keccak256 of the proxy bytecode = init code hash used by CREATE2.
const { keccak256 } = await import("ethers");
const INIT_CODE_HASH = keccak256(MINIMAL_PROXY_BYTECODE);

// ---- vanity salt mining --------------------------------------------------

function predictTokenAddress(saltHex) {
  // CREATE2 address = keccak256(0xff || deployer || salt || initCodeHash)[12:]
  const data = "0xff" + FLAP_PORTAL.slice(2).toLowerCase() + saltHex.slice(2) + INIT_CODE_HASH.slice(2);
  return "0x" + keccak256(data).slice(-40);
}

function mineVanitySalt(maxIterations = 5_000_000) {
  // Seed: any 32-byte random; iterate keccak until address ends with 7777.
  const { randomBytes } = await import("ethers");
  let salt = "0x" + Buffer.from(randomBytes(32)).toString("hex");
  for (let i = 0; i < maxIterations; i++) {
    const predicted = predictTokenAddress(salt);
    if (predicted.toLowerCase().endsWith(VANITY_SUFFIX)) {
      return { salt, address: predicted, iterations: i + 1 };
    }
    salt = "0x" + keccak256(salt).slice(2);
  }
  throw new Error(`Failed to find vanity salt in ${maxIterations} iterations`);
}

// ---- main ---------------------------------------------------------------

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 1) {
    fail("Usage: launch.js <name> [buyTaxBps=300] [sellTaxBps=300] [xHandle=''] [xId=0]");
  }

  const name = args[0].toUpperCase();
  const buyTaxBps = Number(args[1] ?? DEFAULT_BUY_TAX_BPS);
  const sellTaxBps = Number(args[2] ?? DEFAULT_SELL_TAX_BPS);
  const xHandle = (args[3] ?? "").toLowerCase();
  const xId = args[4] ? BigInt(args[4]) : 0n;

  // Validation
  if (xHandle && xId === 0n) fail("xId required when xHandle is set");
  if (!xHandle && xId !== 0n) fail("xId must be 0 when xHandle is empty");
  if (!/^[A-Z0-9]{1,11}$/.test(name)) {
    fail(`Invalid name: ${name}. Must be 1-11 alphanumeric characters.`);
  }
  if (buyTaxBps > MAX_TAX_BPS || sellTaxBps > MAX_TAX_BPS) {
    fail(`Tax too high. Max ${MAX_TAX_BPS} bps (20%).`);
  }

  const wallet = getWallet();
  const factory = getFactoryAddress();
  const vaultPortal = ADDRESSES.VAULT_PORTAL;

  // 1. Mine vanity salt (predicts token address ending in "7777")
  const { salt, address: predictedToken, iterations } = mineVanitySalt();
  ok({
    step: "vanity_salt",
    salt,
    predictedToken,
    iterations,
  });

  // 2. Build vaultData (factory's BuybackVaultConfig: owner, xController, xId)
  const vaultData = AbiCoder.defaultAbiCoder().encode(
    ["address", "string", "uint128"],
    [
      wallet.address,   // owner (0x0 → factory's commissionRecipient)
      xHandle,          // xController (lowercase, "" = no X controller)
      xId,              // xId (numeric X user ID; 0 = none)
    ]
  );

  // 3. Build VaultPortal.newTokenV6WithVault params
  //    (26 fields per Flap NewTokenV6WithVaultParams)
  const params = {
    name,
    symbol: name,
    meta: "",                            // IPFS CID or empty
    dexThresh: 0,                        // not used for V2 migrator
    salt,
    migratorType: MIGRATOR_TYPE_V2,      // V2_MIGRATOR (UniV2)
    quoteToken: "0x0000000000000000000000000000000000000000",  // native ETH
    quoteAmt: 0n,                        // no initial buy
    permitData: "0x",
    extensionID: "0x0000000000000000000000000000000000000000000000000000000000000000",
    extensionData: "0x",
    dexId: DEX_ID_UNIV2,                 // UniV2
    lpFeeProfile: 0,
    buyTaxRate: buyTaxBps,
    sellTaxRate: sellTaxBps,
    taxDuration: 0n,                     // tax forever (or set to specific)
    antiFarmerDuration: 0n,
    mktBps: 10000,                       // 100% to marketing/vault (factory gates vaultBps=10000)
    deflationBps: 0,
    dividendBps: 0,
    lpBps: 0,
    minimumShareBalance: 0n,
    dividendToken: "0x0000000000000000000000000000000000000000",
    commissionReceiver: wallet.address,  // X Agent wallet
    tokenVersion: TOKEN_VERSION_TAXED_V3, // MUST be 6 (TAXED_V3)
    vaultFactory: factory,               // our BuybackVaultFactory
    vaultData,
  };

  // 4. Submit
  const { Contract } = await import("ethers");
  const portalContract = new Contract(vaultPortal, VAULT_PORTAL_ABI, wallet);
  const tx = await portalContract.newTokenV6WithVault(params);
  const receipt = await tx.wait();

  // 5. Parse FlapTaxVaultTokenCreated event
  const iface = portalContract.interface;
  let tokenAddress = null;
  let vaultAddress = null;
  for (const log of receipt.logs) {
    try {
      const parsed = iface.parseLog(log);
      if (parsed && parsed.name === "FlapTaxVaultTokenCreated") {
        tokenAddress = parsed.args.token;
        vaultAddress = parsed.args.vault;
        break;
      }
    } catch {}
  }

  if (!tokenAddress) {
    fail("FlapTaxVaultTokenCreated event not found in receipt");
  }

  ok({
    action: "launch",
    name,
    buyTaxBps,
    sellTaxBps,
    tokenAddress,
    vaultAddress,
    txHash: receipt.hash,
    blockNumber: receipt.blockNumber,
    creator: wallet.address,
    predictedToken,    // should match tokenAddress
    xController: { handle: xHandle || null, xId: xId.toString() },
    flapPageUrl: `https://flap.sh/robinhood/${tokenAddress}`,
  });
}

main().catch((err) => fail(err));
