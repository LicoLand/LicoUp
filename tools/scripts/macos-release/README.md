# Apple Release product adapter

This directory is LicoUp's complete product-owned adapter surface for Apple
Release. Apple Release is the sole authority for the macOS publication flow.
LicoUp prepares and validates its own product artifacts; it does not choose the
publication stages, reorder them, authorize remote mutations, or publish by
itself.

## Control and ownership

Apple Release owns the release state machine, stage order, immutable
authorization, source binding, command contract, signing and notarization
sequence, GitHub reconciliation, publication, public verification, retry and
resume semantics, and terminal receipt. Its configuration schema dictates how
this repository exposes gates, builds, inputs, outputs, and update-manifest
generation.

LicoUp owns only product preparation behind that contract: repository gates,
the reproducible macOS app build, bundled product materials, and the signed
update manifest. The adapter may reuse general LicoUp implementation modules,
but Apple Release never references those internal modules directly. Changing
or moving an internal implementation therefore cannot redefine the release
workflow; this directory must continue to satisfy the Apple Release contract.

Control flows in one direction:

```text
one user authorization
        |
        v
Apple Release policy and state machine
        |
        v
LicoUp macos-release adapter
        |
        v
LicoUp product artifacts
```

LicoUp must not duplicate Apple Release orchestration, read publication
credentials from another source, create tags or Releases, submit notarization
jobs, upload assets, or turn these scripts into an independent publisher.
Apple Release must not depend on scattered LicoUp script names or allow LicoUp
to dictate stage semantics: it consumes only the stable adapter commands
declared in `tools/apple-release/macos-direct-arm64.json`.

## Required script inventory

| Script | Apple Release stage | Inputs | Product output | Failure contract |
| --- | --- | --- | --- | --- |
| `gate-source.mjs` | repository source gate | authorized workspace and process environment | successful source-policy receipt on stdout | first failed LicoUp gate exits non-zero and emits its structured failure event |
| `gate-release-policy.mjs` | release-policy gate | authorized workspace and process environment | successful release-policy receipt on stdout | first failed LicoUp gate exits non-zero and emits its structured failure event |
| `build.mjs` | product build | exact authorized source | `build/apps/desktop/runnable/macos/release/LicoUp.app` | any preflight, Flutter, native, packaging, or source-binding failure exits non-zero with a privacy-safe package error |
| `write-update-manifest.mjs` | update manifest | `{tag}`, `{repository}`, `{version}` plus `LICO_UPDATE_OFFLINE_ROOT_KEY` and `LICO_UPDATE_ONLINE_CHANNEL_KEY` supplied by Apple Release | `build/apple-release/LicoUp-update-manifest.json` | mismatched metadata, missing assets or keys, signing failure, or invalid output exits non-zero without printing secrets |

`npm ci` is intentionally not wrapped here. Dependency installation is a
command selected and ordered directly by Apple Release, not a product release
decision owned by LicoUp.

## Five-artifact contract

Apple Release requires and publishes exactly these roles:

1. `installer` — `LicoUp-macos-arm64.dmg`
2. `installer-digest` — `LicoUp-macos-arm64.dmg.sha256`
3. `update-archive` — `LicoUp-macos-arm64-update.zip`
4. `update-digest` — `LicoUp-macos-arm64-update.zip.sha256`
5. `update-manifest` — `LicoUp-update-manifest.json`

These are the five macOS-owned assets, not a second Release. The source workflow
has already created the version's single public `v<version>` Release directly
from `release` with its source archive and digest. Apple Release performs all
macOS work on `macos-release-candidate` and appends the five assets above to
that same Release. It never replaces the source assets, creates another tag or
Release, or merges the platform branch back into `release`.

Apple Release creates and verifies the installer, archive, and digests around
the accepted app. The LicoUp adapter creates the signed update manifest only
after Apple Release has sealed the update archive and supplied the authorized
tag, repository, version, and signing-key environment.

## One-command publication boundary

After the user has completed the one authorization requested by Apple Release,
the repository exposes exactly one publication entry point:

```sh
npm run client:release:macos -- --version <version> --build <build>
```

That command delegates the complete cloud-facing publication lifecycle to
Apple Release. The scripts in this directory are not user-facing release
commands and must never be invoked as a substitute for Apple Release.

When Apple Release changes its product-adapter schema or command contract, the
authoritative change lands there first. LicoUp then migrates this directory,
its declarative configuration, tests, and documentation as one atomic contract
update; obsolete adapters and compatibility entry points are removed.
