---
name: flapvault
description: Launch and control Flap tax tokens with auto-buyback vaults on Robinhood Chain 4663. Supports launch, X-proof buyback, reserve withdrawal, airdrop setup, proposal execution, and status reads.
---
# FlapVault skill

Robinhood Chain only. Deployed factory: `0x39769E037884718dcA021BD6beaafFC902377B29`.

## Commands
- `node scripts/launch.js <SYMBOL> [buyTaxBps=300] [sellTaxBps=300] [xHandle=""] [xId=0]`
- `node scripts/buyback.js <token> <vault> <tweetId> <xHandle> <xId>`
- `node scripts/withdraw.js <token> <vault> <amountTokens> <to> <tweetId> <xHandle> <xId>`
- `node scripts/airdrop.js <token> <vault> <amountPerClaimantTokens> <maxClaimants> <tweetId> <xHandle> <xId>`
- `node scripts/execute.js <token> <vault> <proposalId> <tweetId> <xHandle> <xId>`
- `node scripts/status.js [token|vault]`

Write actions validate chain 4663, contract code, vault/token pairing, controller handle/id, monotonic tweet ID, and minimum 0.01 ETH gas. Human token amounts are converted with token decimals. Canonical proof text uses the exact `@flapdotshvault` prefix and lowercase addresses required by the contract.

X-proof buyback submits `minTaxtokenOut=0`. When `lastGoodPrice` is zero, owner/guardian must first bootstrap with `autoBuybackAuto(minOut > 0)`.

## Invariants

**One launch per tweetId (1:1 dedup).** Before any `launch.js` invocation, you MUST:

1. Read `launched.json` (in the skill root) and check the tweetId is not already present.
2. Set `LAUNCH_TWEET_ID=<tweetId>` env var when invoking `launch.js`. The script refuses to run without it.
3. On successful launch, write `{ tweetId, token, vault, txHash, block, name, taxes, xHandle, xId, at }` to `launched.json`.

The cron poll path (`poll-mentions.js`) does NOT invoke `launch.js` directly — it only lists new mentions for the user to approve. Only the orchestrator (the chat LLM) calls `launch.js`, and it MUST pass `LAUNCH_TWEET_ID` every time.

## Environment
- wallet: `X_AGENT_PRIVATE_KEY` or `FLAP_PRIV_KEY`
- RPC: `RPC_URL` or `ALCHEMY_RPC_ROBINHOOD`
- optional: `BUYBACK_VAULT_FACTORY`, `ORACLE_URL`, `ORACLE_API_KEY`

Each script emits one final JSON object to stdout. No vault action bypasses X proof.
