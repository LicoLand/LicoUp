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
technology lanes: Flutter, Rust, Android, or dependency regression. These lanes
are independent and may run in parallel. Release policy is not a changed-path
lane; it runs only at the `stable` → `release` promotion edge described in the
[client promotion authority](docs/releases/PROMOTION-GATES.md). The commit gate
never builds or publishes every platform.

The maintained complete client regression is a bounded dependency graph. It
runs the shared foundation once, overlaps frontend and backend work, settles
all eligible siblings after failures, and only then reaches integration,
scenarios, and the parallel capability-aware platform/Agent frontier. Use the
dedicated `client:regression:frontend`, `:backend`, and `:integration` entries
for focused work. Use `client:regression:environment -- --platform <id>` or
`--agent <id>` immediately before a live compatibility target. Use
`client:regression -- --retry-report build/reports/client-module-regression.json`
to redispatch failed evidence instead of repeating unrelated successes.
Agent static checks are independently scheduled after one shared inventory
contract, and aggregated Node tests attribute failures through anonymous input
indexes, so one Agent or test file does not invalidate its whole peer batch.

After all intended changes, source review, in-scope repairs, and focused checks
are complete, run the selected complete regression once. If it fails, diagnose
and report the cause, effect, and concrete repair and verification proposal.
The developer decides subsequent repairs and whether to rerun that regression;
do not automatically widen scope, repair, or repeat it. Continue independent
authorized work and report required checks that remain incomplete. Ordinary
implementation and focused-test failures within the accepted scope can be
fixed directly. Promotion failures follow the separate
[promotion gates](docs/releases/PROMOTION-GATES.md).

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

## Format before final verification

Once all writers have finished, run the affected formatters before the final
regression. This is a required preparation step, including for Agent-assisted
work. Review the formatting diff, then run the selected checks.

```bash
npm run client:format              # Flutter and Rust changes together
npm run client:format:flutter      # Flutter changes only
npm run client:format:rust         # Rust changes only
```

The shared entry reuses `dart format` for the same `lib` and `test` roots as
the Flutter format check, and `cargo fmt --all` for the Rust workspace. It adds
no formatter dependency. Use only the relevant entry; documentation and Node-only
changes do not require these toolchains. Do not format while another writer is
still editing. If later repairs change source, format those affected sources
again before verification. CI and regression lanes remain check-only: they
report formatting omissions rather than silently changing the source being
verified. Formatting does not stage files or create a commit.

## Local client verification

After a client fix or behavior change, including a bundled Agent prompt or
Skill change, build macOS once and verify that exact installed output:

```bash
npm run client:build -- --platform macos
npm run client:install:macos -- --launch-installed --verify-stable
```

Do not substitute `client:run:macos`; it rebuilds. Ordinary documentation and
tests without product binary impact do not require a client build or launch.
Honor an explicit request to skip installation and report the remaining
verification. Local installation does not authorize signing, notarization,
source promotion, public publication, or production changes.

## Agent guidance

Keep AGENTS.md to stable boundaries and task links. Shared development Skills
are maintained in `lico-dev`; this repository bundles only `licoup-guide` for
operating LicoUp. Independent planning Skills remain with their own projects.
Read a Skill only when explicitly requested or when its
purpose and trigger match the actual task; a project or model name alone is
not a trigger. Skill descriptions state purpose, trigger, and exclusions.
Keep SKILL.md as a minimal route to task-specific references or existing tools.
A bundled Skill must remain usable with the resources its loader supplies.

User instructions override Skill guidelines. Ordinary authorized work proceeds
without repeated approval; obtain any missing authorization before the actual
protected or irreversible effect. Reading a runbook or an example does not
authorize its operations. If guidance blocks work, identify its exact source,
quote the relevant rule, and explain what decision or authority is missing.

Scale planning and tests to the change. Delegate only useful independent work,
with clear ownership and no fast mode. Allow at least a 10-minute observation
window for ordinary delegated work and 30 minutes for large work, split into
host-supported waits with progress updates. These windows are not deadlines;
a wait returning does not prove completion or permit cancellation.

## Agent-assisted contribution

An Agent may assist your work, but you remain the author of every commit. If
an Agent takes part in your contribution, prepare in this order before the
first commit:

