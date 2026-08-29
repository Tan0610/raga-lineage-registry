/**
 * The slices of the on-chain interface this script needs. Kept hand-written and
 * minimal so the script is readable on its own, rather than importing a 2000-line
 * generated artifact.
 */

export const licenseRegistryAbi = [
  {
    type: "function",
    name: "getRecording",
    stateMutability: "view",
    inputs: [{name: "recordingId", type: "bytes32"}],
    outputs: [
      {
        type: "tuple",
        components: [
          {name: "performer", type: "address"},
          {name: "exists", type: "bool"},
          {name: "raga", type: "string"},
          {name: "title", type: "string"},
        ],
      },
    ],
  },
  {
    type: "function",
    name: "getRecordingLineage",
    stateMutability: "view",
    inputs: [{name: "recordingId", type: "bytes32"}],
    outputs: [
      {name: "performer", type: "address"},
      {name: "teachers", type: "address[]"},
      {name: "sharesBps", type: "uint16[]"},
      {name: "uids", type: "bytes32[]"},
    ],
  },
  {
    type: "function",
    name: "previewRoyalty",
    stateMutability: "view",
    inputs: [
      {name: "recordingId", type: "bytes32"},
      {name: "amount", type: "uint256"},
    ],
    outputs: [
      {name: "recipients", type: "address[]"},
      {name: "amounts", type: "uint256[]"},
    ],
  },
  {
    type: "function",
    name: "checkLicense",
    stateMutability: "view",
    inputs: [
      {name: "recordingId", type: "bytes32"},
      {name: "licensee", type: "address"},
    ],
    outputs: [{name: "", type: "uint8"}],
  },
  {
    type: "function",
    name: "lineageRegistry",
    stateMutability: "view",
    inputs: [],
    outputs: [{name: "", type: "address"}],
  },
] as const;

export const lineageRegistryAbi = [
  {
    type: "function",
    name: "decodeLineage",
    stateMutability: "view",
    inputs: [{name: "attestationUid", type: "bytes32"}],
    outputs: [
      {name: "student", type: "address"},
      {name: "teacher", type: "address"},
      {name: "tradition", type: "string"},
      {name: "teacherShareBps", type: "uint16"},
      {name: "note", type: "string"},
    ],
  },
  {
    type: "function",
    name: "lineageStatusOf",
    stateMutability: "view",
    inputs: [{name: "performer", type: "address"}],
    outputs: [{name: "", type: "uint8"}],
  },
] as const;

/** Mirrors `RagaLicenseRegistry.LicenseStatus`, in declaration order. */
export const LICENSE_STATUS = [
  "NEVER LICENSED",
  "REVOKED",
  "EXPIRED",
  "LINEAGE REVOKED",
  "VALID",
] as const;

/** Mirrors the `LineageStatus` enum. */
export const LINEAGE_STATUS = ["NO CLAIM", "ACTIVE", "REVOKED"] as const;

/** Plain-language explanation of each licence state, for a non-technical reader. */
export const LICENSE_STATUS_MEANING: Record<string, string> = {
  "NEVER LICENSED": "No licence has ever been issued to this party for this recording.",
  REVOKED: "A licence was issued and has since been withdrawn by the performer.",
  EXPIRED: "A licence was issued but its term has run out.",
  "LINEAGE REVOKED":
    "The licence itself is intact, but a guru has withdrawn the teaching lineage behind it.",
  VALID: "Licensed, in good standing, as of the block just read.",
};

/**
 * The three events needed to rebuild the teaching graph from scratch, without asking
 * the contract what it thinks the answer is.
 *
 * `LineageProposed` carries the agreed share; `LineageConfirmed` carries the attestation
 * uid that share became real under; `LineageRevoked` retires it. Joined on `claimId`,
 * they are enough to reconstruct every edge and its current standing.
 */
export const lineageEventsAbi = [
  {
    type: "event",
    name: "LineageProposed",
    inputs: [
      {name: "claimId", type: "uint256", indexed: true},
      {name: "student", type: "address", indexed: true},
      {name: "teacher", type: "address", indexed: true},
      {name: "teacherShareBps", type: "uint16", indexed: false},
    ],
  },
  {
    type: "event",
    name: "LineageConfirmed",
    inputs: [
      {name: "claimId", type: "uint256", indexed: true},
      {name: "attestationUid", type: "bytes32", indexed: true},
      {name: "teacher", type: "address", indexed: true},
      {name: "student", type: "address", indexed: false},
    ],
  },
  {
    type: "event",
    name: "LineageRevoked",
    inputs: [
      {name: "attestationUid", type: "bytes32", indexed: true},
      {name: "teacher", type: "address", indexed: true},
      {name: "student", type: "address", indexed: true},
    ],
  },
] as const;

export const splitRoyaltyAbi = [
  {
    type: "function",
    name: "splitRoyalty",
    stateMutability: "view",
    inputs: [
      {name: "performer", type: "address"},
      {name: "amount", type: "uint256"},
    ],
    outputs: [
      {name: "recipients", type: "address[]"},
      {name: "amounts", type: "uint256[]"},
    ],
  },
  {
    type: "function",
    name: "MAX_LINEAGE_DEPTH",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "TOTAL_BPS",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint256"}],
  },
] as const;
