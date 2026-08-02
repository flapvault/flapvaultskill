// Set airdrop round via X proof
// Usage: node airdrop.js <token> <vault> <amountPerClaimant> <maxClaimants> <tweetId> <xHandle> <xId>
// Example: node airdrop.js 0xtoken 0xvault 100 1000 1234567890 andi 9876543210

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
    fail("Usage: airdrop.js <token> <vault> <amountPerClaimant> <maxClaimants> <tweetId> <xHandle> <xId>");
  }

  const [token, vault, amountPerClaimant, maxClaimants, tweetId, xHandle, xId] = args;
  const amountWei = BigInt(amountPerClaimant);
  const maxN = BigInt(maxClaimants);

  const wallet = getWallet();
  const vaultContract = new (await import("ethers")).Contract(vault, BUYBACK_VAULT_ABI, wallet);

  // Verify X controller
  const boundHandle = (await vaultContract.controllerXHandle()).toLowerCase();
  if (boundHandle !== xHandle.toLowerCase()) {
    fail(`X handle mismatch`);
  }
  const boundXId = await vaultContract.controllerXId();
  if (BigInt(boundXId) !== BigInt(xId)) {
    fail(`X id mismatch`);
  }
  const lastTweetId = await vaultContract.lastXControllerTweetId(xHandle.toLowerCase());
  if (BigInt(lastTweetId) >= BigInt(tweetId)) {
    fail(`Tweet ID too old (replay)`);
  }

  // Canonical substring
  const substring = `airdrop ${token} ${vault} amount=${amountPerClaimant} max=${maxClaimants}`;

  // Fetch proof
  const proofData = await fetchXProof({ tweetId, substring });
  const proof = buildProof(
    proofData.tweet_id,
    proofData.x_handle,
    proofData.x_id,
    proofData.substring
  );

  // Submit
  const tx = await vaultContract.setAirdropRoundByProof(amountWei, maxN, proof, proofData.signature);
  const receipt = await tx.wait();

  ok({
    action: "airdrop",
    token,
    vault,
    amountPerClaimant: amountWei.toString(),
    maxClaimants: maxN.toString(),
    txHash: receipt.hash,
    blockNumber: receipt.blockNumber,
  });
}

main().catch((err) => fail(err));
