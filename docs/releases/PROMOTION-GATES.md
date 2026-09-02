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

## Delegated Apple publication

Promotion readiness is not publication. The repository stops at a verified
`origin/release` source cut. Post-release macOS Developer ID publication is
delegated to the local Apple Release engine through
`tools/apple-release/macos-direct-arm64.json`.

The delegated release run cuts the fixed `macos-release-candidate` branch from
the authorized `origin/release` revision, waits for its required checks, and
publishes the declared tag, Release, and five-asset contract from that
candidate. The fifth asset is the signed update manifest: the configured update
command generates it during the build, the engine uploads it with the other
assets, and it is verified by the same unauthenticated public download. The
engine never mutates `nightly`, `stable`, `release`, Rulesets, or
required checks, and the only remote mutations it may perform are the frozen
candidate and the declared public tag, Release, and assets.

Configure the local release authority and inspect release runs with:

```sh
npm run client:release:authority:configure
npm run client:release:status -- --job <job-id>
```

One authorization precondition applies: export the two update signing keys
(`LICO_UPDATE_OFFLINE_ROOT_KEY` and `LICO_UPDATE_ONLINE_CHANNEL_KEY`, Ed25519
PEM) before configuration so they are registered into the Keychain; they may be
unset afterwards. A run with either key missing is blocked at preflight.

An explicitly authorized publication starts with one command:

```sh
npm run client:release:macos:publish
```

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

Branch promotion never starts a release run and never creates or publishes a
GitHub Release, tag, asset, notarization submission, or update-channel record.
