# BSC Launch Guide for OpenClaw X Agent

This guide explains the **important things the X agent must do when a user wants to launch a token on BSC mainnet (chain 56)** vs the default Robinhood Chain (chain 4663). Read this before responding to any `@flapdotshvault launch` mention.

## TL;DR for the X agent

> **For launches, the user MUST specify the chain in the tweet.**
> Look for `on BSC` or `on Robinhood` in the tweet text.
> If the user did NOT specify a chain, **DO NOT GUESS — ASK THEM FIRST**.

## Why this matters

- The launch creates a token on a SPECIFIC chain. Once launched, you can't "move" it to another chain.
- A wrong chain = wrong factory address = failed tx + wasted gas + the tweet was used (one-shot, see dedup invariant in SKILL.md).
- Robinhood and BSC have different explorers, different DEX liquidity, different wallets — picking the wrong one is a real cost to the user.

## How to detect chain from a launch tweet

### Step 1: Read the tweet text

Look for these substrings (case-insensitive):

| Substring (any case) | Means |
|---|---|
| `on BSC` / `on bnb` / `on bsc` / `on binance` | Launch on **BSC mainnet (chain 56)** |
| `on Robinhood` / `on RH` / `on robinhood` / `on rh` | Launch on **Robinhood Chain (chain 4663)** |
| `on Polygon` / `on ETH` / `on Base` / `on Arbitrum` / anything else | **Reject** — not supported |
| *(no chain substring at all)* | **ASK THE USER** — see Step 3 |

### Step 2: Parse the launch params

Canonical launch tweet format:
```
@flapdotshvault launch <NAME> <buyTaxBps> <sellTaxBps> [on <chain>] [x=@<handle> <xId>]
```

Examples the X agent should handle:

| Tweet | Parsed as | Action |
|---|---|---|
| `@flapdotshvault launch TEST 300 300` | chain = NONE | **ASK before launching** |
| `@flapdotshvault launch TEST 300 300 on BSC` | chain = BSC | **Launch on BSC** |
| `@flapdotshvault launch TEST 300 300 on Robinhood` | chain = Robinhood | **Launch on Robinhood** |
| `@flapdotshvault launch KOPI 500 500 on BSC x=@alice 145621088` | chain = BSC + X controller bound | **Launch on BSC, bind @alice as X controller** |
| `@flapdotshvault launch X 300 300 on Polygon` | chain = Polygon | **Reply: "Only BSC and Robinhood are supported."** |
| `@flapdotshvault launch X 300 300 on BSC on Robinhood` | chain = both (conflict) | **Reply: "Pick ONE chain. Re-tweet with `on BSC` OR `on Robinhood`."** |
| `@flapdotshvault launch X 300 300 bsc` (no "on") | chain = ambiguous | **Default: BSC** (recognized keyword), but confirm in reply |

### Step 3: If chain is missing — ASK FIRST, do NOT launch

**Reply template when chain is missing:**
```
@{handle} Which chain? BSC or Robinhood?

📌 Robinhood (default): {existing factories, your familiar launch spot}
📌 BSC: {new chain, factory 0xECD3f4b7...2c763}

Re-tweet with `on BSC` or `on Robinhood` to confirm. The launch tweet is one-shot — I won't guess.
```

**NEVER do these:**
- ❌ Do NOT silently default to Robinhood and launch — the user might have wanted BSC
- ❌ Do NOT silently default to BSC and launch — same risk
- ❌ Do NOT launch and ask the user to "verify the chain" — too late, the token is already on a chain

### Step 4: When chain is present, also confirm explicitly in the launch reply

After a successful launch, the reply should make the chain OBVIOUS:

```
@{handle} {NAME} live on {CHAIN_NAME}! 🦋

Token: {tokenAddress}
Vault: {vaultAddress}
Explorer: {explorerUrl}  ← include the chain's explorer
View: https://flap.sh/{chain_slug}/{token}
Tx: {txHash}
```

Explorer URLs:
- Robinhood: `https://explorer.robinhood.com/tx/{txHash}` (verify exact URL)
- BSC: `https://bscscan.com/tx/{txHash}`

`chain_slug` for Flap page:
- Robinhood: `robinhood`
- BSC: `bnb`

## Per-chain constants (the agent must know)

When launching on **BSC** (chain 56), the launch tx uses these constants instead of the Robinhood ones:

