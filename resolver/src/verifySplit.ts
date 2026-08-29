/**
 * verify-split — an independent check on the contract's royalty arithmetic.
 *
 * This deliberately does NOT ask the registry who gets paid and then print it. That would
 * only prove the contract agrees with itself. Instead it:
 *
 *   1. reads LineageProposed / LineageConfirmed / LineageRevoked straight from the event
 *      log and rebuilds the teaching graph from scratch, the way an indexer — or a judge
 *      reading the raw log — would have to;
 *   2. re-implements the cascading split in TypeScript over that independently-rebuilt
 *      graph;
 *   3. calls the contract's own splitRoyalty() and diffs the two, printing MATCH or
 *      MISMATCH.
 *
 * So it doubles as a live correctness check: if the on-chain arithmetic ever disagreed
 * with what the event log says actually happened, this would say so.
 *
 * Usage:
 *   npm run verify-split -- --performer 0x… --amount 10 \
 *     --rpc http://127.0.0.1:8545 --registry <LICENSE_REGISTRY>
 */

import {
  createPublicClient,
  formatEther,
  http,
  isAddress,
  parseEther,
  type Address,
  type Hex,
} from "viem";
import {baseSepolia} from "viem/chains";
import {licenseRegistryAbi, lineageEventsAbi, splitRoyaltyAbi} from "./abi.js";

const TOTAL_BPS = 10_000n;

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
}

function fail(message: string): never {
  console.error(`\n  ✖ ${message}\n`);
  process.exit(1);
}

/** One edge of the graph, as reconstructed purely from logs. */
type Edge = {
  student: Address;
  teacher: Address;
  shareBps: bigint;
  uid: Hex;
  confirmedAt: bigint; // block number, to resolve "which edge is current"
};

