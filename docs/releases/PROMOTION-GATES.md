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

The stable proof uses an ephemeral runner-local integrity identity. It is not a
publisher identity or a release artifact, and neither the installed app nor its
local proof is carried into publication.

Promotion readiness is not publication. The manually authorized workflow in
`.github/workflows/client-release.yml` remains the sole path that builds formal
artifacts and creates or updates a GitHub Release from `release`.
