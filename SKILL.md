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
| **BSC mainnet** | 56 | BNB | `0xECD3f4b799f2FA090fCb68294FF6f2a2AF32c763` (set after deploy) | `v2.2-bsc-lite` (no governance) | ⏳ Live |

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
- `0xECD3f4b799f2FA090fCb68294FF6f2a2AF32c763` → BSC mainnet (chain 56, native BNB)

If `factory()` doesn't match any known factory, **refuse the action** and explain that the vault isn't recognized.

## Chain resolution from tweet

The X agent must determine the target chain from the user's tweet text. The mechanism differs by action type:

### Launches (no vault yet → chain must be in tweet)

The user must specify the chain explicitly. The agent MUST look for one of these tokens in the tweet (case-insensitive):

| Token | Resolves to |
|---|---|
| `on BSC` / `on bnb` / `on bsc` / `on binance` / `bsc` / `bnb` / `binance` | BSC mainnet (chain 56) |
| `on Robinhood` / `on RH` / `on robinhood` / `robinhood` / `rh` | Robinhood Chain (chain 4663) |
| *(no chain token, or anything else)* | **Default: Robinhood** |

**Canonical launch tweet format:**
```
@flapdotshvault launch <NAME> <buyTaxBps> <sellTaxBps> [on <chain>] [x=@<handle> <xId>]
```

**Examples:**
```
@flapdotshvault launch TEST 300 300                              # defaults to Robinhood
@flapdotshvault launch TEST 300 300 on Robinhood                 # explicit Robinhood
@flapdotshvault launch TEST 300 300 on BSC                       # explicit BSC
@flapdotshvault launch KOPI 500 500 on BSC x=@alice 145621088    # BSC + X controller bound
```

If the user wants to be sure: ask them to include `on BSC` or `on Robinhood` explicitly. If they omit the chain token and the X agent has prior context (a previous tweet in the thread specifying chain), use that. Otherwise default to Robinhood.

**When chain is ambiguous and could be a typo, ASK the user to confirm.** Never guess between BSC and Robinhood — these are different factories, different native tokens, different explorers. A wrong guess burns gas and the launch tweet is one-shot.

### Post-launch actions (vault exists → chain from on-chain lookup)

For `buyback`, `withdraw`, `airdrop`, `execute`, the user tweets the **vault address** (and token address). The chain is determined by:

1. Read `factory()` from the vault contract.
2. Compare against the whitelist:
   - `0x39769E037884718dcA021BD6beaafFC902377B29` → Robinhood (chain 4663, native ETH)
   - `0xECD3f4b799f2FA090fCb68294FF6f2a2AF32c763` → BSC mainnet (chain 56, native BNB)
3. If factory doesn't match any known factory, refuse the action.
4. The user does NOT need to specify the chain in the tweet — the on-chain lookup is authoritative.

**Even if the user writes `on BSC` in a buyback tweet, ignore it** — chain is determined by the vault, not the tweet. If the tweet claims a chain that contradicts the on-chain factory, post a warning reply but proceed with the on-chain chain (don't silently switch).

### Handling conflicting or missing chain hints

| Situation | Resolution |
|---|---|
| Launch tweet, no chain token, no prior context | Default to **Robinhood**, post reply with `Launching on Robinhood (default). Reply "switch to BSC" to cancel + relaunch.` |
| Launch tweet, chain token present | Use the specified chain |
| Launch tweet, multiple chain tokens (e.g. `on BSC on Robinhood`) | Reject: `"Please specify only one chain. Tweet again with `on BSC` OR `on Robinhood`."` |
| Launch tweet, unknown chain token (e.g. `on Polygon`) | Reject: `"Only BSC and Robinhood are supported. Tweet again with `on BSC` or `on Robinhood`."` |
| Post-launch tweet, vault factory unknown | Reject: `"Vault factory not recognized. Are you sure this is a FlapVault?"` |
| Post-launch tweet, `on BSC` in text but vault is on Robinhood | Ignore the text hint, proceed with on-chain Robinhood, append to reply: `⚠️ tweet said BSC but vault is on Robinhood — used Robinhood.` |
| Post-launch tweet, vault factory on BSC + user calls `execute_proposal` | Reject: `"BSC lite has no governance. No execution path."` |

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

**Launch path applies to both chains.** The `launch.js` script will work on BSC once `shared.js` is refactored. Until then, BSC launches must go through `cast` or `forge` with the BSC factory address as `vaultFactory` in the `NewTokenV6WithVaultParams` tuple (field 25). When invoking `launch.js` for BSC manually, set `CHAIN_ID=56` and `BUYBACK_VAULT_FACTORY=0xECD3f4b799f2FA090fCb68294FF6f2a2AF32c763` as env vars.

**Canonical tweet formats by action:**

```
LAUNCH (chain from tweet text):
  @flapdotshvault launch <NAME> <buyTaxBps> <sellTaxBps> [on BSC|on Robinhood] [x=@<handle> <xId>]

BUYBACK (chain from vault.factory() — vault address in tweet):
  @flapdotshvault buyback 0x<token> 0x<vault>

WITHDRAW (Robinhood + BSC lite; chain from vault):
  @flapdotshvault withdraw 0x<token> 0x<vault> <amount> to 0x<to>

AIRDROP (Robinhood only; chain from vault):
  @flapdotshvault airdrop 0x<token> 0x<vault> amount=<amt> max=<max>

EXECUTE PROPOSAL (Robinhood only; chain from vault):
  @flapdotshvault execute proposal 0x<token> 0x<vault> <id>
```

For buyback/withdraw/airdrop/execute, the tweet text is converted by the oracle into an `XGeneralProof` struct and verified on-chain. The canonical substring (used by `_verifyXController`) must EXACTLY match the format above — lowercase addresses, single space between tokens, `to` for withdraw destination.

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
