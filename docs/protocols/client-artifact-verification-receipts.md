# Client Artifact Consumer Verification Receipts

[Documentation](../README.md) · [Canonical schema](../../tools/scripts/config/client-artifact-verification-receipts-report.schema.json)

This document describes the public receipt format and its verification boundary.
The schema and release tooling are authoritative; this document does not define
an independent receipt contract.

The canonical selected-target receipt is produced by:

```bash
LICO_CLIENT_RELEASE_TARGETS=macos-arm64,android-arm64,linux-glibc-arm64 \
  npm run client:verify:artifact-verification-receipts
```

The target list is explicit and non-empty. Only selected targets are reduced;
an unselected or deferred target is not an implicit blocker. In one release
closure, the reducer creates a random closure challenge and a distinct random
invocation nonce for every selected target, deletes any previous target report,
and directly invokes the approved platform producer. Therefore selecting
Android can install and launch on the authorized phone, selecting macOS can
launch the installed app, and selecting Linux can install and exercise the
canonical distribution archive on the approved native ARM64 release runner.
Only an exit-zero producer result generated after that invocation and bound to
both digests can be accepted; a producer failure can never reuse an older green
JSON file. Report modification time is not an authority.

The reducer parses and hashes each evidence report from the same stable,
no-follow file descriptor. Artifact, evidence, and producer paths must be
canonical non-symlink paths inside their approved roots. File and directory
mutation during hashing, escaping bundle symlinks, output traversal, and
symlinked output paths fail closed. The receipt binds current source digest,
product version and build number, exact target, exact artifact digest, producer
source digest, report digest, closure challenge, and per-invocation nonce.
For macOS and Linux it also binds the exact distribution-manifest digest; the
receipt and final acceptance reducer must name the same artifact kind, archive,
and manifest.
Each ready target also binds the exact packaged runtime executable digest. The
macOS receipt carries the user-presence child-proof reference and digest; the
final reducer re-hashes that child and includes it in selected-closure
redaction.
The source-root set is code-owned and cannot be narrowed by editing the JSON
config; it includes both package manifests and locks, Cargo manifests and lock,
native/client/protocol sources, and release tooling. Tracked or untracked
source symlinks, Git pathspec syntax, traversal, oversized untracked inputs,
and source mutation while hashing are rejected.

The accepted local-install boundary is:

| Target | Required local evidence | Publication boundary |
| --- | --- | --- |
| `macos-arm64` | The published distribution ZIP and manifest bind the source, version, build, and exact locally signed `.app` digest; built and installed app digests match; the ephemeral local integrity signature, Hardened Runtime, normalized outer Release entitlements, and empty entitlements on every recursively discovered nested code object match; a new exact process survives the stability window with the challenge; post-launch artifact checks and sidecar smoke pass | App Store, Developer ID distribution, and notarization are not required or claimed |
| `android-arm64` | APK package/version/debuggable/ABI/single-signer/signature-scheme/alignment facts and the exact stored ARM64 native-library digest match the current build manifest; the checked-in tool digest allowlist and controlled macOS ARM64 release-runner class match; the relay CLI is rebuilt from the same checkout before acceptance; install returns explicit success; the installed `base.apk` matches; exact activity launch consumes the challenge and nonce | Play Store and production update identity are not required or claimed; redacted receipts expose only signer-match booleans, never a stable certificate fingerprint |
| `linux-glibc-arm64` | The published distribution TAR and manifest version/build/source/archive bindings match; the final reducer directly verifies Ed25519 over the archive SHA-256 digest using the embedded public verification key; compressed size, entry count, per-entry size, total expanded size, path type, listing time, and extraction time remain within fixed bounds; the same archive is installed on the native ARM64 release runner, starts in the supported bounded session, and passes CLI/GUI smoke | Registry or package-repository publication is not required or claimed |

Android certificate material is process-local verification input, not release
evidence. The APK build manifest, distribution manifest, and physical
install/launch receipt publish only `signerIdentityVerified` and
`signingPolicySatisfied` conclusions. They never serialize a certificate
digest, fingerprint, subject, or other stable signing-identity value.

