# FlapVault OpenClaw Skill

OpenClaw skill for launching Flap tax tokens + buyback vault on Robinhood Chain (chain 4663).

## What it does

- `launch_token` — Launch a new Flap tax token with auto-buyback vault
- `trigger_buyback` — Trigger buyback via X proof
- `withdraw_taxtoken` — Withdraw from vault reserve
- `set_airdrop_round` — Set airdrop round (7 days, #FlapAirdrop)
- `execute_proposal` — Execute governance proposal
- `get_status` — Read vault/token status

## Install

```bash
# In OpenClaw chat:
"Install skill from https://github.com/dmattrenggana/flapvault-skill"
```

## Configuration

After install, configure env vars in OpenClaw secrets store or `/data/workspace/.env`:

| Var | Required | Secret? |
|---|---|---|
| `X_AGENT_PRIVATE_KEY` | yes | yes |
| `RPC_URL` | yes | no |
| `CHAIN_ID` | yes (default 4663) | no |
| `BUYBACK_VAULT_FACTORY` | yes | no |
| `ORACLE_URL` | yes | no |
| `ORACLE_API_KEY` | yes | yes |
| `X_API_KEY`, `X_API_SECRET` | yes | yes |
| `X_ACCESS_TOKEN`, `X_ACCESS_SECRET` | yes | yes |
| `X_BEARER_TOKEN` | yes | yes |
| `X_BOT_USER_ID` | yes | no |
| `X_BOT_HANDLE` | yes | no |

## See also

- [FlapVault smart contracts](https://github.com/dmattrenggana/flapvault) — audited buyback vault
- [Flap docs](https://docs.flap.sh) — Portal / Vault integration reference
