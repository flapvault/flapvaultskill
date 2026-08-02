// Withdraw taxtoken from vault reserve via X proof
// Usage: node withdraw.js <token> <vault> <amount> <to> <tweetId> <xHandle> <xId>
// Example: node withdraw.js 0xtoken 0xvault 2000 0xto 1234567890 andi 9876543210

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
  if (args.length < 7) {
    fail("Usage: withdraw.js <token> <vault> <amount> <to> <tweetId> <xHandle> <xId>");
  }

  const [token, vault, amount, to, tweetId, xHandle, xId] = args;
  const amountWei = BigInt(amount);

  const wallet = getWallet();
  const vaultContract = new (await import("ethers")).Contract(vault, BUYBACK_VAULT_ABI, wallet);

  // Verify X controller (same as buyback)
  const boundHandle = (await vaultContract.controllerXHandle()).toLowerCase();
  if (boundHandle !== xHandle.toLowerCase()) {
    fail(`X handle mismatch. Bound: ${boundHandle}, got: ${xHandle}`);
  }
  const boundXId = await vaultContract.controllerXId();
  if (BigInt(boundXId) !== BigInt(xId)) {
    fail(`X id mismatch`);
  }
  const lastTweetId = await vaultContract.lastXControllerTweetId(xHandle.toLowerCase());
  if (BigInt(lastTweetId) >= BigInt(tweetId)) {
    fail(`Tweet ID too old (replay)`);
  }

  // Build canonical substring
  const substring = `withdraw ${token} ${vault} ${amount} to ${to}`;

  // Fetch proof
  const proofData = await fetchXProof({ tweetId, substring });
  const proof = buildProof(
    proofData.tweet_id,
    proofData.x_handle,
    proofData.x_id,
    proofData.substring
  );

  // Submit
  const tx = await vaultContract.withdrawVaultTaxtokenByProof(amountWei, to, proof, proofData.signature);
  const receipt = await tx.wait();

  ok({
    action: "withdraw",
    token,
    vault,
    amount: amountWei.toString(),
    to,
    txHash: receipt.hash,
    blockNumber: receipt.blockNumber,
  });
}

main().catch((err) => fail(err));
