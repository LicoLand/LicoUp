# LicoUp developer guide

Updated: 2026-10-01

[简体中文](RUNBOOK.zh-CN.md) · [Documentation](README.md) · [Contributing](../CONTRIBUTING.md) · [Security](../SECURITY.md)

`nightly` is the only integration trunk. Product work enters through the pull
requests described in [Contributing](../CONTRIBUTING.md); the protected promotion
train advances from `nightly` and receives no direct development commits. This
guide explains LicoUp's boundaries and design trade-offs; tests and configuration
own executable behavior.

## Investigation before design

Investigation is a prerequisite for planning, Designer dispatch, informed requirements
discussion and project edits. Bound it to the requested outcome and its actual
dependencies. Inspect the applicable rules and historical requirements, trace current
production producers and consumers, and review existing contracts and engineering
coverage. Verify claims of completion against current source; distinguish shipped
capabilities, partial implementations, absent wiring, unverified behavior and retired
proposals. Resolve contradictions and discoverable questions before proposing work.

The lead may parallelize independent read-only investigations, but must consolidate
their evidence before design begins. The Designer receives the requested outcome,
source-grounded baseline, requirement provenance, dependency boundaries and remaining
maintainer decisions together. Do not ask the maintainer to approve guessed groupings
or repeat facts available in the repository or supplied history. Until discovery is
complete, questions are limited to missing access or information needed to investigate.
Unavailable evidence remains explicit and dependent design stays pending.

Record the findings in the existing private work record, without another permanent
report or enforcement mechanism. After consolidation, discuss consequential choices,
design the selected scope and obtain any required approval before implementation.
New contradictory evidence reopens the affected investigation before revising its
design; it does not authorize extending the delivery scope.

## Requirements and milestone boundaries

After completing investigation, discuss requirements before implementation. Resolve
consequential questions about scope, design, contracts, authority, dependencies and
completion with the maintainer; record the decision and its rationale in the local
work record. Investigate first and present concrete options. Do not infer approval
from a plan or from silence. Routine in-scope implementation decisions and repairs
need no renewed approval.

Select one approved milestone with a finite outcome and stopping condition, and keep
one milestone active at a time. Resolve its inherited defects and superseded paths
before extending it. Give independent ready tasks within the milestone separate
owners and run them in parallel. Preserve dependency order and exclusive ownership
of shared integration files. Later milestones remain inactive until the approved
progression condition is met. Stop at the selected milestone's engineering handoff;
an explicit finite programme assignment may authorize continuing to the next
dependency-satisfied milestone after the current milestone is reviewed and its
delivery is recorded, but nothing else advances the roadmap automatically.

Static source review must examine the complete production path, affected contracts,
data ownership, state transitions and failure/recovery behavior. Resolve its findings
alongside focused tests before final deterministic regression. Passing tests alone
cannot replace this review, and static review alone cannot prove runtime behavior.
Report missing implementation, failed checks and live-only unknowns separately.

Client packaging, installation, real-data transition, launch and live acceptance are
centralized on the integrated candidate by the assigned delivery owner. Module Agents
do not perform these actions during implementation. Necessary compilation and
synthetic unit, contract and isolated integration tests remain engineering work.

## Agent collaboration

These role rules apply to Agents; human contributors need not simulate Agent teams.

- Designers start from the lead's consolidated investigation and identify every
  affected module and boundary before assigning work. Give each module a distinct
  owner and explicit create/edit/delete scope. A contract change includes its
  producer and consumers, with one owner for shared files.
- Module implementers read the owning tests, configuration and architecture document,
  stay in their assigned scope, and notify the designer when a neighboring contract
  must change. Do not edit another owner's files or revert their work. Independent
  module work may run in parallel.
- Reviewers integrate the module commits, inspect both sides of changed boundaries,
  then verify the complete feature. The lead prepares the integrated PR. Corrections
  may be later commits; each affected module needs an attributable commit.

Discover the registered checks for a changed path with the regression catalog:

```sh
npm run client:regression:list
npm run client:regression -- --changed-from <ref> --dry-run
```

Catalog selection maps changed paths to the registered suites that cover them. It is
not a complete impact graph: an unmapped path needs an ownership review, the affected
producers and consumers still need manual inspection, and a plan is never evidence
that the dependency is covered.

### One writer per working tree

Parallel work needs separate working trees, not separate intentions. Two writers in one
checkout do not merely collide in Git: they compile each other's half-finished moves, and a
green gate then describes a tree that never existed. The dispatcher is a writer too — while
another Agent holds a task in a checkout, the dispatcher reads and plans there, it does not
edit.

Give each concurrent workstream its own worktree:

```sh
git worktree add ../LicoUp-android feature/android-native
git worktree add ../LicoUp-ios feature/ios-native
```

`build/` is ignored, so every worktree gets its own Cargo target directory, fixture roots,
leases and generated reports without configuration, and each worktree's verification describes
only its own changes.

Work may run in parallel when the file sets are disjoint — a delivery that rewrites `crates/`
and a mobile delivery that writes its own application root do not touch the same files. Work
must stay ordered when it shares files: two tasks that both rewrite a crate manifest and its
module wiring are one writer at a time, in one tree, however independent their subject matter
looks. A plan that runs such tasks "in parallel" has not ordered them.

The complete regression derives its concurrency from the machine's core count; this
revision's runner accepts no explicit budget option. When another worktree or a long
build shares the host, select only the affected modules instead of running the whole
regression, and state that the host was shared when a result is reported, because the
same command on the same host is a different measurement at a different budget.

## Start

Use the Node, Rust and Flutter versions declared by the package and toolchain
manifests. Run `npm ci` and `npm run client:get` when preparing a checkout. The
explicitly assigned client operation uses `npm run client:run:macos` (or the
corresponding Android/iOS command); repository setup does not authorize launching
the client.

## Design boundaries

