// Trigger a buyback via X proof
// Usage: node buyback.js <token> <vault> <tweetId> <xHandle> <xId> [substring]
// Example: node buyback.js 0xtoken 0xvault 1234567890123456789 andi 9876543210

import {
  getWallet,
  BUYBACK_VAULT_ABI,
  buildProof,
  fetchXProof,
  ok,
  fail,
} from "./shared.js";

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 5) {
    fail("Usage: buyback.js <token> <vault> <tweetId> <xHandle> <xId> [substring]");
  }

  const [token, vault, tweetId, xHandle, xId] = args;
  const substring = args[5] || `buyback ${token} ${vault}`;

  const wallet = getWallet();
  const vaultContract = new (await import("ethers")).Contract(vault, BUYBACK_VAULT_ABI, wallet);

  // 1. Verify X controller binding
  const boundHandle = (await vaultContract.controllerXHandle()).toLowerCase();
  if (!boundHandle) {
    fail("Vault has no X controller bound");
  }
  if (boundHandle !== xHandle.toLowerCase()) {
    fail(`X handle mismatch. Bound: ${boundHandle}, got: ${xHandle}`);
  }
  const boundXId = await vaultContract.controllerXId();
  if (BigInt(boundXId) !== BigInt(xId)) {
    fail(`X id mismatch. Bound: ${boundXId}, got: ${xId}`);
  }

  // 2. Replay protection check
  const lastTweetId = await vaultContract.lastXControllerTweetId(xHandle.toLowerCase());
  if (BigInt(lastTweetId) >= BigInt(tweetId)) {
    fail(`Tweet ID too old (replay). Last: ${lastTweetId}, got: ${tweetId}`);
  }

  // 3. Fetch X proof from oracle
  const proofData = await fetchXProof({ tweetId, substring });
  const proof = buildProof(
    proofData.tweet_id,
    proofData.x_handle,
    proofData.x_id,
    proofData.substring
  );

  // 4. Submit buyback
  const minTaxtokenOut = 1n; // Accept any positive amount (slippage handled at quote level)
  const tx = await vaultContract.triggerBuybackByProof(minTaxtokenOut, proof, proofData.signature);
  const receipt = await tx.wait();

  ok({
    action: "buyback",
    token,
    vault,
    txHash: receipt.hash,
    blockNumber: receipt.blockNumber,
    tweetId,
    xHandle,
    xId,
  });
}

main().catch((err) => fail(err));
