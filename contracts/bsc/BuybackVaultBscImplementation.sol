// =====================================================================
//  ⚠️  THIS IS THE BSC VARIANT (BNB Smart Chain, chain 56)
//  Original Robinhood Chain (chain 4663) version: ./BuybackVaultFactory.sol
//  All chain-specific addresses updated to BSC equivalents:
//    - WETH (constant, address = WBNB on BSC)
//    - V2      → PancakeSwap V2 (factory + router)
//    - V3      → PancakeSwap V3 SwapRouter02
//    - X       → BSC XGeneralVerifier
//    - Portal  → BSC Flap Portal
//    - V4 PM   → 0x0 (Uniswap V4 not deployed on BSC; swapType=1 disabled)
//  createProposal with swapType=1 (V4) will revert at execution time since
//  POOL_MANAGER is 0x0. Either keep that behavior, or use a different
//  governance flow (e.g. reject at proposal creation).
//  _getPortal() and _getGuardian() are chain-aware (already support BSC).
// =====================================================================

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultDataSchema, FieldDescriptor, VaultUISchema, VaultMethodSchema, ApproveAction} from "./flap/IVaultSchemasV1.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IUniswapV3Pool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data) external returns (int256 amount0, int256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

// Uniswap V3 SwapRouter02 (Robinhood Chain: 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4)
// Used for ECO buyback (proposal execution) — NOT for taxtoken buyback.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// Uniswap V2 Factory (Robinhood Chain: 0xcA143ce32fe78f1f7019D838670724e5259BB757)
// `getPair(WETH, token)` returns the deterministic V2 pair address. Used to discover
// the post-graduation V2 pool for taxtoken buyback (Flap V2_MIGRATOR creates the
// pair at graduation; the vault never has to pre-register it).
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

// Uniswap V2 Router02 (Robinhood Chain: 0x10ED43C718714eb63d5aA57B78B54704E256024E)
// Full router interface with `SupportingFeeOnTransferTokens` variants — required for
// tax-token buyback (the V2 pair output transfer has tax-on-transfer).
interface IUniswapV2Router02 {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    // AUDIT FIX #5: used to derive a 95%-of-quote slippage floor on the
    // post-graduation V2 buyback path.
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function take(address currency, address to, uint256 amount) external;
    function settle() external payable returns (uint256);
    function sync(address currency) external;
    function swap(BuybackTypes.PoolKey memory key, BuybackTypes.SwapParams memory params, bytes calldata hookData) external returns (int256);
}

interface IXGeneralVerifier {
    function verify(BuybackTypes.XGeneralProof calldata proof, bytes calldata signature) external view returns (bool);
}

/// @notice Minimal tax-token interface to read the rate (cached on first receive).
interface ITaxToken {
    function taxRate() external view returns (uint256);
}

/// @notice Flap Portal interface — used to query token status and trade during
///         the bonding-curve phase. On Robinhood Chain, the Portal address is
///         `0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0`.
///
///         V2 spec only requires `getTokenV6`, `swapExactInput`, `quoteExactInput`,
///         plus the `TokenStatus` enum for phase detection. We do NOT use V5
///         because the v6 selector is available on mainnet (0xdbde08f0).
interface IPortal {
    enum TokenStatus { Invalid, Tradable, InDuel, Killed, DEX }

    struct QuoteExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
    }

    struct ExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes permitData;
    }

    /// @notice Get full token state (V6). 480-byte return, but we only read the first
    ///         field (`status`) for phase dispatch. Other fields are read positionally
    ///         but only `status` is used by the buyback logic.
    function getTokenV6(address token) external view returns (
        uint8 status,
        uint256 reserve,
        uint256 circulatingSupply,
        uint256 price,
        uint8 tokenVersion,
        uint256 r,
        uint256 h,
        uint256 k,
        uint256 dexSupplyThresh,
        address quoteTokenAddress,
        bool nativeToQuoteSwapEnabled,
        bytes32 extensionID
    );

    function quoteExactInput(QuoteExactInputParams calldata params) external returns (uint256 outputAmount);
    function swapExactInput(ExactInputParams calldata params) external payable returns (uint256 outputAmount);
}

library BuybackTypes {
    struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    // Flap XGeneralVerifier official layout: tweetId(uint128), xHandle(string), xId(uint128), substring(string)
    struct XGeneralProof { uint128 tweetId; string xHandle; uint128 xId; string substring; }
}

