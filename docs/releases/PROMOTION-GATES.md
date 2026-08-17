# Client promotion gates

[Documentation index](../README.md) · [简体中文](PROMOTION-GATES.zh-CN.md)

English is normative. The GitHub default branch remains `release`; default-branch
selection is independent from the direction in which changes are promoted.

| Pull request edge | Required aggregate | Claim established |
| --- | --- | --- |
| temporary branch → `nightly` | `Client required` | Source policy and only the changed Flutter, Rust, Android, or dependency regression lanes pass. Release policy is not part of this edge. |
| `nightly` → `stable` | `Stable client` | The macOS ARM64 client is built and installed once on `macos-15`, then the exact installed app is launched and observed through its bounded survival proof. |
| `stable` → `release` | `Release ready` | Node-only release authority and publication-readiness contracts pass without building, installing, launching, signing for publication, or publishing a client. |

`Branch flow`, `Commit identity`, and `Auditor` remain common required checks on
all three destination branches. Each branch additionally requires only the
aggregate owned by its incoming edge.

The stable proof uses the repository's ordinary local ad-hoc package path. It
uses no publisher identity, repository credential, or notarization secret. The
installed app and its local proof are not carried into publication.

Promotion readiness is not publication. `client:promotion -- train` cuts one
verified snapshot onto `release`. Later commits on `nightly` are a later cut,
not that in-flight version. Public publication is only from exact
`origin/release` (a clean detached worktree and
`npm run client:release:macos:publish`, or the manually authorized workflow in
`.github/workflows/client-release.yml`). Never publish from `nightly` or
`stable`.

During an in-flight publication, `nightly` stays open for ordinary
action-prefixed merge-commit pull requests. Do not run `nightly` → `stable` or
`stable` → `release` again until the current publication succeeds or is
explicitly abandoned.

## Repeatable promotion

Preview the next valid edge without changing GitHub:

```sh
npm run client:promotion -- plan
```

After the current action-prefixed branch is committed and locally verified,
one command pushes it and advances all three pull requests. The command waits
for each destination's required checks, uses merge commits, and stops on the
first failed check or invalid topology:

```sh
npm run client:promotion -- train
```

To resume only one edge, run `advance` with its exact source and destination:

```sh
npm run client:promotion -- advance --head nightly --base stable
```

The promotion command never dispatches `.github/workflows/client-release.yml`.
Artifact preparation and publication remain separate, explicitly authorized
actions after `release` is ready.
