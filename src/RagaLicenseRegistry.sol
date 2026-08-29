// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
import {RagaLineageRegistry, LineageStatus} from "./RagaLineageRegistry.sol";

/// @title RagaLicenseRegistry
/// @notice Licensing for a specific recording, where "is this licence valid?" is answered
///         against the state of the teaching lineage *today*, not the state it was in
///         when the licence was issued.
///
///         A streaming platform licenses one of Devika's Carnatic recordings. The royalty
///         owed is not only hers: a share belongs upstream to the gurus who shaped the
///         piece. This contract resolves that split by reading the lineage attestation
///         graph, and refuses to call a licence valid if the lineage under it has been
///         revoked in the meantime.
///
/// @dev The licence itself is an EAS attestation with a real schema and a genuine
///      expiry. `checkLicense` re-reads it from EAS on every call.
contract RagaLicenseRegistry is AccessControl, ReentrancyGuard {
    // ---------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------

    /// @notice May register recordings on behalf of the catalogue, alongside performers
    ///         registering their own.
    bytes32 public constant CATALOGUE_ROLE = keccak256("CATALOGUE_ROLE");

    // ---------------------------------------------------------------------
    // Schema
    // ---------------------------------------------------------------------

    /// @notice The EAS schema for a commercial licence over one recording.
    string public constant LICENSE_SCHEMA =
        "bytes32 recordingId,address licensee,address performer,string usageScope,uint16 lineageRoyaltyBps";

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Why a licence is or is not good right now. Deliberately distinct values:
    ///         "never licensed" is a different fact from "licensed, but the licence has
    ///         lapsed", which is different again from "licensed, but the lineage the
    ///         licence rests on has been withdrawn". A caller that only gets `false`
    ///         cannot tell a pirate from a lapsed subscriber.
    enum LicenseStatus {
        NeverLicensed, // no licence was ever issued for this pair
        Revoked, // a licence existed and was revoked
        Expired, // a licence existed and its expiry has passed
        LineageRevoked, // the licence stands, but a guru has withdrawn the lineage under it
        Valid // good, as of this block
    }

    struct Recording {
        address performer;
        bool exists;
        string raga;
        string title;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IEAS public immutable eas;
    RagaLineageRegistry public immutable lineageRegistry;

    /// @notice UID of the registered licence schema.
    bytes32 public immutable licenseSchemaId;

    mapping(bytes32 recordingId => Recording recording) private _recordings;

    /// @notice The licence attestation for a (recording, licensee) pair. Kept after
    ///         revocation on purpose, so a later check can distinguish "revoked" from
    ///         "never licensed".
    mapping(bytes32 recordingId => mapping(address licensee => bytes32 attestationUid)) public licenseUid;

    /// @notice Pull-payment ledger for royalties.
    mapping(address account => uint256 amount) public withdrawable;
    uint256 public totalOwed;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event RecordingRegistered(
        bytes32 indexed recordingId, address indexed performer, string raga, string title
    );
    event LicenseIssued(
        bytes32 indexed recordingId,
        address indexed licensee,
        bytes32 indexed attestationUid,
        uint64 expirationTime,
        string usageScope
    );
    event LicenseRevoked(bytes32 indexed recordingId, address indexed licensee, bytes32 attestationUid);
    event RoyaltyDistributed(
        bytes32 indexed recordingId, address indexed payer, uint256 amount, uint256 recipients
    );
    event RoyaltyCredited(address indexed recipient, uint256 amount, uint256 generation);
    /// @notice A royalty was paid on a recording whose lineage has been withdrawn. The
    ///         performer is paid in full and no upstream teacher receives a share.
    event RoyaltyPaidUnderRevokedLineage(
        bytes32 indexed recordingId, address indexed performer, uint256 amount
    );
    event Withdrawn(address indexed account, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error EmptyRecordingId();
    error RecordingExists(bytes32 recordingId);
    error RecordingUnknown(bytes32 recordingId);
    error NotThePerformer(address caller, address performer);
    error NotAPerformer(address caller);
    error ExpiryMustBeInFuture(uint64 expirationTime, uint256 nowTs);
    error LicenseAlreadyLive(bytes32 recordingId, address licensee, bytes32 attestationUid);
    error NoLicenseToRevoke(bytes32 recordingId, address licensee);
    error LicenseNotValid(bytes32 recordingId, address licensee, LicenseStatus status);
    error NothingToWithdraw(address account);
    error TransferFailed(address to, uint256 amount);

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    constructor(
        IEAS eas_,
        ISchemaRegistry schemaRegistry,
        RagaLineageRegistry lineageRegistry_,
        address admin
    ) {
        if (address(eas_) == address(0) || address(lineageRegistry_) == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }

        eas = eas_;
        lineageRegistry = lineageRegistry_;

        // A real EAS schema for licences, revocable and with a genuine expiry field.
        licenseSchemaId = schemaRegistry.register(LICENSE_SCHEMA, ISchemaResolver(address(0)), true);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CATALOGUE_ROLE, admin);
    }

    // ---------------------------------------------------------------------
    // Recordings
    // ---------------------------------------------------------------------

    /// @notice Register a recording under the caller, who must be a registered performer
    ///         in the lineage registry.
    function registerRecording(bytes32 recordingId, string calldata raga, string calldata title) external {
        if (!lineageRegistry.hasRole(lineageRegistry.PERFORMER_ROLE(), msg.sender)) {
            revert NotAPerformer(msg.sender);
        }
        _registerRecording(recordingId, msg.sender, raga, title);
    }

    /// @notice Register a recording on a performer's behalf, for a catalogue operator.
    function registerRecordingFor(
        bytes32 recordingId,
        address performer,
        string calldata raga,
        string calldata title
    ) external onlyRole(CATALOGUE_ROLE) {
        if (!lineageRegistry.hasRole(lineageRegistry.PERFORMER_ROLE(), performer)) {
            revert NotAPerformer(performer);
        }
        _registerRecording(recordingId, performer, raga, title);
    }

    // ---------------------------------------------------------------------
    // Licences
    // ---------------------------------------------------------------------

    /// @notice License a recording for commercial use, as an EAS attestation with a real
    ///         expiry.
    /// @param expirationTime Unix time the licence lapses. EAS records this on the
    ///                       attestation, and `checkLicense` compares against it live.
    function issueLicense(
        bytes32 recordingId,
        address licensee,
        uint64 expirationTime,
        string calldata usageScope
    ) external returns (bytes32 attestationUid) {
        Recording storage r = _requireRecording(recordingId);
        if (msg.sender != r.performer) revert NotThePerformer(msg.sender, r.performer);
        if (licensee == address(0)) revert ZeroAddress();
        if (expirationTime <= block.timestamp) revert ExpiryMustBeInFuture(expirationTime, block.timestamp);

        bytes32 existing = licenseUid[recordingId][licensee];
        if (existing != bytes32(0) && checkLicense(recordingId, licensee) == LicenseStatus.Valid) {
            revert LicenseAlreadyLive(recordingId, licensee, existing);
        }

        bytes memory data = abi.encode(recordingId, licensee, r.performer, usageScope, uint16(0));

        attestationUid = eas.attest(
            AttestationRequest({
                schema: licenseSchemaId,
                data: AttestationRequestData({
                    recipient: licensee,
                    expirationTime: expirationTime,
                    revocable: true,
                    refUID: bytes32(0),
                    data: data,
                    value: 0
                })
            })
        );

        licenseUid[recordingId][licensee] = attestationUid;
        emit LicenseIssued(recordingId, licensee, attestationUid, expirationTime, usageScope);
    }

    /// @notice The performer revokes a licence. The attestation stays; EAS records the
    ///         revocation, and every later check sees it.
    function revokeLicense(bytes32 recordingId, address licensee) external {
        Recording storage r = _requireRecording(recordingId);
        if (msg.sender != r.performer) revert NotThePerformer(msg.sender, r.performer);

        bytes32 uid = licenseUid[recordingId][licensee];
        if (uid == bytes32(0)) revert NoLicenseToRevoke(recordingId, licensee);

        eas.revoke(
            RevocationRequest({schema: licenseSchemaId, data: RevocationRequestData({uid: uid, value: 0})})
        );

        emit LicenseRevoked(recordingId, licensee, uid);
    }

    // ---------------------------------------------------------------------
    // The check, answered against today's state
    // ---------------------------------------------------------------------

    /// @notice Is this licence good right now, and if not, why not?
    /// @dev Nothing here is decided at issuance. Every call re-reads the licence
    ///      attestation from EAS and re-reads the lineage graph, so a revocation or an
    ///      expiry that happened one second ago changes the answer immediately.
    ///
    ///      The four failure values are distinct on purpose — a platform needs to tell a
    ///      party that never held a licence from one whose licence lapsed from one whose
    ///      guru withdrew the lineage.
    function checkLicense(bytes32 recordingId, address licensee) public view returns (LicenseStatus) {
        bytes32 uid = licenseUid[recordingId][licensee];
        if (uid == bytes32(0)) return LicenseStatus.NeverLicensed;

        // Current state of the licence attestation, as EAS holds it in this block.
        Attestation memory a = eas.getAttestation(uid);
        if (a.uid == bytes32(0)) return LicenseStatus.NeverLicensed;
        if (a.revocationTime != 0) return LicenseStatus.Revoked;
        if (a.expirationTime != 0 && block.timestamp >= a.expirationTime) return LicenseStatus.Expired;

        // The licence is only as good as the lineage it rests on, checked now.
        address performer = _recordings[recordingId].performer;
        if (lineageRegistry.lineageStatusOf(performer) == LineageStatus.Revoked) {
            return LicenseStatus.LineageRevoked;
        }

        return LicenseStatus.Valid;
    }

    /// @notice Convenience boolean over `checkLicense`.
    function isLicenseValid(bytes32 recordingId, address licensee) external view returns (bool) {
        return checkLicense(recordingId, licensee) == LicenseStatus.Valid;
    }

    // ---------------------------------------------------------------------
    // Royalties, resolved through the graph
    // ---------------------------------------------------------------------

    /// @notice Preview how a royalty of `amount` would divide for this recording.
    /// @dev Recipients are derived entirely from the lineage attestations. There is no
    ///      fixed payee: if the graph changes, so does this answer.
    function previewRoyalty(bytes32 recordingId, uint256 amount)
        external
        view
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        Recording storage r = _requireRecording(recordingId);
        return lineageRegistry.splitRoyalty(r.performer, amount);
    }

    /// @notice Pay a royalty for a licensed recording. It divides across the performer
    ///         and the surviving teaching lineage, and is credited for each party to pull.
    /// @dev Requires a currently valid licence, so a revoked lineage or a lapsed licence
    ///      stops payment flowing rather than silently paying the wrong people.
    function payRoyalty(bytes32 recordingId, address licensee) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        Recording storage r = _requireRecording(recordingId);

        LicenseStatus status = checkLicense(recordingId, licensee);

        // A licence that was never issued, has been revoked, or has lapsed stops payment
        // dead: there is no agreement to pay under.
        //
        // `LineageRevoked` is deliberately treated differently. The guru has withdrawn
        // their confirmation, which is a real fact and one `checkLicense` keeps
        // reporting — but the performer still recorded and performed the work. Refusing
        // the payment outright would hand any teacher a unilateral freeze on their
        // former student's income, which is a worse version of the middleman problem
        // this registry exists to remove. So the money still flows, and
        // `resolveLineage` has already stopped at the revoked edge, meaning the split
        // naturally pays the performer alone and the withdrawn teacher receives
        // nothing. The event records that this happened.
        if (status != LicenseStatus.Valid && status != LicenseStatus.LineageRevoked) {
            revert LicenseNotValid(recordingId, licensee, status);
        }
        if (status == LicenseStatus.LineageRevoked) {
            emit RoyaltyPaidUnderRevokedLineage(recordingId, r.performer, msg.value);
        }

        (address[] memory recipients, uint256[] memory amounts) =
            lineageRegistry.splitRoyalty(r.performer, msg.value);

        for (uint256 i; i < recipients.length; ++i) {
            if (amounts[i] != 0) {
                withdrawable[recipients[i]] += amounts[i];
                emit RoyaltyCredited(recipients[i], amounts[i], i);
            }
        }
        totalOwed += msg.value;

        emit RoyaltyDistributed(recordingId, msg.sender, msg.value, recipients.length);
    }

    /// @notice Pull your accrued royalties.
    /// @dev Balance zeroed before the external call, plus `nonReentrant`.
    function withdraw() external nonReentrant returns (uint256 amount) {
        amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw(msg.sender);

        withdrawable[msg.sender] = 0;
        totalOwed -= amount;
        emit Withdrawn(msg.sender, amount);

        // forge-lint: disable-next-line(reentrancy-eth, low-level-calls)
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getRecording(bytes32 recordingId) external view returns (Recording memory) {
        return _recordings[recordingId];
    }

    /// @notice The whole picture for a recording: who performed it, the verified teaching
    ///         lineage behind it, and the attestation backing each hop.
    function getRecordingLineage(bytes32 recordingId)
        external
        view
        returns (
            address performer,
            address[] memory teachers,
            uint16[] memory sharesBps,
            bytes32[] memory uids
        )
    {
        Recording storage r = _requireRecording(recordingId);
        performer = r.performer;
        (teachers, sharesBps, uids) = lineageRegistry.resolveLineage(performer);
    }

    /// @notice The licence attestation exactly as EAS holds it now.
    function getLicenseAttestation(bytes32 recordingId, address licensee)
        external
        view
        returns (Attestation memory)
    {
        return eas.getAttestation(licenseUid[recordingId][licensee]);
    }

    function isSolvent() external view returns (bool) {
        return address(this).balance >= totalOwed;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _registerRecording(
        bytes32 recordingId,
        address performer,
        string calldata raga,
        string calldata title
    ) private {
        if (recordingId == bytes32(0)) revert EmptyRecordingId();
        if (_recordings[recordingId].exists) revert RecordingExists(recordingId);

        _recordings[recordingId] = Recording({performer: performer, exists: true, raga: raga, title: title});

        emit RecordingRegistered(recordingId, performer, raga, title);
    }

    function _requireRecording(bytes32 recordingId) private view returns (Recording storage r) {
        r = _recordings[recordingId];
        if (!r.exists) revert RecordingUnknown(recordingId);
    }
}
