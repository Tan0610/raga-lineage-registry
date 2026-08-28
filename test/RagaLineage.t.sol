// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {EAS} from "eas-contracts/EAS.sol";
import {SchemaRegistry} from "eas-contracts/SchemaRegistry.sol";
import {IEAS, AttestationRequest, AttestationRequestData} from "eas-contracts/IEAS.sol";
import {ISchemaRegistry} from "eas-contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "eas-contracts/resolver/ISchemaResolver.sol";
import {Attestation} from "eas-contracts/Common.sol";
import {SchemaRecord} from "eas-contracts/ISchemaRegistry.sol";

import {LineageAttestationResolver} from "../src/LineageAttestationResolver.sol";
import {RagaLineageRegistry, LineageStatus} from "../src/RagaLineageRegistry.sol";
import {RagaLicenseRegistry} from "../src/RagaLicenseRegistry.sol";

/// @notice The full story under test.
///
///         Devika sings Carnatic compositions she learned from Rajam, who learned them
///         from Ariyakudi. A streaming platform licenses one of her recordings. The
///         royalty has to reach all three, and the licence has to stop being valid the
///         moment the lineage under it stops being true.
///
///         Tests run against a real EAS deployment, not a mock: `SchemaRegistry` and
///         `EAS` from eas-contracts v1.4.0 are deployed in `setUp`, schemas are registered
///         through the registry, and every assertion about revocation or expiry is read
///         back out of EAS itself.
contract RagaLineageTest is Test {
    SchemaRegistry internal schemaRegistry;
    EAS internal eas;
    LineageAttestationResolver internal resolver;
    RagaLineageRegistry internal lineage;
    RagaLicenseRegistry internal license;

    address internal admin = makeAddr("sabhaAdmin");
    address internal devika = makeAddr("devika"); // the performer
    address internal rajam = makeAddr("rajam"); // her guru
    address internal ariyakudi = makeAddr("ariyakudi"); // her guru's guru
    address internal platform = makeAddr("streamingPlatform");
    address internal impostor = makeAddr("impostor");

    bytes32 internal constant RECORDING = keccak256("kalyani-varnam-2026");

    bytes32 internal performerRole;
    bytes32 internal guruRole;

    uint64 internal licenceExpiry;

    function setUp() public {
        // --- a genuine EAS stack ---
        schemaRegistry = new SchemaRegistry();
        eas = new EAS(ISchemaRegistry(address(schemaRegistry)));

        resolver = new LineageAttestationResolver(IEAS(address(eas)), admin);
        lineage = new RagaLineageRegistry(
            IEAS(address(eas)),
            ISchemaRegistry(address(schemaRegistry)),
            ISchemaResolver(address(resolver)),
            admin
        );

        vm.prank(admin);
        resolver.bindRegistry(address(lineage));

        license = new RagaLicenseRegistry(
            IEAS(address(eas)), ISchemaRegistry(address(schemaRegistry)), lineage, admin
        );

        performerRole = lineage.PERFORMER_ROLE();
        guruRole = lineage.GURU_ROLE();

        // The sabha admits performers and gurus. A guru is also someone's student, so
        // Rajam holds both roles.
        vm.startPrank(admin);
        lineage.grantRole(performerRole, devika);
        lineage.grantRole(performerRole, rajam);
        lineage.grantRole(guruRole, rajam);
        lineage.grantRole(guruRole, ariyakudi);
        vm.stopPrank();

        licenceExpiry = uint64(block.timestamp + 365 days);
        vm.deal(platform, 100 ether);
    }

    // -----------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------

    /// @dev Devika -> Rajam, confirmed. Rajam takes 20% of what reaches him.
    function _confirmDevikaUnderRajam() internal returns (bytes32 uid) {
        vm.prank(devika);
        uint256 claimId = lineage.proposeLineage(rajam, "Carnatic", 2_000, "Kalyani varnam, 2018-2024");
        vm.prank(rajam);
        uid = lineage.confirmLineage(claimId);
    }

    /// @dev Rajam -> Ariyakudi, confirmed. Ariyakudi takes 15% of what reaches him.
    function _confirmRajamUnderAriyakudi() internal returns (bytes32 uid) {
        vm.prank(rajam);
        uint256 claimId = lineage.proposeLineage(ariyakudi, "Carnatic", 1_500, "the older pathantara");
        vm.prank(ariyakudi);
        uid = lineage.confirmLineage(claimId);
    }

    function _registerAndLicense() internal returns (bytes32 licenceUid) {
        vm.prank(devika);
        license.registerRecording(RECORDING, "Kalyani", "Vanajakshi varnam");
        vm.prank(devika);
        licenceUid = license.issueLicense(RECORDING, platform, licenceExpiry, "streaming, worldwide");
    }

    // =================================================================
    // 1. A lineage claim requires the teacher's confirmation
    // =================================================================

    /// @notice Proposing is inert. Until Rajam acts, there is no attestation anywhere.
    function test_ProposingAloneCreatesNoAttestation() public {
        vm.prank(devika);
        uint256 claimId = lineage.proposeLineage(rajam, "Carnatic", 2_000, "note");

        RagaLineageRegistry.LineageClaim memory c = lineage.getClaim(claimId);
        assertEq(uint8(c.status), uint8(RagaLineageRegistry.ClaimStatus.Pending));
        assertEq(c.attestationUid, bytes32(0), "no attestation was minted by the student alone");

        assertEq(lineage.primaryLineageEdge(devika), bytes32(0));
        assertEq(uint8(lineage.lineageStatusOf(devika)), uint8(LineageStatus.NoClaim));
    }

    function test_TeacherConfirmationIsWhatCreatesTheAttestation() public {
        bytes32 uid = _confirmDevikaUnderRajam();

        assertTrue(uid != bytes32(0), "confirming minted the attestation");
        assertEq(lineage.primaryLineageEdge(devika), uid);
        assertEq(uint8(lineage.lineageStatusOf(devika)), uint8(LineageStatus.Active));

        Attestation memory a = eas.getAttestation(uid);
        assertEq(a.attester, address(lineage), "the registry is the attester");
        assertEq(a.recipient, devika);
    }

    function test_OnlyTheNamedTeacherCanConfirm() public {
        vm.prank(devika);
        uint256 claimId = lineage.proposeLineage(rajam, "Carnatic", 2_000, "note");

        // Ariyakudi holds GURU_ROLE but was not the teacher Devika named.
        vm.prank(ariyakudi);
        vm.expectRevert(
            abi.encodeWithSelector(RagaLineageRegistry.NotTheNamedTeacher.selector, ariyakudi, rajam)
        );
        lineage.confirmLineage(claimId);

        // Devika cannot confirm her own claim.
        vm.prank(devika);
        vm.expectRevert();
        lineage.confirmLineage(claimId);

        assertEq(lineage.primaryLineageEdge(devika), bytes32(0));
    }

    /// @notice The resolver closes the back door: even bypassing this registry entirely
    ///         and calling EAS directly, a student cannot mint a lineage claim about
    ///         themselves.
    function test_StudentCannotAttestLineageDirectlyToEas() public {
        bytes memory data = abi.encode(devika, rajam, "Carnatic", uint16(2_000), "forged");
        // Read before the expectRevert/prank: an external getter in the argument list
        // would otherwise be the call those cheatcodes latch onto.
        bytes32 schemaId = lineage.lineageSchemaId();

        vm.prank(devika);
        vm.expectRevert(); // resolver returns false -> EAS rejects
        eas.attest(
            AttestationRequest({
                schema: schemaId,
                data: AttestationRequestData({
                    recipient: devika,
                    expirationTime: 0,
                    revocable: true,
                    refUID: bytes32(0),
                    data: data,
                    value: 0
                })
            })
        );

        assertEq(uint8(lineage.lineageStatusOf(devika)), uint8(LineageStatus.NoClaim));
    }

    function test_TeacherCanRejectAClaim() public {
        vm.prank(devika);
        uint256 claimId = lineage.proposeLineage(rajam, "Carnatic", 2_000, "note");

        vm.prank(rajam);
        lineage.rejectLineage(claimId);

        RagaLineageRegistry.LineageClaim memory c = lineage.getClaim(claimId);
        assertEq(uint8(c.status), uint8(RagaLineageRegistry.ClaimStatus.Rejected));
        assertEq(uint8(lineage.lineageStatusOf(devika)), uint8(LineageStatus.NoClaim));
    }

    function test_StudentCanWithdrawTheirOwnPendingClaim() public {
        vm.prank(devika);
        uint256 claimId = lineage.proposeLineage(rajam, "Carnatic", 2_000, "note");

        vm.prank(devika);
        lineage.withdrawClaim(claimId);

        vm.prank(rajam);
        vm.expectRevert();
        lineage.confirmLineage(claimId);
    }

    function test_CannotNameATeacherWhoIsNotAGuru() public {
        vm.prank(devika);
        vm.expectRevert(abi.encodeWithSelector(RagaLineageRegistry.TeacherLacksGuruRole.selector, impostor));
        lineage.proposeLineage(impostor, "Carnatic", 2_000, "note");
    }

    // =================================================================
    // 2 & 5. Validity is read at time of use; revocation changes it
    // =================================================================

    function test_FreshLicenseIsValid() public {
        _confirmDevikaUnderRajam();
        _registerAndLicense();

        assertEq(
            uint8(license.checkLicense(RECORDING, platform)), uint8(RagaLicenseRegistry.LicenseStatus.Valid)
        );
        assertTrue(license.isLicenseValid(RECORDING, platform));
    }

    /// @notice The decisive test. Nothing about the licence changes — the guru withdraws
    ///         the lineage, and the same check returns a different answer.
    function test_GuruRevokingLineageInvalidatesAnAlreadyIssuedLicense() public {
        bytes32 edge = _confirmDevikaUnderRajam();
        _registerAndLicense();

        assertTrue(license.isLicenseValid(RECORDING, platform), "valid before");

        vm.prank(rajam);
        lineage.revokeLineage(edge);

        assertEq(
            uint8(license.checkLicense(RECORDING, platform)),
            uint8(RagaLicenseRegistry.LicenseStatus.LineageRevoked),
            "the same licence now reads invalid, because the lineage under it was withdrawn"
        );
        assertFalse(license.isLicenseValid(RECORDING, platform));
        assertEq(uint8(lineage.lineageStatusOf(devika)), uint8(LineageStatus.Revoked));
    }

    function test_ExpiryIsCheckedAgainstTheCurrentBlock() public {
        _confirmDevikaUnderRajam();
        _registerAndLicense();

        assertTrue(license.isLicenseValid(RECORDING, platform));

        vm.warp(uint256(licenceExpiry) + 1);

        assertEq(
            uint8(license.checkLicense(RECORDING, platform)), uint8(RagaLicenseRegistry.LicenseStatus.Expired)
        );
    }

    function test_RevokingTheLicenseItselfInvalidatesIt() public {
        _confirmDevikaUnderRajam();
        _registerAndLicense();

        vm.prank(devika);
        license.revokeLicense(RECORDING, platform);

        assertEq(
            uint8(license.checkLicense(RECORDING, platform)), uint8(RagaLicenseRegistry.LicenseStatus.Revoked)
        );
    }

    /// @notice Revocation is visible in EAS itself, not only in our bookkeeping.
    function test_RevocationIsRecordedOnTheEasAttestation() public {
        bytes32 edge = _confirmDevikaUnderRajam();
        assertEq(eas.getAttestation(edge).revocationTime, 0);

        vm.prank(rajam);
        lineage.revokeLineage(edge);

        assertTrue(eas.getAttestation(edge).revocationTime != 0, "EAS recorded the revocation time");
        assertFalse(lineage.isEdgeLive(edge));
    }

    function test_OnlyTheTeacherCanRevokeALineageEdge() public {
        bytes32 edge = _confirmDevikaUnderRajam();

        vm.prank(devika);
        vm.expectRevert(
            abi.encodeWithSelector(RagaLineageRegistry.NotTheNamedTeacher.selector, devika, rajam)
        );
        lineage.revokeLineage(edge);

        vm.prank(impostor);
        vm.expectRevert();
        lineage.revokeLineage(edge);

        assertTrue(lineage.isEdgeLive(edge));
    }

    // =================================================================
    // 3. A genuine EAS schema, not an ad hoc mapping
    // =================================================================

    function test_SchemasAreRegisteredWithTheEasSchemaRegistry() public view {
        SchemaRecord memory lineageSchema = schemaRegistry.getSchema(lineage.lineageSchemaId());
        assertEq(lineageSchema.uid, lineage.lineageSchemaId());
        assertEq(lineageSchema.schema, lineage.LINEAGE_SCHEMA());
        assertTrue(lineageSchema.revocable);
        assertEq(address(lineageSchema.resolver), address(resolver), "guarded by the resolver");

        SchemaRecord memory licenseSchema = schemaRegistry.getSchema(license.licenseSchemaId());
        assertEq(licenseSchema.schema, license.LICENSE_SCHEMA());
        assertTrue(licenseSchema.revocable);
    }

    /// @notice The lineage data really lives in an EAS attestation, and decodes back to
    ///         the schema's typed fields.
    function test_LineageDataRoundTripsThroughTheEasSchema() public {
        bytes32 uid = _confirmDevikaUnderRajam();

        Attestation memory a = eas.getAttestation(uid);
        assertEq(a.schema, lineage.lineageSchemaId(), "attested against the lineage schema");
        assertTrue(a.revocable);

        (address student, address teacher, string memory tradition, uint16 shareBps, string memory note) =
            lineage.decodeLineage(uid);

        assertEq(student, devika);
        assertEq(teacher, rajam);
        assertEq(tradition, "Carnatic");
        assertEq(shareBps, 2_000);
        assertEq(note, "Kalyani varnam, 2018-2024");
    }

    function test_LicenseIsAnEasAttestationWithARealExpiry() public {
        _confirmDevikaUnderRajam();
        bytes32 uid = _registerAndLicense();

        Attestation memory a = eas.getAttestation(uid);
        assertEq(a.schema, license.licenseSchemaId());
        assertEq(a.recipient, platform);
        assertEq(a.expirationTime, licenceExpiry, "the expiry lives on the attestation itself");
        assertEq(a.attester, address(license));
    }

    // =================================================================
    // 4. The royalty split resolves through the lineage graph
    // =================================================================

    function test_RoyaltySplitsAcrossThreeGenerations() public {
        _confirmDevikaUnderRajam(); // devika <- rajam, 20%
        _confirmRajamUnderAriyakudi(); // rajam  <- ariyakudi, 15%
        _registerAndLicense();

        vm.prank(platform);
        license.payRoyalty{value: 10 ether}(RECORDING, platform);

        // Cascading: rajam takes 20% of 10, ariyakudi 15% of the remaining 8,
        // devika keeps the rest.
        assertEq(license.withdrawable(rajam), 2 ether, "guru");
        assertEq(license.withdrawable(ariyakudi), 1.2 ether, "guru's guru");
        assertEq(license.withdrawable(devika), 6.8 ether, "performer");

        assertEq(
            license.withdrawable(devika) + license.withdrawable(rajam) + license.withdrawable(ariyakudi),
            10 ether,
            "the whole payment was distributed"
        );
    }

    /// @notice The recipients come from the graph, so changing the graph changes who is
    ///         paid — with no code change and no hardcoded address anywhere.
    function test_RevokedUpstreamEdgeDropsThatTeacherFromTheSplit() public {
        _confirmDevikaUnderRajam();
        bytes32 upper = _confirmRajamUnderAriyakudi();
        _registerAndLicense();

        // Ariyakudi withdraws his confirmation that he taught Rajam.
        vm.prank(ariyakudi);
        lineage.revokeLineage(upper);

        // Devika's own edge is untouched, so her licence is still good...
        assertTrue(license.isLicenseValid(RECORDING, platform));

        // ...but the chain now stops at Rajam.
        (, address[] memory teachers,,) = license.getRecordingLineage(RECORDING);
        assertEq(teachers.length, 1);
        assertEq(teachers[0], rajam);

        vm.prank(platform);
        license.payRoyalty{value: 10 ether}(RECORDING, platform);

        assertEq(license.withdrawable(rajam), 2 ether);
        assertEq(license.withdrawable(ariyakudi), 0, "no longer in the lineage");
        assertEq(license.withdrawable(devika), 8 ether, "his share returns to the performer");
    }

    function test_PerformerWithNoLineageKeepsTheWholeRoyalty() public {
        _registerAndLicense(); // no lineage confirmed at all

        vm.prank(platform);
        license.payRoyalty{value: 10 ether}(RECORDING, platform);

        assertEq(license.withdrawable(devika), 10 ether);
    }

    function test_RoyaltyCannotBePaidOnAnInvalidLicense() public {
        bytes32 edge = _confirmDevikaUnderRajam();
        _registerAndLicense();

        vm.prank(rajam);
        lineage.revokeLineage(edge);

        vm.prank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(
                RagaLicenseRegistry.LicenseNotValid.selector,
                RECORDING,
                platform,
                RagaLicenseRegistry.LicenseStatus.LineageRevoked
            )
        );
        license.payRoyalty{value: 1 ether}(RECORDING, platform);
    }

    function test_RecipientsPullTheirOwnRoyalties() public {
        _confirmDevikaUnderRajam();
        _confirmRajamUnderAriyakudi();
        _registerAndLicense();

        vm.prank(platform);
        license.payRoyalty{value: 10 ether}(RECORDING, platform);

        vm.prank(rajam);
        license.withdraw();
        assertEq(rajam.balance, 2 ether);

        vm.prank(rajam);
        vm.expectRevert();
        license.withdraw(); // no double withdrawal

        assertEq(rajam.balance, 2 ether);
        assertTrue(license.isSolvent());
    }

    function testFuzz_RoyaltySplitAlwaysConservesTheWholePayment(uint96 amount) public {
        amount = uint96(bound(amount, 1, 90 ether));

        _confirmDevikaUnderRajam();
        _confirmRajamUnderAriyakudi();
        _registerAndLicense();

        vm.deal(platform, amount);
        vm.prank(platform);
        license.payRoyalty{value: amount}(RECORDING, platform);

        assertEq(
            license.withdrawable(devika) + license.withdrawable(rajam) + license.withdrawable(ariyakudi),
            amount,
            "no wei created or lost, whatever the rounding"
        );
    }

    // =================================================================
    // 6. Attesting a lineage edge is role-gated
    // =================================================================

    function test_ProposingRequiresThePerformerRole() public {
        vm.prank(impostor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, impostor, performerRole
            )
        );
        lineage.proposeLineage(rajam, "Carnatic", 2_000, "note");
    }

    function test_ConfirmingRequiresTheGuruRole() public {
        vm.prank(devika);
        uint256 claimId = lineage.proposeLineage(rajam, "Carnatic", 2_000, "note");

        // Strip Rajam's guru role; his confirmation must stop working.
        vm.prank(admin);
        lineage.revokeRole(guruRole, rajam);

        vm.prank(rajam);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, rajam, guruRole)
        );
        lineage.confirmLineage(claimId);
    }

    function test_OnlyTheRegistrarCanAdmitPerformersAndGurus() public {
        vm.prank(impostor);
        vm.expectRevert();
        lineage.grantRole(performerRole, impostor);
    }

    // =================================================================
    // 7. Unlicensed, expired and revoked are distinct answers
    // =================================================================

    function test_EveryFailureReasonIsDistinguishable() public {
        _confirmDevikaUnderRajam();
        vm.prank(devika);
        license.registerRecording(RECORDING, "Kalyani", "Vanajakshi varnam");

        // Never licensed.
        assertEq(
            uint8(license.checkLicense(RECORDING, platform)),
            uint8(RagaLicenseRegistry.LicenseStatus.NeverLicensed),
            "a platform that never licensed anything"
        );

        vm.prank(devika);
        license.issueLicense(RECORDING, platform, licenceExpiry, "streaming");
        assertEq(
            uint8(license.checkLicense(RECORDING, platform)), uint8(RagaLicenseRegistry.LicenseStatus.Valid)
        );

        // Expired is not the same as never licensed.
        vm.warp(uint256(licenceExpiry) + 1);
        assertEq(
            uint8(license.checkLicense(RECORDING, platform)),
            uint8(RagaLicenseRegistry.LicenseStatus.Expired),
            "lapsed, not absent"
        );

        // And an unrelated address is still 'never licensed', at the same moment.
        assertEq(
            uint8(license.checkLicense(RECORDING, impostor)),
            uint8(RagaLicenseRegistry.LicenseStatus.NeverLicensed)
        );
    }

    function test_RevokedIsDistinctFromExpiredAndFromLineageRevoked() public {
        bytes32 edge = _confirmDevikaUnderRajam();
        _registerAndLicense();

        // Lineage withdrawn -> LineageRevoked, distinct from a revoked licence.
        vm.prank(rajam);
        lineage.revokeLineage(edge);
        assertEq(
            uint8(license.checkLicense(RECORDING, platform)),
            uint8(RagaLicenseRegistry.LicenseStatus.LineageRevoked)
        );

        // Now revoke the licence itself: the licence-level reason takes precedence.
        vm.prank(devika);
        license.revokeLicense(RECORDING, platform);
        assertEq(
            uint8(license.checkLicense(RECORDING, platform)), uint8(RagaLicenseRegistry.LicenseStatus.Revoked)
        );
    }

    // =================================================================
    // The full lifecycle the deliverable asks for: attest -> license ->
    // check -> revoke
    // =================================================================

    function test_FullLifecycle_AttestLicenseCheckRevoke() public {
        // --- attest ---
        bytes32 edge = _confirmDevikaUnderRajam();
        bytes32 upper = _confirmRajamUnderAriyakudi();
        assertEq(uint8(lineage.lineageStatusOf(devika)), uint8(LineageStatus.Active));

        // Anyone can look up the recording and see the verified lineage behind it.
        vm.prank(devika);
        license.registerRecording(RECORDING, "Kalyani", "Vanajakshi varnam");

        (address performer, address[] memory teachers, uint16[] memory shares, bytes32[] memory uids) =
            license.getRecordingLineage(RECORDING);
        assertEq(performer, devika);
        assertEq(teachers.length, 2);
        assertEq(teachers[0], rajam);
        assertEq(teachers[1], ariyakudi);
        assertEq(shares[0], 2_000);
        assertEq(shares[1], 1_500);
        assertEq(uids[0], edge);
        assertEq(uids[1], upper);

        // --- license ---
        vm.prank(devika);
        license.issueLicense(RECORDING, platform, licenceExpiry, "streaming, worldwide");

        // --- check ---
        assertTrue(license.isLicenseValid(RECORDING, platform));

        vm.prank(platform);
        license.payRoyalty{value: 10 ether}(RECORDING, platform);
        assertEq(license.withdrawable(devika), 6.8 ether);
        assertEq(license.withdrawable(rajam), 2 ether);
        assertEq(license.withdrawable(ariyakudi), 1.2 ether);

        // --- revoke ---
        vm.prank(rajam);
        lineage.revokeLineage(edge);

        // The same check, asked again, now answers differently.
        assertEq(
            uint8(license.checkLicense(RECORDING, platform)),
            uint8(RagaLicenseRegistry.LicenseStatus.LineageRevoked)
        );

        // Royalties already earned are still owed; only future licensing is affected.
        vm.prank(ariyakudi);
        license.withdraw();
        assertEq(ariyakudi.balance, 1.2 ether);
    }
}