Local identity and validation signatures authenticate an artifact only within
their declared verification policy; they do not imply a production platform
publisher. When a named platform channel is explicitly requested, a separate
non-public channel-status receipt reports only bounded pass/fail proof classes
for publication and continuity; it omits the publisher identity and protected
channel metadata. An absent or failing channel receipt does not block
development, ordinary builds, client functionality, or GitHub Release
readiness, and cannot substitute for required exact-artifact checks.

Public GitHub Release receipts expose only artifact identity, target/version,
digest, verification outcome, signature or attestation, and the public
verification material strictly required to authenticate the official package.
They never expose publisher accounts, team/store identifiers, certificate
subjects or stable fingerprints, credentials, private keys, custody details,
or private-channel infrastructure.

The manual GitHub workflow requires an explicit Release tag and exactly one
release-supported target per dispatch. Different targets build independently
and may run concurrently for the same tag. A target publisher waits only for
its own build; only the same-tag asset append and manifest replacement are
serialized. The publisher creates or reuses a same-source draft or published
Release, merges the new target with already verified target assets, rebuilds
the canonical consumer manifest, and verifies the exact remote set. The Release
remains a draft unless `publish_release` is selected; a later target may also
extend an already published same-source Release. GitHub repository write
authority is the only publication authority used by this path. Platform
publisher identity, store accounts, notarization credentials, listing metadata,
and private update-channel access are neither read nor accepted as prerequisites.

On Linux, automatic host selection is permitted only when glibc can be proven.
For an ambiguous libc, set `LICO_CLIENT_RELEASE_TARGETS=linux-glibc-arm64`
explicitly after confirming the intended target.

The canonical output schema is
`tools/scripts/config/client-artifact-verification-receipts-report.schema.json`.
It excludes absolute paths, runtime or device identity, device model, signing
identity, key material, certificates, and raw command output.

The final acceptance reducer runs the artifact producers before its explicit
generic-evidence DAG. Every generic producer receives the same closure
challenge and a distinct nonce. Before publication, the reducer re-hashes all
reports and producers, rechecks the support matrix and target catalog, and
performs a second direct artifact plus manifest/signature/entitlements state
capture. Any replacement between checks blocks the report. The fixed canonical
output is removed before config parsing, so a config or producer failure cannot
leave an older green report in place.

The macOS final local-install path is `npm run client:install:macos`. In GitHub
Release automation, a short-lived local integrity identity is generated inside
the isolated runner; it is not a publisher identity and is never published.
For a local developer install with no explicit identity, the command installs
the build pipeline's already verified ad-hoc-signed app and does not select or
modify an existing developer identity. An explicit
`LICO_MACOS_LOCAL_SIGNING_IDENTITY` selects the identity-signed integrity path
used by release automation.
The installer re-signs the app, verifies the local integrity signature,
atomically installs the exact app, and emits a redacted preparation receipt.
The subsequent macOS capability producer launches the installed app and issues
the canonical install/launch/smoke evidence. A separately requested platform
channel may supply its own protected signing identity, but that path is not a
GitHub Release prerequisite.

Run the side-effect-free negative suite with:

```bash
npm run client:verify:artifact-verification-receipts:self-test
npm run client:verify:release-artifact-io:self-test
npm run client:verify:source-state-digest:self-test
npm run client:verify:linux-tar-resource-bounds:self-test
npm run client:verify:android-apk-zip-facts:self-test
npm run client:verify:android-release-toolchain:self-test
npm run client:verify:release-report-schema:self-test
npm run client:verify:macos-nested-code-bounds:self-test
npm run client:verify:package-client:self-test
npm run client:native:smoke:policy:self-test
npm run client:verify:closure-producer-writer:self-test
npm run client:verify:client-release-acceptance:self-test
```

`client:gate:release-policy` runs these side-effect-free release tests only for
the `stable` → `release` promotion. It is independent from the Node-only source policy
and from all platform build lanes. The real reducer, which may install, launch,
or start a bounded platform session for an explicitly selected target, is
invoked through `client:verify:product-line-security` only. The GitHub artifact
gate is `client:verify:github-release`; it consumes source/version-bound
artifact manifests and public consumer-verification files, and it does not
consume physical custody, device, KT/MLS, or independent-review evidence. The
single public `LicoUp-consumer-verification.json` is rebuilt after the publisher
has downloaded the existing same-source assets, merged exactly one target, and
rejected every unexpected file.
