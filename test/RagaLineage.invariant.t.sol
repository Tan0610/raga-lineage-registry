// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {EAS} from "eas-contracts/EAS.sol";
import {SchemaRegistry} from "eas-contracts/SchemaRegistry.sol";
import {IEAS} from "eas-contracts/IEAS.sol";
import {ISchemaRegistry} from "eas-contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "eas-contracts/resolver/ISchemaResolver.sol";

import {LineageAttestationResolver} from "../src/LineageAttestationResolver.sol";
import {RagaLineageRegistry, LineageStatus} from "../src/RagaLineageRegistry.sol";
import {RagaLicenseRegistry} from "../src/RagaLicenseRegistry.sol";

/// @notice Drives randomised sequences over the whole lifecycle: students propose lineage,
///         teachers confirm and revoke, performers register recordings and issue licences,
///         platforms pay royalties, and everyone withdraws.
///
/// @dev Every hop runs against a real EAS deployment, so the revocation and expiry
///      behaviour under test is EAS's own, not a mock's. The candidate set is small and
///      every actor holds both roles, so the fuzzer can build genuinely deep chains — and,
///      deliberately, cyclic ones, which is exactly what MAX_LINEAGE_DEPTH must survive.
contract LineageHandler is Test {
    RagaLineageRegistry public immutable lineage;
    RagaLicenseRegistry public immutable license;

    address[5] public people;
    bytes32[4] public recordings;

    uint256[] public pendingClaims;
    bytes32[] public confirmedEdges;

    // --- ghost accounting ---
    uint256 public totalRoyaltyPaid;
    uint256 public totalWithdrawn;

    uint256 public proposeCalls;
    uint256 public confirmCalls;
    uint256 public revokeCalls;
    uint256 public registerCalls;
    uint256 public licenseCalls;
    uint256 public payCalls;
    uint256 public withdrawCalls;

    constructor(RagaLineageRegistry lineage_, RagaLicenseRegistry license_, address[5] memory people_) {
        lineage = lineage_;
        license = license_;
        people = people_;
        for (uint256 i; i < 4; ++i) {
            recordings[i] = keccak256(abi.encodePacked("recording", i));
        }
    }

    function edgeCount() external view returns (uint256) {
        return confirmedEdges.length;
    }

    function personCount() external pure returns (uint256) {
        return 5;
    }

    function person(uint256 i) external view returns (address) {
        return people[i];
    }

    function _pick(uint256 seed) internal view returns (address) {
        return people[bound(seed, 0, 4)];
    }

    function proposeLineage(uint256 studentSeed, uint256 teacherSeed, uint256 shareSeed) public {
        address student = _pick(studentSeed);
        address teacher = _pick(teacherSeed);
        if (student == teacher) return;

        // One active guru edge per student, so skip if they already have a live one.
        bytes32 existing = lineage.primaryLineageEdge(student);
        if (existing != bytes32(0) && lineage.isEdgeLive(existing)) return;

        uint16 share = uint16(bound(shareSeed, 1, lineage.MAX_TEACHER_SHARE_BPS()));

        vm.prank(student);
        uint256 claimId = lineage.proposeLineage(teacher, "Carnatic", share, "note");
        pendingClaims.push(claimId);
        proposeCalls++;
    }

    function confirmLineage(uint256 seed) public {
        if (pendingClaims.length == 0) return;
        uint256 idx = bound(seed, 0, pendingClaims.length - 1);
        uint256 claimId = pendingClaims[idx];

        RagaLineageRegistry.LineageClaim memory c = lineage.getClaim(claimId);
        if (c.status != RagaLineageRegistry.ClaimStatus.Pending) return;

        bytes32 existing = lineage.primaryLineageEdge(c.student);
        if (existing != bytes32(0) && lineage.isEdgeLive(existing)) return;

        vm.prank(c.teacher);
        bytes32 uid = lineage.confirmLineage(claimId);
        confirmedEdges.push(uid);
        confirmCalls++;
    }

    function revokeLineage(uint256 seed) public {
        if (confirmedEdges.length == 0) return;
        bytes32 uid = confirmedEdges[bound(seed, 0, confirmedEdges.length - 1)];
        if (!lineage.isEdgeLive(uid)) return;

        (, address teacher,,,) = lineage.decodeLineage(uid);
        vm.prank(teacher);
        lineage.revokeLineage(uid);
        revokeCalls++;
    }

    function registerRecording(uint256 recSeed, uint256 whoSeed) public {
        bytes32 id = recordings[bound(recSeed, 0, 3)];
        if (license.getRecording(id).exists) return;

        vm.prank(_pick(whoSeed));
        license.registerRecording(id, "Kalyani", "varnam");
        registerCalls++;
    }

    function issueLicense(uint256 recSeed, uint256 licenseeSeed, uint256 durationSeed) public {
        bytes32 id = recordings[bound(recSeed, 0, 3)];
        RagaLicenseRegistry.Recording memory r = license.getRecording(id);
        if (!r.exists) return;

        address licensee = _pick(licenseeSeed);
        if (licensee == r.performer) return;
        if (license.checkLicense(id, licensee) == RagaLicenseRegistry.LicenseStatus.Valid) return;

        uint64 expiry = uint64(block.timestamp + bound(durationSeed, 1 days, 400 days));
        vm.prank(r.performer);
        license.issueLicense(id, licensee, expiry, "streaming");
        licenseCalls++;
    }

    function payRoyalty(uint256 recSeed, uint256 licenseeSeed, uint256 amountSeed) public {
        bytes32 id = recordings[bound(recSeed, 0, 3)];
        if (!license.getRecording(id).exists) return;

        address licensee = _pick(licenseeSeed);
        RagaLicenseRegistry.LicenseStatus s = license.checkLicense(id, licensee);
        // Valid pays normally; LineageRevoked pays the performer alone. Everything else
        // has no agreement to pay under and would (correctly) revert.
        if (
            s != RagaLicenseRegistry.LicenseStatus.Valid
                && s != RagaLicenseRegistry.LicenseStatus.LineageRevoked
        ) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, 20 ether);
        vm.deal(licensee, licensee.balance + amount);
        vm.prank(licensee);
        license.payRoyalty{value: amount}(id, licensee);

        totalRoyaltyPaid += amount;
        payCalls++;
    }

    function withdraw(uint256 seed) public {
        address who = _pick(seed);
        uint256 owed = license.withdrawable(who);
        if (owed == 0) return;

        vm.prank(who);
        license.withdraw();
        totalWithdrawn += owed;
        withdrawCalls++;
    }

    function passTime(uint256 seed) public {
        vm.warp(block.timestamp + bound(seed, 1 hours, 60 days));
    }

    receive() external payable {}
}

