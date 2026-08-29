# Raga Lineage & License Registry

> Road to Devcon II — *Art, Culture & Ethereum in India*
> Problem 2: **Who Taught You That Raga?**

Devika sings Carnatic compositions passed down from her guru, who learned them from his
guru before that. A streaming platform wants to license one of her recordings, but the
royalty owed is not just hers — tradition says a share belongs upstream, to the teachers
who shaped the piece long before Devika ever recorded it. Right now that share goes
nowhere: platforms pay the performer they can find, and the lineage's claim evaporates the
moment money changes hands.

This is the registry that remembers who taught whom, records it as real
[EAS](https://attest.org) attestations, and makes sure a license granted today actually
checks that record — as it stands today — before calling itself valid.

---

## The four hard parts, and how each is handled

### 1. A student cannot claim a guru on their own word

The relationship is created in **two steps, by two different addresses**:

```
devika:  proposeLineage(rajam, "Carnatic", 2000, "Kalyani varnam")  -> claim #1, Pending
                                          (no attestation exists yet)

rajam:   confirmLineage(1)  -> IEAS.attest(...)  -> attestation uid 0x…
```

`proposeLineage` writes a pending claim and emits an event. That is all it does. No
attestation exists, `lineageStatusOf(devika)` still returns `NoClaim`, and nothing
downstream will pay Rajam a paisa. Only `confirmLineage` — callable solely by the address
the student named — causes `IEAS.attest` to run.

And the back door is closed too. The lineage schema is registered with
`LineageAttestationResolver`, whose `onAttest` returns false unless the attester is the
registry. So even calling `EAS.attest()` directly, bypassing this contract entirely, a
student cannot forge a "trained by Rajam" record. That is
`test_StudentCannotAttestLineageDirectlyToEas`.

The teacher can also `rejectLineage`, and the student can `withdrawClaim` before it is
answered.

### 2. Validity is read at the time of use, never snapshotted

`checkLicense(recordingId, licensee)` decides nothing at issuance. On every single call it:

1. re-reads the licence attestation from EAS via `getAttestation(uid)`,
2. checks `revocationTime` and `expirationTime` **against the current block**,
3. re-walks the lineage graph, reading each edge's live attestation.

A revocation that happened one second ago changes the answer immediately. Nothing is
cached anywhere that could go stale.

### 3. Royalties resolve through the graph, not to a fixed address

`splitRoyalty` walks upward from the performer, reading each teacher and their share
**out of the attestation data itself**. There is no hardcoded or constructor-set payee
anywhere in the payout path.

The split cascades — each teacher takes their share of what is still unallocated as the
walk moves upward:

```
payment = 10 ETH,  devika <- rajam (2000 bps) <- ariyakudi (1500 bps)

  rajam      = 10   × 2000/10000 = 2.0 ETH     remaining 8.0
  ariyakudi  = 8.0  × 1500/10000 = 1.2 ETH     remaining 6.8
  devika     = remaining          = 6.8 ETH
                                    ─────────
                                    10.0 ETH exactly
```

Cascading rather than absolute shares means nearer teachers naturally receive more, the
total can never exceed the payment however deep the chain runs, and the performer absorbs
the rounding dust — so no wei is created or lost at any depth. That property is fuzzed over
256 runs in `testFuzz_RoyaltySplitAlwaysConservesTheWholePayment`.

The walk is bounded by `MAX_LINEAGE_DEPTH = 8`, which also makes a cyclic graph safe to
traverse.

### 4. Revocation actually means something

When a guru revokes, the edge is **deliberately not deleted** from `primaryLineageEdge`.
The uid stays; what changes is the state EAS reports for it. That is the whole point — a
deleted edge would make the relationship silently vanish, whereas a revoked one is visible
to every later read.

Two distinct consequences, both tested:

| Who revokes | Effect |
|---|---|
| Rajam revokes `devika ← rajam` | `checkLicense` returns `LineageRevoked`. The licence Devika already issued stops being valid, without anyone touching the licence. |
| Ariyakudi revokes `rajam ← ariyakudi` | Devika's own edge is intact, so her licence stays valid — but the royalty split drops Ariyakudi, and his share returns to Devika. |

---

## Why `LicenseStatus` is an enum, not a bool

```solidity
enum LicenseStatus {
    NeverLicensed,   // no licence was ever issued for this pair
    Revoked,         // a licence existed and was revoked
    Expired,         // a licence existed and its expiry has passed
    LineageRevoked,  // the licence stands, but a guru withdrew the lineage under it
    Valid
}
```

A platform that only gets `false` back cannot tell a pirate from a lapsed subscriber, and
cannot tell either from a licensee whose paperwork is fine but whose lineage claim just
collapsed. Those are three different conversations and three different remedies.
`isLicenseValid()` is available as a boolean wrapper when the caller genuinely only needs
yes or no.

---

## Contracts

| Contract | Role |
|---|---|
| `RagaLineageRegistry` | The teaching graph. Propose / confirm / reject / revoke lineage edges as EAS attestations; resolve the chain and the royalty split. |
| `RagaLicenseRegistry` | Recordings and commercial licences as EAS attestations; `checkLicense`; royalty payment and pull-withdrawal. |
| `LineageAttestationResolver` | EAS schema resolver that rejects any lineage attestation not written by the registry. |

### Schemas

Both are registered with the real EAS `SchemaRegistry`, revocable:

```
lineage:  address student, address teacher, string tradition,
          uint16 teacherShareBps, string note

licence:  bytes32 recordingId, address licensee, address performer,
          string usageScope, uint16 lineageRoyaltyBps
```

### Roles

| Role | Held by | Can |
|---|---|---|
| `REGISTRAR_ROLE` | the sabha / academy | admit performers and gurus |
| `PERFORMER_ROLE` | Devika, Rajam | propose a lineage claim, register recordings |
| `GURU_ROLE` | Rajam, Ariyakudi | confirm and revoke a lineage claim naming them |
| `CATALOGUE_ROLE` | catalogue operator | register recordings on a performer's behalf |

A guru is also somebody's student, so Rajam holds both `PERFORMER_ROLE` and `GURU_ROLE`.

---

## Tests

```
forge test -vv
```

30 tests, run against a **real EAS deployment** — `SchemaRegistry` and `EAS` from
eas-contracts v1.4.0 are deployed in `setUp`, not mocked, so every claim about revocation
and expiry is verified against EAS's own behaviour.

| Guarantee | Tests |
|---|---|
| Teacher confirmation is required | `test_ProposingAloneCreatesNoAttestation`, `test_TeacherConfirmationIsWhatCreatesTheAttestation`, `test_OnlyTheNamedTeacherCanConfirm`, `test_StudentCannotAttestLineageDirectlyToEas`, `test_TeacherCanRejectAClaim` |
| Validity read at time of use | `test_GuruRevokingLineageInvalidatesAnAlreadyIssuedLicense`, `test_ExpiryIsCheckedAgainstTheCurrentBlock`, `test_RevokingTheLicenseItselfInvalidatesIt` |
| Genuine EAS schema | `test_SchemasAreRegisteredWithTheEasSchemaRegistry`, `test_LineageDataRoundTripsThroughTheEasSchema`, `test_LicenseIsAnEasAttestationWithARealExpiry` |
| Royalty resolves through the graph | `test_RoyaltySplitsAcrossThreeGenerations`, `test_RevokedUpstreamEdgeDropsThatTeacherFromTheSplit`, `test_PerformerWithNoLineageKeepsTheWholeRoyalty`, `testFuzz_RoyaltySplitAlwaysConservesTheWholePayment` |
| Revocation changes state | `test_RevocationIsRecordedOnTheEasAttestation`, `test_OnlyTheTeacherCanRevokeALineageEdge`, `test_RevokedLineageStillPaysThePerformerButNotTheWithdrawnGuru` |
| Payment refused without a live licence | `test_RoyaltyCannotBePaidWithoutALiveLicense`, `test_RoyaltyCannotBePaidOnAnExpiredLicense` |
| Role-gated attestation | `test_ProposingRequiresThePerformerRole`, `test_ConfirmingRequiresTheGuruRole`, `test_OnlyTheRegistrarCanAdmitPerformersAndGurus` |
| Distinct failure states | `test_EveryFailureReasonIsDistinguishable`, `test_RevokedIsDistinctFromExpiredAndFromLineageRevoked` |
| Full lifecycle | `test_FullLifecycle_AttestLicenseCheckRevoke` — attest → license → check → revoke, end to end |

---

## Design notes and trade-offs

**One primary guru per performer.** The Guru-Shishya tradition centres on a single primary
teacher, so `primaryLineageEdge` holds one confirmed edge per student and the graph walk is
a chain. A student may propose a new edge once their existing one is revoked.

**A revoked lineage invalidates the licence, but does not freeze the performer's income.**
`checkLicense` returns `LineageRevoked` — that is the behaviour the problem asks for, and a
platform relying on the check sees the truth immediately.

`payRoyalty` treats that state differently from the others, though. A licence that was
never issued, was revoked, or has lapsed reverts: there is no agreement to pay under. But a
withdrawn *lineage* still permits payment, because the performer did record and perform the
work. Blocking it would hand any teacher a unilateral freeze on their former student's
income — a worse version of the middleman problem this registry exists to remove.

The split resolves itself correctly with no special case: `resolveLineage` already stops at
the revoked edge, so the performer is paid in full and the guru who withdrew receives
nothing. A `RoyaltyPaidUnderRevokedLineage` event records that it happened, so the
situation is auditable rather than silent.

**Arbiter of last resort.** There is deliberately no admin override that can resurrect a
revoked lineage. A guru's withdrawal is final unless the student obtains a new confirmation.

---

## Build and deploy

Requires [Foundry](https://getfoundry.sh).

```bash
git clone --recursive <this repo>   # submodules: forge-std, OpenZeppelin, eas-contracts
cd raga-lineage-registry
forge build
forge test
```

Deploying to Base Sepolia:

```bash
cp .env.example .env                 # then edit; .env is gitignored
cast wallet import devcon --interactive      # encrypted keystore, no raw key on disk
forge script script/Deploy.s.sol:Deploy \
  --rpc-url base_sepolia --account devcon --broadcast --verify
```

The script deploys the resolver, then the lineage registry (which registers the lineage
schema against that resolver), then calls `resolver.bindRegistry()` to close the loop, then
deploys the licence registry. If `REGISTRY_ADMIN` is set to an address other than the
broadcaster, that address must call `bindRegistry` itself — the script says so on exit.

EAS addresses default to the Base Sepolia predeploys
(`0x42...21` for EAS, `0x42...20` for the SchemaRegistry) and are overridable via
`EAS_ADDRESS` / `EAS_SCHEMA_REGISTRY`. Verify them against the
[EAS contract registry](https://docs.attest.org/docs/quick--start/contracts) before
deploying to any other chain.

No private key, API key, or authenticated URL is stored in this repository. `.env` is
gitignored; `.env.example` contains placeholders only, and the deploy script takes its
signer from the forge invocation rather than from a file.

---

## Stack

Solidity 0.8.28 · Foundry · Ethereum Attestation Service v1.4.0 · OpenZeppelin v5.1.0
(`AccessControl`, `ReentrancyGuard`) · Base Sepolia.

## License

MIT
