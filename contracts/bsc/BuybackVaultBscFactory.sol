// =====================================================================
//  ⚠️  THIS IS THE BSC VARIANT (BNB Smart Chain, chain 56) — "LITE" build
//  Original Robinhood Chain (chain 4663) version: ./BuybackVaultFactory.sol
//  All chain-specific addresses updated to BSC equivalents:
//    - WETH (constant) = WBNB (token)
//    - V2      → PancakeSwap V2 (factory + router)
//    - V3      → PancakeSwap V3 SwapRouter02
//    - X       → BSC XGeneralVerifier
//    - Portal  → BSC Flap Portal
//    - V4 PM   → 0x0 (Uniswap V4 not deployed on BSC; swapType=1 disabled)
//
//  LITE FEATURE SET (vs Robinhood):
//    REMOVED to fit BSC's 24KB contract size limit (EIP-170):
//      - Governance proposals / voting (createProposal, voteApproval, vote, tally, execute)
//      - ecoEthPool (25% BNB reserve for governance was killed with governance)
//      - X-proof admin actions: withdrawVaultTaxtokenByProof,
//        setAirdropRoundByProof, executeProposalByProof
//    KEPT:
//      - 100% BNB->taxtoken buyback (no ecopool, more aggressive than Robinhood's 75%)
//      - 2/3 taxtoken to vault reserve, 1/3 to staker dividend
//      - Staking + dividend (1 day stake lock, no unstake cooldown)
//      - Tweet-gated airdrops
//      - X-controller proof buyback trigger (triggerBuybackByProof)
//      - Emergency withdraw (ETH + token)
//
//  factorySpecVersion() returns "v2.2-bsc-lite" to distinguish from
//  Robinhood "v2.2" and from a future full-feature "v2.2-bsc" if governance
//  is restored via library refactor.
//  _getVaultPortal() and _getGuardian() are chain-aware (already support BSC).
// =====================================================================

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2, IPortalTypes} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "./flap/IVaultSchemasV1.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BuybackVaultBsc} from "./BuybackVaultBscImplementation.sol";

