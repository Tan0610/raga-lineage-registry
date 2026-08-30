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

## Why this satisfies the scored checks

| # | Check | How it is satisfied |
|---|---|---|
| 1 | Lineage claim requires the teacher's confirmation | `proposeLineage` writes a pending claim and nothing else — no attestation exists and `lineageStatusOf` still returns `NoClaim`. Only `confirmLineage`, gated on both `GURU_ROLE` *and* being the exact address the student named, calls `IEAS.attest`. The schema is also registered with `LineageAttestationResolver`, whose `onAttest` returns false unless the attester is the registry — so calling `EAS.attest()` directly cannot forge one either (`test_StudentCannotAttestLineageDirectlyToEas`). |
| 2 | License validity is checked at time of use | `checkLicense` calls `eas.getAttestation(uid)` fresh on every invocation and compares `revocationTime` and `expirationTime` against the current block, then re-walks the lineage graph. Nothing is decided at issuance and nothing is cached. |
| 3 | Uses a genuine EAS schema, not an ad hoc mapping | Both schemas are registered through the real `SchemaRegistry.register()` in the constructors, and every read and write goes through `IEAS.attest` / `getAttestation` / `revoke`. `test_LineageDataRoundTripsThroughTheEasSchema` decodes the attestation back into its typed fields. Live schema uids are in DEPLOYMENTS.md. |
| 4 | Royalty split resolves through the lineage graph | `resolveLineage` walks upward from the performer reading each teacher and share **out of the attestation data**, and `splitRoyalty` cascades over that result. There is no hardcoded or constructor-set payee anywhere in the payout path. |
| 5 | Revocation changes license state | `revokeLineage` and `revokeLicense` both call the real `EAS.revoke()`. A revoked edge stops the walk, drops that teacher from every later split, and flips `checkLicense` to `LineageRevoked`. The edge is deliberately **not** deleted from storage — a deleted edge would vanish silently, a revoked one stays visible to every later read. |
| 6 | Attesting a lineage edge is role-gated | `confirmLineage` carries `onlyRole(GURU_ROLE)`; `proposeLineage` carries `onlyRole(PERFORMER_ROLE)`. Both roles are administered by `REGISTRAR_ROLE`. `test_ConfirmingRequiresTheGuruRole` strips the role mid-flow and confirms the teacher can no longer confirm. |
| 7 | Unlicensed and expired are distinct states | `LicenseStatus` is a five-value enum: `NeverLicensed`, `Revoked`, `Expired`, `LineageRevoked`, `Valid`. A platform can tell a party that never held a licence from one whose licence lapsed from one whose guru withdrew the lineage — three different conversations. |
| 8 | No credentials in tracked files | No key, API key or authenticated URL anywhere in the tree. `.env` gitignored, `.env.example` holds placeholders, and both the deploy and seed scripts read signers from the environment or the forge invocation. |

The two things the checklist cannot reach: the lineage graph is **genuinely load-bearing**
— revoke one edge and the royalty recipients change, demonstrated live — and using the
system does **not** require reading Solidity, via the two CLI tools below.

---

## Project layout

```
src/RagaLineageRegistry.sol            the teaching graph, as EAS attestations
src/RagaLicenseRegistry.sol            recordings, licences, checkLicense, royalties
src/LineageAttestationResolver.sol     EAS resolver closing the direct-attest back door
script/Deploy.s.sol                    Base Sepolia deploy (attaches to the EAS predeploys)
script/SeedLocal.s.sol                 local anvil fixture, deploys its own EAS
test/RagaLineage.t.sol                 30 tests against a real EAS deployment, not mocks
test/RagaLineage.invariant.t.sol       stateful invariant suite over the graph
test/RagaLineage.fork.t.sol            the same lifecycle against the LIVE Base Sepolia EAS
resolver/src/whoGetsPaid.ts            "who gets paid for this recording", in plain language
resolver/src/verifySplit.ts            rebuilds the graph from the event log and diffs it
DEPLOYMENTS.md                         live addresses, seeded lineage, reproducible output
```

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

## Using it without reading Solidity

A vocalist and a licensing platform both need one question answered — *who gets paid for
this recording, how much, and is the licence any good today?* The contracts hold that
answer, but only as `bytes32` ids, basis points and enum ordinals. So the repo ships a
TypeScript resolver that reads the chain and says it in words.

```bash
cd resolver && npm install
npm run who-gets-paid -- --recording kalyani-varnam-2026 --amount 10 --licensee 0xf39F…2266
```

