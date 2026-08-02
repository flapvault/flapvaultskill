// Launch a new Flap tax token + buyback vault via VaultPortal.newTokenV6WithVault.
// Usage: node launch.js <name> [buyTaxBps=300] [sellTaxBps=300] [xHandle=""] [xId=0]
// Example: node launch.js KOPI 300 300 mattrenggana 145621088
//
// CRITICAL: 27-field ABI per Flap docs. Selector 0x1b806220.
// Field 25 = `tokenVersion` (NOT mevModuleV2Type!). MUST be 6 (TOKEN_TAXED_V3)
// otherwise revert FeatureDisabled().
// Field 26 = `vaultFactory` (NOT mevModuleV2!). Set to our factory address.
//
// Verified working test deploy:
//   tx 0x718960e8...e840 → token 0xaF76...7777
//   field 24 (tokenVersion) = 6
//   field 25 (vaultFactory) = 0x39769E... (our factory)
//   field 17 (mktBps) = 10000 (100% to marketing/wallet)
//   field 18 (deflationBps) = 0 (no burn)
//   field 13 (buyTaxRate) = 300 (3%)
//   field 14 (sellTaxRate) = 300 (3%)
//   field 15 (taxDuration) = 3153600000 (3.15B seconds = 100 years)
//   field 16 (antiFarmerDuration) = 2592000 (2.59M seconds = 30 days)
//
// Token address must end in "7777" (Flap vanity suffix for TAXED_V3).
// Salt is mined locally via CREATE2 prediction before submission.

import {
  getWallet,
  VAULT_PORTAL_ABI,
  ADDRESSES,
  ok,
  fail,
  getFactoryAddress,
  AbiCoder,
} from "./shared.js";

const FLAP_PORTAL = "0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09";
const TOKEN_IMPL_TAXED_V3 = "0x7777C8743C88B3aff3cf262135bef2c8b2e83333";
const VANITY_SUFFIX = "7777";
const TOKEN_VERSION_TAXED_V3 = 6;
const MIGRATOR_TYPE_V2 = 1;
const MAX_TAX_BPS = 2000;

// EIP-1167 minimal proxy pointing at TOKEN_IMPL_TAXED_V3
const MINIMAL_PROXY_BYTECODE =
  "0x3d602d80600a3d3981f3363d3d373d3d3d363d73" +
  TOKEN_IMPL_TAXED_V3.slice(2).toLowerCase() +
  "5af43d82803e903d91602b57fd5bf3";

const { keccak256, randomBytes } = await import("ethers");
const INIT_CODE_HASH = keccak256(MINIMAL_PROXY_BYTECODE);

function predictTokenAddress(saltHex) {
  const data =
    "0xff" +
    FLAP_PORTAL.slice(2).toLowerCase() +
    saltHex.slice(2) +
    INIT_CODE_HASH.slice(2);
  return "0x" + keccak256(data).slice(-40);
}

function mineVanitySalt(maxIterations = 5_000_000) {
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

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 1) {
    fail("Usage: launch.js <name> [buyTaxBps=300] [sellTaxBps=300] [xHandle=''] [xId=0]");
  }

  const name = args[0].toUpperCase();
  const buyTaxBps = Number(args[1] ?? 300);
  const sellTaxBps = Number(args[2] ?? 300);
  const xHandle = (args[3] ?? "").toLowerCase();
  const xId = args[4] ? BigInt(args[4]) : 0n;

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

  // 1. Mine vanity salt
  const { salt, address: predictedToken, iterations } = mineVanitySalt();
  ok({
    step: "vanity_salt",
    salt,
    predictedToken,
    iterations,
  });

  // 2. Build vaultData (factory's BuybackVaultConfig — 3 fields: owner, xController, xId)
  const vaultData = AbiCoder.defaultAbiCoder().encode(
    ["address", "string", "uint128"],
    [wallet.address, xHandle, xId]
  );

  // 3. Build params with CORRECT 27-field ABI per Flap docs.
  //    Per test tx: 100% mktBps, no deflation, no LP, no dividend.
  //    tokenVersion MUST be 6 (TOKEN_TAXED_V3) — else FeatureDisabled().
  //
  //  CRITICAL: meta must be non-empty (Flap Portal validation).
  const meta = `ipfs://flapvault/${name.toLowerCase()}-metadata-v1`;
  const params = [
    name,                                                 // 0: name
    name,                                                 // 1: symbol
    meta,                                                 // 2: meta (non-empty)
    1,                                                    // 3: dexThresh (1 per test)
    salt,                                                 // 4: salt (vanity 7777)
    MIGRATOR_TYPE_V2,                                     // 5: migratorType
    "0x0000000000000000000000000000000000000000",         // 6: quoteToken (native ETH)
    0n,                                                   // 7: quoteAmt
    "0x",                                                 // 8: permitData
    "0x0000000000000000000000000000000000000000000000000000000000000000", // 9: extensionID
    "0x",                                                 // 10: extensionData
    0,                                                    // 11: dexId
    0,                                                    // 12: lpFeeProfile
    buyTaxBps,                                            // 13: buyTaxRate
    sellTaxBps,                                           // 14: sellTaxRate
    3153600000n,                                          // 15: taxDuration (100 years)
    2592000n,                                             // 16: antiFarmerDuration (30 days)
    10000,                                                // 17: mktBps (100% to marketing)
    0,                                                    // 18: deflationBps (no burn)
    0,                                                    // 19: dividendBps
    0,                                                    // 20: lpBps
    0n,                                                   // 21: minimumShareBalance
    "0x0000000000000000000000000000000000000000",         // 22: dividendToken
    "0x0000000000000000000000000000000000000000",         // 23: commissionReceiver
    TOKEN_VERSION_TAXED_V3,                              // 24: tokenVersion (MUST be 6)
    factory,                                              // 25: vaultFactory
    vaultData,                                            // 26: vaultData
  ];

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
    predictedToken,
    xController: { handle: xHandle || null, xId: xId.toString() },
    flapPageUrl: `https://flap.sh/robinhood/${tokenAddress}`,
  });
}

main().catch((err) => fail(err));
