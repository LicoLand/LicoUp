# Client promotion boundaries

Updated: 2026-09-25

[Documentation index](../README.md) · [简体中文](PROMOTION-GATES.zh-CN.md)

English is normative. The GitHub default branch is `release`; default-branch
selection is independent from the direction in which verified source moves.

| Pull request edge | Required aggregate | Claim established |
| --- | --- | --- |
| action-prefixed branch → `nightly` | `Client required` | Source policy and the affected Flutter, Rust, Android, or dependency lanes pass. |
| `nightly` → `stable` | `Stable client` | The stable-client acceptance contract passes for the exact source. |
| `stable` → `release` | `Release ready` | The release-policy contract passes for the exact source without claiming external publication. |

`Branch flow`, `Commit identity`, and `Auditor` are common required checks.
Each destination additionally requires the aggregate owned by its incoming
edge. The three edges use merge commits. A pull request must deliver a complete
feature and preserve dependent consumers; a partial protocol or configuration
migration is not eligible to merge.

Run the repository-owned checks selected by the affected module. Release-tool
changes also run:

```sh
npm run client:gate:release-policy
npm run repo:version
npm run repo:version:test
```

The version-source command reads `tools/release/source-version.json`. It checks
the product version sources and changelog, and checks an exact `vMAJOR.MINOR.PATCH`
tag when invoked for a tag. It does not plan a release, track acceptance status,
project work into GitHub Projects, or authorize publication.

Published source and platform artifacts remain separate claims. The
[package contract](../RELEASE-PACKAGES.md) defines the public artifact set and
verification receipts. Local plans, progress reports, machine acceptance
results, signing state, and operator credentials do not belong in the source
repository.
