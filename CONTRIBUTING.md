# Contributing

English · [简体中文](CONTRIBUTING.zh-CN.md) · [Home](README.md)

Thank you for helping LicoUp. Keep each change small enough to review and
test as one clear client feature, module, or flow.

## Set up

You need Node.js 22 or 24 for the source policy. Install Flutter, Rust, Java,
and Android tooling only when the affected technology lane requires them.

```bash
npm ci
```

During development, run the smallest relevant checks. Before handoff, run the
targeted tests for the changed module. After every intended change is confirmed
effective, run the mandatory Node-only source policy once and only the affected
Flutter, Rust, Android, or dependency regression lanes. These lanes are
independent and may run in parallel. Release policy is not a changed-path lane;
it runs only at the `stable` → `release` promotion edge described in the
[client promotion gate authority](docs/releases/PROMOTION-GATES.md). The commit
gate never builds or publishes every platform.

Starting a complete regression expands the current verification closure to
every problem it reveals. Do not hand off with a known failure, stale golden,
layout overflow, timeout, or flaky test from that run. Diagnose and fix its
canonical owner, add or tighten a focused regression, and inspect visual diffs
before updating any golden. During repair, rerun only the affected slices; when
all reported problems are closed, run one final complete regression and require
it to pass. If an external condition makes closure impossible, stop and obtain
an explicit maintainer decision instead of calling the problem pre-existing or
out of scope.

```bash
npm run client:gate:source
npm run client:gate:flutter         # Flutter changes only
npm run client:gate:rust            # Rust changes only
npm run client:gate:android         # Android changes only
npm run client:gate:dependencies    # dependency authority changes only
```

Build-producing tests share one managed compiler target. The test runner holds
an active lease while a build is using it and marks the output reclaimable on
every terminal path. Inspect or remove only inactive, marked output with:

```bash
npm run client:artifacts:status
npm run client:artifacts:prune -- --dry-run
npm run client:artifacts:prune
```

Pruning never removes Cargo, Pub, Gradle, SDK, or toolchain download caches, so
the next build can continue to reuse downloaded dependencies. Unmanaged legacy
targets are reported but are not deleted automatically. After an abnormal test
exit, a structurally valid dead lease remains protected for a grace period and
only then becomes reclaimable; malformed or tampered records always fail closed.

When every locked dependency is already cached, the dependency audit has a
separate offline form: `npm run client:deps:audit:offline`. It does not cause
unaffected language or platform lanes to run.

## Commit identity and authorship

Every newly created commit must carry exactly one authenticated developer
identity. The repository Git identity must match the account currently
authenticated by GitHub CLI. Existing human-authored history keeps its original
Author and Committer metadata when it is consolidated or published. After
cloning the repository, and whenever `gh auth` changes to a different account,
install the repository policy:

```bash
npm run repo:identity:install
npm run repo:identity:verify
```

The installer uses the account's canonical GitHub noreply address and enables
the repository-controlled `pre-commit`, `commit-msg`, and `pre-push` hooks.
The hooks inspect every commit that is not already reachable from the selected
remote, not only `HEAD`. They reject Agent-shaped Authors, Committers, and
attribution lines while allowing historical human identities and GitHub's merge
service. Missing, redirected, modified, symbolic-link, or non-executable policy
files fail closed. Never use `--no-verify`, change `core.hooksPath`, or otherwise
bypass these gates.

An Agent may assist a developer, but it must never replace, overwrite, or claim
the developer's authorship. An Agent's name, email, or other contact details
must not appear as an Author, Committer, co-author, sign-off, attribution
trailer, or identity-shaped line. Known Agent and bot identity forms are
rejected locally and remotely, and all attribution trailers are forbidden so an
unknown Agent cannot enter the contributor graph as a secondary identity. No
metadata rule can identify an Agent that deliberately impersonates an ordinary
human identity; the trust boundary for that case is the repository-controlled
hook, the authenticated GitHub identity, and the developer's personal review
before committing.

## Privacy rules

- Never commit secrets, local paths, user content, account data, device details,
  logs, or raw runtime reports.
- Use synthetic, redacted test data. Test frameworks may be public; real user
  and system data may not.
- Keep sensitive data on the client. Peer content must be encrypted before it
  leaves the sender.
- Do not add a general path that sends user content or runtime data to a
  service.
- Any allowed external transfer must require a fresh direct user approval bound
  to the exact destination, purpose, scope, and content digest.

## Native interface consistency

The Flutter client and the Rust native core share two interfaces:

- Generated contract types, owned by `schemas/client_bridge/` and generated
  into Dart (`apps/desktop/lib/src/contracts/generated/*.g.dart`) and Rust
  (`crates/licoup-native/src/ffi/generated/*.rs`) from one schema.
- The native CLI command surface (`licoup.stdio.v1` frames and one-shot
  arguments). The Rust side admits options through `admitted_params` in
  `crates/licoup-native/src/ffi/commands/`; the Flutter side sends them from
  `apps/desktop/lib/src/platform/native_client/`.

The packaged app carries its own sidecar, so a running app keeps the old
native binary until it is rebuilt. Rebuild and verify the client bundle
after any native interface change.

## Documentation rules

