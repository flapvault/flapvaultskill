---
name: flapvault
description: Launch and control Flap tax tokens (TOKEN_TAXED_V3) with auto-buyback vaults on Robinhood Chain (4663) and BSC mainnet (56). Supports launch, X-proof buyback, X-proof reserve withdrawal, airdrop setup (Robinhood only), and status reads.
---
# FlapVault skill

Cross-chain support for the BuybackVault pattern on Robinhood Chain and BSC mainnet.

## Supported chains

| Chain | Chain ID | Native | Factory | Vault variant | Status |
|---|---|---|---|---|---|
| **Robinhood Chain** | 4663 | ETH | `0x39769E037884718dcA021BD6beaafFC902377B29` | `v2.2` (full feature) | ✅ Live |
| **BSC mainnet** | 56 | BNB | `<BSC_FACTORY>` (set after deploy) | `v2.2-bsc-lite` (no governance) | ⏳ Pending deploy |

### Feature parity matrix

| Feature | Robinhood | BSC lite |
|---|---|---|
| Token launch via VaultPortal | ✅ | ✅ |
| X-proof buyback trigger (`triggerBuybackByProof`) | ✅ | ✅ |
| 75% / 25% buyback split (with ecoEthPool) | ✅ | ❌ (100% buyback, no ecopool) |
| Staking + dividend (1 day lock) | ✅ | ✅ |
| Tweet-gated airdrops | ✅ | ✅ |
| X-proof withdraw (`withdrawVaultTaxtokenByProof`) | ✅ | ✅ (re-enabled) |
| X-proof airdrop round (`setAirdropRoundByProof`) | ✅ | ❌ (owner/guardian EOA only) |
| Governance: createProposal / vote / execute | ✅ | ❌ (entirely removed) |
| Uniswap V4 buyback | ✅ | ❌ (V4 not on BSC) |

