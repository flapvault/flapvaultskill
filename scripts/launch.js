// Launch a new Flap tax token + buyback vault via VaultPortal.newTokenV6WithVault.
// Usage: node launch.js <name> [buyTaxBps] [sellTaxBps] [xHandle] [xId]
// Example: node launch.js KOPI 300 300 mattrenggana 145621088
//
// Token address must end in "7777" (Flap vanity suffix for TOKEN_TAXED_V3).
// Salt is mined locally before submission via CREATE2 prediction.
//
// The actual deployed NewTokenV6WithVaultParams on Robinhood has 27 fields,
// NOT 26 like the Flap docs (docs describe a different/newer version).
// We use the openchain-verified 27-field ABI that matches the test deploy.

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
const DEX_ID_UNIV2 = 1;
const DEFAULT_BUY_TAX_BPS = 300;
const DEFAULT_SELL_TAX_BPS = 300;
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
  const buyTaxBps = Number(args[1] ?? DEFAULT_BUY_TAX_BPS);
  const sellTaxBps = Number(args[2] ?? DEFAULT_SELL_TAX_BPS);
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

  // 2. Build vaultData (factory's BuybackVaultConfig: owner, xController, xId)
  const vaultData = AbiCoder.defaultAbiCoder().encode(
    ["address", "string", "uint128"],
    [
      wallet.address,
      xHandle,
      xId,
    ]
  );

  // 3. Build params with the actual 27-field ABI
  //    Field order matches openchain-verified signature and test deploy:
  //    (string,string,string,uint8,bytes32,uint8,address,uint256,bytes,
  //     bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,
  //     uint16,uint16,uint256,address,address,uint8,address,bytes)
  const params = [
    name,                                                 // name
    name,                                                 // symbol
    "",                                                   // meta
    0x3e,                                                 // dexThresh (62, matches test)
    salt,                                                 // salt
    MIGRATOR_TYPE_V2,                                     // migratorType
    "0x0000000000000000000000000000000000000000",         // quoteToken (native ETH)
    0n,                                                   // quoteAmt
    "0x",                                                 // permitData
    "0x0000000000000000000000000000000000000000000000000000000000000000",  // extensionID
    "0x",                                                 // extensionData
    0,                                                    // dexId
    0,                                                    // lpFeeProfile
    buyTaxBps,                                            // buyTaxRate
    sellTaxBps,                                           // sellTaxRate
    197000000n,                                           // totalSupply (matches test)
    10125,                                                // maxWallet (matches test)
    0,                                                    // deflationBps
    0,                                                    // dividendBps
    10000,                                                // vaultBps (100% to vault)
    0,                                                    // lpBps
    0n,                                                   // lockerDeadline
    "0x0000000000000000000000000000000000000000",         // locker
    "0x0000000000000000000000000000000000000000",         // hook
    0,                                                    // mevModuleV2Type
    "0x0000000000000000000000000000000000000000",         // mevModuleV2
    vaultData,                                            // vaultData
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
