# Lico-Arc

Lico-Arc is the open-source repository for the official LicoLite client product line:
Flutter desktop shell, native sidecar, client contracts, client scenarios, and
client release gates.

## Open-source release boundary

Development, ordinary client builds, and GitHub Releases do not depend on a
production publisher account, store credential, Developer ID, notarization,
store submission, public store download, or store update/rollback channel.
Those inputs decide only whether the corresponding platform or software-store
distribution is ready and may remain unavailable without blocking source
development or publication of an otherwise accepted GitHub Release.

The repository and GitHub Release expose only the minimum metadata consumers
need to authenticate an official distribution artifact and verify its
integrity: artifact identity, target and version, cryptographic digest, and an
artifact signature or attestation plus the public verification material when
required. Publisher account identifiers, certificate subjects or stable
fingerprints, team/store identifiers, credentials, private keys, custody
details, and private distribution infrastructure are not public release
metadata.

The `LicoLite/LicoLite` repository owns the open gateway fabric,
server-facing protocols, SDK-facing contracts, self-hosted deployment path, and
minimal operator surfaces. Lico-Arc owns the official client product experience
and the authority for its custom end-to-end encryption protocol (Secure Client
Mesh). Encrypted communication is a native Lico-Arc capability and does not
depend on a relay or gateway server implementation; relays only carry opaque
envelopes.

## Repository Boundary

Owned by this repository:

- Official desktop, mobile, and LicoArc client surfaces.
- Local product workspace UX, activity, snapshots, target adapters, Skill Hub,
  model forwarding, mobile relay, update channel, and client packaging.
- Native sidecar code used by the official client.
- The Lico-Arc custom encryption protocol, cryptography, and client-side
  encrypted-communication verification.
- Client product scenarios and release gates.

Gateway-facing work stays in `LicoLite/LicoLite`:

- Gateway, relay, routing, policy hooks, audit, checkpoint, and receipts.
- Non-encryption protocol specifications needed for third-party or self-hosted
  integration.
- SDKs, CLI/debug tools, and deployment examples that make the open gateway
  fabric usable without the official client.

## License

Lico-Arc is free software licensed under the GNU General Public License,
version 3 or (at your option) any later version (`GPL-3.0-or-later`). See
[`LICENSE`](LICENSE). Distribution of binaries must continue to provide the
corresponding source and license notices required by the GPL. Publisher,
store-account, credential, device, and private-channel metadata are not part of
the public source or GitHub Release consumer-verification record.

## Local Setup

Required local tools:

- Node.js 22 or 24
- Flutter stable with desktop support
- Rust stable

Useful commands:

```bash
npm ci
npm run client:version:check
npm run repo:workspace-cache-boundary
npm run client:get
npm run client:analyze
npm run client:test
npm run client:runtime:package
npm run client:cli:vm:list
npm run client:cli:vm:prepare
npm run client:cli:vm:verify
npm run client:native:test
npm run client:verify
```

`npm run client:verify` is the local merge gate. It runs boundary hygiene,
client version governance, client architecture/plan checks, schema checks,
Flutter checks, Rust sidecar checks, and the fail-closed Secure Mesh E2EE
evidence handoff bundle for the public LicoLite release gate.

Client product versions are centralized in `tools/client-version.json`. Use
`npm run client:version:sync` after editing that manifest, or run
`npm run client:version:set -- --version 0.0.1-alpha --build-number 2` to update
the manifest and all supported package manifests together. `npm run
client:version:check` fails if Flutter, iOS, macOS, Cargo, npm, or supported
generated lock metadata drift from the manifest.

`npm run repo:workspace-cache-boundary` scans sibling Git repositories under the
workspace root and fails if build outputs, dependency caches, local runtime
data, logs, checkpoints, or portable client data are tracked or are visible as
unignored files. Its JSON report is written under `build/reports/`.

Linux ARM64 CLI validation uses QEMU VMs, not Android or iOS client builds. The
matrix is defined in `tools/client-cli-vm-matrix.json` and currently covers
Ubuntu, Debian, openSUSE, AlmaLinux, and Rocky Linux from official ARM64 cloud
images. Arch Linux is represented as a manual-image row; set
`LICO_CLIENT_CLI_VM_ARCH_IMAGE_URL` to an approved ARM64 cloud image before
running that row. VM images and disks default to an external client cache root;
CLI artifacts are copied back under `build/client-cli-vm/`.

## Layout

| Path | Owner |
| --- | --- |
| `apps/desktop/` | Flutter official desktop client |
| `crates/lico-client-native/` | Native sidecar and `lico-client` command |
| `packages/contracts/client/` | Client DTO schemas |
| `packages/protocols/native-client/` | Client-side native protocol notes |
| `docs/functionality/CLIENT-DESKTOP.md` | Current client functionality contract |
| `docs/scenarios/personal-user/` | Client product scenario ledger |
| `tests/` | Client contract, native, release, and boundary checks |

## Contribution Boundary

Do not reintroduce a parallel legacy client, compatibility facade, or old
server-console product surface. Client refactors must complete the migration in
one pass: source, callers, docs, tests, packaging, and gates should all point to
the current client path before verification is treated as final.

Persistent user state owned by a retired product name is reset directly. The
current client initializes fresh Lico Arc state and never discovers, imports,
renames, copies, translates, or prompts for a retired-name data root or
preference namespace.
