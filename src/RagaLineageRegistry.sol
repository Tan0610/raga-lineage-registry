// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    IEAS,
    AttestationRequest,
    AttestationRequestData,
    RevocationRequest,
    RevocationRequestData
} from "eas-contracts/IEAS.sol";
import {ISchemaRegistry} from "eas-contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "eas-contracts/resolver/ISchemaResolver.sol";
import {Attestation} from "eas-contracts/Common.sol";

/// @notice Where a performer stands with respect to a claimed teacher, read fresh from
///         EAS every time it is asked.
enum LineageStatus {
    NoClaim, // this performer has never had a lineage edge confirmed
    Active, // a confirmed edge exists and is neither revoked nor expired
    Revoked // an edge existed and the teacher has since revoked it
}

/// @title RagaLineageRegistry
/// @notice The registry that remembers who taught whom.
///
///         Devika sings Carnatic compositions she learned from her guru, who learned them
///         from his guru before that. Tradition says a share of any royalty belongs
///         upstream. Today that share evaporates: a platform pays the performer it can
///         find and the lineage's claim disappears the moment money changes hands.
///
///         This contract records the Guru-Shishya chain as real EAS attestations, and
///         does it in a way that a student cannot fake: the student proposes, the named
///         teacher confirms, and only then does an attestation exist.
///
/// @dev Three properties this design is built around:
///
///      1. A CLAIM NEVER STANDS ON THE STUDENT'S WORD ALONE.
///         `proposeLineage` writes a pending claim and nothing else — no attestation is
///         created. Only `confirmLineage`, callable solely by the teacher named in that
///         claim, causes `IEAS.attest` to run. On top of that, the lineage schema is
///         registered with `LineageAttestationResolver`, which rejects any attestation
///         whose attester is not this registry, so the two-step cannot be bypassed by
///         calling EAS directly.
///
///      2. THE GRAPH IS READ AT TIME OF USE, NOT SNAPSHOTTED.
///         `resolveLineage` and `lineageStatusOf` call `IEAS.getAttestation` on every
///         invocation and inspect `revocationTime` and `expirationTime` as they are at
///         that block. Nothing about the chain is cached in a way that could go stale.
///
///      3. REVOCATION IS NOT A DELETION.
///         When a teacher revokes, the edge is deliberately left in
///         `primaryLineageEdge`. The uid stays; what changes is the attestation state EAS
///         reports. That is what makes a revocation visible to every later read, rather
///         than making the relationship silently vanish.
contract RagaLineageRegistry is AccessControl {
    // ---------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------

    /// @notice Grants and revokes the performer and guru roles. The sabha or academy.
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    /// @notice May propose a lineage claim about themselves.
    bytes32 public constant PERFORMER_ROLE = keccak256("PERFORMER_ROLE");

    /// @notice May confirm that they taught someone, which is what mints the attestation.
    bytes32 public constant GURU_ROLE = keccak256("GURU_ROLE");

    // ---------------------------------------------------------------------
    // Schema
    // ---------------------------------------------------------------------

    /// @notice The EAS schema for one edge of the teaching graph. A real schema with
    ///         typed fields, registered with the EAS SchemaRegistry — not a bare mapping.
    string public constant LINEAGE_SCHEMA =
        "address student,address teacher,string tradition,uint16 teacherShareBps,string note";

    uint256 public constant TOTAL_BPS = 10_000;

    /// @notice How far up the chain a royalty resolution will walk. Also the guard that
    ///         makes a cyclic graph safe to traverse.
    uint256 public constant MAX_LINEAGE_DEPTH = 8;

    /// @notice Ceiling on any single teacher's cut, so a guru cannot take the whole fee.
    uint16 public constant MAX_TEACHER_SHARE_BPS = 5_000;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum ClaimStatus {
        None,
        Pending, // the student has proposed; the teacher has not answered
        Confirmed, // the teacher confirmed and an attestation was created
        Rejected, // the teacher denied teaching this student
        Withdrawn // the student pulled the claim before it was answered
    }

    struct LineageClaim {
        address student;
        address teacher;
        uint16 teacherShareBps;
        ClaimStatus status;
        bytes32 attestationUid; // zero until the teacher confirms
        string tradition;
        string note;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IEAS public immutable eas;

    /// @notice UID of the registered lineage schema.
    bytes32 public immutable lineageSchemaId;

    mapping(uint256 claimId => LineageClaim claim) private _claims;
    uint256 public nextClaimId = 1;

    /// @notice The student's confirmed guru edge. Deliberately NOT cleared on revocation:
    ///         the uid remains so that every later read can see, via EAS, that it was
    ///         revoked.
    mapping(address student => bytes32 attestationUid) public primaryLineageEdge;

    mapping(bytes32 attestationUid => uint256 claimId) public claimIdByUid;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event LineageProposed(
        uint256 indexed claimId, address indexed student, address indexed teacher, uint16 teacherShareBps
    );
    event LineageConfirmed(
        uint256 indexed claimId, bytes32 indexed attestationUid, address indexed teacher, address student
    );
    event LineageRejected(uint256 indexed claimId, address indexed teacher);
    event LineageWithdrawn(uint256 indexed claimId, address indexed student);
    event LineageRevoked(bytes32 indexed attestationUid, address indexed teacher, address indexed student);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error CannotTeachYourself();
    error TeacherLacksGuruRole(address teacher);
    error ShareTooHigh(uint16 provided, uint16 max);
    error ClaimNotFound(uint256 claimId);
    error ClaimNotPending(uint256 claimId, ClaimStatus status);
    error NotTheNamedTeacher(address caller, address teacher);
    error NotTheStudent(address caller, address student);
    error AlreadyHasActiveLineage(address student, bytes32 attestationUid);
    error AttestationNotFound(bytes32 attestationUid);
    error AlreadyRevoked(bytes32 attestationUid);

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /// @param eas_            The EAS instance (a predeploy on Base).
    /// @param schemaRegistry  The EAS schema registry.
    /// @param resolver        The lineage resolver, which must later be bound to this
    ///                        contract so it will accept our attestations.
    /// @param admin           Holds the default admin and registrar roles.
    constructor(IEAS eas_, ISchemaRegistry schemaRegistry, ISchemaResolver resolver, address admin) {
        if (address(eas_) == address(0) || admin == address(0)) revert ZeroAddress();

        eas = eas_;

        // Register the real EAS schema. This is what makes the lineage data an EAS
        // attestation rather than a private struct.
        lineageSchemaId = schemaRegistry.register(LINEAGE_SCHEMA, resolver, true);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, admin);
        _setRoleAdmin(PERFORMER_ROLE, REGISTRAR_ROLE);
        _setRoleAdmin(GURU_ROLE, REGISTRAR_ROLE);
    }

    // ---------------------------------------------------------------------
    // Step 1: the student proposes. This creates NO attestation.
    // ---------------------------------------------------------------------

    /// @notice Propose that you were trained by a specific teacher.
    /// @dev Deliberately inert: it records a pending claim and emits an event so the
    ///      teacher can see it. The teaching relationship does not exist on-chain, in any
    ///      form EAS would report, until the teacher confirms it.
    /// @param teacher          The guru being named.
    /// @param tradition        e.g. "Carnatic" or "Baul".
    /// @param teacherShareBps  The teacher's cut of downstream royalties, in basis points
    ///                         of what reaches this point in the chain. The teacher agrees
    ///                         to this figure by confirming the claim.
    /// @param note             Free text, e.g. which compositions were passed down.
    function proposeLineage(
        address teacher,
        string calldata tradition,
        uint16 teacherShareBps,
        string calldata note
    ) external onlyRole(PERFORMER_ROLE) returns (uint256 claimId) {
        if (teacher == address(0)) revert ZeroAddress();
        if (teacher == msg.sender) revert CannotTeachYourself();
        if (!hasRole(GURU_ROLE, teacher)) revert TeacherLacksGuruRole(teacher);
        if (teacherShareBps > MAX_TEACHER_SHARE_BPS) {
            revert ShareTooHigh(teacherShareBps, MAX_TEACHER_SHARE_BPS);
        }

        bytes32 existing = primaryLineageEdge[msg.sender];
        if (existing != bytes32(0) && _isAttestationLive(existing)) {
            revert AlreadyHasActiveLineage(msg.sender, existing);
        }

        claimId = nextClaimId++;
        _claims[claimId] = LineageClaim({
            student: msg.sender,
            teacher: teacher,
            teacherShareBps: teacherShareBps,
            status: ClaimStatus.Pending,
            attestationUid: bytes32(0),
            tradition: tradition,
            note: note
        });

        emit LineageProposed(claimId, msg.sender, teacher, teacherShareBps);
    }

    /// @notice A student can pull their own claim back before the teacher answers.
    function withdrawClaim(uint256 claimId) external {
        LineageClaim storage c = _requirePending(claimId);
        if (msg.sender != c.student) revert NotTheStudent(msg.sender, c.student);

        c.status = ClaimStatus.Withdrawn;
        emit LineageWithdrawn(claimId, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Step 2: the teacher confirms. THIS is what creates the attestation.
    // ---------------------------------------------------------------------

    /// @notice Confirm that you taught this student, creating the EAS attestation.
    /// @dev Two independent gates, both required: the caller must hold `GURU_ROLE`, and
    ///      the caller must be the exact address the student named. There is no path
    ///      anywhere in this contract that produces a lineage attestation without the
    ///      teacher sending this transaction themselves.
    function confirmLineage(uint256 claimId) external onlyRole(GURU_ROLE) returns (bytes32 attestationUid) {
        LineageClaim storage c = _requirePending(claimId);
        if (msg.sender != c.teacher) revert NotTheNamedTeacher(msg.sender, c.teacher);

        bytes32 existing = primaryLineageEdge[c.student];
        if (existing != bytes32(0) && _isAttestationLive(existing)) {
            revert AlreadyHasActiveLineage(c.student, existing);
        }

        bytes memory data = abi.encode(c.student, c.teacher, c.tradition, c.teacherShareBps, c.note);

        attestationUid = eas.attest(
            AttestationRequest({
                schema: lineageSchemaId,
                data: AttestationRequestData({
                    recipient: c.student,
                    expirationTime: 0, // a teaching relationship does not lapse on its own
                    revocable: true, // but the teacher can withdraw it
                    refUID: bytes32(0),
                    data: data,
                    value: 0
                })
            })
        );

        c.status = ClaimStatus.Confirmed;
        c.attestationUid = attestationUid;
        primaryLineageEdge[c.student] = attestationUid;
        claimIdByUid[attestationUid] = claimId;

        emit LineageConfirmed(claimId, attestationUid, msg.sender, c.student);
    }

    /// @notice Deny a claim. No attestation is created and none ever was.
    function rejectLineage(uint256 claimId) external {
        LineageClaim storage c = _requirePending(claimId);
        if (msg.sender != c.teacher) revert NotTheNamedTeacher(msg.sender, c.teacher);

        c.status = ClaimStatus.Rejected;
        emit LineageRejected(claimId, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Step 4: revocation, and it has to mean something
    // ---------------------------------------------------------------------

    /// @notice A teacher withdraws their confirmation of a lineage edge.
    /// @dev Revokes through EAS, so `revocationTime` is set on the attestation itself.
    ///      The uid stays in `primaryLineageEdge` on purpose: every later read of the
    ///      graph and every later license check goes back to EAS and sees the revocation,
    ///      rather than the edge quietly disappearing. This is what makes revocation
    ///      change the answer that `checkLicense` returns.
    function revokeLineage(bytes32 attestationUid) external {
        Attestation memory a = eas.getAttestation(attestationUid);
        if (a.uid == bytes32(0)) revert AttestationNotFound(attestationUid);
        if (a.revocationTime != 0) revert AlreadyRevoked(attestationUid);

        (address student, address teacher,,,) = _decode(a.data);
        if (msg.sender != teacher) revert NotTheNamedTeacher(msg.sender, teacher);

        eas.revoke(
            RevocationRequest({
                schema: lineageSchemaId, data: RevocationRequestData({uid: attestationUid, value: 0})
            })
        );

        emit LineageRevoked(attestationUid, teacher, student);
    }

    // ---------------------------------------------------------------------
    // Reading the graph, always at time of use
    // ---------------------------------------------------------------------

    /// @notice Walk the teaching chain upward from a performer.
    /// @dev Every hop reads the live attestation from EAS and stops at the first edge
    ///      that is missing, revoked, or expired *as of this block*. A revoked edge
    ///      therefore removes that teacher and everyone above them from the result the
    ///      moment it is revoked, with no bookkeeping anywhere else.
    ///
    ///      `MAX_LINEAGE_DEPTH` bounds the walk, which also makes a cyclic graph safe.
    /// @return teachers  Ordered from the immediate guru upward.
    /// @return sharesBps Each teacher's cut, decoded from their own attestation.
    /// @return uids      The attestation backing each hop, so a caller can verify it.
    function resolveLineage(address performer)
        public
        view
        returns (address[] memory teachers, uint16[] memory sharesBps, bytes32[] memory uids)
    {
        address[] memory tTeachers = new address[](MAX_LINEAGE_DEPTH);
        uint16[] memory tShares = new uint16[](MAX_LINEAGE_DEPTH);
        bytes32[] memory tUids = new bytes32[](MAX_LINEAGE_DEPTH);

        uint256 count;
        address current = performer;

        for (uint256 depth; depth < MAX_LINEAGE_DEPTH; ++depth) {
            bytes32 uid = primaryLineageEdge[current];
            if (uid == bytes32(0)) break;

            Attestation memory a = eas.getAttestation(uid);
            if (!_isLive(a)) break;

            (, address teacher,, uint16 shareBps,) = _decode(a.data);
            if (teacher == address(0)) break;

            tTeachers[count] = teacher;
            tShares[count] = shareBps;
            tUids[count] = uid;
            unchecked {
                ++count;
            }

            current = teacher;
        }

        teachers = new address[](count);
        sharesBps = new uint16[](count);
        uids = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            teachers[i] = tTeachers[i];
            sharesBps[i] = tShares[i];
            uids[i] = tUids[i];
        }
    }

    /// @notice Where this performer stands right now: never claimed, standing, or revoked.
    /// @dev Read fresh from EAS on every call.
    function lineageStatusOf(address performer) public view returns (LineageStatus) {
        bytes32 uid = primaryLineageEdge[performer];
        if (uid == bytes32(0)) return LineageStatus.NoClaim;

        Attestation memory a = eas.getAttestation(uid);
        if (a.uid == bytes32(0)) return LineageStatus.NoClaim;

        return _isLive(a) ? LineageStatus.Active : LineageStatus.Revoked;
    }

    /// @notice Split `amount` across the performer and their surviving lineage.
    /// @dev Cascading: each teacher takes their share of what is still unallocated as the
    ///      walk moves upward, so nearer teachers receive more, the total can never
    ///      exceed the payment however deep the chain runs, and the performer absorbs
    ///      whatever integer division leaves behind. Recipients come entirely from the
    ///      attestation graph — there is no fixed payee anywhere in this function.
    /// @return recipients Performer first, then each surviving teacher up the chain.
    /// @return amounts    Their cuts, summing to exactly `amount`.
    function splitRoyalty(address performer, uint256 amount)
        public
        view
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        (address[] memory teachers, uint16[] memory sharesBps,) = resolveLineage(performer);

        recipients = new address[](teachers.length + 1);
        amounts = new uint256[](teachers.length + 1);

        uint256 remaining = amount;
        for (uint256 i; i < teachers.length; ++i) {
            uint256 cut = (remaining * sharesBps[i]) / TOTAL_BPS;
            recipients[i + 1] = teachers[i];
            amounts[i + 1] = cut;
            remaining -= cut;
        }

        // The performer keeps what is left, which also absorbs any rounding dust.
        recipients[0] = performer;
        amounts[0] = remaining;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getClaim(uint256 claimId) external view returns (LineageClaim memory) {
        return _claims[claimId];
    }

    /// @notice The EAS attestation behind a confirmed edge, exactly as EAS holds it now.
    function getLineageAttestation(bytes32 attestationUid) external view returns (Attestation memory) {
        return eas.getAttestation(attestationUid);
    }

    /// @notice Decode a lineage attestation's data into its schema fields.
    function decodeLineage(bytes32 attestationUid)
        external
        view
        returns (
            address student,
            address teacher,
            string memory tradition,
            uint16 teacherShareBps,
            string memory note
        )
    {
        Attestation memory a = eas.getAttestation(attestationUid);
        if (a.uid == bytes32(0)) revert AttestationNotFound(attestationUid);
        return _decode(a.data);
    }

    /// @notice True only while the edge exists and EAS reports it neither revoked nor
    ///         expired at this moment.
    function isEdgeLive(bytes32 attestationUid) external view returns (bool) {
        return _isAttestationLive(attestationUid);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _requirePending(uint256 claimId) private view returns (LineageClaim storage c) {
        c = _claims[claimId];
        if (c.status == ClaimStatus.None) revert ClaimNotFound(claimId);
        if (c.status != ClaimStatus.Pending) revert ClaimNotPending(claimId, c.status);
    }

    function _isAttestationLive(bytes32 attestationUid) private view returns (bool) {
        return _isLive(eas.getAttestation(attestationUid));
    }

    /// @dev The time-of-use check. Both conditions are read from the attestation as EAS
    ///      reports it in the current block.
    function _isLive(Attestation memory a) private view returns (bool) {
        if (a.uid == bytes32(0)) return false;
        if (a.revocationTime != 0) return false;
        if (a.expirationTime != 0 && block.timestamp >= a.expirationTime) return false;
        return true;
    }

    function _decode(bytes memory data)
        private
        pure
        returns (
            address student,
            address teacher,
            string memory tradition,
            uint16 teacherShareBps,
            string memory note
        )
    {
        return abi.decode(data, (address, address, string, uint16, string));
    }
}