async function main() {
  const performer = arg("performer") as Address | undefined;
  if (!performer || !isAddress(performer)) {
    fail("Missing or invalid --performer 0x…");
  }

  const registryAddress = (arg("registry") ?? process.env.LICENSE_REGISTRY) as Address | undefined;
  if (!registryAddress || !isAddress(registryAddress)) {
    fail("No licence registry. Set LICENSE_REGISTRY or pass --registry 0x…");
  }

  const amount = parseEther(arg("amount") ?? "10");
  const fromBlock = BigInt(arg("fromBlock") ?? "0");

  const client = createPublicClient({
    chain: baseSepolia,
    transport: http(arg("rpc") ?? process.env.RPC_URL),
  });

  const lineageRegistry = await client.readContract({
    address: registryAddress,
    abi: licenseRegistryAbi,
    functionName: "lineageRegistry",
    args: [],
  });

  console.log(`\n  Rebuilding the teaching graph for ${performer}`);
  console.log(`  from the event log of ${lineageRegistry} (fromBlock=${fromBlock})…\n`);

  // --- 1. read the raw log ------------------------------------------------

  const [proposed, confirmed, revoked] = await Promise.all([
    client.getContractEvents({
      address: lineageRegistry,
      abi: lineageEventsAbi,
      eventName: "LineageProposed",
      fromBlock,
    }),
    client.getContractEvents({
      address: lineageRegistry,
      abi: lineageEventsAbi,
      eventName: "LineageConfirmed",
      fromBlock,
    }),
    client.getContractEvents({
      address: lineageRegistry,
      abi: lineageEventsAbi,
      eventName: "LineageRevoked",
      fromBlock,
    }),
  ]);

  // The agreed share lives on the proposal; the uid lives on the confirmation.
  // Join them on claimId.
  const shareByClaim = new Map<string, bigint>();
  for (const e of proposed) {
    shareByClaim.set(String(e.args.claimId), BigInt(e.args.teacherShareBps ?? 0));
  }

  const revokedUids = new Set<string>();
  for (const e of revoked) {
    revokedUids.add(String(e.args.attestationUid).toLowerCase());
  }

  // --- 2. rebuild the graph ----------------------------------------------

  // A student's live edge is their most recently confirmed one that has not been revoked.
  // (The contract overwrites primaryLineageEdge on each confirmation, so "latest wins".)
  const latestEdge = new Map<string, Edge>();
  for (const e of confirmed) {
    const claimId = String(e.args.claimId);
    const student = e.args.student as Address;
    const teacher = e.args.teacher as Address;
    const uid = e.args.attestationUid as Hex;
    const share = shareByClaim.get(claimId);
    if (share === undefined) continue; // confirmation without a proposal: impossible on-chain

    const key = student.toLowerCase();
    const prev = latestEdge.get(key);
    const blockNumber = e.blockNumber ?? 0n;
    if (!prev || blockNumber >= prev.confirmedAt) {
      latestEdge.set(key, {student, teacher, shareBps: share, uid, confirmedAt: blockNumber});
    }
  }

  console.log(`  ${proposed.length} proposals · ${confirmed.length} confirmations · ${revoked.length} revocations`);

  // --- 3. walk it ---------------------------------------------------------

  const maxDepth = await client.readContract({
    address: lineageRegistry,
    abi: splitRoyaltyAbi,
    functionName: "MAX_LINEAGE_DEPTH",
    args: [],
  });

  const chain: Edge[] = [];
  let current: Address = performer;
  for (let depth = 0n; depth < maxDepth; depth++) {
    const edge = latestEdge.get(current.toLowerCase());
    if (!edge) break;
    if (revokedUids.has(edge.uid.toLowerCase())) break; // revoked stops the chain, as on-chain
    chain.push(edge);
    current = edge.teacher;
  }

  // --- 4. re-implement the cascading split -------------------------------

  const offchain: {who: Address; amount: bigint}[] = [];
  let remaining = amount;
  for (const edge of chain) {
    const cut = (remaining * edge.shareBps) / TOTAL_BPS;
    offchain.push({who: edge.teacher, amount: cut});
    remaining -= cut;
  }
  // The performer keeps the rest, absorbing the rounding dust.
  offchain.unshift({who: performer, amount: remaining});

  const pctOf = (x: bigint) =>
    amount === 0n ? "0.00%" : `${((Number(x) / Number(amount)) * 100).toFixed(2)}%`;

  console.log(`\n  Off-chain reconstructed split of ${formatEther(amount)} ETH:`);
  for (const r of offchain) {
    console.log(`    ${r.who.toLowerCase()}  ${pctOf(r.amount).padStart(7)}  ${formatEther(r.amount)} ETH`);
  }

  // --- 5. ask the contract, and diff -------------------------------------

  const [onchainWho, onchainAmt] = await client.readContract({
    address: lineageRegistry,
    abi: splitRoyaltyAbi,
    functionName: "splitRoyalty",
    args: [performer, amount],
  });

  console.log(`\n  On-chain splitRoyalty() split:`);
  for (const [i, who] of onchainWho.entries()) {
    const a = onchainAmt[i]!;
    console.log(`    ${who.toLowerCase()}  ${pctOf(a).padStart(7)}  ${formatEther(a)} ETH`);
  }

  let matches = onchainWho.length === offchain.length;
  if (matches) {
    for (const [i, who] of onchainWho.entries()) {
      if (
        who.toLowerCase() !== offchain[i]!.who.toLowerCase() ||
        onchainAmt[i]! !== offchain[i]!.amount
      ) {
        matches = false;
        break;
      }
    }
  }

  // Independent of the diff: the split must conserve the payment exactly.
  const onchainTotal = onchainAmt.reduce((a, b) => a + b, 0n);
  const conserves = onchainTotal === amount;

  console.log("");
  if (matches) {
    console.log("  MATCH: the independently-reconstructed split agrees with the on-chain result.");
  } else {
    console.log("  MISMATCH: the event log and the on-chain arithmetic disagree.");
  }
  console.log(
    conserves
      ? `  CONSERVED: the split distributes exactly ${formatEther(amount)} ETH, no wei created or lost.`
      : `  LEAK: on-chain split totals ${formatEther(onchainTotal)} ETH against a ${formatEther(amount)} ETH payment.`,
  );
  console.log("");

  if (!matches || !conserves) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
