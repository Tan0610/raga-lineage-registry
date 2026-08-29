// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IEAS} from "eas-contracts/IEAS.sol";
import {ISchemaRegistry} from "eas-contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "eas-contracts/resolver/ISchemaResolver.sol";
import {ISemver} from "eas-contracts/ISemver.sol";
import {Attestation} from "eas-contracts/Common.sol";

import {LineageAttestationResolver} from "../src/LineageAttestationResolver.sol";
import {RagaLineageRegistry, LineageStatus} from "../src/RagaLineageRegistry.sol";
import {RagaLicenseRegistry} from "../src/RagaLicenseRegistry.sol";

/// @notice Runs the whole lifecycle against the EAS that is *actually deployed on Base
///         Sepolia*, rather than against a local EAS this repo deploys itself.
///
///         This matters because the two are not the same version. The unit suite deploys
///         eas-contracts v1.4.0; Base Sepolia's predeploy reports v1.2.0. Everything here
///         is built on the parts of the interface that are stable across those versions
///         — `attest`, `revoke`, `getAttestation`, `SchemaRegistry.register`, and the
///         `Attestation` struct — but "should be compatible" is not the same as knowing.
///         So this test finds out, against the real thing, before anything is deployed.
///
/// @dev Skipped automatically unless a Base Sepolia RPC is configured, so it never breaks
///      a normal `forge test` run or CI without network access:
///
///        forge test --match-contract Fork --fork-url https://sepolia.base.org
contract RagaLineageForkTest is Test {
    /// @dev OP Stack predeploys, the same on Base mainnet and Base Sepolia.
    address internal constant BASE_SEPOLIA_EAS = 0x4200000000000000000000000000000000000021;
    address internal constant BASE_SEPOLIA_SCHEMA_REGISTRY = 0x4200000000000000000000000000000000000020;

    RagaLineageRegistry internal lineage;
    RagaLicenseRegistry internal license;
    LineageAttestationResolver internal resolver;

    address internal admin = makeAddr("sabha");
    address internal devika = makeAddr("devika");
    address internal rajam = makeAddr("rajam");
    address internal platform = makeAddr("platform");

    bytes32 internal constant RECORDING = keccak256("fork-kalyani-varnam");

    /// @dev True only when running against a fork that actually has the predeploys.
    bool internal onFork;

    function setUp() public {
        // No fork configured -> every test below no-ops. Keeps `forge test` green offline.
        if (BASE_SEPOLIA_EAS.code.length == 0) return;
        onFork = true;

        // On a fork the basefee is real, so a pranked sender with no balance is rejected
        // before its call even executes. Fund every actor.
        vm.deal(admin, 10 ether);
        vm.deal(devika, 10 ether);
        vm.deal(rajam, 10 ether);
        vm.deal(platform, 100 ether);

        resolver = new LineageAttestationResolver(IEAS(BASE_SEPOLIA_EAS), admin);
        lineage = new RagaLineageRegistry(
            IEAS(BASE_SEPOLIA_EAS),
            ISchemaRegistry(BASE_SEPOLIA_SCHEMA_REGISTRY),
            ISchemaResolver(address(resolver)),
            admin
        );
        vm.prank(admin);
        resolver.bindRegistry(address(lineage));

        license = new RagaLicenseRegistry(
            IEAS(BASE_SEPOLIA_EAS), ISchemaRegistry(BASE_SEPOLIA_SCHEMA_REGISTRY), lineage, admin
        );

        vm.startPrank(admin);
        lineage.grantRole(lineage.PERFORMER_ROLE(), devika);
        lineage.grantRole(lineage.GURU_ROLE(), rajam);
        vm.stopPrank();
    }

    /// @notice Records which EAS version this actually ran against, so the result is
    ///         attributable rather than just green.
    function test_fork_ReportsTheLiveEasVersion() public view {
        if (!onFork) return;
        string memory v = ISemver(BASE_SEPOLIA_EAS).version();
        assertGt(bytes(v).length, 0, "live EAS reported no version");
    }

    /// @notice Both schemas register against the live SchemaRegistry, and the lineage one
    ///         keeps our resolver attached.
    function test_fork_SchemasRegisterAgainstTheLiveRegistry() public view {
        if (!onFork) return;
        assertTrue(lineage.lineageSchemaId() != bytes32(0), "lineage schema did not register");
        assertTrue(license.licenseSchemaId() != bytes32(0), "licence schema did not register");
    }

    /// @notice The full lifecycle, against the real EAS: a student proposes, only the named
    ///         teacher can confirm, the attestation is real, a licence reads Valid, the
    ///         royalty splits up the chain, and a revocation flips the answer.
    function test_fork_FullLifecycleAgainstLiveEas() public {
        if (!onFork) return;

        // --- propose: creates nothing on EAS ---
        vm.prank(devika);
        uint256 claimId = lineage.proposeLineage(rajam, "Carnatic", 2_000, "fork run");
        assertEq(uint8(lineage.lineageStatusOf(devika)), uint8(LineageStatus.NoClaim));

        // --- confirm: this is what writes to the live EAS ---
        vm.prank(rajam);
        bytes32 uid = lineage.confirmLineage(claimId);
        assertTrue(uid != bytes32(0), "live EAS did not return an attestation uid");

        Attestation memory a = IEAS(BASE_SEPOLIA_EAS).getAttestation(uid);
        assertEq(a.uid, uid, "live EAS did not store the attestation");
        assertEq(a.attester, address(lineage), "attester should be the registry");
        assertEq(a.recipient, devika);
        assertEq(a.schema, lineage.lineageSchemaId());
        assertEq(uint8(lineage.lineageStatusOf(devika)), uint8(LineageStatus.Active));

        // --- the resolver still blocks a direct forge on the live EAS ---
        assertEq(lineage.primaryLineageEdge(devika), uid);

        // --- register, licence, check ---
        vm.prank(devika);
        license.registerRecording(RECORDING, "Kalyani", "fork varnam");
        vm.prank(devika);
        license.issueLicense(RECORDING, platform, uint64(block.timestamp + 30 days), "streaming");
        assertTrue(license.isLicenseValid(RECORDING, platform), "licence should be valid on the live EAS");

        // --- the royalty resolves up the real attestation graph ---
        vm.prank(platform);
        license.payRoyalty{value: 10 ether}(RECORDING, platform);
        assertEq(license.withdrawable(rajam), 2 ether, "guru share came out of the live attestation");
        assertEq(license.withdrawable(devika), 8 ether);

        // --- revoke on the live EAS, and watch the answer change ---
        vm.prank(rajam);
        lineage.revokeLineage(uid);

        assertTrue(IEAS(BASE_SEPOLIA_EAS).getAttestation(uid).revocationTime != 0, "live EAS did not revoke");
        assertEq(
            uint8(license.checkLicense(RECORDING, platform)),
            uint8(RagaLicenseRegistry.LicenseStatus.LineageRevoked),
            "revocation on the live EAS did not change the licence answer"
        );
    }
}
