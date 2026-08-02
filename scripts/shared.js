// Shared utilities for FlapVault skill scripts
// All scripts import from this file

import { JsonRpcProvider, Wallet, Contract, getAddress, AbiCoder, parseUnits, isAddress } from "ethers";
export { AbiCoder };
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

export const CHAIN_ID = Number(process.env.CHAIN_ID || 4663);
if (CHAIN_ID !== 4663) throw new Error(`Unsupported CHAIN_ID ${CHAIN_ID}`);
export const RPC_URL = process.env.RPC_URL || process.env.ALCHEMY_RPC_ROBINHOOD || "https://rpc.mainnet.chain.robinhood.com";

export const ADDRESSES = {
  WETH: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  PORTAL: "0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09",
  VAULT_PORTAL: "0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B",
  V2_FACTORY: "0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f",
  V2_ROUTER: "0x89e5DB8B5aA49aA85AC63f691524311AEB649eba",
  V3_SWAP_ROUTER: "0xCaf681a66D020601342297493863E78C959E5cb2",
  X_VERIFIER: "0xccDaB0d5Bc6E0aCb8B157cffFA062688Aa849c17",
  BUYBACK_VAULT_FACTORY: "0x39769E037884718dcA021BD6beaafFC902377B29",
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
    const pk = process.env.X_AGENT_PRIVATE_KEY || process.env.FLAP_PRIV_KEY || requireEnv("X_AGENT_PRIVATE_KEY");
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
  "function airdropRoundCount() view returns (uint256)",
  "function airdropRounds(uint256) view returns (uint256 amountPerClaimant, uint256 maxClaimants, uint256 startTime, uint256 endTime, uint256 claimed, string tweetId, address creator)",
  "function lastGoodPrice() view returns (uint256)",
  "function ecoEthPool() view returns (uint256)",
  "function taxtokenvaultPool() view returns (uint256)",
  "function triggerBuybackByProof(uint256 minTaxtokenOut, tuple(uint128 tweetId, string xHandle, uint128 xId, string substring), bytes signature)",
  "function withdrawVaultTaxtokenByProof(uint256 amount, address to, tuple(uint128 tweetId, string xHandle, uint128 xId, string substring), bytes signature)",
  "function setAirdropRoundByProof(uint256 amountPerClaimant, uint256 maxClaimants, tuple(uint128 tweetId, string xHandle, uint128 xId, string substring), bytes signature)",
  "function executeProposalByProof(uint256 proposalId, tuple(uint128 tweetId, string xHandle, uint128 xId, string substring), bytes signature)",
];

export const VAULT_PORTAL_ABI = [
  // Flap's actual NewTokenV6WithVaultParams (per docs.flap.sh):
  // - 3 strings: name, symbol, meta
  // CORRECT 27-field ABI per Flap docs.
  // Verified selector: 0x1b806220 (matches test tx 0x718960e8...e840).
  // Field 24 = tokenVersion (MUST be 6 = TOKEN_TAXED_V3, else FeatureDisabled).
  // Field 25 = vaultFactory (our factory address).
  // Field 17 = mktBps (100% to marketing in the verified test).
  "function newTokenV6WithVault(tuple(string name, string symbol, string meta, uint8 dexThresh, bytes32 salt, uint8 migratorType, address quoteToken, uint256 quoteAmt, bytes permitData, bytes32 extensionID, bytes extensionData, uint8 dexId, uint8 lpFeeProfile, uint16 buyTaxRate, uint16 sellTaxRate, uint64 taxDuration, uint64 antiFarmerDuration, uint16 mktBps, uint16 deflationBps, uint16 dividendBps, uint16 lpBps, uint256 minimumShareBalance, address dividendToken, address commissionReceiver, uint8 tokenVersion, address vaultFactory, bytes vaultData) params) payable returns (address token)",
  "event FlapTaxVaultTokenCreated(address indexed token, address indexed vault, address indexed vaultFactory, address creator, string name, string symbol, uint16 buyTaxBps, uint16 sellTaxBps)",
];

export const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function totalSupply() view returns (uint256)",
  "function decimals() view returns (uint8)",
];

export const FACTORY_ABI = [
  "function newVault(address,address,address,bytes) returns (address)",
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
    headers: { "Content-Type": "application/json", ...(process.env.ORACLE_API_KEY ? { "X-API-Key": process.env.ORACLE_API_KEY } : {}) },
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
  return getAddress(process.env.BUYBACK_VAULT_FACTORY || ADDRESSES.BUYBACK_VAULT_FACTORY);
}

export const normalizeHandle=v=>String(v).replace(/^@/, "").trim().toLowerCase();
export function normalizeAddress(v,label="address"){if(!isAddress(v))throw new Error(`Invalid ${label}: ${v}`);return getAddress(v)}
export const canonical={buyback:(t,v)=>`@flapdotshvault buyback ${t.toLowerCase()} ${v.toLowerCase()}`,withdraw:(t,v,a,to)=>`@flapdotshvault withdraw ${t.toLowerCase()} ${v.toLowerCase()} ${a} to ${to.toLowerCase()}`,airdrop:(t,v,a,m)=>`@flapdotshvault airdrop ${t.toLowerCase()} ${v.toLowerCase()} amount=${a} max=${m}`,execute:(t,v,id)=>`@flapdotshvault execute proposal ${t.toLowerCase()} ${v.toLowerCase()} ${id}`};
export async function assertWriteReady(w){if(Number((await w.provider.getNetwork()).chainId)!==4663)throw new Error("Wrong chain");if(await w.provider.getBalance(w.address)<parseUnits("0.01",18))throw new Error("Gas balance below 0.01 ETH")}
export async function openVault(a,r){const vault=normalizeAddress(a,"vault");if(await r.provider.getCode(vault)==="0x")throw new Error("Vault has no code");const contract=new Contract(vault,BUYBACK_VAULT_ABI,r),token=normalizeAddress(await contract.taxtoken());return{vault,token,contract}}
export async function verifyController(c,h,id,tw){h=normalizeHandle(h);if(normalizeHandle(await c.controllerXHandle())!==h)throw new Error("X handle mismatch");if(BigInt(await c.controllerXId())!==BigInt(id))throw new Error("X id mismatch");if(BigInt(await c.lastXControllerTweetId(h))>=BigInt(tw))throw new Error("Tweet replay")}
export async function tokenAmount(t,r,v){return parseUnits(String(v),Number(await new Contract(t,ERC20_ABI,r).decimals()))}
export function enforceRateLimit(){}
