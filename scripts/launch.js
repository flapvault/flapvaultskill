// Launch a new Flap tax token + buyback vault
// Usage: node launch.js <name> [buyTaxBps] [sellTaxBps] [imageUrl] [xHandle] [xId]
// Example: node launch.js KOPI 300 300 "" mattrenggana 145621088
//
// xHandle + xId are extracted from the tweet author at runtime by the X Agent
// (NOT from env vars — each launch is bound to a different user who mentioned the bot).
// Pass empty strings for both to skip X controller binding (manual mode).

import {
  getWallet,
  VAULT_PORTAL_ABI,
  FACTORY_ABI,
  ADDRESSES,
  ok,
  fail,
  getFactoryAddress,
  AbiCoder,
} from "./shared.js";

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 1) {
    fail("Usage: launch.js <name> [buyTaxBps=300] [sellTaxBps=300] [imageUrl=''] [xHandle=''] [xId=0]");
  }

  const name = args[0].toUpperCase();
  const buyTaxBps = Number(args[1] ?? 300);
  const sellTaxBps = Number(args[2] ?? 300);
  const imageUrl = args[3] ?? "";
  const xHandle = (args[4] ?? "").toLowerCase();
  const xId = args[5] ? BigInt(args[5]) : 0n;

  // Validate X controller consistency
  if (xHandle && xId === 0n) {
    fail("xId required when xHandle is set");
  }
  if (!xHandle && xId !== 0n) {
    fail("xId must be 0 when xHandle is empty");
  }

  // Validate name
  if (!/^[A-Z0-9]{1,11}$/.test(name)) {
    fail(`Invalid name: ${name}. Must be 1-11 alphanumeric characters.`);
  }

  if (buyTaxBps > 2000 || sellTaxBps > 2000) {
    fail(`Tax too high. Max 2000 bps (20%).`);
  }

  const wallet = getWallet();
  const factory = getFactoryAddress();
  const portal = ADDRESSES.VAULT_PORTAL;

  // Note: vaultBps=10000 is enforced ON-CHAIN by factory's _validateBeforeLaunch.
  // No client-side check needed (and previous script-side check used wrong ABI for
  // tokenCreationPolicies() which returns FactoryPolicy[] not (uint16,bool)).

  // Build params
  const salt = "0x" + Array.from({ length: 64 }, () => Math.floor(Math.random() * 16).toString(16)).join("");
  const uri = imageUrl
    ? // Use imageUrl directly if it looks like JSON metadata
      imageUrl
    : // Default metadata (basic)
      `data:application/json,${encodeURIComponent(
        JSON.stringify({
          name,
          description: `${name} on Flap`,
          image: "",
        })
      )}`;

  // Encode BuybackVaultConfig: (owner, xController, xId)
  // 3 fields matching the on-chain struct (taxtoken is set by implementation.initialize, not here).
  const vaultData = AbiCoder.defaultAbiCoder().encode(
    ["address", "string", "uint128"],
    [
      wallet.address,   // owner (X Agent wallet; 0x0 falls back to commissionRecipient)
      xHandle,          // xController (from CLI = tweet author handle)
      xId,              // xId (from CLI = tweet author numeric ID)
    ]
  );

  const params = {
    name,
    symbol: name,
    buyTaxBps,
    sellTaxBps,
    tokenAdmin: wallet.address,
    uri,
    salt,
    locker: "0x0000000000000000000000000000000000000000",
    mevModules: [],
    hook: "0x0000000000000000000000000000000000000000",
    mevModuleV2: "0x0000000000000000000000000000000000000000",
    mevDescendingFees: true,
    lockerDeadline: 0n,
    vaultConfig: {
      vaultBps: 10000, // Hard-enforced: 100%
      vaultFactory: factory,
      vaultImpl: "0x0000000000000000000000000000000000000000", // Factory uses default impl
      vaultData,
    },
  };

  // Submit
  const portalContract = new (await import("ethers")).Contract(portal, VAULT_PORTAL_ABI, wallet);
  const tx = await portalContract.newTokenV6WithVault(params);
  const receipt = await tx.wait();

  // Parse TokenCreated event
  const iface = portalContract.interface;
  let tokenAddress = null;
  let vaultAddress = null;
  for (const log of receipt.logs) {
    try {
      const parsed = iface.parseLog(log);
      if (parsed && parsed.name === "TokenCreated") {
        tokenAddress = parsed.args.token;
        vaultAddress = parsed.args.vault;
        break;
      }
    } catch {}
  }

  if (!tokenAddress) {
    fail("TokenCreated event not found in receipt");
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
    flapPageUrl: `https://flap.sh/robinhood/${tokenAddress}`,
  });
}

main().catch((err) => fail(err));