| Constant | Robinhood (chain 4663) | BSC mainnet (chain 56) |
|---|---|---|
| `CHAIN_ID` | 4663 | 56 |
| `RPC_URL` | `https://rpc.mainnet.chain.robinhood.com` | `https://bsc-dataseed.binance.org` |
| `BUYBACK_VAULT_FACTORY` | `0x39769E037884718dcA021BD6beaafFC902377B29` | `0xECD3f4b799f2FA090fCb68294FF6f2a2AF32c763` |
| `FLAP_PORTAL` | `0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09` | `0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0` |
| `VAULT_PORTAL` | `0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B` | `0x90497450f2a706f1951b5bdda52B4E5d16f34C06` |
| `WETH` (wrapped native) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` (WBNB) |
| `V2_FACTORY` | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` | `0xcA143ce32fe78f1f7019D838670724e5259BB757` (PancakeSwap) |
| `V2_ROUTER` | `0x89e5DB8B5aA49aA85AC63f691524311AEB649eba` | `0x10ED43C718714eb63d5aA57B78B54704E256024E` (PancakeSwap) |
| `V3_SWAP_ROUTER` | `0xCaf681a66D020601342297493863E78C959E5cb2` | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` (PancakeSwap) |
| `X_VERIFIER` | `0xccDaB0d5Bc6E0aCb8B157cffFA062688Aa849c17` | `0xcA8DBE6CAC4BFDc41226b0BaF2359fd99989b3E4` |
| `TOKEN_IMPL_TAXED_V3` | `0x7777C8743C88B3aff3cf262135bef2c8b2e83333` | `0x024f18294970B5c76c0691b87f138A0317156422` |
| `Flap page URL` | `https://flap.sh/robinhood/{token}` | `https://flap.sh/bnb/{token}` |

## After-launch differences (BSC vs Robinhood)

The X agent should ALSO know that BSC vaults are "lite" — different from Robinhood:

| Feature | Robinhood | BSC lite |
|---|---|---|
| Auto-buyback via X proof | ✅ | ✅ |
| Withdraw via X proof | ✅ | ✅ |
| Airdrop setup via X proof | ✅ | ❌ (owner/guardian EOA only) |
| Governance proposals | ✅ | ❌ (no governance) |

**Reply template if user asks for unsupported BSC feature:**
```
@{handle} BSC vault (lite build) doesn't support that. Governance + X-proof airdrop setup were removed to fit BSC's 24KB contract size limit.

Owner/guardian can still do it via direct EOA tx.
```

## Pre-launch checklist for the X agent

Before running `launch.js` for a BSC launch, the X agent must verify:

- [ ] Tweet says `on BSC` (not just `bsc` alone — should be unambiguous)
- [ ] Tweet does NOT also say `on Robinhood` (no conflict)
- [ ] Tweet's `NAME`, `buyTaxBps`, `sellTaxBps` are all parseable
- [ ] If `xHandle` and `xId` are present, they look like a real X handle (starts with `@`) and a numeric ID
- [ ] tweetId is fresh (not in `launched.json` yet)
- [ ] `RPC_URL` is set to BSC RPC (`https://bsc-dataseed.binance.org`)
- [ ] `CHAIN_ID=56` is set
- [ ] `BUYBACK_VAULT_FACTORY=0xECD3f4b799f2FA090fCb68294FF6f2a2AF32c763` is set
- [ ] `X_AGENT_PRIVATE_KEY` has ≥ 0.0005 BNB balance (gas for launch + small buffer)

## What to tell the user when they tweet `@flapdotshvault launch TEST 300 300 on BSC`

The X agent should reply (before launching):

```
@{handle} Got it — launching {NAME} on BSC mainnet. Confirming:

• Chain: BSC (chain 56)
• Buy tax: {buyTaxBps/100}%
• Sell tax: {sellTaxBps/100}%
• X controller: {if xHandle, show it; else "none — set later via setXController"}
• Factory: 0xECD3f4b799f2FA090fCb68294FF6f2a2AF32c763 (v2.2-bsc-lite)
• Note: BSC vault has no governance + no X-proof airdrop setup. Buyback + withdraw via X proof are supported.

Reply "confirm" to proceed, or "cancel" to abort.
```

Wait for the user's "confirm" reply (with tweetId > original launch tweet). Then launch.

## What to reply if the user tweets `@flapdotshvault launch TEST 300 300` (no chain)

```
@{handle} Which chain? Re-tweet with `on BSC` or `on Robinhood`:

• Robinhood (chain 4663): ETH gas, factory 0x39769E...7B29 (full feature)
• BSC mainnet (chain 56): BNB gas, factory 0xECD3f4b7...2c763 (lite — no governance)

⚠️ Once launched, you can't switch chains. So please specify.
```

## One-shot launch tweet (the dedup invariant)

**A launch tweet is one-shot.** If the user already tweeted `@flapdotshvault launch X 300 300 on BSC` once, and you launched it, the same tweet text cannot launch again. If the user re-sends the SAME tweet (e.g. bot crashed mid-launch), check `launched.json` first:

```bash
cat launched.json | jq '.[] | select(.tweetId == "<TWEET_ID>")'
```

If found, reply: `@{handle} Already launched {NAME} on {CHAIN} at {originalTxHash}. Tweet a NEW launch request (different tweetId) to try again.`

If NOT found, proceed with the launch (this handles the bot-crash-mid-launch case).

## Summary: The 5-minute mental model

1. **User tweets `@flapdotshvault launch NAME 300 300 on <chain>`** — X agent detects chain from text.
2. **If no chain → ASK.** Never guess. Never default-and-launch.
3. **If chain = BSC** → use BSC constants (factory 0xECD3f4b7..., WBNB, PancakeSwap, etc.).
4. **If chain = Robinhood** → use Robinhood constants (factory 0x39769E..., WETH, Uniswap, etc.).
5. **After launch → reply with chain OBVIOUSLY** in the response (token, vault, explorer, flap.sh link).

That's it. The X agent should be able to handle BSC launches correctly with this guide.
