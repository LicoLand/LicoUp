# LicoUp Runbook

[Documentation index](README.md) · [Contributing](../CONTRIBUTING.md) · [Security](../SECURITY.md)

This runbook contains repository-root operational entry points. `package.json`
is authoritative for command definitions, the regression catalog under
`tools/regression/` owns module selection, and platform packaging scripts under
`apps/desktop/scripts/` own package behavior.

## Prepare a development checkout

Use a supported Node.js version from `package.json`, the Rust toolchain declared
by `rust-toolchain.toml`, and a Flutter SDK compatible with
`apps/desktop/pubspec.yaml`.

```bash
npm ci
npm run client:get
```

Dependency directories, toolchain downloads, and generated metadata are local
assets. They do not enter Git or a release candidate.

## Start a client

Run the platform entry point from the repository root:

```bash
npm run client:run:macos
npm run client:run:android -- --debug
npm run client:run:ios -- --debug
```

Each command returns a nonzero exit code when its required toolchain or target
is unavailable. Stop an interactive development client through its normal
platform UI or the foreground process that launched it. Do not treat a
successful development launch as package, store, or release evidence.

## Build a package

Preview packaging before producing an artifact:

```bash
npm run client:package:plan
```

Then select one target:

```bash
npm run client:build:macos
npm run client:build:windows
npm run client:build:linux
npm run client:build:android
```

Generated packages remain under `build/`. A local build is not a formal release
artifact. Formal artifacts are generated from an exact Git candidate by the
controlled release workflow and are bound to source, target, immutable digest,
and generation metadata.

## Run focused verification

List the maintained regression modules and preview change-based selection:

```bash
npm run client:regression:list
npm run client:regression -- --changed-from <ref> --dry-run
```

Run the smallest owning module:

```bash
npm run client:regression -- --module <module-id>
```

Common focused checks are:

| Change | Command |
| --- | --- |
| Public documents and links | `npm run repo:docs` |
| Repository privacy boundary | `npm run repo:local-info-hygiene` |
| Flutter source | `npm run client:analyze` |
| Flutter behavior | `npm run client:test` |
| Native client | `npm run client:native:test` |
| Client contracts | `npm run client:contracts:test` |
| Architecture boundaries | `npm run client:verify:architecture` |
| Version and generated compatibility | `npm run client:version:check` |

Run `npm run client:gate:source` once after all focused checks pass. Then run
only the affected `client:gate:flutter`, `client:gate:rust`,
`client:gate:android`, `client:gate:dependencies`, or
`client:gate:release-policy` lane. These lanes are independent and may run in
parallel. Source policy is Node-only; it does not install platform toolchains
and is not authorization for live services, runtime-data capture, device
installation, signing, publication, or store operations.

## Diagnose a failed check

1. Re-run the failing focused command, not the complete suite.
2. Inspect `npm run client:artifacts:status` before assuming compiler output is
   stale.
3. Use `npm run client:regression -- --changed-from <ref> --dry-run` to confirm
   module ownership.
4. Keep logs and raw output local. Record only stable error codes,
   repository-relative paths, counts, and irreversible digests in retained
   evidence.
5. If the failure requires a device, credential, network service, installer, or
   publication authority, stop and report that prerequisite before running the
   side-effecting command.

## Recover local generated state

Compiler output managed by the repository lifecycle can be previewed before
reclaim:

```bash
npm run client:artifacts:prune -- --dry-run
```

After reviewing the exact managed targets, run:

```bash
npm run client:artifacts:prune
```

The lifecycle must not remove dependency downloads, SDKs, package-manager
caches, or active compiler output. `build/` and `cache/` contain reproducible
local assets and must never be used as the sole source for a formal release.

## Verify release source

The mandatory side-effect-free source policy is:

```bash
npm run client:gate:source
```

The generated compatibility projection must be refreshed and checked whenever
the product version, target catalog, support catalog, or native driver inventory
changes:

```bash
npm run client:support-matrix:sync
npm run client:support-matrix:check
```

Commands that install or launch on a device, use protected platform identity,
contact a live service, create release assets, or publish through a channel are
separate operator-authorized actions. Their success cannot be inferred from a
source or package build.

The manual GitHub Release workflow accepts exactly one `target` per dispatch.
`macos-arm64`, `linux-glibc-arm64`, and `android-arm64` builds may advance
concurrently for the same tag. Each target waits only for its own build. A
same-tag concurrency group serializes only the final append, merged consumer
manifest, and exact remote-asset verification. Existing same-source drafts or
published Releases may be extended; no platform waits for another platform.

## Maintain documentation

Before editing documentation, run:

```bash
lico-dev context <changed-path>
```

The public document layout is indexed in [`docs/README.md`](README.md).
Architecture, functionality, protocols, examples, and implemented ADRs stay in
their owning directories. Plans and reports stay under ignored `docs/plans/`
and `docs/reports/`; generated or runtime assets stay under ignored `build/` and
`cache/`.

When moving a public document, update its old and new path, master index,
cross-links, bilingual mapping, generators, tests, regression catalog,
packaging/release references, and ignore rules in one change. Delete the old
entry and duplicate fact sources. Use a one-time search during the migration;
do not retain an old-path absence check as a permanent gate.

Before handoff, run:

```bash
npm run repo:docs
npm run repo:local-info-hygiene
```

Formal documents state only implemented and verified behavior. Requirements,
future design, progress, checkpoints, raw audit output, and unverified
conclusions remain local plan or report material.