- Use short sentences and common words.
- Keep English as the normative public entry and link each maintained
  Simplified Chinese localization back to it. Shared product facts in the two
  root READMEs change together.
- Use a small Mermaid diagram when a data flow is hard to explain in text.
- Keep product text focused on diversity, connection, openness, integration,
  and user control.
- Treat `README.md` as the public product page. Check every claim.
- Keep structured plans under `docs/plans/`. Keep audit reports, temporary
  proposals, and other one-off documents under `docs/reports/`. Both paths are
  local only.
- Do not add local skills or temporary scripts to the repository.

## Maintained model and cost tables

Each maintained model, Agent, benchmark, capability table, and model cost table
has one current checked-in authority. The table freshness identity is a
non-empty ISO date in `last_updated`; do not add table `schema_version`,
`catalog_version`, `as_of`, `snapshot_date`, or parallel/versioned copies.
Before a release, review every official HTTPS source, refresh the date, and
remove rows that are no longer served. Never retain a generated or compatibility
cost source beside the current catalog.

## Parallel next-version work during a release freeze

LicoUp uses one release train. The release window starts when a candidate is
cut from the latest verified `nightly`. It ends only after the release passes
the final public download, source and digest verification, public-path install,
stable launch, and published-update checks described below, or after the
candidate is explicitly invalidated and the release is abandoned.

The project must complete 100 distinct releases before promoting any build to
the `1.0.0` line. Every pre-1.0 release keeps its own immutable version,
candidate evidence, and artifact receipts; skipped or replaced candidates do
not count as releases.

Work for the next version may continue during this window, but it must remain
isolated:

- Keep the frozen candidate and next-version branch in separate Git worktrees.
  Never use the candidate worktree, build output, or preflight receipt for
  next-version development.
- Use an ordinary action-prefixed branch such as `feature/<topic>` or
  `fix/<topic>`. The branch may build and test the next version, but it has no
  authority to prepare, promote, or publish the frozen release.
- Freeze ordinary merges into `nightly`. Only the candidate promotion may
  enter it. If a release blocker is found, invalidate the candidate first,
  merge one approved focused fix through an ordinary pull request, and cut a
  replacement candidate.
- Do not merge next-version or unrelated work into `nightly`, `stable`, or
  `release` until the window closes. After verified success or explicit
  abandonment, unfreeze `nightly` and merge the next-version branch through a
  normal merge-commit pull request.

This keeps, for example, `0.1.1` development from changing a frozen `0.1.0`
release. It does not create two simultaneous `stable` or `release` lanes.

## Pull request checklist

Finish product changes, refactors, migrations, release tooling, workflows,
Rulesets, identity policy, and Auditor policy through separate ordinary pull
requests before starting a release. A release candidate must start from the
latest verified `nightly` and contain only the version, build, target, and
release-manifest changes produced by the canonical release command. Never copy
an entire working tree into a candidate or carry a known gate failure,
unfinished migration, stale verifier, or unexpected path. Review the complete
`origin/nightly...HEAD` diff before running preflight.

Use a clean committed branch named
`release-candidate/v<version>-<target>` and run the one local preflight on the
target's real platform:

```bash
npm run client:pr:preflight -- --base origin/nightly --target <target> --full-target
```

The preflight builds, signs, archives, installs, updates, rolls back, and
launches the exact candidate, then writes an ignored redacted receipt. The
pre-push hook only checks that receipt. It does not repeat the expensive work.
Keep the candidate branch local until this receipt passes for every selected
package target. Only then may the exact verified commit be pushed or used to
open a remote release-candidate pull request; remote branches are never a
packaging or signing debug loop.
Preflight is final acceptance, not a development loop. If it finds a defect
outside the release-only diff, invalidate the candidate. Fix the canonical
owner through an ordinary pull request, merge it to `nightly`, and cut a new
candidate; do not patch product code, a verifier, a workflow, or a Ruleset on
the failed candidate.

Opening the candidate pull request freezes its HEAD, required checks, Rulesets,
branch topology, identity authorities, Auditor policy, workflow contract, and
asset contract. Do not open or update it when the receipt is missing or stale.
The exact required checks are `Branch flow`, `Commit identity`, `Client
required`, and `Auditor`. The first unexplained remote failure freezes the
release; no repair pull request, repeated publication, or frozen-authority
change is allowed inside that release window.

A remote build, promotion merge, successful workflow, or draft is not release
success. Success requires downloading the final public assets, verifying their
bound source and digests, installing through the public path, observing a
stable launch, and verifying the published update path. Draft assets may be
reconciled before publication. Once public, the tag, source revision, and asset
set are immutable. A damaged public Release requires an explicitly approved
corrective-release plan with a new verified source and a new build or version;
never replace an asset in place.

- The change has one clear scope.
- Native CLI or generated contract changes keep the Flutter and Rust sides
  consistent in the same change.
- Old paths and old names are removed when a migration is complete.
- New or changed tests use made-up, redacted data.
- Public documentation has matching English and Chinese text.
- No sensitive values or raw runtime output are included.
- New commits use the current `gh` account; published history contains no Agent
  Author, Committer, attribution trailer, or bypassed hook.

LicoUp uses the `AGPL-3.0-or-later` license.