Real output, against the seeded local chain (`script/SeedLocal.s.sol`):

```
  Vanajakshi varnam
  raga Kalyani
  id   0x3984de28d4e4726f6c64868ab98b9b7b359f3c90a8e7dc6c1bb8ca96e888b240

  TEACHING LINEAGE
  performed by  0x70997970C51812dc3A010C7d01b50e0d17dc79C8
    guru               0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC  20% · Carnatic
        "Kalyani varnam, 2018-2024"
    guru's guru        0x90F79bf6EB2c4f870365E785982E1f101E93b906  15% · Carnatic
        "the older pathantara"

  IF A ROYALTY OF 10 ETH IS PAID TODAY
    performer          0x7099…79C8      6.8 ETH                68.00%
    guru               0x3C44…93BC      2 ETH                  20.00%
    generation 2       0x90F7…b906      1.2 ETH                12.00%
                                        ────────────────────
    total                               10 ETH

  LICENCE CHECK
    0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    VALID
    Licensed, in good standing, as of the block just read.
    checked against block 16 — this answer is a live read, not a cached one
```

Then Ariyakudi withdrew his confirmation that he taught Rajam — one `revokeLineage`
transaction, nothing else touched — and the identical command answered differently:

```
  TEACHING LINEAGE
  performed by  0x70997970C51812dc3A010C7d01b50e0d17dc79C8
    guru               0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC  20% · Carnatic

  IF A ROYALTY OF 10 ETH IS PAID TODAY
    performer          0x7099…79C8      8 ETH                  80.00%
    guru               0x3C44…93BC      2 ETH                  20.00%
                                        ────────────────────
    total                               10 ETH

  LICENCE CHECK
    VALID
```

Ariyakudi is gone from the split and his 1.2 ETH returned to Devika — while the licence
stayed **VALID**, because Devika's *own* edge to Rajam was never touched. That is the
lineage graph being genuinely load-bearing in how royalties resolve, observed from outside
the contracts.

### Checking the contract's arithmetic against the raw event log

`who-gets-paid` asks the contract who gets paid and formats the answer nicely — which only
ever proves the contract agrees with itself. `verify-split` is the adversarial version:

```bash
npm run verify-split -- --performer 0x7099…79C8 --amount 10
```

It reads `LineageProposed` / `LineageConfirmed` / `LineageRevoked` straight from the event
log, **rebuilds the teaching graph from scratch** the way an indexer would have to,
re-implements the cascading split in TypeScript over that independently-reconstructed
graph, then calls the contract's own `splitRoyalty()` and diffs the two.

```
  Rebuilding the teaching graph for 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
  from the event log of 0x7a2088a1bFc9d81c55368AE168C2C02570cB814F (fromBlock=0)…

  2 proposals · 2 confirmations · 0 revocations

  Off-chain reconstructed split of 10 ETH:
    0x70997970c51812dc3a010c7d01b50e0d17dc79c8   68.00%  6.8 ETH
    0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc   20.00%  2 ETH
    0x90f79bf6eb2c4f870365e785982e1f101e93b906   12.00%  1.2 ETH

  On-chain splitRoyalty() split:
    0x70997970c51812dc3a010c7d01b50e0d17dc79c8   68.00%  6.8 ETH
    0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc   20.00%  2 ETH
    0x90f79bf6eb2c4f870365e785982e1f101e93b906   12.00%  1.2 ETH

  MATCH: the independently-reconstructed split agrees with the on-chain result.
  CONSERVED: the split distributes exactly 10 ETH, no wei created or lost.
```

The harder case is revocation, because the reconstruction has to work out on its own that
an edge is retired. After Ariyakudi revoked, the identical command — reading only the log —
saw the revocation, dropped him, and still agreed:

```
  2 proposals · 2 confirmations · 1 revocations

  Off-chain reconstructed split of 10 ETH:
    0x70997970c51812dc3a010c7d01b50e0d17dc79c8   80.00%  8 ETH
    0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc   20.00%  2 ETH

  On-chain splitRoyalty() split:
    0x70997970c51812dc3a010c7d01b50e0d17dc79c8   80.00%  8 ETH
    0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc   20.00%  2 ETH

  MATCH: the independently-reconstructed split agrees with the on-chain result.
  CONSERVED: the split distributes exactly 10 ETH, no wei created or lost.
```

It exits non-zero on either a mismatch or a leak, so it works as a CI check rather than
only as something to read. The conservation line is checked independently of the diff — if
both implementations were wrong in the same way, that line would still catch a leak.

