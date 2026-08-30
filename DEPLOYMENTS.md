# Deployments — Base Sepolia (chain 84532)

Live and seeded. Every address below was verified on-chain after deployment, not just
read off the deploy script's output.

| Contract | Address |
|---|---|
| `RagaLineageRegistry` | [`0x7213E581c9a49Cdf9B10400ac52A90B7D5D4095F`](https://sepolia.basescan.org/address/0x7213E581c9a49Cdf9B10400ac52A90B7D5D4095F) |
| `RagaLicenseRegistry` | [`0x56Da8B087A7B482340805fb03F56910175A699E5`](https://sepolia.basescan.org/address/0x56Da8B087A7B482340805fb03F56910175A699E5) |
| `LineageAttestationResolver` | [`0x241d8fb560A670BEaE4915B25EC757b051eE7330`](https://sepolia.basescan.org/address/0x241d8fb560A670BEaE4915B25EC757b051eE7330) |

Attached to the Base Sepolia EAS predeploys, which report **v1.2.0**:

| | |
|---|---|
| EAS | `0x4200000000000000000000000000000000000021` |
| SchemaRegistry | `0x4200000000000000000000000000000000000020` |
| lineage schema uid | `0x6989ee544ae065a2dccd2489f64de875b32862d7c3f6dfe12b4bea4975432b44` |
| licence schema uid | `0x6898edc8eebcde2673989aec81065b8476218219cd11bdd1710bae48f61454a3` |

Verified after deploy: the resolver's `registry()` points at `RagaLineageRegistry`, so the
teacher-confirmation guarantee is live — a student cannot mint a lineage attestation by
calling EAS directly.

## Seeded state

The Devika story is played out on-chain, using the real two-step flow:

| Role | Address | Share |
|---|---|---|
| Devika (performer) | `0xA39D127B021196AA7Eec7427d4c9af19001A086b` | keeps the remainder |
| Rajam (guru) | `0xa13C26f432a9Ff9E8D4577B2a4880274FB373476` | 2000 bps |
| Ariyakudi (guru's guru) | `0x60c54d721bAC607A355107527F87eB52d1538C10` | 1500 bps |

Recording `kalyani-varnam-2026`
→ `0x3984de28d4e4726f6c64868ab98b9b7b359f3c90a8e7dc6c1bb8ca96e888b240`, licensed to
`0x…5001` for a year.

Each lineage edge was created the hard way: the student proposed, and the *named teacher*
sent the confirming transaction themselves.

## Reading it back

```bash
cd resolver && npm install

npm run who-gets-paid -- --recording kalyani-varnam-2026 --amount 10 \
  --rpc https://sepolia.base.org \
  --registry 0x56Da8B087A7B482340805fb03F56910175A699E5 \
  --licensee 0x0000000000000000000000000000000000005001

npm run verify-split -- --performer 0xA39D127B021196AA7Eec7427d4c9af19001A086b \
  --amount 10 --rpc https://sepolia.base.org \
  --registry 0x56Da8B087A7B482340805fb03F56910175A699E5
```

Actual output from the live deployment:

```
  2 proposals · 2 confirmations · 0 revocations

  Off-chain reconstructed split of 10 ETH:
    0xa39d127b021196aa7eec7427d4c9af19001a086b   68.00%  6.8 ETH
    0xa13c26f432a9ff9e8d4577b2a4880274fb373476   20.00%  2 ETH
    0x60c54d721bac607a355107527f87eb52d1538c10   12.00%  1.2 ETH

  On-chain splitRoyalty() split:
    0xa39d127b021196aa7eec7427d4c9af19001a086b   68.00%  6.8 ETH
    0xa13c26f432a9ff9e8d4577b2a4880274fb373476   20.00%  2 ETH
    0x60c54d721bac607a355107527f87eb52d1538c10   12.00%  1.2 ETH

  MATCH: the independently-reconstructed split agrees with the on-chain result.
  CONSERVED: the split distributes exactly 10 ETH, no wei created or lost.
```

> The deploying key is a throwaway that has only ever held Base Sepolia testnet ETH, and
> its private key was exposed during development. It holds `DEFAULT_ADMIN_ROLE` on this
> deployment, which is therefore a demonstration, not a production instance. A real
> deployment would put that role behind a multisig.

## Source verification

All three contracts are verified on **Sourcify** with an exact match on both creation and
runtime bytecode, so the deployed code is provably the code in this repo:

| Contract | Sourcify |
|---|---|
| `RagaLineageRegistry` | https://repo.sourcify.dev/84532/0x7213E581c9a49Cdf9B10400ac52A90B7D5D4095F |
| `RagaLicenseRegistry` | https://repo.sourcify.dev/84532/0x56Da8B087A7B482340805fb03F56910175A699E5 |
| `LineageAttestationResolver` | https://repo.sourcify.dev/84532/0x241d8fb560A670BEaE4915B25EC757b051eE7330 |

```bash
curl -s https://sourcify.dev/server/v2/contract/84532/0x7213E581c9a49Cdf9B10400ac52A90B7D5D4095F
# {"match":"match","creationMatch":"match","runtimeMatch":"match", ...}
```

Sourcify rather than Basescan because it needs no API key, and Basescan surfaces
Sourcify-verified sources anyway. That the *resolver* is verified matters most: anyone can
read it and confirm for themselves that it rejects any attester but the registry, which is
what makes the teacher-confirmation step unbypassable.
