// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {EAS} from "eas-contracts/EAS.sol";
import {SchemaRegistry} from "eas-contracts/SchemaRegistry.sol";
import {IEAS} from "eas-contracts/IEAS.sol";
import {ISchemaRegistry} from "eas-contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "eas-contracts/resolver/ISchemaResolver.sol";

import {LineageAttestationResolver} from "../src/LineageAttestationResolver.sol";
import {RagaLineageRegistry} from "../src/RagaLineageRegistry.sol";
import {RagaLicenseRegistry} from "../src/RagaLicenseRegistry.sol";

/// @notice Stands up the whole system on a local anvil node and plays out the story:
///         Devika, her guru Rajam, his guru Ariyakudi, one recording, one licence.
///
///         This exists so the TypeScript resolver can be run against something real
///         rather than only typechecked. It deploys its own EAS, because a fresh anvil
///         has no predeploys.
///
/// @dev The four signing keys are read from the environment and deliberately NOT written
///      down here. Anvil prints ten funded development accounts and their keys in its own
///      startup banner; export the first four before running. No key material lives in
///      this repository.
///
///      Run:
///        anvil &
///        export SEED_ADMIN_PK=0x…      # anvil account (0)
///        export SEED_DEVIKA_PK=0x…     # anvil account (1)
///        export SEED_RAJAM_PK=0x…      # anvil account (2)
///        export SEED_ARIYAKUDI_PK=0x…  # anvil account (3)
///        forge script script/SeedLocal.s.sol:SeedLocal --rpc-url http://127.0.0.1:8545 --broadcast
///
///      This is a local-development fixture. Never point it at a live chain.
contract SeedLocal is Script {
    bytes32 internal constant RECORDING = keccak256("kalyani-varnam-2026");

    function run() external {
        uint256 ADMIN_PK = vm.envUint("SEED_ADMIN_PK");
        uint256 DEVIKA_PK = vm.envUint("SEED_DEVIKA_PK");
        uint256 RAJAM_PK = vm.envUint("SEED_RAJAM_PK");
        uint256 ARIYAKUDI_PK = vm.envUint("SEED_ARIYAKUDI_PK");

        address admin = vm.addr(ADMIN_PK);
        address devika = vm.addr(DEVIKA_PK);
        address rajam = vm.addr(RAJAM_PK);
        address ariyakudi = vm.addr(ARIYAKUDI_PK);

        // --- deploy ---------------------------------------------------------
        vm.startBroadcast(ADMIN_PK);
        SchemaRegistry schemaRegistry = new SchemaRegistry();
        EAS eas = new EAS(ISchemaRegistry(address(schemaRegistry)));

        LineageAttestationResolver resolver = new LineageAttestationResolver(IEAS(address(eas)), admin);
        RagaLineageRegistry lineage = new RagaLineageRegistry(
            IEAS(address(eas)),
            ISchemaRegistry(address(schemaRegistry)),
            ISchemaResolver(address(resolver)),
            admin
        );
        resolver.bindRegistry(address(lineage));
        RagaLicenseRegistry license = new RagaLicenseRegistry(
            IEAS(address(eas)), ISchemaRegistry(address(schemaRegistry)), lineage, admin
        );

        // The sabha admits the performers and the gurus.
        lineage.grantRole(lineage.PERFORMER_ROLE(), devika);
        lineage.grantRole(lineage.PERFORMER_ROLE(), rajam);
        lineage.grantRole(lineage.GURU_ROLE(), rajam);
        lineage.grantRole(lineage.GURU_ROLE(), ariyakudi);
        vm.stopBroadcast();

        // --- lineage: Devika <- Rajam ---------------------------------------
        vm.broadcast(DEVIKA_PK);
        uint256 claim1 = lineage.proposeLineage(rajam, "Carnatic", 2_000, "Kalyani varnam, 2018-2024");
        vm.broadcast(RAJAM_PK);
        lineage.confirmLineage(claim1);

        // --- lineage: Rajam <- Ariyakudi ------------------------------------
        vm.broadcast(RAJAM_PK);
        uint256 claim2 = lineage.proposeLineage(ariyakudi, "Carnatic", 1_500, "the older pathantara");
        vm.broadcast(ARIYAKUDI_PK);
        lineage.confirmLineage(claim2);

        // --- the recording and a licence ------------------------------------
        vm.broadcast(DEVIKA_PK);
        license.registerRecording(RECORDING, "Kalyani", "Vanajakshi varnam");

        vm.broadcast(DEVIKA_PK);
        license.issueLicense(RECORDING, admin, uint64(block.timestamp + 365 days), "streaming, worldwide");

        console.log("");
        console.log("LICENSE_REGISTRY=%s", address(license));
        console.log("LINEAGE_REGISTRY=%s", address(lineage));
        console.log("recording slug: kalyani-varnam-2026");
        console.log("licensee (admin): %s", admin);
        console.log("");
        console.log("Now run, from resolver/:");
        console.log("  npm run who-gets-paid -- --recording kalyani-varnam-2026 --amount 10 \\");
        console.log("    --rpc http://127.0.0.1:8545 --registry %s \\", address(license));
        console.log("    --licensee %s", admin);
    }
}
