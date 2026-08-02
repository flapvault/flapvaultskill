# FlapVault — Buyback Vault Skill

This skill lets the agent launch and control Flap tax tokens on Robinhood Chain (chain 4663) via the BuybackVault factory and the X (Twitter) controller pattern.

## What this skill does

- **Launch tokens** via VaultPortal.newTokenV6WithVault
- **Trigger buyback** on a vault (via X proof from the bound X controller)
- **Withdraw** from vault reserve (via X proof)
- **Set airdrop rounds** (via X proof)
- **Execute governance proposals** (via X proof)
- **Read** vault state and token info

## When to use this skill

Use when the user (on X or in chat) wants to:
- Launch a new tax token with auto-buyback
- Trigger a buyback
- Withdraw tokens
- Run an airdrop
- Execute a passed proposal
- Check token/vault status

## Chain

Robinhood Chain only (chain 4663). Never use this skill for BNB, Base, or any other chain.

## Tools

| Tool | Description | Inputs |
|---|---|---|
| `launch_token` | Launch a new Flap tax token + buyback vault | `name`, `buyTaxBps?`, `sellTaxBps?`, `imageUrl?` |
| `trigger_buyback` | Trigger buyback on a vault | `token`, `vault`, `tweetId`, `xHandle`, `xId` |
| `withdraw_taxtoken` | Withdraw from reserve | `token`, `vault`, `amount`, `to`, `tweetId`, `xHandle`, `xId` |
| `set_airdrop_round` | Set a new airdrop round (7 days, #FlapAirdrop) | `token`, `vault`, `amountPerClaimant`, `maxClaimants`, `tweetId`, `xHandle`, `xId` |
| `execute_proposal` | Execute a tallied governance proposal | `token`, `vault`, `proposalId`, `tweetId`, `xHandle`, `xId` |
| `get_status` | Read vault/token status | `name?` or `token?` or `vault?` |

## How to call

Always use the bundled scripts in `./scripts/`:

```bash
# Launch
./scripts/launch.js KOPI 300 300

# Buyback (requires X proof params from oracle)
./scripts/buyback.js <token> <vault> <tweetId> <xHandle> <xId>

# Status
./scripts/status.js KOPI
```

The scripts print JSON to stdout. Parse the JSON and reply to the user with a short, human-friendly message.

## Response style

After any action, post a tweet reply (if X-triggered) or chat reply (if developer-triggered) following the templates in `AGENTS.md`. Always include:
- Tx hash on success
- Clear reason on failure
- Short, English-only text
- 1-2 emojis max

For launch success, include the Flap.sh token page link:
```
https://flap.sh/robinhood/{tokenAddress}
```

## Constraints

- **English only** — never reply in Indonesian or other languages
- **Always verify X proof** for vault actions — never bypass
- **Replay protection** — tweetId must be > lastXControllerTweetId for the handle
- **Rate limit** — max 10 actions per xHandle per hour
- **Gas check** — if wallet balance < 0.01 ETH, warn and pause

## Environment

Required env vars:
- `X_AGENT_PRIVATE_KEY` — operational wallet private key
- `RPC_URL` — Robinhood RPC endpoint
- `CHAIN_ID=4663`
- `BUYBACK_VAULT_FACTORY` — deployed factory address
- `ORACLE_URL` — Flap X oracle endpoint
- `X_API_KEY`, `X_API_SECRET`, `X_API_BEARER` — for X API access
- `X_BOT_USER_ID` — numeric ID of @flapdotshvault
- `X_BOT_HANDLE=flapdotshvault`
