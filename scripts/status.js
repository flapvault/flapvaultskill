// Read vault/token status (no X proof needed, read-only)
// Usage: node status.js [name|token|vault]
// Examples:
//   node status.js                    # overall agent status
//   node status.js KOPI               # by name (searches launched tokens)
//   node status.js 0xtoken            # by token address
//   node status.js 0xvault            # by vault address

import {
  getProvider,
  BUYBACK_VAULT_ABI,
  ERC20_ABI,
  ok,
  fail,
  ADDRESSES,
} from "./shared.js";

async function readVaultStatus(vaultAddress) {
  const provider = getProvider();
  const vault = new (await import("ethers")).Contract(vaultAddress, BUYBACK_VAULT_ABI, provider);

  const [
    taxtoken,
    taxRateBps,
    totalStaked,
    ecoEthPool,
    reserve,
    airdrop,
    controllerXHandle,
    controllerXId,
  ] = await Promise.all([
    vault.taxtoken(),
    vault.taxRateBps(),
    vault.totalStaked(),
    vault.ecoEthPool(),
    vault.getTaxtokenReserve(),
    vault.airdropRound(),
    vault.controllerXHandle(),
    vault.controllerXId(),
  ]);

  // Read token info
  const token = new (await import("ethers")).Contract(taxtoken, ERC20_ABI, provider);
  const [name, symbol, totalSupply] = await Promise.all([
    token.name(),
    token.symbol(),
    token.totalSupply(),
  ]);

  return {
    token: taxtoken,
    name,
    symbol,
    taxRateBps: Number(taxRateBps),
    totalStaked: totalStaked.toString(),
    ecoEthPool: ecoEthPool.toString(),
    reserve: reserve.toString(),
    totalSupply: totalSupply.toString(),
    airdrop: {
      amountPerClaimant: airdrop.amountPerClaimant.toString(),
      maxClaimants: airdrop.maxClaimants.toString(),
      claimed: airdrop.claimed.toString(),
      startTime: Number(airdrop.startTime),
      endTime: Number(airdrop.endTime),
    },
    xController: {
      handle: controllerXHandle,
      xId: controllerXId.toString(),
    },
    flapPageUrl: `https://flap.sh/robinhood/${taxtoken}`,
  };
}

async function main() {
  const query = process.argv[2];

  if (!query) {
    // Overall agent status
    const provider = getProvider();
    const blockNumber = await provider.getBlockNumber();
    const walletAddress = (await import("ethers")).Wallet.createRandom().address; // Just for format
    ok({
      type: "agent_overall",
      chain: "Robinhood",
      chainId: 4663,
      rpc: process.env.RPC_URL || "https://rpc.mainnet.chain.robinhood.com",
      lastBlock: blockNumber,
      note: "Pass a name, token address, or vault address to see details",
    });
    return;
  }

  // If looks like an address, read directly
  if (query.startsWith("0x") && query.length === 42) {
    try {
      // Try as vault first
      const status = await readVaultStatus(query);
      ok({ type: "vault_status", vault: query, ...status });
      return;
    } catch (err) {
      // Maybe a token — just return token info
      try {
        const provider = getProvider();
        const token = new (await import("ethers")).Contract(query, ERC20_ABI, provider);
        const [name, symbol, totalSupply, decimals] = await Promise.all([
          token.name(),
          token.symbol(),
          token.totalSupply(),
          token.decimals(),
        ]);
        ok({
          type: "token_status",
          token: query,
          name,
          symbol,
          totalSupply: totalSupply.toString(),
          decimals: Number(decimals),
          flapPageUrl: `https://flap.sh/robinhood/${query}`,
        });
        return;
      } catch (err2) {
        fail(`Could not read address as vault or token: ${err.message}`);
      }
    }
  }

  // Search by name (would need launched_tokens DB — out of scope for read-only script)
  fail(`Searching by name "${query}" requires the launched_tokens DB. Pass a token or vault address instead.`);
}

main().catch((err) => fail(err));