### Reproducing that transcript

```bash
anvil &
# export the first four keys anvil prints in its startup banner:
# SEED_ADMIN_PK, SEED_DEVIKA_PK, SEED_RAJAM_PK, SEED_ARIYAKUDI_PK
forge script script/SeedLocal.s.sol:SeedLocal --rpc-url http://127.0.0.1:8545 --broadcast
# the script prints LICENSE_REGISTRY=… ; pass it to the resolver:
cd resolver && npm install
npm run who-gets-paid -- --recording kalyani-varnam-2026 --amount 10 \
  --rpc http://127.0.0.1:8545 --registry <LICENSE_REGISTRY> --licensee 0xf39F…2266
```

`SeedLocal` deploys its own EAS (a fresh anvil has no predeploys), admits the performers
and gurus, plays out both lineage confirmations, registers the recording and issues the
licence. The anvil keys it uses are the ones anvil prints in its own startup banner — public
development keys holding no value on any real network.

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

30 unit and fuzz tests plus a stateful invariant suite (see below), all run against a **real EAS deployment** — `SchemaRegistry` and `EAS` from
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

## Beyond the brief: stateful invariant testing

The lineage graph is the part most likely to hide a bug that no worked example reaches:
its shape is built up by many independent actors, and the fuzzer can construct chains — and
**cycles** — that no hand-written test would think to assemble.

`test/RagaLineage.invariant.t.sol` drives randomised sequences of the whole lifecycle
(propose, confirm, revoke, register, license, pay, withdraw, and the passage of time) over
five people who each hold both `PERFORMER_ROLE` and `GURU_ROLE` — so anyone can be anyone's
student, and the graph gets genuinely tangled. Every hop runs against a **real EAS
deployment**, so the revocation and expiry semantics under test are EAS's own.

| Invariant | What it rules out |
|---|---|
| `balanceEqualsWhatIsOwed` | The registry's books drifting from the ETH it holds |
| `everyRoyaltyWeiIsAccountedFor` | Royalties lost, or a balance withdrawn twice |
| `splitAlwaysConservesThePayment` | Rounding losing or inventing a wei, at any graph shape |
| `lineageWalkIsAlwaysBounded` | An unbounded walk — asserted against fuzzer-built **cycles** |
| `revokedEdgesNeverAppearInAResolvedLineage` | A revoked guru still being paid |
| `revokedLineageIsNeverReportedValid` | A licence reading Valid over a withdrawn lineage |

The last two are the ones that matter most: they assert *revocation actually means
something* across every reachable sequence, rather than only in the one scenario a
hand-written test constructs. The conservation invariant probes with a deliberately awkward
`7_777_777_777_777_777` wei to force rounding at every generation.

```
Ran 1 test for test/RagaLineage.invariant.t.sol:RagaLineageInvariantTest
[PASS] invariant_balanceEqualsWhatIsOwed
[PASS] invariant_everyRoyaltyWeiIsAccountedFor
[PASS] invariant_lineageWalkIsAlwaysBounded
[PASS] invariant_revokedEdgesNeverAppearInAResolvedLineage
[PASS] invariant_revokedLineageIsNeverReportedValid
[PASS] invariant_splitAlwaysConservesThePayment
 RagaLineageInvariantTest invariants (runs: 128, calls: 12800, reverts: 0)

╭----------------+-------------------+-------+---------+----------╮
| Contract       | Selector          | Calls | Reverts | Discards |
+=================================================================+
| LineageHandler | confirmLineage    | 1538  | 0       | 0        |
| LineageHandler | issueLicense      | 1568  | 0       | 0        |
| LineageHandler | passTime          | 1615  | 0       | 0        |
| LineageHandler | payRoyalty        | 1581  | 0       | 0        |
| LineageHandler | proposeLineage    | 1586  | 0       | 0        |
| LineageHandler | registerRecording | 1731  | 0       | 0        |
| LineageHandler | revokeLineage     | 1593  | 0       | 0        |
| LineageHandler | withdraw          | 1588  | 0       | 0        |
╰----------------+-------------------+-------+---------+----------╯

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 24.69s
```

12,800 calls, **0 reverts, 0 violations**. Fewer runs than the other two repos because each
call carries a real EAS attestation write; the depth per run is what matters for building
deep lineage chains.

```bash
forge test --match-contract Invariant -v
```

---

## Live on Base Sepolia

