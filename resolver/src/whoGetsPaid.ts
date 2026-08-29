/**
 * who-gets-paid — answers, in plain language, the one question a streaming platform
 * or a vocalist actually needs answered about a recording:
 *
 *     Who gets paid for this, how much, and is the licence any good today?
 *
 * The contracts already hold the answer, but only as `bytes32` ids, basis points and
 * enum ordinals. Reading it out of them should not require knowing Solidity. This
 * script resolves the lineage graph, renders the royalty split as rupees-and-paise
 * style figures, and names the licence state in words.
 *
 * Usage:
 *   npm run who-gets-paid -- --recording "kalyani-varnam-2026" --amount 10
 *   npm run who-gets-paid -- --recording 0xabc… --amount 2.5 --licensee 0x…
 *
 * Configure the chain with env vars (see .env.example in the repo root):
 *   RPC_URL, LICENSE_REGISTRY
 */

import {
  createPublicClient,
  formatEther,
  http,
  isAddress,
  keccak256,
  parseEther,
  toHex,
  type Address,
  type Hex,
} from "viem";
import {baseSepolia} from "viem/chains";
import {
  LICENSE_STATUS,
  LICENSE_STATUS_MEANING,
  LINEAGE_STATUS,
  licenseRegistryAbi,
  lineageRegistryAbi,
} from "./abi.js";

// ---------------------------------------------------------------------------
// arguments
// ---------------------------------------------------------------------------

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
}

function fail(message: string): never {
  console.error(`\n  ✖ ${message}\n`);
  process.exit(1);
}

/**
 * A recording id is a bytes32. Humans have a slug ("kalyani-varnam-2026"), so accept
 * either and hash the slug the same way the tests and the dashboard do.
 */
function toRecordingId(input: string): Hex {
  if (/^0x[0-9a-fA-F]{64}$/.test(input)) return input as Hex;
  return keccak256(toHex(input));
}

/** 2000 bps -> "20%" */
function bpsToPercent(bps: number): string {
  return `${(bps / 100).toFixed(bps % 100 === 0 ? 0 : 2)}%`;
}

/** Right-pad for column alignment without pulling in a table library. */
function pad(s: string, width: number): string {
  return s.length >= width ? s : s + " ".repeat(width - s.length);
}