Keep domain decisions, host effects, transport and presentation in separate modules.
Interfaces belong to their consumers; a UI projects domain state instead of owning a
second lifecycle. Name modules by responsibility. Preserve documented support
obligations for published contracts when reorganizing implementation. Apply the
[development-state policy](../AGENTS.md#development-state-and-corrections) to
unpublished project-owned code: correct defective contracts and their producers,
consumers, tests and documentation together. Existing implementation is not evidence
that its behavior is required. Resolve inherited defects in the selected feature
before adding behavior; remove the replaced path instead of versioning the mistake.

A state machine's transition configuration is its authority; its executor loads that
configuration. Do not maintain a second transition table in prose or handwritten
branching code. Tests assert behavior against the configuration. Register each
machine with its configuration, executor and owning verification in
`tools/development/state-machines.json` so the report and reviewers can find it. The
registry and its report page list registered sources; they do not validate, generate
or execute a machine. Compilation and behavior are verified by the owning tests — the
code-generation suite under `crates/licoup-state-machine-codegen/tests/` and the
owning module's catalog command. Edit the configuration, never a generated table.

## Module ownership and registered checks

The regression catalog under `tools/regression/` owns module selection and the
registered commands. `npm run client:regression:list` lists the modules, and the
owning architecture documents under `docs/architecture/` hold boundaries and design
contracts. This revision does not ship per-module developer guides: read the owning
tests, configuration and architecture document before editing a module. Catalog
selection answers which registered suites cover a changed path; review the affected
producers and consumers manually and report an unmapped path as an ownership gap.

## Development and verification

Run the owning module's registered command, for example:

```sh
npm run client:regression -- --module <module-id>
```

Discover module ids and narrower existing suites with `npm run client:regression:list`.
During development run only affected suites. Shared semantic or transport changes
include their dependent consumers; adapter-specific changes stay with that adapter.
Use synthetic, redacted test data. Do not launch real Agents or live services without
an explicit request.

Before handoff, map every requirement in the approved delivery scope to its production
implementation and engineering evidence. Complete missing behavior and wiring; do
not reduce the scope to one successful demonstration. Distinguish an implementation
gap from a completed implementation whose external behavior still needs live confirmation.

Verify DSL parsing and semantics, configured transitions and guards, scheduling,
cancellation, storage and recovery through the actual owners with deterministic
inputs, synthetic events and isolated integration fixtures. Mock external boundaries,
not the production logic being verified. Include the affected production composition
so that a passing pure core does not conceal missing application wiring.

Real Agent conversations and development tasks belong to a separate user-assigned
acceptance workflow. The implementation owner must finish all verification that can
be performed without those calls before delivering the buildable, locally runnable
client. Identify the specific live-only claims at handoff and leave them unverified;
do not invoke Agents or create live acceptance tasks to substitute for that work.
Authorized building, installation, data migration and application launch do not
authorize Computer Use or reading and exercising the live client interface. Stop
at the requested launch and report the tool results; do not initiate UI acceptance
under the name of a startup check.

Keep each change independently verifiable. Before final checks read
[Closure](CLOSURE.md), resolve findings in the changed scope, and finish source review.
All writers must finish before global regression. Unavailable checks stay unverified.

### Run focused verification

List the maintained regression modules and preview change-based selection:

```bash
npm run client:regression:list
npm run client:regression -- --changed-from <ref> --dry-run
```

Run the smallest owning module:

```bash
npm run client:regression -- --module <module-id>
```

The complete client regression is one capability-aware staged run:

```text
foundation -> (frontend || backend) -> integration -> scenarios -> compatibility
```

Use a dedicated stage entry while developing, and use the standalone probe
before investigating a platform or Agent runtime:

```bash
npm run client:regression:frontend
npm run client:regression:backend
npm run client:regression:integration
npm run client:regression:environment -- --platform android
npm run client:regression:environment -- --agent codex
```

Frontend and backend work run concurrently after the shared foundation.
Locally eligible platform and Agent targets run concurrently after the core
stages settle. Missing optional hosts, SDKs, devices, or Agent executables are
recorded as `unverified`; they do not become false passes or fail the core.
Agent static validation runs one shared inventory/schema contract followed by
independent per-Agent contracts, so one broken adapter blocks only its own live
branch. Aggregated Node tests use an anonymous numeric reporter to attribute
failed inputs back to module IDs; a retry therefore selects the failing
members rather than the entire batch. Incomplete attribution remains
`attribution-pending`.
Each command records wall time and an honest measured/unavailable resource
schema. Rust additionally records Cargo/libtest-native timing facts, and
Flutter reduces its JSON reporter stream to anonymous counts and durations.
The report is written privately to
`build/reports/client-module-regression.json` without command output, paths,
arguments, environment values, PIDs, or runtime payloads.

Redispatch only the failed, attribution-pending, or blocked core members and
failed compatibility targets:

```bash
npm run client:regression -- \
  --retry-report build/reports/client-module-regression.json
```

Common focused checks are:

| Change | Command |
| --- | --- |
| Public documents and links | `npm run repo:docs` |
| Repository privacy boundary | `npm run repo:local-info-hygiene` |
| Dependency-directory boundary | `npm run repo:workspace-cache-boundary` |
| Flutter source | `npm run client:analyze` |
| Flutter behavior | `npm run client:test` |
| Native client | `npm run client:native:test` |
| Client contracts | `npm run client:contracts:test` |
| Architecture boundaries | `npm run client:verify:architecture` |
| Version and generated compatibility | `npm run client:version:check` |

Run `npm run client:gate:source` once after all focused checks pass. Then run
only the affected `client:gate:flutter`, `client:gate:rust`,
`client:gate:android`, or `client:gate:dependencies` lane. These regression
lanes are independent and may run in parallel. Release policy runs only on the
`stable` → `release` promotion edge described in
[`releases/PROMOTION-GATES.md`](releases/PROMOTION-GATES.md). Source policy is
Node-only; it does not install platform toolchains
and is not authorization for live services, runtime-data capture, device
installation, signing, publication, or store operations.

### Static architecture metrics

`npm run client:verify:architecture` ends with the architecture ratchet phase,
which measures five static metrics and prints them as a numeric record for
milestone check results:

- kernel Cargo dependencies on optional capability crates,
- domain/platform and platform/domain importing files in `licoup-native`,
- `licoup-native` Rust size over one defined scope,
- optional capabilities bundled by the packaging module set,
- developer-tool execution sites in runtime sources.

Exact scopes, the optional-crate and packaging ownership maps, and the
justified developer-tool allowlist are declared in
`apps/desktop/scripts/client-architecture/ratchet/definitions.mjs`; every
metric also emits its `details.definition` in the verification report. The
Cargo manifest graph is resolved with the pinned `smol-toml` devDependency so
workspace inheritance, renames and path locality are read the way Cargo
declares them.

Tracked numbers and sets move only in the improving direction. A number that
grows or a set member that appears fails the check with the offending entry; an
improvement passes and prompts a baseline update. The initial comparable
baseline is recorded on the integrated candidate with
`node apps/desktop/scripts/verify-client-architecture.mjs --record-ratchet-baseline`,
which writes `apps/desktop/scripts/client-architecture/ratchet/baseline.json`
and refuses to raise a recorded value. An unrecorded baseline fails the check
by design. Installed size, and the processes, listeners and login items seen
after a fresh minimal install, remain separately assigned installed-candidate
evidence and are not measured here.

### Diagnose a failed check

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

## Run the assigned Agent conversation acceptance

Only the maintainer-assigned delivery owner performs live acceptance on the
integrated ordinary Release candidate. First record the candidate identity,
stop every installed writer, and create a consistent recoverable backup of the
same selected data root, including application-owned encrypted files. Keep
platform-held keys in place; do not read or export them.

Let the candidate's normal startup admission handle the selected root before
opening mutable stores. If bootstrap admission fails, stop the acceptance and
record the candidate's bounded error evidence for the maintainer. Routine
acceptance does not require a separate public read-only state-inspection
command or a manually invoked admission command.

Use the four configured targets—Codex, Cursor, Antigravity, and DeepSeek
Harness—and their exact model, provider, and independent-effort selections from
the [maintained selector configuration](../tools/scripts/config/agent-conversation-verification-models.toml).
Cursor and Antigravity do not use a separate effort selection; Antigravity's
selected model already identifies its effort variant.

Run the four selections sequentially in the system UI through CUA, on the same
data root. Submit exactly one plain `Hi` for each model and accept its actual
reply without a format requirement. Retain only the candidate identity,
selected model/provider/effort, submission and reply status, and result; do not
retain conversation history or reply content.

## Build a client or release package

Platform build commands produce runnable client build output:

```bash
npm run client:package:plan
npm run client:build -- --platform macos
npm run client:build -- --platform windows
npm run client:build -- --platform linux
npm run client:build -- --platform android
```

`client:build` is the only client build entry. It removes inactive compiler
output and temporary Flutter build caches after every build while preserving
the staged runnable/package output used by platform installers.

To plan one or several exact native release packages, use the shared selector:

```bash
npm run client:release:plan -- --target macos-direct-arm64
npm run client:release:plan -- \
  --targets macos-direct-arm64,android-direct-arm64-v8a
```

The same selector is accepted by `client:release:build`,
`client:release:stage`, and `client:release:verify`. Canonical package leaves
are written under `build/releases/<version>/<package-target>/`; no universal
outer archive is created. A local build is not a formal release artifact.
Formal artifacts come from the exact accepted `origin/release` source through
an explicitly authorized publication owner and bind source, package target,
immutable digest, and generation metadata.

## Recover local generated state

Package commands automatically remove their own current staging directory and,
before a later run starts, retire older exact project-owned staging names whose
owner process is no longer active. They do not select runnable bundles,
`build/releases/<version>/<package-target>/`, legacy or unknown names,
dependency caches, SDKs, toolchains, user data, installed applications, or
worktrees. Unsafe entries and cleanup failures stop the package flow with the
stable `flutter-clean-build-*` or `release-package-*` stage instead of exposing
a local path.

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

The repository branch train does not publish. Post-release macOS publication is
delegated to Apple Release from the exact accepted `origin/release` source and
cannot mutate repository source or protected branches. See
[Release packages](RELEASE-PACKAGES.md) for the canonical target and output
model. A same-source draft may be resumed; an already public Release may not be
extended or altered. A damaged public asset requires a corrective build or
version.

## Documentation

Keep only external contributor/user knowledge: necessary design choices, module
boundaries, usage and fixed commands. Link the owner instead of copying assertions,
state tables, command internals or volatile acceptance results. Describe implemented
capabilities and rules currently in force. Remove instructions when their
implementation is removed; do not present proposals as current behavior.

Every maintained Markdown document has `Updated: YYYY-MM-DD`. Update it when editing
content; generated documents retain their content date until their sources change.
A date is not evidence of correctness. `npm run repo:docs` checks required public
files, index coverage, language pairs and link targets. Review meaning and freshness
during closure; never bulk-stamp dates to claim verification.

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

Local workflow, state-machine and architecture pages are generated explicitly
from the maintained report sources:

```bash
node tools/development/reports.mjs
node tools/development/reports.mjs --better-plan <local-source>
```

The output stays in ignored `build/reports/`. The second form adds one
explicitly selected read-only Better Plan projection for the private planning
workspace. Reports are English, are not shipped with the client, run no checks
or Agents, and are not an execution authority; see
[workflow and report sources](../tools/development/workflows/README.md).

Before handoff, run:

```bash
npm run repo:docs
npm run repo:local-info-hygiene
```

Formal documents state only implemented and verified behavior. Requirements,
future design, progress, checkpoints, raw audit output, and unverified
conclusions remain local plan or report material.

### Continuous Assistant collection Unknown

A collection claim is `NotExecuted` until the producer is about to make the
first native invocation, then it becomes `Unknown`. `Unknown` is not proof
that no execution occurred. A later retry of the same session returns
reconciliation and must not dispatch again.

To continue after `Unknown`, the owner re-admits a new evaluation session.
The existing evidence identity still blocks a second commit for the same
candidate. Pre-invoke failures stay `NotExecuted` and release the claim.
A missing runtime (or other corpus-independent cause) may retry on the
same session after the cause is fixed. A missing or changed corpus requires
a new owner-issued evaluation session bound to that corpus; restoring the
exact original corpus permits the original session to retry.

语料收集 claim 在首次原生调用前转为 `Unknown`。`Unknown` 不能证明尚未执行。
同一会话再次收集只返回对账，不会重派。继续工作时由 owner 重新准入新会话；
已有证据身份仍阻止二次提交。调用前失败保持 `NotExecuted` 并释放 claim。
缺少运行时（或其他与语料无关的原因）修复后可在同一会话重试。缺少或已变更
的语料需要 owner 签发绑定该语料的新评估会话；恢复完全相同的原始语料后，
原会话才可以重试。

### Promote an author README update

The README fast path is a positive, author-owned maintenance capability for
quickly correcting inaccurate, outdated, or unsuitable public documentation.
It is not a vulnerability or a CI bypass. Its maintained membership is
`tools/scripts/config/readme-fast-files.json`; the manifest itself is an
implicit member.

For a manifest update, the allowed files are the union of the old manifest,
the new manifest, and the manifest itself. The author may therefore add or
remove a listed resource in the same commit. A file outside that union, an
unreadable manifest, or an uncertain classification automatically uses the
ordinary workflow.

Only Auditor scans added and modified blobs for sensitive information. The
other required checks keep their existing names and return quickly; they do
not inspect README wording, language, links, formatting, claims, or product
correctness. Agent behavior is governed by the `lico-client-development`
skill, not by repository gates, tests, or Rulesets.

Start `docs/readme-refresh` from `nightly`, change only the manifest and old/new
members, and merge it through an ordinary action-prefixed pull request. The
change then follows the same protected promotion train as other accepted work.
