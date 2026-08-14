# Client Artifact Consumer Verification Receipts

[Documentation](../README.md) · [Canonical schema](../../tools/scripts/config/client-artifact-verification-receipts-report.schema.json)

This document describes the public receipt format and its verification boundary.
The schema and release tooling are authoritative; this document does not define
an independent receipt contract.

The canonical selected-target receipt is produced by:

```bash
LICO_CLIENT_RELEASE_TARGETS=macos-direct-arm64,android-direct-arm64-v8a \
  npm run client:verify:artifact-verification-receipts
```

The target list is explicit and non-empty. Only selected targets are reduced;
an unselected or deferred target is not an implicit blocker. In one release
closure, the reducer creates a random closure challenge and a distinct random
invocation nonce for every selected target, deletes any previous target report,
and directly invokes the approved platform producer. Therefore selecting
Android can install and launch on the authorized phone, and selecting macOS can
launch the installed app.
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
For macOS it also binds the exact distribution-manifest digest; the
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
| `macos-direct-arm64` | A locally produced DMG and update ZIP bind source, version, build, and exact `.app` digest; every nested executable and the outer app pass Developer ID, Hardened Runtime, secure-timestamp, notarization-ticket, and Gatekeeper checks; the updater requires the exact installed designated requirement and team before replacement | Local-only Developer ID channel. Remote/GitHub publication and Mac App Store submission remain blocked and are not authorized by the receipt |
| `android-direct-arm64-v8a` | APK package/version/debuggable/ABI/single-signer/signature-scheme/alignment facts and the exact stored ARM64 native-library digest match the current build and package manifests; the controlled release-runner class matches; install returns explicit success; the installed `base.apk` matches; exact activity launch consumes the challenge and nonce | Google Play publication is a separate `android-play-arm64-v8a` AAB target; the current direct APK update authority is manual/system installation |

Android certificate material is process-local verification input, not release
evidence. The APK build manifest, distribution manifest, and physical
install/launch receipt publish only `signerIdentityVerified` and
`signingPolicySatisfied` conclusions. They never serialize a certificate
digest, fingerprint, subject, or other stable signing-identity value.

Validation signatures authenticate an artifact only within their declared
verification policy. When the macOS Developer ID platform channel is explicitly requested, a separate
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

Before a release-candidate pull request, run the single project preflight for
the selected package target set on its real platform. It binds the clean
candidate HEAD, tree, version, ordered target set, release template and every
final installer digest to one redacted receipt.
The pre-push hook checks that receipt only; it never repeats build, install,
update or launch work. The exact required checks are `Branch flow`, `Commit
identity`, `Client required` and `Auditor`.

The receipt proves only its bound evidence; it does not approve an arbitrary
candidate scope. Before preflight, review the complete diff from the latest
verified `nightly`. Product, refactor, migration, release-tooling, workflow,
Ruleset, identity, and Auditor changes must already be merged through ordinary
pull requests. The candidate may contain only canonical version, build, target,
and release-manifest changes. A known gate failure, unfinished migration,
unexpected path, or deterministic preflight defect invalidates the candidate
and returns work to an ordinary branch; preflight is never a development loop.

The manual GitHub workflow requires an explicit Release tag and one or more
release-supported package targets per dispatch. Remote validity currently has
one active strategy, `build-success`: every selected package must build
successfully from the immutable release revision. The publisher creates or
reuses one same-source draft, refuses conflicting existing assets, verifies the
complete remote set, and publishes at most once. Repeating the same input reuses
the same Release and asset set without overwriting it.

`build-success` is only the remote reproduction claim. Overall release
acceptance additionally requires downloading the final public assets,
verifying their bound source and digests, installing through the public path,
observing stable launch, and verifying the published update path. Draft assets
may reconcile before publication. After publication, the tag, source revision,
and asset set are immutable. A damaged public Release requires a separately
approved corrective-release plan with a new verified source and a new build or
version; an existing public asset is never overwritten in place.

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

The supported macOS direct-distribution path is a separately authorized,
local-only Developer ID platform channel. It verifies every nested executable
and the outer app for the expected Developer ID team, Hardened Runtime, secure
timestamp and bounded entitlements, then requires notarization, stapling and
Gatekeeper acceptance for the final artifacts. Protected signing and
notarization inputs are never materialized by GitHub Actions, and both macOS
direct targets are rejected by the generic remote publication workflow. The
legacy self-signed install/archive entry points are disabled.

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

`client:gate:release-policy` runs these side-effect-free release tests only when
release authority changes. It is independent from the Node-only source policy
and from all platform build lanes. The real reducer, which may install, launch,
or start a bounded platform session for an explicitly selected target, is
invoked through `client:verify:product-line-security` only. The GitHub artifact
gate is `client:verify:github-release`; it consumes source/version-bound
artifact manifests and public consumer-verification files, and it does not
consume physical custody, device, KT/MLS, or independent-review evidence. The
single public `LicoUp-consumer-verification.json` is rebuilt after the publisher
has downloaded the existing same-source draft assets, merged exactly one
explicitly selected target before publication, and rejected every unexpected
file. It is never rebuilt to extend an already public Release.
