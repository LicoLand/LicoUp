# Endpoint collaboration

Endpoint collaboration (`endpoint-collaboration.v1`,
`org.licoland.feature.collaboration`) is the optional package that carries
cross-device collaboration for one LicoUp account: the transfer of an account's
data to a replacement endpoint, and the bounded, recoverable removal of the old
endpoint's LicoUp-owned data afterwards.

This document is the owning module guidance for the package. The package
manifest, availability and profile rules belong to
[Deployment profiles](../architecture/DEPLOYMENT-PROFILES.md) and the extension
platform; the protocol semantics belong to Lico Arc Protocol. Nothing here
restates them.

## Modules

| Module | What it owns |
| --- | --- |
| `components/endpoint-collaboration/cleanup/` | The file half of a staged erase: close the data root's writer admission, settle the frozen file inventory entry by entry with durable, replay-safe progress, and report a partial file-stage result to the replacement endpoint. It deletes no credential and reads no protected key. |
| `components/endpoint-collaboration/transfer/` | Device-transfer ownership inventory: classify one full-data-root archive into managed payloads, external references and nonportable credential requirements. |
| `crates/licoup-native/src/domain/mobile_relay/secret_custody/cleanup_authority.rs` | The cleanup-specific authorization: derive the custody subject from persisted identity, accept a replacement endpoint only against a locally signed device trust record that verifies, enumerate the bounded custody inventory, and require an explicit informed confirmation naming that subject, that replacement endpoint, the inventory digest and every scope entry. |
| `crates/licoup-native/src/domain/mobile_relay/secret_custody/cleanup.rs` | The custody consumer: delete exactly the authorized credentials through the platform secret store's own authorized session, remove exactly the authorized durable-store files, and report observed settlement. |

## The approved credential deletion route

The old endpoint is revoked and is not present to cooperate. Its manual-presence
requirement is therefore replaced — **only** for the deletion of its own bound
LicoUp inventory — by two facts established on the replacement endpoint:

1. **Strict authentication.** The replacement endpoint is the persisted peer
   identity, accepted only when the device trust record the subject itself
   signed for that peer verifies, is unexpired and reports the `verified` trust
   state. A persisted flag or any caller-supplied claim authenticates nothing.
2. **Explicit informed confirmation.** The confirmation is a record, not a
   boolean. It must name the derived subject (endpoint identifier, identity
   fingerprint, custody namespace), the authenticated replacement endpoint and
   its trust fingerprint, the enumerated inventory digest, the consequence
   `irreversibleLocalSecretErasure`, and every entry of the bounded scope. An
   entry outside the enumerated inventory is refused rather than erased.

The authorized set is the exact, deduplicated custody inventory owned by that
subject: the root secret handles, the pairwise snapshot handles and the fixed
set of durable-store files the pairwise store owns. The erase loop walks that
set and nothing else, sizes the platform secret store's authorization batch from
it, and checks the session's own consumed-operation count afterwards so a wider
session than declared cannot pass unnoticed.

Ordinary protected operations keep their existing authorization. The cleanup
route neither reads, exports nor signs with a protected key, and it returns no
reusable handle or session to any other caller.

## Settlement is observed, never assumed

A cleanup reports `complete` only when every authorized credential deletion and
every authorized durable-store file was observed settled. A locked platform
store, an unavailable backend or a denied file removal leaves the report
`partial` with the exact pending entries; it is never converted into a finished
erase. After the last observation the cleaned side writes nothing — no data
root, log, temporary payload or credential is recreated there.

The cleanup's own progress material is owned by the data root's cleanup state
directory and is settled by the terminal stage. Only the replacement endpoint
holds the final evidence: the receipt block is issued with
`replacementEndpointConfirmed: false` until that endpoint observes arrival, so a
lost receipt is never silently converted into success.

## What this package does not claim

Removing LicoUp-managed files and credentials leaves forensic traces on the
storage device and in operating-system backups. Neither the package nor this
document promises forensic or backup erasure.

## Tests

```sh
cargo test --manifest-path components/endpoint-collaboration/cleanup/Cargo.toml
cargo test -p licoup-native --lib secret_custody
```

The component's fixtures are synthetic: an in-memory file owner, a recording
receipt path and disposable temporary roots. The native custody fixtures seed
synthetic identities, trust records and an ephemeral secret store; no test reads
or removes a real credential, keychain entry or installed application's data.