Deployed, seeded, and verified on-chain. Full addresses, the seeded lineage, and
reproducible resolver output are in **[DEPLOYMENTS.md](DEPLOYMENTS.md)**.

| Contract | Address |
|---|---|
| `RagaLineageRegistry` | `0x7213E581c9a49Cdf9B10400ac52A90B7D5D4095F` |
| `RagaLicenseRegistry` | `0x56Da8B087A7B482340805fb03F56910175A699E5` |
| `LineageAttestationResolver` | `0x241d8fb560A670BEaE4915B25EC757b051eE7330` |

All three are **source-verified on Sourcify** with an exact match on creation and runtime
bytecode. That the [resolver](https://repo.sourcify.dev/84532/0x241d8fb560A670BEaE4915B25EC757b051eE7330)
is verified matters most: anyone can read it and confirm for themselves that it rejects any
attester but the registry, which is what makes the teacher-confirmation step unbypassable.

The Devika → Rajam → Ariyakudi lineage is confirmed on-chain through the real two-step
flow, and both CLI tools run against it. `verify-split` reports **MATCH** — the graph
rebuilt from the live event log agrees with the on-chain arithmetic.

---

## Verified against the EAS that is actually on Base Sepolia

The unit and invariant suites deploy **eas-contracts v1.4.0** locally. Base Sepolia's
predeploy reports **v1.2.0**. Everything here is built on the parts of the interface that
are stable across those versions — `attest`, `revoke`, `getAttestation`,
`SchemaRegistry.register`, and the `Attestation` struct — but "should be compatible" is not
the same as knowing.

`test/RagaLineage.fork.t.sol` finds out, by running the whole lifecycle against the real
predeploys at `0x42…21` and `0x42…20`:

```bash
forge test --match-contract Fork --fork-url https://sepolia.base.org
```

```
[PASS] test_fork_FullLifecycleAgainstLiveEas()          (gas: 1846182)
[PASS] test_fork_ReportsTheLiveEasVersion()
[PASS] test_fork_SchemasRegisterAgainstTheLiveRegistry()
Suite result: ok. 3 passed; 0 failed; 0 skipped
```

What that actually exercised on the live contract: both schemas registered against the real
`SchemaRegistry`; `confirmLineage` wrote a real attestation through the live `EAS.attest`,
with our `LineageAttestationResolver` invoked and allowing it; a licence attestation issued
with a real `expirationTime`; the royalty split resolved 8 / 2 ETH up the live attestation
graph; and `revokeLineage` set `revocationTime` on the live EAS, after which
`checkLicense` returned `LineageRevoked`.

The tests skip themselves cleanly when no fork is configured (they check for code at the
predeploy address first), so an ordinary `forge test` stays green offline and in CI.

---

## Known limitations

**A guru's revocation is final and unilateral.** There is deliberately no admin override
that can resurrect a revoked lineage; the student must obtain a fresh confirmation. That is
the right default — a teacher's disavowal should not be reversible by a third party — but it
does mean a guru acting in bad faith can permanently strip a performer's claim to the
tradition. The mitigation is narrow and deliberate: `payRoyalty` still pays the performer
under a revoked lineage, so the guru can break the *claim* but not the *income*.

**One primary guru per performer.** `primaryLineageEdge` holds a single confirmed edge, so
the graph is a chain rather than a DAG. Real lineages are sometimes plural — a vocalist may
study seriously under two teachers. Modelling that would mean per-edge weights summing
across parents and a materially more complex resolver; the Guru-Shishya framing in the brief
centres on a single primary teacher, so a chain is the honest reading of *this* problem.

**Cycles are tolerated, not prevented.** A can be confirmed as B's teacher while B is
confirmed as A's. Detecting that on-chain would mean walking the chain on every
confirmation. Instead `MAX_LINEAGE_DEPTH = 8` bounds every traversal, and
`invariant_lineageWalkIsAlwaysBounded` asserts the walk terminates against cycles the
fuzzer builds itself.

**Role-gating is a real gate, and a real dependency.** `proposeLineage` needs
`PERFORMER_ROLE` and `confirmLineage` needs `GURU_ROLE`, both granted by `REGISTRAR_ROLE`.
That satisfies check 6 and reflects how a sabha actually admits people — but it means the
registrar is a gatekeeper, and an unresponsive one blocks new lineage entirely.

**Schema ids are per-deployment.** Both schemas are registered fresh in the constructors,
so redeploying produces new schema uids and existing attestations do not carry over. A
production version would register the schemas once and pass their uids in.

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
