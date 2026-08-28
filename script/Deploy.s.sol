// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IEAS} from "eas-contracts/IEAS.sol";
import {ISchemaRegistry} from "eas-contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "eas-contracts/resolver/ISchemaResolver.sol";

import {LineageAttestationResolver} from "../src/LineageAttestationResolver.sol";
import {RagaLineageRegistry} from "../src/RagaLineageRegistry.sol";
import {RagaLicenseRegistry} from "../src/RagaLicenseRegistry.sol";

/// @notice Deploys the lineage resolver, the lineage registry and the licence registry,
///         and binds them together.
///
/// @dev No key material lives in this file. The broadcasting account comes from the forge
///      invocation (`--account <keystore>` is preferred over `--private-key`), and the RPC
///      endpoint comes from the environment. See .env.example.
///
///      Usage:
///        forge script script/Deploy.s.sol:Deploy \
///          --rpc-url base_sepolia --account devcon --broadcast --verify
contract Deploy is Script {
    /// @notice EAS on Base Sepolia. These are the OP Stack predeploy addresses Base uses;
    ///         both are overridable by environment variable, and both should be checked
    ///         against https://docs.attest.org/docs/quick--start/contracts before use on
    ///         any chain other than the one this was tested against.
    address internal constant BASE_SEPOLIA_EAS = 0x4200000000000000000000000000000000000021;
    address internal constant BASE_SEPOLIA_SCHEMA_REGISTRY = 0x4200000000000000000000000000000000000020;

    function run()
        external
        returns (
            LineageAttestationResolver resolver,
            RagaLineageRegistry lineage,
            RagaLicenseRegistry license
        )
    {
        address easAddr = vm.envOr("EAS_ADDRESS", BASE_SEPOLIA_EAS);
        address schemaRegistryAddr = vm.envOr("EAS_SCHEMA_REGISTRY", BASE_SEPOLIA_SCHEMA_REGISTRY);
        address admin = vm.envOr("REGISTRY_ADMIN", msg.sender);

        IEAS eas = IEAS(easAddr);
        ISchemaRegistry schemaRegistry = ISchemaRegistry(schemaRegistryAddr);

        vm.startBroadcast();

        // 1. The resolver must exist before the schema can name it.
        resolver = new LineageAttestationResolver(eas, admin);

        // 2. The registry registers the lineage schema against that resolver.
        lineage = new RagaLineageRegistry(eas, schemaRegistry, ISchemaResolver(address(resolver)), admin);

        // 3. Close the loop: from here the resolver only accepts attestations written by
        //    this registry, which is what makes the teacher-confirmation step
        //    unbypassable. One-time and irreversible.
        if (msg.sender == admin) {
            resolver.bindRegistry(address(lineage));
        }

        // 4. Licences reference the lineage registry for their validity check.
        license = new RagaLicenseRegistry(eas, schemaRegistry, lineage, admin);

        vm.stopBroadcast();

        console.log("LineageAttestationResolver:", address(resolver));
        console.log("RagaLineageRegistry:       ", address(lineage));
        console.log("RagaLicenseRegistry:       ", address(license));
        console.log("Admin / registrar:         ", admin);

        if (msg.sender != admin) {
            console.log("");
            console.log("ACTION REQUIRED: the admin must still call");
            console.log("  resolver.bindRegistry(<RagaLineageRegistry>)");
            console.log("Until then the registry cannot write lineage attestations.");
        }
    }
}
