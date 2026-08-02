// Shared utilities for FlapVault skill scripts
// All scripts import from this file

import { JsonRpcProvider, Wallet, Contract, getAddress } from "ethers";
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// ─── Env loader (no dotenv dep, read from process.env directly) ───

function requireEnv(name) {
  const v = process.env[name];
  if (!v) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return v;
}

// ─── Constants ───

export const CHAIN_ID = 4663;
export const RPC_URL = process.env.RPC_URL || "https://rpc.mainnet.chain.robinhood.com";

export const ADDRESSES = {
  WETH: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  PORTAL: "0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09",
  VAULT_PORTAL: "0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B",
  V2_FACTORY: "0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f",
  V2_ROUTER: "0x89e5DB8B5aA49aA85AC63f691524311AEB649eba",
  V3_SWAP_ROUTER: "0xCaf681a66D020601342297493863E78C959E5cb2",
  X_VERIFIER: "0xccDaB0d5Bc6E0aCb8B157cffFA062688Aa849c17",
};

// ─── Provider & wallet ───

let _provider = null;
let _wallet = null;

export function getProvider() {
  if (!_provider) {
    _provider = new JsonRpcProvider(RPC_URL, CHAIN_ID, { staticNetwork: true });
  }
  return _provider;
}

export function getWallet() {
  if (!_wallet) {
    const pk = requireEnv("X_AGENT_PRIVATE_KEY");
    _wallet = new Wallet(pk, getProvider());
  }
  return _wallet;
}

// ─── ABIs (minimal, just what we need) ───

export const BUYBACK_VAULT_ABI = [
  "function taxtoken() view returns (address)",
  "function factory() view returns (address)",
  "function taxRateBps() view returns (uint16)",
  "function totalStaked() view returns (uint256)",
  "function dividendPerStakedToken() view returns (uint256)",
  "function controllerXHandle() view returns (string)",
  "function controllerXId() view returns (uint128)",
  "function lastXControllerTweetId(string) view returns (uint128)",
  "function airdropRound() view returns (uint256 amountPerClaimant, uint256 maxClaimants, uint256 startTime, uint256 endTime, uint256 claimed, string tweetId, address creator)",
  "function ecoEthPool() view returns (uint256)",
  "function getTaxtokenReserve() view returns (uint256)",
  "function triggerBuybackByProof(uint256 minTaxtokenOut, tuple(uint128 tweetId, string xHandle, uint128 xId, string substring), bytes signature)",
  "function withdrawVaultTaxtokenByProof(uint256 amount, address to, tuple(uint128 tweetId, string xHandle, uint128 xId, string substring), bytes signature)",
  "function setAirdropRoundByProof(uint256 amountPerClaimant, uint256 maxClaimants, tuple(uint128 tweetId, string xHandle, uint128 xId, string substring), bytes signature)",
  "function executeProposalByProof(uint256 proposalId, tuple(uint128 tweetId, string xHandle, uint128 xId, string substring), bytes signature)",
];

export const VAULT_PORTAL_ABI = [
  "function newTokenV6WithVault(tuple(string name, string symbol, uint16 buyTaxBps, uint16 sellTaxBps, address tokenAdmin, string uri, bytes32 salt, address locker, address[] mevModules, address hook, address mevModuleV2, bool mevDescendingFees, uint256 lockerDeadline, tuple(uint16 vaultBps, address vaultFactory, address vaultImpl, bytes vaultData) vaultConfig) params) payable returns (address token, address vault, address mevModule)",
  "event TokenCreated(address indexed token, address indexed vault, address indexed creator, string name, string symbol, uint16 buyTaxBps, uint16 sellTaxBps)",
];

export const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function totalSupply() view returns (uint256)",
  "function decimals() view returns (uint8)",
];

export const FACTORY_ABI = [
  "function deployVault(tuple(address taxtoken, address owner) data) returns (address)",
  "function tokenCreationPolicies() view returns (uint16 vaultBps, bool enabled)",
  "function totalCommission() view returns (uint256)",
  "function commissionRecipient() view returns (address)",
];

// ─── Build proof struct tuple ───

export function buildProof(tweetId, xHandle, xId, substring) {
  return {
    tweetId: BigInt(tweetId),
    xHandle: xHandle.toLowerCase(),
    xId: BigInt(xId),
    substring: substring,
  };
}

// ─── Oracle client (Flap X General Verifier) ───

export async function fetchXProof({ tweetId, substring, chainId = CHAIN_ID }) {
  const url = process.env.ORACLE_URL || "https://verifyx.taxed.fun/prove";
  const sep = url.includes("?") ? "&" : "?";
  const fullUrl = `${url}${sep}chain_id=${chainId}`;

  const res = await fetch(fullUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ tweet_id: tweetId, substring }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Oracle returned ${res.status}: ${text}`);
  }

  return await res.json();
  // Returns: { tweet_id, x_handle, x_id, substring, signature, ipfs_cid, chain_id, verifier_address }
}

// ─── Output helpers ───

export function ok(data) {
  console.log(JSON.stringify({ ok: true, ...data }));
}

export function fail(error, extra = {}) {
  console.log(JSON.stringify({ ok: false, error: String(error), ...extra }));
  process.exit(1);
}

// ─── Main helper: get the factory from env ───

export function getFactoryAddress() {
  return requireEnv("BUYBACK_VAULT_FACTORY");
}
