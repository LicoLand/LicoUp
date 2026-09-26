# Distribution closure, install lock and byte attribution (module M31)

Updated: 2026-09-25

Graph commands require an explicit `--project <local-project.json>`. Local graph
inputs never replace the public module registry or contributor rules.

Reads the same graph documents as the architecture graph tool (module M24) and
answers the deployment questions C08/C12 own: which packages a profile installs,
what removing one would affect, what a real local build produced, and whether the
recorded artifact bytes still match the files.

It never installs, downloads, executes or removes anything, never mutates the
graph or the development ledger, and never marks work complete. A profile is an
initial selection, not a permanent prohibition, so every preview here is a
declaration about a fixed target catalog.

## Commands

```bash
node tools/distribution/resolve/cli.mjs profile standard
node tools/distribution/resolve/cli.mjs removal-preview standard --package org.licoland.adapter.codex --pinned org.licoland.adapter.codex
node tools/distribution/resolve/cli.mjs closure org.licoland.adapter.generic
node tools/distribution/resolve/cli.mjs check
node tools/distribution/resolve/cli.mjs fourth-graph --out build/fourth.json
node tools/distribution/resolve/cli.mjs render --out build/fourth-render
node tools/distribution/resolve/cli.mjs lock build --build build-result.json --artifacts . --out build/install-lock.json
node tools/distribution/resolve/cli.mjs lock verify --lock build/install-lock.json --artifacts .
```

`profile`, `removal-preview` and `closure` are read-only previews. `render`
requires `--out` on purpose: the tool never picks a write location. A verdict
that fails (an ownership gap, a closure mismatch, a lock drift) exits `2` with
its JSON result on stdout; a bad input exits `2` with an error object on stderr.

## The install lock

`lock build` consumes a real local build result
(`licoup.distribution-build.v1`) that names, per package, the artifact files the
build produced, and writes `licoup.distribution-lock.v1`: package versions,
artifact paths, and **byte counts and sha256 values read from the files**. A
declared size or digest is checked against the bytes and refused when it
differs, so a build result cannot launder a claim into a lock. Package roots
must be real, disjoint directories, and a symlinked artifact is refused rather
than followed, so one package cannot attribute bytes outside its own root. The
same inputs produce byte-identical locks, and `lock_digest` covers every field
except itself.

`lock verify` compares the lock with the current graph — package declaration
digests, profile closures and delivery-task fingerprints — and, when
`--artifacts` is given, with the bytes on disk. Drift means recorded evidence is
stale; verification reports it and repairs nothing. Files under a package root
that no artifact claims are reported as unattributed, and `--strict` turns that
warning into a failure.

## Dependency semantics

The closure is the product's closure: `requires` only, unknown packages refused
with the dependent named, `requires` cycles refused, and optional dependencies
reported as declined rather than installed. The plan side reimplements those
declarations and is compared against the executing product:

- `tests/contract/distribution/vectors/catalogue-cases.json` is one shared
  vector corpus with the recorded decisions;
- `tests/contract/distribution/rust-probe/` is a minimal Cargo workspace
  (its own `[workspace]`, no product membership) that consumes
  `crates/licoup-extension-contracts` by path and runs the real `install_closure`
  and `capability_owner` over that corpus, printing machine-readable decisions;
- `tests/contract/distribution/probe.mjs` runs the probe and compares the
  product and plan decisions item by item — selected and declined-optional sets
  for a pass; refusal code, offending field, package and dependent for a
  refusal. Either side changing a decision fails the suite, and the comparison
  itself is tested with mutated decisions so a silently tolerant checker cannot
  pass it.

The probe builds under the ignored `cache/` directory with `--offline --locked`;
it needs no network and adds no product dependency. A machine without `cargo`
records those comparisons as skipped with that reason. The probe has no
production role and never installs, downloads or executes a package.

The fourth graph projection (packages, profiles, provider ownership and the
package → module → contract → task traceability) lives in
`tools/architecture-graph/distribution/`, because the architecture graph tool
owns the typed graph and the first three relation classes.

## Checks

```bash
npm run verify:distribution
```

The suite uses synthetic fixtures and native contract comparisons. It runs without
any developer's personal plan or retained local result.
