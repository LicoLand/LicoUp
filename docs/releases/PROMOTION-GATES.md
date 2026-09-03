# Client promotion and delegated Apple publication

[Documentation index](../README.md) · [简体中文](PROMOTION-GATES.zh-CN.md)

English is normative. The GitHub default branch remains `release`; default-branch
selection is independent from the direction in which verified source is promoted.

| Pull request edge | Required aggregate | Claim established |
| --- | --- | --- |
| action-prefixed branch → `nightly` | `Client required` | Source policy and only the changed Flutter, Rust, Android, or dependency lanes pass. |
| `nightly` → `stable` | `Stable client` | The macOS arm64 client is built and installed once, then the exact installed app is launched and observed through its bounded survival proof. |
| `stable` → `release` | `Release ready` | Node-only release policy passes without rebuilding, installing, signing for publication, or publishing a client. |

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

## Local macOS installation

Build and install a local client with:

```sh
npm run client:build -- --platform macos
npm run client:install:macos -- --launch-installed --verify-stable
```

The installer validates the existing release output, prepares the new payload,
quits running copies and replaces `LicoUp.app` in `/Applications`. Set
`LICO_CLIENT_INSTALL_DIR` for a different destination. Both this command and the
packager's `--install` use the same replacement flow. Other LicoUp copies in the
system, user and selected application directories are removed. Deleted and build
copies are unregistered from LaunchServices; after successful installation,
generated macOS app bundles in this checkout's runnable, bundle and Flutter
product directories are deleted so Spotlight cannot list them as extra apps.
The installed app and package manifest remain. Build again before another
installation or packaging operation that needs those generated app bundles.
Compiler and dependency caches are not removed by the installer.

```sh
npm run client:uninstall:macos
```

Uninstall requires no build. It removes those installed and generated app copies,
the installed package metadata and their system registrations. Repeating it is
safe. Installation and uninstallation preserve personal histories, settings,
keys and other user data. Applications with another product name are not removed
even if they reuse LicoUp's bundle identifier. External archives, mounted images,
and build outputs in other checkouts are not deleted.

## Delegated Apple publication

Nightly and Stable are tracks of one LicoUp identity. Nightly uses
`tools/apple-release/macos-direct-arm64-nightly.json` from `nightly` and the
fixed `nightly` prerelease. Stable uses the existing profile from `release`
and immutable `v{version}` tags. Both manifests bind their track and exact
embedded migration frontier. Stable promotion must be non-prerelease and
strictly newer; a same-version Stable is not offered to Nightly. See
[client update and state migration](../architecture/CLIENT-UPDATE-AND-STATE-MIGRATION.md).

After a same-repository `stable` → `release` pull request merges,
`client-source-release.yml` publishes only the exact merge commit's source.
It verifies the second parent against the accepted stable head and creates
`v{version}`, `LicoUp {version}`, `LicoUp-source-v{version}.tar.gz` and its
`.sha256` companion. The Release body binds `apple-release-source:v1:{revision}`.
It never builds, signs, notarizes, or uploads binaries. Retries preserve public
tags and assets; only a matching draft can finish missing source files.

Apple Release then uses `tools/apple-release/macos-direct-arm64.json` in the
clean existing repository on `release`, equal to `origin/release`. Its complete
product adapter surface is `tools/scripts/macos-release/`: `gate-source.mjs`,
`gate-release-policy.mjs`, `build.mjs`, and `write-update-manifest.mjs`.
Dependency preparation (`npm ci`) is selected by the engine. The build adapter
fixes the stable track and produces `build/apps/desktop/runnable/macos/release/LicoUp.app`;
the update adapter binds tag, repository and version and produces
`build/apple-release/LicoUp-update-manifest.json`.

The engine creates `macos-release-candidate` at the exact release revision,
without a commit or pull request. After preparation and product gates, it pushes
the unchanged candidate and observes successful `Branch flow`, `Commit identity`,
`Auditor`, and `Release ready` jobs bound to that SHA, branch, workflow, run and
attempt before building or signing. Missing/running checks wait on the same
candidate without a cancellation deadline; failures and skipped checks block.
The candidate never merges back and is removed only after public verification.

The mandatory Apple compliance skill delegates to this read-only authority check:

```sh
apple-release compliance check --project . --config tools/apple-release/macos-direct-arm64.json
```

Require `PASS` for the unchanged session before submission. The check validates
source, metadata, toolchain, both entitlement modes, privacy, profile/certificate,
update keys and notary authority/queue without publishing. An existing `In Progress`
submission blocks a new session. Actual app/archive validation remains mandatory
immediately before upload; build and notary waits have no cancellation deadline.

Apple Release preserves the source pair and appends only the five macOS assets:
`LicoUp-macos-arm64.dmg`, its `.sha256`, `LicoUp-macos-arm64-update.zip`, its
`.sha256`, and `LicoUp-update-manifest.json`. The single public Release therefore
contains seven immutable assets. A conflict stops; public files are never replaced.

Configure the local release authority and inspect release runs with:

```sh
npm run client:release:authority:configure
npm run client:release:status -- --job <job-id>
```

One authorization precondition applies: export the two update signing keys
(`LICO_UPDATE_OFFLINE_ROOT_KEY` and `LICO_UPDATE_ONLINE_SIGNING_KEY`, Ed25519
PEM) before configuration so they are registered into the Keychain; they may be
unset afterwards. A run with either key missing is blocked at preflight.

An explicitly authorized publication starts with one command:

```sh
npm run client:release:macos:nightly:publish
npm run client:release:macos:publish
```

The first command updates the fixed Nightly prerelease from `nightly`; the
second publishes an immutable Stable release from `release`.

The version and build come from the version document at the frozen `release`
revision. `npm run client:release:macos -- --version <version> --build <build>`
remains the interactive variant and asks once before authorizing; explicit
values must match that document exactly.

Read-only preflight precedes one immutable authorization. Once authorized, the
CLI launches a detached runner that executes the release; no service
installation is involved. Credentials remain in their owning secure stores,
and retained receipts exclude credentials, account
identity, machine paths, raw output, and runtime data. A tag, draft Release,
notarization result, or uploaded asset alone is not success. Terminal success
requires exact public-asset reconciliation, anonymous installer download,
digest verification, installation, and stable launch.

The final merged promotion publishes source automatically. macOS signing,
notarization and the five platform assets remain separately authorized Apple
Release operations.