/// @title BuybackVaultBscFactory
/// @notice Permissionless beacon-backed factory that deploys `BuybackVaultBsc`
///         vaults for any ERC20 tax token. The factory's commission (10% of tax revenue when
///         tax ≤ 1%, 20% when tax > 1%) is auto-sent by every vault to `commissionRecipient`
///         on each `receive()`, and the recipient can withdraw all accumulated commission at
///         once via `withdrawCommission()`.
///
///         Spec compliance:
///           - Inherits `VaultFactoryBaseV2` (canonical Flap V2.2 surface)
///           - `factorySpecVersion() = "v2.2"`
///           - `_validateBeforeLaunch(...)` enforces product rules
///           - `tokenCreationPolicies()` returns machine-readable UI hints
///           - V2.3 features (LP/child dividend resolution) are NOT implemented
contract BuybackVaultBscFactory is VaultFactoryBaseV2 {
    /// @dev Config that the launcher encodes in `vaultData` when calling
    ///      `VaultPortal.newTokenV6WithVault(...)` with this factory.
    ///      The V2 pair is auto-discovered at buyback time (no pre-launch pool registration
    ///      required). WETH (WBNB on BSC), V2_FACTORY (PancakeSwap), V2_ROUTER (PancakeSwap) are protocol-level constants on BSC.
    struct BuybackVaultConfig {
        address owner;           // Vault admin (0x0 = factory deployer / commissionRecipient).
        string  xController;     // X (Twitter) handle authorized to control this vault via X proof (lowercase, e.g. "andi"). Empty = no X controller.
        uint128 xId;             // Numeric X user ID of the X controller (Snowflake-style, paired with xController for handle-rename protection).
    }

    // ─── State ─────────────────────────────────────────────────────────────
    address public immutable beacon;

    /// @notice Recipient of the factory commission. Set in the constructor to
    ///         `msg.sender` (the factory deployer). Implemented as `immutable`
    ///         so it can never be rotated by an upgrade.
    address public immutable commissionRecipient;

    /// @notice The address that should receive the **Flap protocol's** commission
    ///         (calculated by `_commissionForTax` in the Portal). Set to **this
    ///         factory contract** in the constructor (`address(this)`) so that:
    ///           1. The Flap protocol's commission (via `commissionReceiver` in
    ///              `NewTokenV6WithVaultParams`) flows into the factory.
    ///           2. The vault's `receive()` commission also flows into the factory.
    ///           3. The factory's `commissionRecipient` (deployer EOA) can sweep
    ///              BOTH commission streams via `withdrawCommission(self)`.
    ///         This is intentionally **NOT** the deployer EOA — having the factory
    ///         itself as the receiver creates a single on-chain sink that can be
    ///         upgraded/audited independently of the deployer.
    /// @return The address to set as `commissionReceiver` in `NewTokenV6WithVaultParams`.
    function getProtocolCommissionReceiver() external view returns (address) {
        return defaultProtocolCommissionReceiver;
    }

    /// @notice State variable set in the constructor to `address(this)`. See
    ///         `getProtocolCommissionReceiver()` for the rationale.
    /// @dev    Set in the constructor (not at compile time) so the address
    ///         automatically tracks wherever this factory is deployed — BSC mainnet,
    ///         BSC testnet, or any other chain. The deployer does NOT need to know
    ///         the address in advance.
    address public immutable defaultProtocolCommissionReceiver;

    /// @notice WETH constant (set to WBNB address on BSC) — used for V2/V3/V4 swap paths.
    ///         deployed by this factory.
    address public constant WETH = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /// @notice Accumulated factory commission from all vaults deployed by this factory.
    ///         `withdrawCommission()` resets this to 0.
    uint256 public totalCommission;

    // ─── Events ───────────────────────────────────────────────────────────
    event CommissionWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Factory constructor — Beacon pattern.
     * @param _implementation Address of a pre-deployed BuybackVaultBsc implementation.
     *        Must be deployed separately because BSC's 24KB contract size limit
     *        prevents the factory + implementation from fitting in a single init
     *        code (the combined size is ~43KB).
     * @dev    Deploy order:
     *        1. Deploy BuybackVaultBsc implementation (constructor has no args)
     *        2. Deploy BuybackVaultBscFactory with the impl address above
     *        3. Register factory as Guardian/Portal in the Flap BSC config
     */
    constructor(address _implementation) {
        require(_implementation != address(0), "Zero implementation");
        commissionRecipient = msg.sender;
        defaultProtocolCommissionReceiver = address(this);
        beacon = address(new UpgradeableBeacon(_implementation, address(this)));
    }

    // ─── newVault ─────────────────────────────────────────────────────────
    /// @notice Creates a new vault instance for a tax token.
    /// @dev Only callable by the chain's VaultPortal. Decodes a `BuybackVaultConfig`
    ///      from `vaultData`, sanity-checks it, and deploys a `BeaconProxy` pointing
    ///      at the implementation. The factory address is forwarded to the vault so
    ///      commission auto-send works out of the box.
    function newVault(
        address taxToken,
        address quoteToken,
        address /* creator — kept for VaultPortal interface compatibility, ignored: 0x0 owner resolves to commissionRecipient per cfg */,
        bytes calldata vaultData
    ) external override returns (address vault) {
        require(msg.sender == _getVaultPortal(), "Only VaultPortal");
        require(quoteToken == address(0), "Only native BNB supported");

        BuybackVaultConfig memory cfg = abi.decode(vaultData, (BuybackVaultConfig));

        // AUDIT FIX (round 2 #3): zero owner → commissionRecipient (the
        // factory deployer EOA). Documented behavior; matches the struct
        // field comment and the vaultDataSchema field text.
        address ownerAddr = cfg.owner == address(0) ? commissionRecipient : cfg.owner;

        vault = address(new BeaconProxy(beacon, abi.encodeCall(
            BuybackVaultBsc.initialize,
            (taxToken, ownerAddr, address(this), cfg.xController, cfg.xId)
        )));
    }

    /// @notice Checks if a quote token is supported by this vault factory.
    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool supported) {
        supported = quoteToken == address(0);
    }

    // ─── V2.2 spec features ───────────────────────────────────────────────
    /// @notice Returns the VaultFactoryBaseV2 spec version this factory implements.
    /// @return The spec version string. Returns "v2.2-bsc" to distinguish from the
    ///         Robinhood Chain ("v2.2") variant. The base spec is the same; the suffix
    ///         signals BSC-specific address overrides (PancakeSwap, WBNB, BSC Portal).
    function factorySpecVersion() public pure virtual override returns (string memory) {
        return "v2.2-bsc-lite";
    }

    /// @notice Validates the launch params before the VaultPortal creates a token.
    /// @param data The normalized launch payload (token version, tax rates, dividend config, ...).
    /// @return success True if the params are accepted by this factory.
    /// @return reason  Human-readable rejection reason (empty on success).
    /// @dev Overrides the default which always returns true. Restricts to native BNB (no ERC20 quote)
    ///      and requires `vaultBps == 10000` (this vault receives 100% of the platform fee — self-buyback model).
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal pure override returns (bool success, string memory reason)
    {
        // Only TOKEN_TAXED_V3 is supported — same constraint as newTokenV6WithVault
        if (data.tokenVersion != IPortalTypes.TokenVersion.TOKEN_TAXED_V3) {
            return (false, "Buyback Vault requires TOKEN_TAXED_V3 (FlapTaxTokenV3).");
        }
        if (data.quoteToken != address(0)) {
            return (false, "Buyback Vault supports native BNB only.");
        }
        if (data.vaultBps != 10000) {
            return (false, "vaultBps must be 10000 (100% to vault, self-buyback model).");
        }
        if (data.buyTaxRate == 0 && data.sellTaxRate == 0) {
            return (false, "At least one tax rate (buy or sell) must be > 0.");
        }
        return (true, "");
    }

    /// @notice Returns machine-readable UI hints describing the constraints this factory enforces.
    /// @return policies Array of `FactoryPolicy` structs. Each describes a field-level constraint
    ///                  (eq/neq/gt/gte/lt/lte/in/notIn) on the launch params, shown in the launch UI.
    function tokenCreationPolicies() public pure virtual override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](2);
        policies[0] = FactoryPolicy({
            target: "quoteToken",
            operator: "eq",
            value: abi.encode(address(0)),
            description: "Only native BNB (quoteToken == 0) is supported."
        });
        policies[1] = FactoryPolicy({
            target: "vaultBps",
            operator: "eq",
            value: abi.encode(uint256(10000)),
            description: "vaultBps must be 10000 (100% to vault, self-buyback model)."
        });
    }

    // ─── Beacon management (Guardian-gated) ──────────────────────────────
    /// @notice Guardian-only: upgrades the vault implementation behind all beacon proxies.
    /// @param newImplementation Address of the new implementation contract.
    /// @dev All existing vaults immediately delegate to the new implementation on next call.
    ///      Reverts if upgrades have been locked (see `lockVaultUpgrades`).
    function upgradeVaultImplementation(address newImplementation) external {
        require(msg.sender == _getGuardian(), "Only Guardian");
        require(newImplementation != address(0), "Zero implementation");
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
    }

    /// @notice Guardian-only: permanently locks the beacon so the implementation can never be upgraded again.
    /// @dev After calling, `upgradeVaultImplementation` reverts. One-way operation.
    function lockVaultUpgrades() external {
        require(msg.sender == _getGuardian(), "Only Guardian");
        UpgradeableBeacon(beacon).renounceOwnership();
    }

    /// @notice Returns whether the beacon upgrades have been permanently locked.
    /// @return locked True if the beacon has renounced ownership (no more upgrades possible).
    function isVaultUpgradesLocked() external view returns (bool locked) {
        locked = UpgradeableBeacon(beacon).owner() == address(0);
    }

    /// @notice Returns the current vault implementation address behind the beacon.
    /// @return The implementation address that all beacon proxies delegate to.
    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }

    // ─── Commission accounting ───────────────────────────────────────────
    /// @notice CRITICAL: This `receive()` MUST NEVER REVERT.
    /// @dev Vaults auto-send commission here on every `receive()`. If this reverts,
    ///      the vault's `receive()` reverts too, breaking tax collection for the
    ///      vault's tax token. The implementation is intentionally trivial — only
    ///      a state update. DO NOT MODIFY WITHOUT GUARDIAN REVIEW.
    receive() external payable {
        totalCommission += msg.value;
    }

    /// @notice Withdraw the entire accumulated commission to `to`.
    ///         Callable by `commissionRecipient` OR the chain Guardian.
    function withdrawCommission(address to) external {
        // AUDIT FIX #2: Guardian must be able to rescue commission
        // if the recipient key is lost or compromised. Per spec mandate,
        // the Guardian always has backstop access to privileged functions.
        require(
            msg.sender == commissionRecipient || msg.sender == _getGuardian(),
            "Only recipient or Guardian"
        );
        require(to != address(0), "Zero address");
        uint256 amt = totalCommission;
        require(amt > 0, "Nothing to withdraw");
        totalCommission = 0;
        (bool ok,) = payable(to).call{value: amt}("");
        require(ok, "Transfer failed");
        emit CommissionWithdrawn(to, amt);
    }

    // ─── Schema (UI form for token launch) ──────────────────────────────
    /// @notice Returns the schema describing the `vaultData` bytes expected by `newVault()`.
    /// @return schema Struct with `description`, `fields[]`, and `isArray` flag for UI rendering.
    /// @dev Schema: 4 fields — taxtoken (address), owner (address),
    ///      xController (string), xId (uint128). V2 pair is auto-discovered at
    ///      buyback time (no pre-launch pool registration required).
    function vaultDataSchema() public pure virtual override returns (VaultDataSchema memory schema) {
        schema.description = "Buyback Vault: 75% BNB -> taxtoken buyback via Portal (bonding curve) "
                             "or V2 router with FoT support (post-graduation, pair auto-discovered via V2_FACTORY). "
                             "2/3 of buyback output to vault reserve, 1/3 to staker dividend. "
                             "25% BNB to eco pool. 1 day stake lock, no unstake cooldown, snapshot voting, tweet-gated airdrop. "
                             "Factory commission: 10% of tax revenue (tax <= 1%), 20% (tax > 1%). "
                             "X controller (optional) lets the bound X account authorize 4 admin actions via tweet proof.";
        // Note: 'taxtoken' is NOT in the schema — it is auto-injected by the factory
        // from VaultPortal's predicted CREATE2 address (passed as `taxToken` arg to
        // `newVault`). This avoids the chicken-and-egg problem of asking the UI for
        // a token address that doesn't exist yet.
        schema.fields = new FieldDescriptor[](3);
        schema.fields[0] = FieldDescriptor("owner",       "address", "Vault admin (0x0 = factory deployer / commissionRecipient)", 0);
        schema.fields[1] = FieldDescriptor("xController", "string",  "X handle authorized to control vault via tweet (lowercase, e.g. 'andi'). Empty = no X controller.", 0);
        schema.fields[2] = FieldDescriptor("xId",         "uint128", "Numeric X user ID of the X controller (Snowflake-style, paired with handle for rename-attack protection). 0 if xController empty.", 0);
        schema.isArray = false;
    }
}
