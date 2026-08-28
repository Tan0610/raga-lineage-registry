// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEAS} from "eas-contracts/IEAS.sol";
import {Attestation} from "eas-contracts/Common.sol";
import {SchemaResolver} from "eas-contracts/resolver/SchemaResolver.sol";

/// @title LineageAttestationResolver
/// @notice The EAS schema resolver guarding the lineage schema.
///
///         Without this, anyone could call `EAS.attest()` directly against the lineage
///         schema and mint themselves a "trained by Devika" record with no involvement
///         from Devika at all — bypassing the two-step confirmation the registry
///         enforces. This resolver closes that door: an attestation on the lineage
///         schema is only accepted when the attester is the registry itself, and the
///         registry only attests once the named teacher has confirmed.
///
/// @dev EAS calls `onAttest` before recording an attestation and `onRevoke` before
///      recording a revocation. Returning false makes EAS reject the operation.
contract LineageAttestationResolver is SchemaResolver {
    /// @notice The registry permitted to write lineage attestations.
    address public registry;

    /// @notice Allowed to bind the registry, exactly once.
    address public immutable admin;

    event RegistryBound(address indexed registry);

    error NotAdmin(address caller);
    error AlreadyBound(address registry);
    error ZeroAddress();

    constructor(IEAS eas, address admin_) SchemaResolver(eas) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
    }

    /// @notice Point the resolver at the registry.
    /// @dev Deployment is necessarily circular — the schema needs a resolver address
    ///      before it can be registered, and the registry needs the schema id — so this
    ///      is a one-time binding rather than a constructor argument. It can never be
    ///      changed afterwards, so the guarantee cannot be quietly rerouted later.
    function bindRegistry(address registry_) external {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        if (registry != address(0)) revert AlreadyBound(registry);
        if (registry_ == address(0)) revert ZeroAddress();

        registry = registry_;
        emit RegistryBound(registry_);
    }

    /// @inheritdoc SchemaResolver
    function onAttest(Attestation calldata attestation, uint256) internal view override returns (bool) {
        return attestation.attester == registry;
    }

    /// @inheritdoc SchemaResolver
    function onRevoke(Attestation calldata attestation, uint256) internal view override returns (bool) {
        return attestation.attester == registry;
    }
}