/// @notice System-wide properties over the lineage graph and the money that flows through
///         it, checked after every call in every randomised sequence.
contract RagaLineageInvariantTest is StdInvariant, Test {
    SchemaRegistry internal schemaRegistry;
    EAS internal eas;
    LineageAttestationResolver internal resolver;
    RagaLineageRegistry internal lineage;
    RagaLicenseRegistry internal license;
    LineageHandler internal handler;

    address internal admin = makeAddr("sabhaAdmin");

    function setUp() public {
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

        address[5] memory people;
        for (uint256 i; i < 5; ++i) {
            people[i] = address(uint160(0xA000 + i));
        }

        // Everyone is both a performer and a guru, exactly as in the tradition — which
        // also lets the fuzzer build deep and cyclic chains.
        vm.startPrank(admin);
        for (uint256 i; i < 5; ++i) {
            lineage.grantRole(lineage.PERFORMER_ROLE(), people[i]);
            lineage.grantRole(lineage.GURU_ROLE(), people[i]);
        }
        vm.stopPrank();

        handler = new LineageHandler(lineage, license, people);
        targetContract(address(handler));
    }

    /// @notice The licence registry's books balance exactly against the ETH it holds.
    function invariant_balanceEqualsWhatIsOwed() public view {
        assertEq(address(license).balance, license.totalOwed(), "balance drifted from totalOwed");
        assertTrue(license.isSolvent());
    }

    /// @notice Every rupee of royalty ever paid is either withdrawn or still owed.
    function invariant_everyRoyaltyWeiIsAccountedFor() public view {
        assertEq(
            handler.totalRoyaltyPaid(),
            handler.totalWithdrawn() + license.totalOwed(),
            "royalties paid do not equal royalties withdrawn plus royalties owed"
        );
    }

    /// @notice A royalty split always distributes exactly the payment — no wei created,
    ///         none lost — for every performer, at any graph shape the fuzzer reaches.
    function invariant_splitAlwaysConservesThePayment() public view {
        uint256 probe = 7_777_777_777_777_777; // deliberately awkward, to force rounding
        for (uint256 i; i < handler.personCount(); ++i) {
            (, uint256[] memory amounts) = lineage.splitRoyalty(handler.person(i), probe);
            uint256 sum;
            for (uint256 j; j < amounts.length; ++j) {
                sum += amounts[j];
            }
            assertEq(sum, probe, "royalty split did not conserve the payment");
        }
    }

    /// @notice The walk is always bounded, even if the fuzzer builds a cycle — A taught B,
    ///         B taught A — which the contract permits and must survive.
    function invariant_lineageWalkIsAlwaysBounded() public view {
        for (uint256 i; i < handler.personCount(); ++i) {
            (address[] memory teachers,,) = lineage.resolveLineage(handler.person(i));
            assertLe(teachers.length, lineage.MAX_LINEAGE_DEPTH(), "lineage walk exceeded its bound");
        }
    }

    /// @notice A revoked edge never appears in a resolved lineage. This is revocation
    ///         meaning something, asserted across every reachable sequence rather than
    ///         only the one a hand-written test constructs.
    function invariant_revokedEdgesNeverAppearInAResolvedLineage() public view {
        for (uint256 i; i < handler.personCount(); ++i) {
            (,, bytes32[] memory uids) = lineage.resolveLineage(handler.person(i));
            for (uint256 j; j < uids.length; ++j) {
                assertTrue(lineage.isEdgeLive(uids[j]), "a revoked edge was still being paid");
            }
        }
    }

    /// @notice A performer whose own guru edge has been revoked can never have a licence
    ///         report as Valid.
    function invariant_revokedLineageIsNeverReportedValid() public view {
        for (uint256 i; i < handler.personCount(); ++i) {
            address p = handler.person(i);
            if (lineage.lineageStatusOf(p) != LineageStatus.Revoked) continue;

            for (uint256 j; j < handler.personCount(); ++j) {
                bytes32 rec = keccak256(abi.encodePacked("recording", j % 4));
                if (license.getRecording(rec).performer != p) continue;
                assertTrue(
                    license.checkLicense(rec, handler.person(j)) != RagaLicenseRegistry.LicenseStatus.Valid,
                    "licence reported Valid over a revoked lineage"
                );
            }
        }
    }

    function invariant_callSummary() public view {
        console.log("propose  ", handler.proposeCalls());
        console.log("confirm  ", handler.confirmCalls());
        console.log("revoke   ", handler.revokeCalls());
        console.log("register ", handler.registerCalls());
        console.log("license  ", handler.licenseCalls());
        console.log("payRoyalty", handler.payCalls());
        console.log("withdraw ", handler.withdrawCalls());
    }
}