1. Clone the repository and run `npm ci`.
2. Authenticate GitHub CLI with your own account, then install and verify the
   repository identity policy:

   ```bash
   gh auth login
   npm run repo:identity:install
   npm run repo:identity:verify
   ```

   Commits created before the hooks are installed fail the push-time and
   remote identity checks and must be repaired in history.
3. Disable your Agent tool's commit attribution. Most tools add a
   `Co-Authored-By`, `Generated-by`, or "Generated with" line by default (for
   example, Claude Code's `attribution` setting). The local hooks and the
   remote identity check reject every attribution trailer and every
   Agent-shaped identity.
4. Review the Agent's output yourself. Commit only changes you have read and
   accepted, under your own authenticated identity. The full policy is in
   [Commit identity and authorship](#commit-identity-and-authorship).

Start each change on one action-prefixed branch (`feature/`, `fix/`,
`docs/`, `refactor/`, `test/`, or `chore/`) and open a merge-commit pull
request to `nightly`. The contract is the
[Pull request checklist](#pull-request-checklist). During development, run
the smallest relevant checks. Before handoff, run the source policy once
plus only the technology lanes your change touches, as listed in
[Set up](#set-up).

## Platform permissions

Request an OS privacy permission only when the current user action needs that
resource. Automatic Agent discovery probes only the Agent Scan Path Manifest
and must not walk PATH, Desktop, Documents, Downloads, Pictures, Music, the
photo library, the media library, network volumes, or unused Agent stores. A
usage string, entitlement, or plugin that the current action does not use must
not ship.

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

- **Strict Single Source of Truth (SSOT)**: Every architectural model, protocol specification, feature mechanism, or platform rule must have exactly one authoritative owning document (see [ADR 0009](docs/adrs/0009-single-source-of-truth-documentation-architecture.md)). Other documents must reference that owner rather than duplicating or paraphrasing facts.
- **Overview Document Modularity & Domain Indexing**: Top-level overview documents (architecture, protocols, functionalities) must remain concise and high-level, using structured Markdown tables to index and navigate to dedicated domain specifications.
- **Tabular Document References**: Header cross-references (normative versions, localizations, governing product charters) must be presented in structured Markdown tables.
- **Language & Synchronization**: Keep English as the normative public entry and link each maintained Simplified Chinese localization back to it. Shared product facts in the two root READMEs change together.
- Use short sentences and common words. Use a small Mermaid diagram when a data flow is hard to explain in text.
- Keep product text focused on diversity, connection, openness, integration, and user control. Design philosophy and product promises belong to `PRODUCT.md`.
- Treat `README.md` as the public product page. Check every claim.
- Keep structured plans under `docs/plans/`. Keep audit reports, temporary proposals, and other one-off documents under `docs/reports/`. Both paths are local only.
- Do not add local skills or temporary scripts to the repository.

## Maintained model and cost tables

Each maintained model, Agent, benchmark, capability table, and model cost table
has one current checked-in authority. The table freshness identity is a
non-empty ISO date in `last_updated`; do not add table `schema_version`,
`catalog_version`, `as_of`, `snapshot_date`, or parallel/versioned copies.
Before a release, review every official HTTPS source, refresh the date, and
remove rows that are no longer served. Never retain a generated or compatibility
cost source beside the current catalog.

## Cut onto `release`; delegate publication

`nightly` is the open integration branch. Product changes land there through
ordinary action-prefixed pull requests, then one accepted snapshot advances by
merge commit from `nightly` to `stable` and from `stable` to `release`.

The project must complete 100 distinct releases before promoting any build to
the `1.0.0` line. Every pre-1.0 release keeps its own immutable version,
candidate evidence, and artifact receipts; skipped or replaced candidates do
not count as releases.

After the cut, post-release macOS publication may be delegated from the exact
`origin/release` revision with `npm run client:release:macos`. Read-only
preflight runs first. One immutable authorization freezes the source and public
installer contract. The delegated service never creates a source candidate,
merges a pull request, or mutates the protected release train.

## Pull request checklist

Finish product changes, refactors, migrations, release tooling, workflows,
Rulesets, identity policy, and Auditor policy through separate ordinary pull
requests. Product work lands on `nightly`; the cut advances only through the
fixed protected train. Public publication is a separate operation from the
exact accepted `origin/release` source and is owned by Apple Release.

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
