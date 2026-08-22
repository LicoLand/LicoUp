# Client promotion and authoritative Apple publication

[Documentation index](../README.md) · [简体中文](PROMOTION-GATES.zh-CN.md)

English is normative. The GitHub default branch remains `release`; default-branch
selection is independent from the direction in which verified source is promoted.

| Pull request edge | Required aggregate | Claim established |
| --- | --- | --- |
| action-prefixed branch → `nightly` | `Client required` | Source policy and only the changed Flutter, Rust, Android, or dependency lanes pass. |
| `nightly` → `stable` | `Stable client` | The macOS arm64 client is built and installed once, then the exact installed app is launched and observed through its bounded survival proof. |
| `stable` → `release` | `Release ready` | Node-only release policy passes without rebuilding, installing, or signing; after merge, the exact accepted source is packaged and published automatically. |

`Branch flow`, `Commit identity`, and `Auditor` are common required checks
on every edge. Each destination additionally requires only the aggregate owned
by its incoming edge. All three edges use merge commits. Rulesets, required
check names, and the default branch are not changed during a release cut.

Preview or advance the fixed train with:

```sh
npm run client:promotion -- plan
npm run client:promotion -- advance --head nightly --base stable
npm run client:promotion -- advance --head stable --base release
```

The promotion command reuses the open pull request for an edge, binds checks to
its exact head, and stops on the first invalid topology or failed check.
`nightly` remains open for later ordinary work. Once a snapshot is cut, do not
promote a later `nightly` tip into the same in-flight publication.

## Automatic source publication

Merging the same-repository `stable` → `release` pull request immediately
triggers `.github/workflows/client-source-release.yml`. The workflow checks out
the exact merge commit, proves that its second parent is the accepted `stable`
head, reads the version from `tools/client-version.json`, and creates a Git
archive plus its SHA-256 digest. It creates the version's single `v<version>`
tag and `LicoUp <version>` Release with exactly these initial assets:

- `LicoUp-source-v<version>.tar.gz`
- `LicoUp-source-v<version>.tar.gz.sha256`

The source workflow cannot build, sign, notarize, or publish the five Apple
assets, and it never invokes Apple Release. Apple Release later appends the five
macOS assets to this same public Release; it does not create a second tag or
Release. A validation, packaging, or upload failure stops source publication
and therefore blocks downstream client packaging. Reusing a source version is
rejected by the existing tag/Release identity; changed source requires a new
product version.

## Delegated Apple publication

Promotion readiness is not publication. The repository stops at a verified
`origin/release` source cut. Post-release macOS Developer ID publication is
delegated to the authoritative Apple Release CLI through
`tools/apple-release/macos-direct-arm64.json`.

Apple Release controls the complete macOS publication state machine. Its disposable
`macos-release-candidate` branch points at the exact authorized
`origin/release` revision; LicoUp neither prepares a separate candidate commit
nor merges that branch into a protected branch. Apple Release verifies its
required checks and publishes the declared tag, Release, and exact five-asset
contract. It never mutates `nightly`, `stable`, `release`, Rulesets, or required
checks. The `v<version>` tag and public Release must already have been created
by source publication. Apple Release's only remote mutations are the frozen
platform candidate branch, the five declared macOS assets appended to that
Release, and cleanup of the platform branch after public verification.

LicoUp's complete product adapter is isolated under
`tools/scripts/macos-release/`. Apple Release dictates the adapter command and
artifact contract; LicoUp only prepares its own gates, app, and update manifest.
There is no LicoUp-owned Apple Release service or alternate orchestration path.

The optional read-only status command is:

```sh
npm run client:release:status -- --job <job-id>
```

An explicitly authorized publication starts with:

```sh
npm run client:release:macos -- --version <version> --build <build>
```

Read-only preflight precedes one immutable authorization. Credentials remain in
their owning secure stores, and retained receipts exclude credentials, account
identity, machine paths, raw output, and runtime data. A tag, source Release,
notarization result, or uploaded asset alone is not success. Terminal success
requires exact public-asset reconciliation, anonymous installer download,
digest verification, installation, and stable launch.

Branch promotion never starts Apple Release and never creates an Apple-only
Release, Apple asset, notarization submission, or update-channel record. It
creates the version's single source-first `v<version>` Release; platform
publishers subsequently extend that same Release with their owned assets.
