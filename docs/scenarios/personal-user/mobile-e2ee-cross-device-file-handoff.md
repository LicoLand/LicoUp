# User-Approved End-to-End Encrypted File Handoff

## Metadata / 元数据

- Last updated: 2026-07-15
- Status: Current Secure Client Mesh scenario contract
- Scope: Explicit file handoff among desktop, Android, and iPhone clients through an opaque relay.
- Staleness check: Reconciled with the Secure Client Mesh file codec, mobile relay, platform bridges, and product approval contract on 2026-07-15.

## Contract

This is an explicit one-file-at-a-time communication flow, not automatic file
synchronization. Before any bytes leave the source device, the user sees and
approves the exact source file, content digest, destination endpoint, destination
directory intent, purpose, size, and conflict policy. The action remains
cancellable until commit. Approval expires when any bound field changes.

| Boundary | Requirement |
| --- | --- |
| Shared algorithm | Desktop, Android, and iOS use the shared Rust Secure Client Mesh file manifest/chunk and pairwise-session implementation. Kotlin and Swift do not own alternate cryptographic algorithms. |
| Key locality | Private keys and content keys stay inside approved platform custody. Raw key material never enters Flutter, logs, evidence, or relay payload metadata. |
| Relay-visible wire | The relay sees only bounded routing fields and authenticated opaque ciphertext. File name, MIME, destination, content, and content key remain encrypted. |
| Destination | The receiver independently validates a user-approved local destination boundary and never trusts a sender-provided absolute path. |
| Local effect | The receiver asks for direct approval before the final write, verifies chunks and digest, writes to a temporary file, applies the chosen conflict policy, atomically commits, and returns an encrypted receipt. |

## Cross-Platform Matrix

- Android-to-desktop-to-iPhone
- iPhone-to-desktop-to-Android
- desktop-to-Android and desktop-to-iPhone
- endpoint-specific resealed ciphertext for every recipient; ciphertext for one
  endpoint cannot be replayed or opened by another endpoint

The sender and receiver each bind trust, endpoint identity, transfer id, digest,
and approval revision. Wrong recipient, revoked endpoint, stale key, reordered or
conflicting chunks, digest mismatch, destination escape, duplicate completion,
expired approval, cancellation, and plaintext relay attempts fail closed.

## Lifecycle

1. The sender obtains direct file-bound approval and creates an encrypted manifest.
2. The sender chunks and encrypts the file with bounded memory and queue capacity.
3. The relay carries opaque entries only.
4. The receiver validates trust, manifest, destination policy, and local approval.
5. Resume requests identify missing encrypted chunks without exposing file facts.
6. The receiver verifies and atomically commits, then returns an encrypted receipt.
7. ACK or expiry purges active opaque entries and bounded local transfer state.

## Acceptance

- `npm run client:verify:secure-client-relay-mock-e2e` proves the opaque relay
  contract and negative controls.
- Native file codec tests cover manifest/chunk confidentiality, integrity,
  traversal rejection, bounded queueing, resume, ACK, purge, and endpoint-specific
  resealing.
- Approval tests cover absent, cancelled, expired, changed-digest, changed-target,
  changed-destination, and agent-originated requests.
- Release evidence requires physical Android and physical iPhone interoperability
  for the claimed platform pair; simulator or synthetic evidence is not a
  physical-device claim.