**BSC lite rationale:** BSC enforces the standard 24KB EIP-170 contract size limit. The full Robinhood implementation is 33,981 bytes. The lite build drops governance + ecopool + setAirdropRoundByProof to fit in 23,633 bytes. Core buyback (now 100% BNB → taxtoken, more aggressive than Robinhood's 75%) + staking + airdrops + X-proof buyback trigger + X-proof withdraw are preserved.

## Commands

> **Note:** The skill scripts (`scripts/launch.js`, `buyback.js`, `withdraw.js`, `airdrop.js`, `execute.js`, `status.js`) currently enforce `CHAIN_ID=4663` and Robinhood addresses only. Multi-chain script support is pending (`shared.js` needs an ADDRESSES-by-chain refactor). **For now:**
> - **Robinhood:** use the scripts as-is.
> - **BSC:** scripts will throw `Unsupported CHAIN_ID` until the refactor lands. Use `forge` or direct ethers calls for BSC.

- `node scripts/launch.js <SYMBOL> [buyTaxBps=300] [sellTaxBps=300] [xHandle=""] [xId=0]`
- `node scripts/buyback.js <token> <vault> <tweetId> <xHandle> <xId>`
- `node scripts/withdraw.js <token> <vault> <amountTokens> <to> <tweetId> <xHandle> <xId>` (Robinhood only — until `shared.js` multi-chain refactor)
- `node scripts/airdrop.js <token> <vault> <amountPerClaimantTokens> <maxClaimants> <tweetId> <xHandle> <xId>` (Robinhood only)
- `node scripts/execute.js <token> <vault> <proposalId> <tweetId> <xHandle> <xId>` (Robinhood only)
- `node scripts/status.js [token|vault]`

Write actions validate chain ID, contract code, vault/token pairing, controller handle/id, monotonic tweet ID, and minimum 0.01 native gas. Human token amounts are converted with token decimals. Canonical proof text uses the exact `@flapdotshvault` prefix and lowercase addresses required by the contract.

X-proof buyback submits `minTaxtokenOut=0`. When `lastGoodPrice` is zero, owner/guardian must first bootstrap with `autoBuybackAuto(minOut > 0)`.

## Chain detection

Always read the vault's `factory()` first and compare against the known factory whitelist. Never assume the chain from a tweet alone.

**Whitelist (add BSC factory address once deployed):**
- `0x39769E037884718dcA021BD6beaafFC902377B29` → Robinhood (chain 4663, native ETH)
- `<BSC_FACTORY>` → BSC mainnet (chain 56, native BNB)

If `factory()` doesn't match any known factory, **refuse the action** and explain that the vault isn't recognized.

## Per-chain constants (read from `shared.js` ADDRESSES or set as env)

The scripts' `shared.js` exports `ADDRESSES` indexed per chain. For BSC (once the refactor lands), expected constants:

| Constant | BSC mainnet value |
|---|---|
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| V2_FACTORY (PancakeSwap) | `0xcA143ce32fe78f1f7019D838670724e5259BB757` |
| V2_ROUTER (PancakeSwap) | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |
| V3 SWAP_ROUTER_02 (PancakeSwap) | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` |
| X_VERIFIER (XGeneralVerifier) | `0xcA8DBE6CAC4BFDc41226b0BaF2359fd99989b3E4` |
| FLAP_PORTAL | `0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0` |
| TOKEN_IMPL_TAXED_V3 | `0x024f18294970B5c76c0691b87f138A0317156422` |
| Page URL | `https://flap.sh/bnb/{token}` |

Oracle endpoint format: `https://verifyx.taxed.fun/prove?chain_id={CHAIN_ID}` (pass `chain_id=56` for BSC).

## Invariants

**One launch per tweetId (1:1 dedup).** Before any `launch.js` invocation, you MUST:

1. Read `launched.json` (in the skill root) and check the tweetId is not already present.
2. Set `LAUNCH_TWEET_ID=<tweetId>` env var when invoking `launch.js`. The script refuses to run without it.
3. On successful launch, write `{ tweetId, chainId, token, vault, txHash, block, name, taxes, xHandle, xId, at }` to `launched.json`.

The cron poll path (`poll-mentions.js`) does NOT invoke `launch.js` directly — it only lists new mentions for the user to approve. Only the orchestrator (the chat LLM) calls `launch.js`, and it MUST pass `LAUNCH_TWEET_ID` every time.

**BSC lite action filter.** When the vault's factory resolves to BSC lite, only the following actions are supported via X proof:
- ✅ `trigger_buyback` — `@flapdotshvault buyback 0xtoken 0xvault`
- ✅ `withdraw_taxtoken` — `@flapdotshvault withdraw 0xtoken 0xvault <amount> to 0xto`
- ❌ `set_airdrop_round` — reply with `"BSC vault (lite build) doesn't support X-proof airdrop round setup. Owner/guardian EOA only."`
- ❌ `execute_proposal` — reply with `"BSC vault (lite build) has no governance. No execution path."`

**Launch path applies to both chains.** The `launch.js` script will work on BSC once `shared.js` is refactored. Until then, BSC launches must go through `cast` or `forge` with the BSC factory address as `vaultFactory` in the `NewTokenV6WithVaultParams` tuple (field 25).

## Environment
- wallet: `X_AGENT_PRIVATE_KEY` or `FLAP_PRIV_KEY`
- RPC: `RPC_URL` (e.g. `https://bsc-dataseed.binance.org` for BSC, `https://rpc.mainnet.chain.robinhood.com` for Robinhood)
- chain: `CHAIN_ID` (4663 or 56)
- optional: `BUYBACK_VAULT_FACTORY`, `ORACLE_URL`, `ORACLE_API_KEY`

Each script emits one final JSON object to stdout. No vault action bypasses X proof.

## Contracts

Source under `contracts/`:
- `BuybackVaultFactory.sol` + `BuybackVaultImplementation.sol` — Robinhood (full feature)
- `bsc/BuybackVaultBscFactory.sol` + `bsc/BuybackVaultBscImplementation.sol` — BSC lite

Both factories share the same VaultBase / VaultBaseV2 / VaultFactoryBaseV2 lineage from the public `FlapVaultExample` repo. The BSC lite build is a surgical refactor: same buyback + staking + airdrop + X-controller flow, just without the governance surface that didn't fit the 24KB limit.