function shortAddress(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

async function main() {
  const recordingArg = arg("recording");
  if (!recordingArg) {
    fail(
      "Missing --recording. Pass a slug or a 0x… bytes32 id.\n" +
        "    e.g. npm run who-gets-paid -- --recording kalyani-varnam-2026 --amount 10",
    );
  }

  const registryAddress = (arg("registry") ?? process.env.LICENSE_REGISTRY) as
    | Address
    | undefined;
  if (!registryAddress || !isAddress(registryAddress)) {
    fail(
      "No licence registry address. Set LICENSE_REGISTRY in your environment, or pass --registry 0x…",
    );
  }

  const rpcUrl = arg("rpc") ?? process.env.RPC_URL;
  const amountEth = arg("amount") ?? "1";
  const licensee = arg("licensee") as Address | undefined;

  const recordingId = toRecordingId(recordingArg);
  const amount = parseEther(amountEth);

  const client = createPublicClient({
    chain: baseSepolia,
    transport: http(rpcUrl),
  });

  // --- the recording ------------------------------------------------------

  const recording = await client
    .readContract({
      address: registryAddress,
      abi: licenseRegistryAbi,
      functionName: "getRecording",
      args: [recordingId],
    })
    .catch((e: unknown) => {
      fail(`Could not reach the registry at ${registryAddress}.\n    ${String(e).split("\n")[0]}`);
    });

  if (!recording.exists) {
    fail(
      `No recording registered under "${recordingArg}".\n` +
        `    (resolved to ${recordingId})`,
    );
  }

  console.log("");
  console.log(`  ${recording.title || "(untitled)"}`);
  console.log(`  raga ${recording.raga || "(unspecified)"}`);
  console.log(`  id   ${recordingId}`);
  console.log("");

  // --- the lineage --------------------------------------------------------

  const [performer, teachers, sharesBps, uids] = await client.readContract({
    address: registryAddress,
    abi: licenseRegistryAbi,
    functionName: "getRecordingLineage",
    args: [recordingId],
  });

  const lineageRegistry = await client.readContract({
    address: registryAddress,
    abi: licenseRegistryAbi,
    functionName: "lineageRegistry",
    args: [],
  });

  const lineageStatus = await client.readContract({
    address: lineageRegistry,
    abi: lineageRegistryAbi,
    functionName: "lineageStatusOf",
    args: [performer],
  });

  console.log("  TEACHING LINEAGE");
  console.log(`  performed by  ${performer}`);

  if (teachers.length === 0) {
    console.log("  no confirmed teachers upstream — the performer holds the whole share");
    if (LINEAGE_STATUS[lineageStatus] === "REVOKED") {
      console.log("  ⚠ a lineage claim existed and the guru has since withdrawn it");
    }
  } else {
    // Each hop is a confirmed EAS attestation; read the tradition and note off it
    // so the output says something a person recognises, not just an address.
    for (const [i, teacher] of teachers.entries()) {
      const uid = uids[i]!;
      const detail = await client
        .readContract({
          address: lineageRegistry,
          abi: lineageRegistryAbi,
          functionName: "decodeLineage",
          args: [uid],
        })
        .catch(() => undefined);

      const generation = i === 0 ? "guru" : i === 1 ? "guru's guru" : `${i + 1} generations up`;
      const tradition = detail?.[2] ? ` · ${detail[2]}` : "";
      const note = detail?.[4] ? `\n        “${detail[4]}”` : "";

      console.log(
        `    ${pad(generation, 18)} ${teacher}  ${bpsToPercent(sharesBps[i]!)}${tradition}${note}`,
      );
    }
  }
  console.log("");

  // --- the split ----------------------------------------------------------

  const [recipients, amounts] = await client.readContract({
    address: registryAddress,
    abi: licenseRegistryAbi,
    functionName: "previewRoyalty",
    args: [recordingId, amount],
  });

  console.log(`  IF A ROYALTY OF ${amountEth} ETH IS PAID TODAY`);
  let total = 0n;
  for (const [i, who] of recipients.entries()) {
    const cut = amounts[i]!;
    total += cut;
    const role = i === 0 ? "performer" : i === 1 ? "guru" : `generation ${i}`;
    const pct = amount === 0n ? "0%" : `${((Number(cut) / Number(amount)) * 100).toFixed(2)}%`;
    console.log(
      `    ${pad(role, 18)} ${pad(shortAddress(who), 16)} ${pad(formatEther(cut) + " ETH", 22)} ${pct}`,
    );
  }
  console.log(`    ${pad("", 18)} ${pad("", 16)} ${pad("─".repeat(20), 22)}`);
  console.log(`    ${pad("total", 18)} ${pad("", 16)} ${formatEther(total)} ETH`);
  if (total !== amount) {
    console.log(`    ⚠ split does not sum to the payment — ${formatEther(amount - total)} ETH unaccounted`);
  }
  console.log("");

  // --- the licence --------------------------------------------------------

  if (licensee) {
    const status = await client.readContract({
      address: registryAddress,
      abi: licenseRegistryAbi,
      functionName: "checkLicense",
      args: [recordingId, licensee],
    });
    const name = LICENSE_STATUS[status] ?? `UNKNOWN(${status})`;
    const block = await client.getBlockNumber();

    console.log("  LICENCE CHECK");
    console.log(`    ${licensee}`);
    console.log(`    ${name}`);
    console.log(`    ${LICENSE_STATUS_MEANING[name] ?? ""}`);
    console.log(`    checked against block ${block} — this answer is a live read, not a cached one`);
    console.log("");
  } else {
    console.log("  (pass --licensee 0x… to check a specific platform's licence)\n");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