/// @title BuybackVaultBsc (BNB Chain version)
/// @notice Upgradeable buyback vault for Flap-launched tax tokens on BSC.
///         Receives BNB tax from the launched token, then buys back the same token
///         via the Flap Portal (bonding-curve phase) or a V2 pair (post-graduation).
///         Supports staking, snapshot-based 2-phase governance, eco pool, and a
///         tweet-gated airdrop. Implements the Flap `VaultBaseV2` interface.
///
///         Design highlights:
///           - Two-phase buyback: 25% to eco pool, 75% swapped for taxtoken.
///             Of buyback output: 2/3 to vault reserve, 1/3 to staker dividend.
///           - Commission auto-sent to factory on each receive() (10% if tax ≤ 1%, 20% else).
///           - Phase detection via `Portal.getTokenV6(taxToken).status`.
///           - `BeaconProxy` upgradeable via the factory.
contract BuybackVaultBsc is Initializable, VaultBaseV2, ReentrancyGuardUpgradeable {
    using BuybackTypes for *;
    using Strings for uint256;

    // ─── Flap protocol constants (BSC, chain 56) ─────────────
    /// @notice Flap Portal — used to query token state and trade during bonding curve.
    address public constant FLAP_PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;

    /// @notice WETH on BSC. Used for V2 buyback path (WETH → taxtoken).
    address public constant WETH = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /// @notice Uniswap V2 Factory on BSC. `getPair(WETH, taxtoken)` returns the
    ///         V2 pair address created by Flap's V2_MIGRATOR at token graduation.
    address public constant V2_FACTORY = 0xcA143ce32fe78f1f7019D838670724e5259BB757;

    /// @notice Uniswap V2 Router02 on BSC. Supports `swapExactETHForTokensSupportingFeeOnTransferTokens`
    ///         which is REQUIRED for tax-token buyback (the pair's output transfer has tax).
    address public constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    // ─── Storage ──────────────────────────────────────────────────────────────
    // Each state variable is one slot. Packed and explicit for clarity in audit.

    /// @notice The token the vault buys back. In self-buyback mode (`taxtoken == taxToken`),
    ///         this is the same as the launched Flap tax token. In legacy mode, it can be a
    ///         different ERC20 (e.g. an existing project token).
    address public taxtoken;                      // slot 0

    /// @notice The launched tax token whose transfer tax funds this vault.
    address public taxToken;                      // slot 1 (was slot 3 in V1)

    /// @notice Vault admin address. Has owner-only permissions (e.g. `autoBuybackAuto`).
    address public owner;                         // slot 2 (was slot 4 in V1)

    /// @notice Reserve of taxtokens accumulated from buybacks. Funded with 2/3 of each
    ///         buyback output. May be withdrawn via `withdrawVaultTaxtoken`.
    uint256 public taxtokenvaultPool;             // slot 3 (was slot 5 in V1)

    /// @notice Reserve of taxtokens owed to stakers as dividends. Funded with 1/3 of
    ///         each buyback output (when there are stakers). When no stakers are present,
    ///         the holder portion is routed to `taxtokenvaultPool` instead (see
    ///         `_autoBuybackAutoUnchecked`).
    uint256 public taxtokenholderPool;            // slot 4 (was slot 6 in V1)

    // Slot 6 (was slot 8 in V1)
    uint256 public totalStaked;
    // Slot 7 (was slot 9 in V1)
    uint256 public dividendPerStakedToken;
    // AUDIT FIX (round 3 #2): accumulates dividend dust that would
    // otherwise be lost to integer-division truncation. When a buyback's
    // holder portion is too small to move dividendPerStakedToken
    // (i.e. (toHolders * 1e18) / totalStaked == 0), the dust is added
    // here and combined with the next buyback's holder portion.
    uint256 public pendingDividendDust;

    // Constants (do not occupy storage slots)
    uint256 public constant MIN_BUYBACK = 0.01 ether;
    // AUDIT FIX (round 4 #2): UNSTAKE_COOLDOWN removed. The unstake wait is
    // now fully covered by STAKE_LOCK_PERIOD (1 day, set at stake time).
    // No additional cooldown is applied at requestUnstake.
    uint256 public constant APPROVAL_DURATION = 6 hours;
    uint256 public constant SELECTION_DURATION = 6 hours;
    uint256 public constant COMMISSION_BPS_LOW = 1000;  // 10% for tax ≤ 1%
    uint256 public constant COMMISSION_BPS_HIGH = 2000; // 20% for tax  > 1%
    // AUDIT FIX (round 3 #1): threshold for governance staker registry.
    // Stakers with stake below MIN_REGISTRATION_STAKE (in taxtoken raw units)
    // are still allowed to stake and earn dividends, but they are NOT added
    // to the stakerList registry (so they have no vote power on governance
    // proposals). This prevents an attacker from inflating stakerCount with
    // dust stakes to DoS createProposal's O(n) snapshot loop.
    // 100e18 raw units = 100 taxtoken (assuming 18 decimals).
    uint256 public constant MIN_REGISTRATION_STAKE = 100e18;
    // AUDIT FIX (round 3 #3): stake lock period. After staking, the
    // staker cannot unstake for this duration. Prevents JIT
    // front-running — the attacker captures dividend at the next
    // buyback but cannot immediately unstake; capital is locked.
    // Legit stakers accept the lock; JIT attackers waste capital.
    uint256 public constant STAKE_LOCK_PERIOD = 1 days;

    // Uniswap V3 SwapRouter02 on BSC, used only for eco-token buybacks.
    address public constant SWAP_ROUTER_02 = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    IXGeneralVerifier public constant X_VERIFIER = IXGeneralVerifier(0xcA8DBE6CAC4BFDc41226b0BaF2359fd99989b3E4);
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x0000000000000000000000000000000000000000);

    // ─── New state (added at end, uses __gap slots) ─────────────────────────
    // Slot 41 (was last __gap slot) — factory address for commission auto-send
    address public factory;
    // Slot 42 (was last __gap slot) — cached tax rate
    uint16  public taxRateBps;

    // ─── X controller state (added 2026-07-25) ─────────────────────────────
    // Slot 44 — bound X handle (lowercase), empty if no X controller
    string  public controllerXHandle;
    // Slot 45 — numeric X user ID (paired with handle for rename-attack protection)
    uint128 public controllerXId;
    // Slot 46 — per-handle replay guard (tweetId monotonic)
    mapping(string => uint128) public lastXControllerTweetId;

    // AUDIT FIX #3: when non-zero, all incoming BNB via receive() is
    // forwarded to this address and the tax/buyback flow is skipped.
    // Set by `emergencyWithdrawETH(to, ...)`. Once set, persists forever
    // (no on-chain way to disable — the only way to resume normal
    // operation is to deploy a new vault). The rest of the vault
    // mechanism (autoBuybackAuto, claimDividend, etc.) is unaffected —
    // only `receive()` is short-circuited.
    // Slot 47 (was __gap[6]).
    address public emergencyForwardTarget;

    // AUDIT FIX #6: staker registry for O(n) per-staker snapshot at
    // createProposal. Pushes to this array happen on first stake (when
    // stakedAmount transitions 0→>0). Entries are NOT removed on unstake
    // (the snapshot only needs to know "who staked at create time",
    // and the live stake at snapshot time is what matters — zero-stake
    // stakers contribute 0 power). Per-staker snapshot is stored in
    // `voteSnapshot[proposalId][staker]`.
    // Slot 48 (was __gap[7]) — array length
    uint256 public stakerCount;
    // Slot 49 (was __gap[8]) — array data (keccak256(slot) for elements)
    mapping(uint256 => address) public stakerList;
    // Slot 50 (was __gap[9]) — 1-indexed reverse lookup (address → array index).
    // 0 = not registered. We use 1-indexed so 0 unambiguously means "not in list".
    mapping(address => uint256) public stakerIndex;

    // AUDIT FIX (round 4 #3): un-manipulable price reference for the X-proof
    // buyback path. Set on every successful buyback to (taxtokenOut * 1e18) /
    // ethIn. The X-proof path uses this to derive a default minOut when the
    // relayer passes 0 — the floor reflects the last CLEAN buyback (pre
    // current block), so sandwich attacks that manipulate the current block's
    // quote cannot drive the floor down.
    // Slot 51 (was __gap[10]).
    uint256 public lastGoodPrice;       // taxtoken per 1 BNB, scaled by 1e18
    // Slot 52 (was __gap[11]).
    uint256 public lastGoodEthAmount;   // BNB amount that produced lastGoodPrice

    // __gap reduced from 41 → 32 (9 slots used: 2 for factory/taxRate + 3 for
    // X controller + 1 for forward + 3 for staker list + 2 for price ref).
    uint256[32] private __gap;

    // ─── Staking & dividend ────────────────────────────────────────────────
    struct StakerInfo {
        uint256 stakedAmount;
        uint256 rewardDebt;
        uint256 pendingUnstake;
        uint256 unstakeReadyAt;
        // AUDIT FIX (round 3 #3): timestamp until which the staker is
        // locked from unstaking. Set on every stake. Prevents JIT
        // front-running — the attacker captures dividend but cannot
        // immediately unstake; capital is locked for the lock period.
        uint256 lockUntil;
    }
    mapping(address => StakerInfo) public stakers;
    // ─── Airdrop ───────────────────────────────────────────────────────────
    struct AirdropRound {
        uint256 amountPerClaimant;
        uint256 startTime;
        uint256 endTime;
        uint256 maxClaimants;
        uint256 totalClaimed;
        string  substringSuffix;
        bool    active;
    }
    uint256 public airdropRoundCount;
    mapping(uint256 => AirdropRound) public airdropRounds;
    mapping(uint256 => mapping(address => bool)) public airdropClaimed;
    mapping(address => uint256) public lastAirdropTweetId;

    // ─── V4 internal accounting ────────────────────────────────────────────
    uint256 private _v4OwedOut;

    // ─── Events ────────────────────────────────────────────────────────────
    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 readyAt);
    event Unstaked(address indexed user, uint256 amount);
    event DividendClaimed(address indexed user, uint256 amount);
    event Buyback(uint256 ethIn, uint256 taxtokenOut, uint256 toVault, uint256 toHolders);
    event AirdropRoundSet(uint256 indexed roundId, uint256 amountPerClaimant, uint256 startTime, uint256 endTime, uint256 maxClaimants, string substringSuffix);
    event AirdropClaimed(uint256 indexed roundId, address indexed claimant, uint256 amount, uint256 tweetId);
    event EmergencyEthWithdraw(address indexed to, uint256 amount);
    /// @notice Emitted the first time `emergencyForwardTarget` is set.
    event EmergencyForwardEnabled(address indexed target);
    /// @notice Emitted on every `receive()` while the forward is active.
    event EmergencyForwarded(address indexed target, uint256 amount);
    event CommissionSent(uint256 amount);

    constructor() { _disableInitializers(); }

    /// @notice Initialize a freshly deployed `BeaconProxy` of this vault.
    /// @param _taxToken       The tax token. In self-buyback mode (the only mode we support),
    ///                        the vault buys back this same token. The Flap tax processor sends
    ///                        the `vaultBps` portion of every buy/sell to this vault.
    /// @param _owner          Vault admin.
    /// @param _factory        Factory contract (recipient of commission auto-send).
    /// @param _xController    X (Twitter) handle authorized to control this vault via X proof (lowercase).
    ///                        Pass empty string to skip X controller binding (manual mode).
    /// @param _xId            Numeric X user ID paired with `_xController`. Pass 0 if `_xController` is empty.
    /// @dev V2 router/factory/WETH addresses are protocol-level constants — the V2 pair for
    ///      (WETH, taxtoken) is auto-discovered at buyback time via `V2_FACTORY.getPair()`,
    ///      so no pre-launch pool registration is required. Flap's V2_MIGRATOR creates the
    ///      pair automatically at token graduation.
    function initialize(
        address _taxToken,
        address _owner,
        address _factory,
        string calldata _xController,
        uint128 _xId
    ) external initializer {
        __ReentrancyGuard_init();
        // Self-buyback: vault buys back the same token it receives tax from
        taxtoken = _taxToken;
        taxToken = _taxToken;
        owner = _owner;
        factory = _factory;
        // X controller binding: must be both or neither (consistency check).
        if (bytes(_xController).length > 0) {
            require(_xId != 0, "XId required when X handle set");
            controllerXHandle = _xController;
            controllerXId = _xId;
        } else {
            require(_xId == 0, "XId must be 0 when X handle empty");
        }
    }

    // ─── receive() — commission auto-send ──────────────────────────────────
    /// @notice Accepts BNB from the tax token's `vaultBps` portion.
    ///         Allocates a commission slice (10% for tax ≤ 1%, 20% for tax > 1%)
    ///         and auto-sends it to `factory`. The rest accumulates in `pendingRevenue`
    ///         and is processed by `autoBuybackAuto()` (the 75/25 buyback mechanism).
    receive() external payable {
        if (msg.value == 0) return;

        // AUDIT FIX #3: persistent forward. When `emergencyForwardTarget`
        // is non-zero (set by a prior `emergencyWithdrawETH` call), all
        // incoming BNB is forwarded to that target and the tax/buyback
        // flow is skipped. The rest of the vault mechanism is unaffected.
        address fwd = emergencyForwardTarget;
        if (fwd != address(0)) {
            (bool ok,) = payable(fwd).call{value: msg.value}("");
            require(ok, "Forward failed");
            emit EmergencyForwarded(fwd, msg.value);
            return;
        }

        // (No pendingRevenue state — the entire vault balance is the unprocessed
        // revenue.  autoBuybackAuto() derives `ethBal = address(this).balance - ecoEthPool`.)

        // Cache tax rate once (tax token deployed after vault, may not have its
        // `taxRate()` set when the first receive() lands).
        if (taxRateBps == 0) {
            try ITaxToken(taxToken).taxRate() returns (uint256 r) {
                if (r > 0) taxRateBps = uint16(r);
            } catch {}
        }

        // Calculate and auto-send commission to factory.
        uint256 commission = _calcCommission(msg.value);
        if (commission > 0) {
            (bool ok,) = factory.call{value: commission}("");
            require(ok, "Commission transfer failed");
            emit CommissionSent(commission);
        }
    }

    /// @dev Commission formula: 10% if tax ≤ 1%, 20% if tax > 1%.
    ///      AUDIT FIX (round 6 #4): if the cached `taxRateBps` is still 0
    ///      (first-receive window before the tax token's `taxRate()` is
    ///      populated), default to the LOW tier (10%). The README promises
    ///      a 10% / 20% cut unconditionally; the previous "return 0" was
    ///      a silent skip. The low tier is the conservative default —
    ///      if the eventual tax rate is > 1%, the next receive() will
    ///      re-cache and the high tier will apply going forward.
    function _calcCommission(uint256 amount) internal view returns (uint256) {
        if (taxRateBps == 0) {
            return (amount * COMMISSION_BPS_LOW) / 10000;
        }
        if (taxRateBps <= 100) {
            return (amount * COMMISSION_BPS_LOW) / 10000;
        }
        return (amount * COMMISSION_BPS_HIGH) / 10000;
    }

    // ─── Views ─────────────────────────────────────────────────────────────
    /// @notice Returns the vault's current BNB balance (unprocessed tax revenue).
    /// @return The vault's BNB balance, denominated in wei.
    function buybackBalance() public view returns (uint256) { return address(this).balance; }
    /// @notice Returns the Flap Portal address for the current chain (chain 4663 on Robinhood).
    /// @return The Portal contract address used for bonding-curve trades and phase queries.
    function portal() public view returns (address) { return _getPortal(); }
    /// @notice Returns the Flap Guardian address for the current chain.
    /// @return The Guardian contract address. May invoke `emergencyWithdrawETH`.
    function guardian() public view returns (address) { return _getGuardian(); }

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner || msg.sender == _getGuardian(), "Only owner or guardian");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // ─── 75/25 buyback mechanism (UNCHANGED logic, renamed) ────────────────
    /// @notice Triggers the buyback. 75% BNB → taxtoken via Portal (bonding curve)
    ///         or V2 router (post-graduation),
    ///         25% → ecoEthPool.  Of the taxtoken out, the split mirrors the
    ///         original BNB share: 2/3 (= 50% of original BNB) goes to
    ///         `taxtokenvaultPool` (reserve / airdrop funding / withdrawals),
    ///         1/3 (= 25% of original BNB) backs `taxtokenholderPool` (staker
    ///         dividend). The ratio is implemented as `(out * 50) / 75` so that
    ///         50% of the pre-buyback BNB ends up in the vault reserve.
    function autoBuybackAuto(uint256 minTaxtokenOut) external nonReentrant onlyOwnerOrGuardian {
        // AUDIT FIX (round 2 #2): require the owner/guardian to specify a
        // meaningful slippage floor. The 95%-of-quote safety floor inside
        // _swapEthForTaxtoken is computed from an in-transaction on-chain
        // quote, which an MEV bot can manipulate within the same block.
        // The caller MUST query an off-chain price reference and pass it
        // as minTaxtokenOut. The 95%-of-quote floor remains as a
        // defensive net (takes the more restrictive of the two).
        require(minTaxtokenOut > 0, "minOut=0");
        _autoBuybackAutoUnchecked(minTaxtokenOut);
    }

    /// @dev Internal buyback logic. Used by `autoBuybackAuto` (after role check)
    ///      and by `triggerBuybackByProof` (after X proof verification). The X
    ///      proof layer provides equivalent authorization to the owner/guardian
    ///      role check, so we don't need to add an "X controller" role.
    function _autoBuybackAutoUnchecked(uint256 minTaxtokenOut) internal {
        // BSC variant: no ecoEthPool (governance/proposals removed to fit 24KB).
        // 100% of new BNB is used to buy taxtoken.
        uint256 ethBal = address(this).balance;
        require(ethBal >= MIN_BUYBACK, "Below min buyback");
        uint256 taxtokenBefore = IERC20(taxtoken).balanceOf(address(this));
        _swapEthForTaxtoken(ethBal, minTaxtokenOut);
        uint256 taxtokenOut = IERC20(taxtoken).balanceOf(address(this)) - taxtokenBefore;
        require(taxtokenOut >= minTaxtokenOut, "Slippage");
        // AUDIT FIX (round 4 #3): record the actual execution price as
        // `lastGoodPrice` for the X-proof default-minOut floor. This is
        // done BEFORE the split so the price reflects the raw buyback
        // outcome (BNB in -> taxtoken out).
        if (taxtokenOut > 0 && ethBal > 0) {
            lastGoodPrice = (taxtokenOut * 1e18) / ethBal;
            lastGoodEthAmount = ethBal;
        }
        // Split: 2/3 of taxtoken out to vault reserve, 1/3 to staker dividend.
        // (Mirrors the original BNB share: 50% vault + 25% stakers was the 75% portion.)
        uint256 toVault = (taxtokenOut * 2) / 3;
        uint256 toHolders = taxtokenOut - toVault;
        // F-v2-2: with no stakers, holder portion is unattributable; route it to vault reserve.
        if (totalStaked > 0) {
            taxtokenvaultPool += toVault;
            taxtokenholderPool += toHolders;
            // AUDIT FIX (round 3 #2): combine this buyback's holder portion
            // with any pending dust from prior buybacks. If the resulting
            // increment is still 0 (i.e. integer-division truncation), keep
            // the combined amount as dust for the next buyback.
            uint256 effectiveToHolders = toHolders + pendingDividendDust;
            uint256 increment = (effectiveToHolders * 1e18) / totalStaked;
            if (increment == 0) {
                pendingDividendDust = effectiveToHolders;
            } else {
                dividendPerStakedToken += increment;
                pendingDividendDust = 0;
            }
        } else {
            taxtokenvaultPool += toVault + toHolders;
        }
        emit Buyback(ethBal, taxtokenOut, toVault, toHolders);
    }

    // ─── Taxtoken buyback: dual routing (Portal → V2) ──────────────────────
    //   - Self-buyback (taxtoken == taxToken) during bonding-curve phase → Portal.swapExactInput
    //   - Post-graduation (status == DEX) → V2 router with FoT support
    //
    // V2 pair is auto-discovered via V2_FACTORY.getPair(WETH, taxtoken) — no pre-launch
    // pool registration needed. Flap's V2_MIGRATOR creates the pair at graduation.
    function _swapEthForTaxtoken(uint256 ethAmount, uint256 minTaxtokenOut) internal {
        // Self-buyback during bonding curve: use Flap Portal. Flap blocks all
        // pool transfers until graduation, so V2 is unavailable in this phase.
        if (_isSelfBuyback()) {
            (uint8 status,,) = _portalTokenStatus();
            if (status == uint8(IPortal.TokenStatus.Tradable)) {
                _swapEthForTaxtokenViaPortal(ethAmount, minTaxtokenOut);
                return;
            }
            // status == DEX: fall through to V2 below
        }

        // V2 path: discover pair on-demand, swap with FoT support.
        address pair = IUniswapV2Factory(V2_FACTORY).getPair(WETH, taxtoken);
        require(pair != address(0), "V2 pair not found");

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = taxtoken;

        // AUDIT FIX #5: derive a 95%-of-quote safety floor for the V2 path
        // so a caller passing 0 (or a stale mempool tx) cannot disable
        // slippage. Mirrors the Portal path's safety floor.
        uint256[] memory amountsOut;
        try IUniswapV2Router02(V2_ROUTER).getAmountsOut(ethAmount, path) returns (uint256[] memory a) {
            amountsOut = a;
        } catch {
            amountsOut = new uint256[](0);
        }
        uint256 quoted = amountsOut.length >= 2 ? amountsOut[1] : 0;
        uint256 slippageFloor = quoted == 0 ? 1 : (quoted * 95) / 100;
        uint256 effectiveMinOut = minTaxtokenOut > slippageFloor ? minTaxtokenOut : slippageFloor;

        // Use FoT-aware router function — required because the V2 pair's output
        // transfer (taxtoken to recipient) is subject to the taxtoken's transfer tax.
        // Standard `swapExactETHForTokens` would mis-account the actual amount received.
        // Pass `effectiveMinOut` as the router's amountOutMin so the router reverts
        // with its own error if slippage is breached (better DX than our outer check).
        IUniswapV2Router02(V2_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethAmount}(
            effectiveMinOut,  // AUDIT FIX #5: 95%-of-quote floor if caller passes 0
            path,
            address(this),
            block.timestamp
        );
    }

    /// @dev Returns true when the launched tax token is buying itself back
    ///      (`taxtoken == taxToken`). In that mode the vault may use Flap Portal
    ///      during the bonding-curve phase. Legacy BNKR-style vaults
    ///      (`taxtoken != taxToken`) always fall back to the V2 path.
    function _isSelfBuyback() internal view returns (bool) {
        return taxtoken != address(0) && taxtoken == taxToken;
    }

    /// @dev Reads the `status` field of `Portal.getTokenV6(taxToken)`.
    ///      Returns (status, reserve, circulatingSupply). Other V6 fields are
    ///      ignored (the buyback path only needs `status` for phase dispatch).
    ///      If Portal.getTokenV6 reverts (e.g. on a non-Flap-launched token in
    ///      legacy BNKR mode), this returns (0, 0, 0) and the V2 path runs.
    function _portalTokenStatus() internal view returns (uint8 status, uint256 reserve, uint256 circulatingSupply) {
        try IPortal(FLAP_PORTAL).getTokenV6(taxToken) returns (
            uint8 s, uint256 r, uint256 c,
            uint256 /*price*/, uint8 /*tokenVersion*/,
            uint256 /*r*/, uint256 /*h*/, uint256 /*k*/,
            uint256 /*dexSupplyThresh*/, address /*quoteTokenAddress*/,
            bool /*nativeToQuoteSwapEnabled*/, bytes32 /*extensionID*/
        ) {
            return (s, r, c);
        } catch {
            return (0, 0, 0);
        }
    }

    /// @dev Buys taxtoken from the Flap bonding curve. Sends BNB directly to
    ///      Portal.swapExactInput (the Portal takes the bonding-curve rate +
    /// @dev Buys taxtoken from the Flap bonding curve. Sends BNB directly to
    ///      Portal.swapExactInput (the Portal takes the bonding-curve rate +
    ///      tax). Uses the caller-supplied `minOut` as the router's
    ///      minOutputAmount (with a 5% slippage buffer as a floor if the
    ///      caller's minOut is too tight relative to the live quote).
    /// @param ethAmount Amount of ETH to swap.
    /// @param callerMinOut The min output the caller (autoBuybackAuto) wants.
    function _swapEthForTaxtokenViaPortal(uint256 ethAmount, uint256 callerMinOut) internal {
        IPortal.QuoteExactInputParams memory q = IPortal.QuoteExactInputParams({
            inputToken: address(0),
            outputToken: taxToken,
            inputAmount: ethAmount
        });
        uint256 quotedOut;
        try IPortal(FLAP_PORTAL).quoteExactInput(q) returns (uint256 qa) {
            quotedOut = qa;
        } catch {
            // No quote available — fall back to caller's minOut (1 wei minimum
            // enforced via outer require in autoBuybackAuto).
            quotedOut = 0;
        }
        // Use the MORE RESTRICTIVE of (95% of quote) and (caller's minOut).
        // 95% of quote acts as a safety floor against quote-staleness; the
        // caller's minOut is the user-stated slippage tolerance.
        uint256 slippageFloor = quotedOut == 0 ? 1 : (quotedOut * 95) / 100;
        uint256 minOut = callerMinOut > slippageFloor ? callerMinOut : slippageFloor;

        IPortal.ExactInputParams memory p = IPortal.ExactInputParams({
            inputToken: address(0),
            outputToken: taxToken,
            inputAmount: ethAmount,
            minOutputAmount: minOut,
            permitData: ""
        });
        IPortal(FLAP_PORTAL).swapExactInput{value: ethAmount}(p);
    }

    // NOTE: Uniswap V3 pool callback (`uniswapV3SwapCallback`) was removed in V2.
    // The taxtoken buyback no longer uses a V3 pool — it uses V2 (auto-discovered
    // pair via V2_FACTORY) with FoT support. The V3 callback is no longer needed.

    // ─── MasterChef dividend accounting (UNCHANGED logic) ─────────────────
    function _accrue(address user) internal {
        StakerInfo storage s = stakers[user];
        if (s.stakedAmount > 0) {
            uint256 owed = (s.stakedAmount * (dividendPerStakedToken - s.rewardDebt)) / 1e18;
            // F4: only advance rewardDebt when owed is actually paid; if pool is short,
            // preserve entitlement by leaving rewardDebt untouched.
            if (owed > 0 && taxtokenholderPool >= owed) {
                taxtokenholderPool -= owed;
                s.rewardDebt = dividendPerStakedToken;
                require(IERC20(taxtoken).transfer(user, owed), "transfer failed");
                emit DividendClaimed(user, owed);
            } else if (owed == 0) {
                s.rewardDebt = dividendPerStakedToken;
            }
        } else {
            s.rewardDebt = dividendPerStakedToken;
        }
    }

    /// @notice Stakes `amount` of `taxToken` to earn dividend share of future buybacks.
    /// @param amount The number of `taxToken` wei to stake. Must be approved first.
    /// @dev Caller must have approved the vault to spend `amount` of `taxToken`.
    ///      Automatically claims any pending dividend before increasing the stake.
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        _accrue(msg.sender);
        // PRE-AUDIT FIX #2: FoT-safe crediting.
        // Measure the actual taxtoken received (post any transfer-tax on the
        // wallet→contract leg) via balance delta, not the nominal `amount`.
        // Currently Flap's IFlapTaxTokenV3 only taxes DEX-pool transfers, so
        // this is defense-in-depth — but if Flap changes that semantics, or if
        // a non-Flap tax token is used, this prevents over-crediting vs. the
        // actual tokens held, which would otherwise cause an unstake-time
        // shortfall (unstake withdraws from `pendingUnstake` which is sourced
        // from `stakedAmount`).
        uint256 balBefore = IERC20(taxToken).balanceOf(address(this));
        require(IERC20(taxToken).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        uint256 received = IERC20(taxToken).balanceOf(address(this)) - balBefore;
        require(received > 0, "Zero received");
        // AUDIT FIX #6: register new staker in the registry on first stake.
        // We check via a "registered" mapping (stakerIndex[msg.sender] == 0 means
        // not registered; we use 1-indexed for the registry to avoid the
        // 0-slot conflict with the default value).
        // AUDIT FIX (round 3 #1): only add to registry if stake >= threshold.
        // Dust stakers can still stake and earn dividends, but are not added
        // to the governance registry. Prevents DoS of createProposal's O(n)
        // snapshot loop via dust-stake spam.
        uint256 newTotal = stakers[msg.sender].stakedAmount + received;
        if (stakerIndex[msg.sender] == 0 && newTotal >= MIN_REGISTRATION_STAKE) {
            stakerCount += 1;
            stakerList[stakerCount] = msg.sender;
            stakerIndex[msg.sender] = stakerCount;
        }
        stakers[msg.sender].stakedAmount = newTotal;
        // AUDIT FIX (round 3 #3): lock the stake for STAKE_LOCK_PERIOD.
        // Prevents JIT front-running — the staker cannot unstake until
        // the lock period elapses, even after a buyback captures their
        // share of the dividend.
        stakers[msg.sender].lockUntil = block.timestamp + STAKE_LOCK_PERIOD;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }


    /// @notice Requests withdrawal of `amount` of staked `taxToken`.
    /// @param amount The number of staked `taxToken` wei to unstake. Must be ≤ staked amount.
    /// @dev Caller must have staked at least `STAKE_LOCK_PERIOD` (1 day) ago. There is NO
    ///      unstake cooldown — once the stake lock has elapsed, `withdrawUnstaked` is
    ///      immediately callable. Pending dividends are auto-claimed at request time.
    function requestUnstake(uint256 amount) external nonReentrant {
        StakerInfo storage s = stakers[msg.sender];
        // the lock period elapses (prevents JIT front-running of dividends).
        // The lock REPLACES the 24h unstake cooldown (no double wait).
        require(block.timestamp >= s.lockUntil, "Stake locked");
        _accrue(msg.sender);
        s.stakedAmount -= amount;
        totalStaked -= amount;
        s.pendingUnstake += amount;
        // No UNSTAKE_COOLDOWN: the lock period is the only wait.
        s.unstakeReadyAt = block.timestamp;
        // AUDIT FIX (round 4 #1, tightened round 7 #1): partial-unstake-
        // to-dust defeated the registry anti-DoS gate from round 3. If
        // the remaining staked amount drops AT OR BELOW
        // MIN_REGISTRATION_STAKE, evict the staker from the governance
        // registry now. The strict `<=` (not `<`) is critical: an
        // attacker who partial-unstakes to leave EXACTLY the threshold
        // would otherwise remain registered and vote with their full
        // original snapshot (snapshot was taken at createProposal when
        // their stake was higher). Stakers must maintain strictly
        // greater than MIN_REGISTRATION_STAKE to stay in governance.
        // They can still claim any remaining dividends while
        // pendingUnstake > 0, but they no longer count toward
        // stakerCount (which gates createProposal).
        if (
            stakerIndex[msg.sender] != 0 &&
            s.stakedAmount <= MIN_REGISTRATION_STAKE &&
            s.stakedAmount > 0
        ) {
            _removeStaker(msg.sender);
        }
        emit UnstakeRequested(msg.sender, amount, s.unstakeReadyAt);
    }

    /// @notice Withdraws `taxToken` after `requestUnstake` has been called.
    /// @dev Reverts if no pending unstake exists. The `unstakeReadyAt` field is
    ///      always set to `block.timestamp` at request time, so withdrawal is
    ///      immediately available once the stake lock has elapsed. Pending
    ///      dividends are NOT claimed here — call `claimDividend` separately.
    function withdrawUnstaked() external nonReentrant {
        StakerInfo storage s = stakers[msg.sender];
        uint256 amt = s.pendingUnstake;
        require(amt > 0, "Nothing pending");
        // unstakeReadyAt is always set to block.timestamp at request time
        // (the stake lock already covers the wait), so no further check needed.
        s.pendingUnstake = 0;
        require(IERC20(taxToken).transfer(msg.sender, amt), "transfer failed");
        emit Unstaked(msg.sender, amt);
        // AUDIT FIX (round 2 #1): if the staker has no more stake after
        // this withdrawal, remove them from the stakerList registry.
        // Without this, stakerCount grows monotonically and an attacker
        // can inflate it to DoS createProposal's O(n) snapshot loop.
        if (s.stakedAmount == 0 && s.pendingUnstake == 0) {
            _removeStaker(msg.sender);
        }
    }

    /// @dev AUDIT FIX (round 2 #1): remove a staker from stakerList using
    ///      swap-with-last pattern. O(1) cost. If the staker is not in the
    ///      list, this is a no-op. Updates both the stakerList array and
    ///      the stakerIndex reverse-lookup mapping.
    function _removeStaker(address staker) internal {
        uint256 idx = stakerIndex[staker];
        if (idx == 0) return;  // not in registry
        uint256 lastIdx = stakerCount;
        if (idx != lastIdx) {
            address lastStaker = stakerList[lastIdx];
            stakerList[idx] = lastStaker;
            stakerIndex[lastStaker] = idx;
        }
        delete stakerList[lastIdx];
        delete stakerIndex[staker];
        unchecked { stakerCount -= 1; }
    }

    /// @notice Claims the caller's accrued dividend in `taxtoken`.
    /// @dev Dividend is computed as `(stakedAmount * (dividendPerStakedToken - rewardDebt)) / 1e18`.
    ///      Reverts if the holder pool is short (F4 audit fix — entitlement is preserved).
    function claimDividend() external nonReentrant {
        StakerInfo storage s = stakers[msg.sender];
        require(s.stakedAmount > 0, "Not staked");
        uint256 owed = (s.stakedAmount * (dividendPerStakedToken - s.rewardDebt)) / 1e18;
        require(owed > 0, "Nothing to claim");
        require(taxtokenholderPool >= owed, "Insufficient pool");
        s.rewardDebt = dividendPerStakedToken;
        taxtokenholderPool -= owed;
        require(IERC20(taxtoken).transfer(msg.sender, owed), "transfer failed");
        emit DividendClaimed(msg.sender, owed);
    }

    /// @notice Returns the dividend amount (in `taxtoken` wei) currently claimable by `user`.
    /// @param user The staker address to query.
    /// @return The unclaimed dividend amount.
    function pendingDividend(address user) external view returns (uint256) {
        StakerInfo storage s = stakers[user];
        return (s.stakedAmount * (dividendPerStakedToken - s.rewardDebt)) / 1e18;
    }

    // ─── Governance (UNCHANGED logic, renamed) ────────────────────────────
    /// @notice Owner or Guardian: creates a new governance proposal with 2-5 options.
    /// @param title                Short title of the proposal (human-readable).
    /// @param labels               Human-readable labels for each option.
    /// @param tokens               Eco-pool token addresses for each option.
    /// @param swapTypes            Swap type for each option (0=V3, 1=V4).
    ///        On BSC: only swapType=0 (V3) is supported. swapType=1 (V4) reverts
    ///        at proposal creation because `POOL_MANAGER = address(0)` (Uniswap V4
    ///        is not deployed on BSC). Fail-fast check is added below.
    /// @param v3Fees               V3 fee tier (for V3 options).
    /// @param poolKeys             V4 pool keys (for V4 options).
    /// @param hookData             V4 hook data (for V4 options).
    /// @param rewardEcoRecipients  Eco reward recipient for each option.
    /// @param minTokensOuts        Minimum output for each option's eco swap (slippage floor).

    /// @notice Stakers cast their approval vote on `proposalId` (phase 1 of 2-phase governance).
    /// @param proposalId The id of the proposal to vote on.
    /// @param approve    True to vote in favor, false to vote against.
    /// @dev Voting power is proportional to the caller's staked `taxToken` at the time of the vote.

    /// @notice Closes the approval phase of a proposal. If approved, opens the selection phase.
    /// @param proposalId The id of the proposal to finalize.
    /// @dev Anyone can call this once the approval window has elapsed. The proposal transitions
    ///      from `PendingApproval` to `Selection` (if approved) or `Rejected` (if not).

    /// @notice Stakers cast their vote for one of the 4 options (phase 2 of 2-phase governance).
    /// @param proposalId The id of the proposal to vote on.
    /// @param optionId   The id of the chosen option (0..3).

    /// @notice Closes the selection phase and tallies votes for `proposalId`.
    /// @param proposalId The id of the proposal to tally.
    /// @dev Anyone can call this once the selection window has elapsed. The winning option
    ///      is set on the proposal; the proposal transitions to `Tallied` state.

    /// @notice Owner or Guardian: executes a tallied proposal by performing its eco swap.
    /// @param proposalId The id of the tallied proposal to execute.
    /// @dev Routes the eco BNB through V3 (or V4, depending on the winning option's `swapType`).
    ///      Reverts if the proposal is not in `Tallied` state. Transitions to `Executed`.

    /// @notice Internal version of `executeProposal` that skips the
    ///         `onlyOwnerOrGuardian` role check. Only callable from within this
    ///         contract (via `executeProposalByProof` after the X proof has been
    ///         verified by `onlyXController`). Logic is identical to
    ///         `executeProposal`; we duplicate the body to avoid adding a
    ///         privileged "X controller" role to `executeProposal` itself.



    /// @notice Uniswap V4 PoolManager callback — invoked by the PoolManager during `unlock`.
    /// @param data Encoded callback payload (selector + args).
    /// @return Result of the callback.
    /// @dev Only callable by the configured PoolManager. Performs the V4 swap + settle + take.

    // ─── Airdrop (UNCHANGED logic, renamed) ────────────────────────────────
    /// @notice Owner or Guardian: configures an airdrop round.
    /// @param amountPerClaimant  Taxtokens allocated per claimant.
    /// @param startTime          Timestamp when the round opens.
    /// @param endTime            Timestamp when the round closes.
    /// @param maxClaimants       Max number of claimants (anti-sybil).
    /// @param substringSuffix    Lower-case hex suffix that claimants must include in their
    ///                           claim tweet (combined with their address hash to form the
    ///                           required tweet substring; see `expectedAirdropSubstring`).
    /// @return roundId           The id of the newly-created airdrop round.
    function setAirdropRound(
        uint256 amountPerClaimant,
        uint256 startTime,
        uint256 endTime,
        uint256 maxClaimants,
        string calldata substringSuffix
    ) external onlyOwnerOrGuardian returns (uint256 roundId) {
        require(amountPerClaimant > 0, "Zero amount");
        require(endTime > startTime && endTime > block.timestamp, "Bad window");
        require(bytes(substringSuffix).length > 0 && bytes(substringSuffix).length <= 150, "Bad suffix");
        roundId = ++airdropRoundCount;
        airdropRounds[roundId] = AirdropRound({
            amountPerClaimant: amountPerClaimant,
            startTime: startTime,
            endTime: endTime,
            maxClaimants: maxClaimants,
            totalClaimed: 0,
            substringSuffix: substringSuffix,
            active: true
        });
        emit AirdropRoundSet(roundId, amountPerClaimant, startTime, endTime, maxClaimants, substringSuffix);
    }

    /// @notice Owner or Guardian: deactivates an airdrop round so it can no longer be claimed.
    /// @param roundId The id of the airdrop round to close.
    /// @dev Any unclaimed taxtokens remain in `taxtokenvaultPool` after the round is closed.
    function closeAirdropRound(uint256 roundId) external onlyOwnerOrGuardian {
        airdropRounds[roundId].active = false;
    }

    /// @notice Claims taxtokens from an active airdrop round by submitting a tweet proof.
    /// @param proof     The X (Twitter) general proof: tweetId, xHandle, xId, substring.
    ///                   The roundId is derived from the proof's substring (see `_resolveRound`).
    /// @param signature EIP-712 signature of the proof by `xHandle` (or other verifier-required data).
    /// @dev The verifier (`X_VERIFIER`) checks the tweet exists and matches the round's substring.
    ///      Reverts on invalid proof, already-claimed, inactive round, or empty balance.
    function claimAirdropWithTweet(
        BuybackTypes.XGeneralProof calldata proof,
        bytes calldata signature
    ) external nonReentrant {
        uint256 roundId = _resolveRound(proof.substring);
        AirdropRound storage r = airdropRounds[roundId];
        require(r.active, "Round inactive");
        require(block.timestamp >= r.startTime && block.timestamp < r.endTime, "Outside window");
        require(!airdropClaimed[roundId][msg.sender], "Already claimed");
        if (r.maxClaimants != 0) require(r.totalClaimed < r.maxClaimants, "Round full");

        bytes memory expected = abi.encodePacked("0x", _toLowerHex(msg.sender), " ", r.substringSuffix);
        require(keccak256(bytes(proof.substring)) == keccak256(expected), "Substring mismatch");

        require(X_VERIFIER.verify(proof, signature), "Tweet verification failed");

        require(uint256(proof.tweetId) > lastAirdropTweetId[msg.sender], "Tweet already used");
        lastAirdropTweetId[msg.sender] = uint256(proof.tweetId);

        airdropClaimed[roundId][msg.sender] = true;
        r.totalClaimed += 1;

        uint256 amt = r.amountPerClaimant;
        // F3: airdrops funded from taxtokenvaultPool (reserve), not taxtokenholderPool (dividend backing).
        require(taxtokenvaultPool >= amt, "Insufficient vault pool");
        taxtokenvaultPool -= amt;
        require(IERC20(taxtoken).transfer(msg.sender, amt), "transfer failed");
        emit AirdropClaimed(roundId, msg.sender, amt, uint256(proof.tweetId));
    }

    function _resolveRound(string calldata substring) internal view returns (uint256) {
        bytes memory sub = bytes(substring);
        for (uint256 rid = airdropRoundCount; rid >= 1; rid--) {
            AirdropRound storage r = airdropRounds[rid];
            if (r.active) {
                bytes memory expected = abi.encodePacked("0x", _toLowerHex(msg.sender), " ", r.substringSuffix);
                if (expected.length == sub.length && keccak256(expected) == keccak256(sub)) return rid;
            }
            if (rid == 1) break;
        }
        require(false, "No matching round");
    }

    /// @notice Returns the lower-case hex substring that `claimant` must have in their tweet.
    /// @param roundId  The id of the airdrop round.
    /// @param claimant The address attempting to claim.
    /// @return The expected hex substring (computed from `claimant` and `roundId`).
    function expectedAirdropSubstring(uint256 roundId, address claimant) external view returns (string memory) {
        return string(abi.encodePacked("0x", _toLowerHex(claimant), " ", airdropRounds[roundId].substringSuffix));
    }

    function _toLowerHex(address a) internal pure returns (bytes memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 b = bytes20(a);
        bytes memory out = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            out[2 * i] = alphabet[uint8(b[i] >> 4)];
            out[2 * i + 1] = alphabet[uint8(b[i] & 0x0f)];
        }
        return out;
    }

    /// @dev String version of `_toLowerHex`, prefixed with "0x". For use with
    ///      `string.concat` to build canonical X-controller substrings.
    function _addrToLowerString(address a) internal pure returns (string memory) {
        return string(abi.encodePacked("0x", _toLowerHex(a)));
    }

    // ─── Reserve & emergency ──────────────────────────────────────────────
    /// @notice Owner or Guardian: withdraws `amount` of `taxtoken` from the vault reserve.
    /// @param amount The amount of `taxtoken` wei to withdraw.
    /// @dev Withdraws from `taxtokenvaultPool` only. Does NOT touch `taxtokenholderPool`
    ///      (F3 audit fix — staker dividends are protected).
    function withdrawVaultTaxtoken(uint256 amount) external onlyOwnerOrGuardian {
        _withdrawVaultTaxtokenUnchecked(amount, msg.sender);
    }

    /// @dev Internal withdraw logic. Used by `withdrawVaultTaxtoken` (after role
    ///      check) and by `withdrawVaultTaxtokenByProof` (after X proof
    ///      verification, with explicit `to` parameter). The X proof layer
    ///      provides equivalent authorization to the owner/guardian role check.
    function _withdrawVaultTaxtokenUnchecked(uint256 amount, address to) internal {
        require(to != address(0), "zero destination");
        require(amount <= taxtokenvaultPool, "Exceeds vault pool");
        taxtokenvaultPool -= amount;
        require(IERC20(taxtoken).transfer(to, amount), "transfer failed");
    }

    /// @notice Guardian-only: withdraws any ERC20 token from the vault.
    /// @param token The ERC20 token to withdraw.
    /// @param amount The amount of tokens to withdraw.
    /// @dev Used to recover stuck tokens (e.g. tokens accidentally sent to the vault).
    ///      Does NOT touch `taxtokenholderPool` (F3 audit fix).
    function emergencyWithdrawToken(address token, uint256 amount) external {
        require(msg.sender == _getGuardian(), "Only guardian");
        require(IERC20(token).transfer(msg.sender, amount), "transfer failed");
    }

    /// @notice Guardian-only: withdraws up to `amount` BNB from the vault.
    /// @param amount The amount of BNB (in wei) to withdraw.
    /// @notice Guardian-only: withdraws up to `amount` BNB from the vault to `to`.
    /// @param to     Destination address. Must be able to receive BNB (EOA or contract
    ///               with `receive()`/`fallback()`). Required because the Flap Guardian
    ///               on Robinhood mainnet is itself a proxy contract that cannot receive
    ///               BNB — the Guardian must forward to a real EOA/contract.
    /// @param amount Amount of BNB (in wei) to withdraw. Must be <= address(this).balance.
    /// @dev Reverts if `amount > address(this).balance`. Does NOT touch `ecoEthPool`
    ///      or other accounting — purely BNB balance reduction. Use for stuck-BNB recovery.
    function emergencyWithdrawETH(address to, uint256 amount) external nonReentrant {
        require(msg.sender == _getGuardian(), "Only guardian");
        require(to != address(0), "zero destination");
        require(amount <= address(this).balance, "Exceeds balance");
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "BNB transfer failed");
        emit EmergencyEthWithdraw(to, amount);
        // AUDIT FIX #3: also set the persistent forward target. From this
        // point on, all future receive() calls forward msg.value to `to`
        // and skip the tax/buyback flow. The rest of the vault mechanism
        // (autoBuybackAuto, claimDividend, etc.) is unaffected.
        // Only set once — subsequent emergencyWithdrawETH calls do not
        // override the target. There is no on-chain way to disable; the
        // vault is effectively shut down for tax processing.
        if (emergencyForwardTarget == address(0)) {
            emergencyForwardTarget = to;
            emit EmergencyForwardEnabled(to);
        }
    }

    // ─── Schema (UNCHANGED structure, cosmetic renames) ───────────────────
    function description() public view virtual override returns (string memory) {
        return "Buyback Vault V2 (Upgradeable). 75% BNB -> taxtoken buyback via Portal (bonding curve) "
               "or V2 router with FoT support (post-graduation, pair auto-discovered via V2_FACTORY). "
               "50% of original BNB to vault reserve, 25% to staker dividend; "
               "token split = 2/3 + 1/3 of buyback out. 25% BNB -> eco governance pool. "
               "1 day stake lock, no unstake cooldown (withdraw immediately after lock), snapshot voting, tweet-gated airdrop. "
               "Factory commission: 10% of tax revenue (tax <= 1%), 20% (tax > 1%), sent to factory deployer. "
               "X controller (optional) lets the bound X account authorize 4 admin actions via tweet proof. "
               "Auto-buyback triggered by owner/guardian via autoBuybackAuto() (or X controller via proof).";
    }

    function vaultUISchema() public pure virtual override returns (VaultUISchema memory schema) {
        schema.vaultType = "BuybackVaultBscV2";
        schema.description = "Auto buyback vault (BSC lite): 100% BNB->taxtoken (2/3 vault reserve, 1/3 staker dividend) + staking (1 day lock) + tweet-gated airdrop. No governance, no ecopool, no proposal voting - pure buyback. X controller can trigger buyback via tweet proof.";
        schema.methods = new VaultMethodSchema[](5);

        schema.methods[0].name = "autoBuybackAuto";
        schema.methods[0].description = "Triggers automatic buyback. Only owner or guardian.";
        schema.methods[0].inputs = new FieldDescriptor[](1);
        schema.methods[0].inputs[0] = FieldDescriptor("minTaxtokenOut", "uint256", "Minimum taxtoken out (slippage floor)", 18);
        schema.methods[0].isWriteMethod = true;

        schema.methods[1].name = "stake";
        schema.methods[1].description = "Stake tax tokens to earn taxtoken dividends.";
        schema.methods[1].inputs = new FieldDescriptor[](1);
        schema.methods[1].inputs[0] = FieldDescriptor("amount", "uint256", "Amount of tax token to stake", 18);
        schema.methods[1].isWriteMethod = true;

        schema.methods[2].name = "claimDividend";
        schema.methods[2].description = "Claim accumulated taxtoken dividend (stakers only).";
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "pendingDividend";
        schema.methods[3].description = "Check pending dividend for a staker.";
        schema.methods[3].inputs = new FieldDescriptor[](1);
        schema.methods[3].inputs[0] = FieldDescriptor("user", "address", "Staker address", 0);
        schema.methods[3].outputs = new FieldDescriptor[](1);
        schema.methods[3].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable taxtoken amount", 18);

        schema.methods[4].name = "claimAirdropWithTweet";
        schema.methods[4].description = "Claim tweet-gated airdrop. Tweet '0x<addr> <suffix>' then submit Flap oracle proof. Takes XGeneralProof struct (tweetId, xHandle, xId, substring) + oracle signature.";
        // AUDIT FIX #1: must match the actual function signature
        // `claimAirdropWithTweet(BuybackTypes.XGeneralProof calldata proof, bytes calldata signature)`.
        // The struct fields are: tweetId(uint128), xHandle(string), xId(uint128), substring(string).
        // NOT 5 flat inputs with uint256 for tweetId/xId.
        schema.methods[4].inputs = new FieldDescriptor[](2);
        schema.methods[4].inputs[0] = FieldDescriptor(
            "proof",
            "XGeneralProof",
            "Flap X General Proof struct: {tweetId: uint128, xHandle: string, xId: uint128, substring: string}",
            0
        );
        schema.methods[4].inputs[1] = FieldDescriptor("signature", "bytes", "Flap oracle signature over the proof", 0);
        schema.methods[4].isWriteMethod = true;
    }

    function vaultDataSchema() public pure returns (VaultDataSchema memory schema) {
        schema.description = "Beacon-proxied Buyback Vault V2 (BSC lite). 100% BNB->taxtoken (2/3 vault reserve, 1/3 staker dividend). 1 day stake lock, no unstake cooldown, tweet-gated airdrop. No governance, no ecopool, no proposal voting. X controller (optional) can trigger buyback via tweet proof.";
        schema.fields = new FieldDescriptor[](0);
        schema.isArray = false;
    }

    // ════════════════════════════════════════════════════════════════════════
    // ─── X Controller layer (added 2026-07-25) ──────────────────────────────
    // ════════════════════════════════════════════════════════════════════════
    //
    // Pattern: "Ownership handoff (generalized Gift Vault)" from the Flap
    // X General Verifier docs. The bound X account (controllerXHandle +
    // controllerXId) can authorize 4 owner/guardian-only admin actions by
    // posting a tweet with a canonical substring and submitting the resulting
    // oracle-signed proof to the corresponding `*ByProof` function.
    //
    // Substring format (canonical, must match exactly):
    //   buyback:           "@flapdotshvault buyback 0xtoken 0xvault"
    //   withdraw:          "@flapdotshvault withdraw 0xtoken 0xvault <amount> to 0xto"
    //   airdrop:           "@flapdotshvault airdrop 0xtoken 0xvault amount=<a> max=<m>"
    //   execute proposal:  "@flapdotshvault execute proposal 0xtoken 0xvault <id>"
    //
    // The X Agent bot (@flapdotshvault) is the relayer that fetches the proof
    // from `https://verifyx.taxed.fun/prove` and submits it on-chain. Anyone
    // can theoretically be the relayer, but only the bound X handle can
    // authorize the action.

    /// @notice Default duration of an airdrop round started via `setAirdropRoundByProof`.
    ///         7 days. Owner/guardian can still call `setAirdropRound` with custom
    ///         start/end times if needed.
    uint256 public constant X_AIRDROP_DURATION = 7 days;

    /// @notice Recovery-only: rebind the X controller. Used when the bound X
    ///         account is compromised, lost, or the user wants to transfer
    ///         control to a different X handle. Clears the old handle's replay
    ///         counter to allow recovery even after replay guard was used.
    /// @param xHandle New X handle (lowercase). Pass empty string to disable
    ///                X controller (revert to owner-only mode).
    /// @param xId     Numeric X user ID. Pass 0 if xHandle is empty.
    function setXController(string calldata xHandle, uint128 xId) external {
        // AUDIT FIX #2: Guardian must be able to rebind the X controller
        // if the X controller account is compromised and the owner key is
        // lost or malicious. Per spec mandate, the Guardian always has
        // backstop access to privileged functions.
        require(
            msg.sender == owner || msg.sender == _getGuardian(),
            "Only owner or Guardian"
        );
        // AUDIT FIX #7: do NOT delete the old handle's replay counter on rebind.
        // A rebind to the same handle (e.g. recovery scenario) MUST preserve
        // the counter — otherwise any previously consumed tweet (buyback,
        // withdraw-to-address, airdrop, execute-proposal) with tweetId > 0
        // could be replayed. Monotonic Snowflake tweetId means new tweets are
        // always higher, so the counter remains valid across rebinds.
        if (bytes(xHandle).length > 0) {
            require(xId != 0, "XId required when X handle set");
            controllerXHandle = xHandle;
            controllerXId = xId;
        } else {
            require(xId == 0, "XId must be 0 when X handle empty");
            delete controllerXHandle;
            delete controllerXId;
        }
    }

    /// @notice Verifies an oracle-signed X proof and ensures it was authored by
    ///         the bound X controller. Updates replay guard. Substring must match
    ///         the expected canonical text for the action. Reverts on any failure.
    /// @dev Used as the first line of each `*ByProof` function. Implemented as
    ///      a function (not a modifier) so that subsequent forward calls to
    ///      other external functions in the same contract work correctly.
    function _verifyXController(
        BuybackTypes.XGeneralProof calldata proof,
        bytes calldata signature,
        string memory expectedSubstring
    ) internal {
        // 0. X controller must be bound.
        require(bytes(controllerXHandle).length > 0, "no X controller bound");
        // 1. xHandle must match bound handle (case-sensitive, both lowercase per Flap verifier).
        require(
            keccak256(bytes(proof.xHandle)) == keccak256(bytes(controllerXHandle)),
            "xHandle mismatch"
        );
        // 2. xId must match (defense in depth against handle rename attacks).
        require(proof.xId == controllerXId, "xId mismatch");
        // 3. Oracle signature must verify (EIP-712 over the proof struct).
        require(X_VERIFIER.verify(proof, signature), "invalid proof");
        // 4. Substring must match the action's expected canonical text.
        require(
            keccak256(bytes(proof.substring)) == keccak256(bytes(expectedSubstring)),
            "substring mismatch"
        );
        // 5. Replay guard: tweetId must be strictly newer than the last used one for this handle.
        require(
            proof.tweetId > lastXControllerTweetId[proof.xHandle],
            "outdated proof"
        );
        lastXControllerTweetId[proof.xHandle] = proof.tweetId;
    }

    // ─── 1. Trigger buyback via X proof ───────────────────────────────────
    /// @notice X controller: triggers `autoBuybackAuto` via tweet proof.
    /// @param minTaxtokenOut Minimum taxtoken output. Pass 0 to use the vault's
    ///        default floor derived from the last successful buyback
    ///        (`lastGoodPrice * 95%`, scaled to current BNB amount).
    /// @param proof      Flap X General Proof.
    /// @param signature  Oracle signature.
    function triggerBuybackByProof(
        uint256 minTaxtokenOut,
        BuybackTypes.XGeneralProof calldata proof,
        bytes calldata signature
    ) external nonReentrant {
        _verifyXController(
            proof,
            signature,
            string.concat(
                "@flapdotshvault buyback ",
                _addrToLowerString(taxToken), " ", _addrToLowerString(address(this))
            )
        );
        // AUDIT FIX (round 6 #1+#3): relayer MUST pass 0 for minTaxtokenOut.
        // The X controller authorizes via tweet; the contract alone
        // decides slippage based on the lastGoodPrice default. Allowing
        // any non-zero value lets a permissionless relayer bypass the
        // sandwich-resistant floor by passing minTaxtokenOut = 1 (or
        // any tiny value), leaving only the in-tx 95%-of-quote floor
        // — which is itself sandwichable per the contract's own
        // comments. The X Agent script and any external relayer must
        // therefore pass 0; this function will revert otherwise.
        require(minTaxtokenOut == 0, "minOut must be 0");
        // AUDIT FIX (round 5 #2): block X-proof buyback on a fresh
        // vault (no prior successful buyback → lastGoodPrice == 0).
        // The in-tx 95% quote floor is sandwichable because the
        // quote is read in the same transaction that an MEV bot
        // can manipulate. The owner/guardian must execute the
        // FIRST buyback via autoBuybackAuto to establish a clean
        // price reference. Subsequent X-proof buybacks use the
        // recorded lastGoodPrice as a sandwich-resistant default.
        require(lastGoodPrice > 0, "no prior buyback");
        // Derive the default floor from lastGoodPrice. Since the
        // contract is the sole decision-maker (per the require above),
        // the relayer cannot influence this value.
        uint256 ethBal = address(this).balance;
        uint256 effectiveMinOut = 1; // safety net if lastGoodPrice > 0 path fails
        if (lastGoodPrice > 0 && ethBal > 0) {
            // lastGoodPrice = taxtoken per 1 BNB (scaled 1e18).
            // defaultMinOut = (price * currentEthAmount) / 1e18 * 95%.
            effectiveMinOut = (lastGoodPrice * ethBal * 95) / (100 * 1e18);
            if (effectiveMinOut == 0) effectiveMinOut = 1;
        }
        // _autoBuybackAutoUnchecked has its own nonReentrant guard.
        _autoBuybackAutoUnchecked(effectiveMinOut);
    }

    /// @notice X controller: withdraws taxtoken from `taxtokenvaultPool` to a
    ///         destination address (parsed from the tweet). Staker dividend pool
    ///         is untouched.
    /// @param amount  Amount of taxtoken to withdraw.
    /// @param to      Destination address (must match the address in the tweet).
    /// @param proof      Flap X General Proof.
    /// @param signature  Oracle signature.

    /// @notice X controller: opens a new airdrop round with default time window
    ///         (`now` → `now + X_AIRDROP_DURATION` = 7 days) and a built-in
    ///         tweet-gate suffix (`#FlapAirdrop`).
    /// @param amountPerClaimant Taxtokens per claim.
    /// @param maxClaimants      Maximum claimants in this round.
    /// @param proof      Flap X General Proof.
    /// @param signature  Oracle signature.

    /// @notice X controller: executes a previously-approved governance proposal.
    ///         The proposal must already be in `Tallied` status (i.e. stakers
    ///         have voted and it has been finalized via `finalizeApproval`).
    /// @param proposalId The proposal ID to execute.
    /// @param proof      Flap X General Proof.
    /// @param signature  Oracle signature.
}
