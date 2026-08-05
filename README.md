# FlapVault OpenClaw Skill

OpenClaw skill for launching Flap tax tokens + buyback vault on **Robinhood Chain (chain 4663) and BSC mainnet (chain 56)**.

## Supported chains

| Chain | Chain ID | Native | Factory | Vault variant | Status |
|---|---|---|---|---|---|
| **Robinhood Chain** | 4663 | ETH | `0x39769E037884718dcA021BD6beaafFC902377B29` | `v2.2` (full feature) | ✅ Live |
| **BSC mainnet** | 56 | BNB | `0xECD3f4b799f2FA090fCb68294FF6f2a2AF32c763` | `v2.2-bsc-lite` (no governance) | ✅ Live |

## What it does

- `launch_token` — Launch a new Flap tax token with auto-buyback vault (any supported chain)
- `trigger_buyback` — Trigger buyback via X proof (any supported chain)
- `withdraw_taxtoken` — Withdraw from vault reserve (any supported chain — BSC lite supported via X proof as of 2026-08-05)
- `set_airdrop_round` — Set airdrop round (Robinhood only — BSC lite is owner/guardian EOA only)
- `execute_proposal` — Execute governance proposal (Robinhood only — BSC lite has no governance)
- `get_status` — Read vault/token status (any supported chain)

## Install

```bash
# In OpenClaw chat:
"Install skill from https://github.com/flapvault/flapvaultskill"
```

The OpenClaw runtime will fetch:
- `SKILL.md` — main spec
- `docs/IDENTITY_BSC.md` — agent identity
- `docs/SOUL_BSC.md` — voice + tone
- `docs/AGENTS_BSC.md` — operating rules
- `docs/BSC_LAUNCH_GUIDE.md` — **how to detect chain from launch tweets** (read this before responding to any `@flapdotshvault launch` mention)

## Configuration

After install, configure env vars in OpenClaw secrets store or `/data/workspace/.env`:

| Var | Required | Secret? | Notes |
|---|---|---|---|
| `X_AGENT_PRIVATE_KEY` | yes | yes | Bot wallet for X-proof buyback gas |
| `RPC_URL` | yes | no | Use BSC RPC for BSC launches: `https://bsc-dataseed.binance.org` |
| `CHAIN_ID` | yes | no | `4663` for Robinhood, `56` for BSC |
| `BUYBACK_VAULT_FACTORY` | yes | no | `0x39769E...7B29` (Robinhood) or `0xECD3f4b7...2c763` (BSC) |
| `ORACLE_URL` | yes | no | `https://verifyx.taxed.fun/prove` |
| `ORACLE_API_KEY` | yes | yes | |
| `X_API_KEY`, `X_API_SECRET` | yes | yes | |
| `X_ACCESS_TOKEN`, `X_ACCESS_SECRET` | yes | yes | |
| `X_BEARER_TOKEN` | yes | yes | |
| `X_BOT_USER_ID` | yes | no | |
| `X_BOT_HANDLE` | yes | no | e.g. `flapdotshvault` |

## How the X agent decides which chain

The X agent must follow the **Chain resolution from tweet** section in `SKILL.md`. Quick summary:

1. **Launch tweets** → chain comes from the tweet text (`on BSC` or `on Robinhood`). If missing, **ask the user**, never default.
2. **Post-launch tweets** (buyback/withdraw/airdrop/execute) → chain comes from `vault.factory()` (read from on-chain). Ignore the tweet's chain hint.

See `docs/BSC_LAUNCH_GUIDE.md` for the full chain detection rules with examples.

## See also

- [FlapVault smart contracts](https://github.com/flapvault/flapvault) — audited buyback vault
- [Flap docs](https://docs.flap.sh) — Portal / Vault integration reference
- [BSC factory on BscScan](https://bscscan.com/address/0xECD3f4b799f2FA090fCb68294FF6f2a2AF32c763) — verify deployed code
- [Robinhood factory on Blockscout](https://robinhoodchain.blockscout.com/address/0x39769E037884718dcA021BD6beaafFC902377B29) — verify deployed code
