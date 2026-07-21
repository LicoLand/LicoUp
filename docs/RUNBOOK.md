# Development Runbook

## Metadata / 元数据

- Last updated: 2026-07-15
- Status: Current maintained runbook
- Scope: Development standards, audit rules, feature-item design standards, plan governance, document maintenance governance, skill local-info hygiene, commit-ready workflow, testing, validation, release gates, and documentation governance.
- Staleness check: Reconciled with `PRODUCT.md`, the canonical product-scope plan, package scripts, module regression, client architecture, privacy gates, and platform delivery rules on 2026-07-15.

## Lico Arc Development Rules

1. **Architecture — Module Independence / 模块独立性**: Modules must be split independently and completely:
    * Module functionality must be relatively independent: a module aggregates a set of similar functional items.
    * Module code files must be mutually independent: a single code file belongs to only one module.
    * Module file paths must be mutually independent: a module resides in an independent folder dedicated solely to that module.
2. **Architecture — Frontend-Backend Decoupling / 前后端解耦**: The frontend and backend must be decoupled, communicating only via general protocols (HTTP/HTTPS, RPC) remotely, or via local CLI command-line invocation. Direct code imports between frontend and backend are forbidden.
3. **Operations — Developer Workflow Management / 开发工作流管理**: Development, testing, release, and operations tools must be effective and aligned with current code and documentation:
    * Tools must be centrally managed in the `tools/` directory; scattering is forbidden.
    * Tool reference configurations must use dynamic scanning (see `tools/config-scanner.mjs`); hardcoding is forbidden.
    * Tool last-updated dates must not be later than the latest Lico Arc version release date.
4. **Architecture Governance — Current Implementations Only / 仅允许当前实现**: Lico Arc forbids prohibited roots, non-current behavior switches, and fallback implementations in production code. All updates must use canonical functional roots and current contracts. Version strings may be recorded only as state facts for releases, protocols, dependencies, artifacts, contracts, or audit records; they must not define implementation, feature, module, document, ADR, or plan boundaries.
5. **Architecture Governance — No Residual Gates / 禁止残留门禁**: One-time cleanup scripts must not leave residual gates or archived implementation paths. Temporary update scripts are deleted after execution; durable evidence belongs in registries, generated reports, tests, or verifier output under canonical roots.
6. **Feature Migration — Complete New Path / 功能完整迁移**: Feature work must finish as a complete migration before verification is considered final: optimize the feature, move ordinary callers and data paths to the new behavior, remove retired compatibility/fallback/shim paths, and update docs, registries, fixtures, and tests that still point at the old behavior.
7. **Commit-Ready Feature Unit / 可提交功能单元**: A feature is not commit-ready until the implementation, upstream/downstream adaptation, minimal verification, and objective blocker documentation are complete. If any required check cannot run in the current environment, record the reason, required platform/credential/collaborator, and follow-up verification command before treating the work as ready.
8. **Plan Governance — Product Scope, Preconditions, and Acceptance**: Current plan documents live in `docs/plan/`; every plan entry point is constrained by `docs/plan/product-scope/Requirements.md`, places `## Prerequisites` before `## Acceptance Criteria`, and states dependencies, parallelization boundaries, subagent boundaries, verifier commands, and concrete pass conditions.
9. **Testing — 95% Coverage / 95% 测试覆盖率**: Lico Arc code branches must achieve at least 95% test coverage where the scoped coverage gate applies. Submissions, pushes, and releases that fall below the declared threshold are rejected.
10. **Documentation — RUNBOOK.md as Sole Dev Doc / 唯一开发准则**: [RUNBOOK.md](RUNBOOK.md) is the sole development guideline document for the Lico Arc project. Other documents may define product or feature contracts but must not create conflicting development rules.
11. **Documentation — Rules Completeness / 准则完整**: The above audit rules must be recorded clearly and accurately in [RUNBOOK.md](RUNBOOK.md). Any missing guidelines must be supplemented promptly. RUNBOOK.md is the authoritative source; discrepancies between RUNBOOK.md and other documents are resolved in favor of RUNBOOK.md.
12. **Documentation - English Engineering Docs**: Repository-maintained engineering documentation is written in English. Chinese prose is allowed only in explicit translation/localization or user-facing product-promotion artifacts, such as localized README or product pages. ADRs, plans, runbooks, functionality docs, verifier guidance, scenario docs, implementation decision rollups, generated engineering docs, and repository skills must not use implicit mixed-language prose.
13. **User Experience — Simplified Credential Verification / 简化凭据验证**: When key or credential storage is involved, the client must request user permission and invoke platform-native biometrics (Face ID, Touch ID, Passkey) or secure key tools. Authentication must be unified in one OS-owned flow for the associated workflow. Biometrics are preferred; when they are unavailable, not enrolled, or locked, the same OS flow may fall back to the system credential. The app must never collect the password itself. Background work, unit tests, CI, and non-interactive acceptance steps must never open an authorization sheet.
14. **Product Scope — Explicit Allowlist**: Default product work is limited to the Rust local task queue, ACP, MCP, five declared platform adapters, local-agent discovery/conversation/skill/conversation-backup/usage scenarios, and Secure Client Mesh mobile relay. A new default navigation item or background service requires an explicit product-scope decision first.
15. **Optional LicoLite Collaboration**: LicoLite collaboration is disabled by default and installed only after a user explicitly enables it and selects a GitHub plugin source. Local LicoLite deployment and LicoLite MCP installation remain plugin-owned manual workflows and must not enter the built-in startup or navigation path.
    The host accepts only bounded non-executable declarative packages, binds apply and uninstall to the reviewed SHA-256 digest, and reads the workflow catalog only through an explicit user command.
16. **External Data — Per-Operation Direct Approval**: Local files, conversations, configuration, diagnostics, paths, device facts, history, and usage remain local by default. Every external transfer binds a direct single-operation approval to destination, purpose, exact scope, and content digest; it remains cancellable until commit and fails closed when missing, cancelled, expired, changed, or unverifiable. Startup, schedules, prior approvals, plugin enablement, and agent requests do not imply consent.
17. **Local Scheduling — Rust Ownership**: The lightweight local task queue is implemented in Rust with fixed-capacity FIFO admission, one exclusive consumer, cloneable producers, blocking backpressure, ownership-preserving rejection, bounded depth accounting, and fail-closed disconnect. Scheduling policy, retries, cancellation, terminal history, and payload persistence remain feature-owned and must not be smuggled into the primitive. UI code does not implement a second queue.
18. **Testing — Fast Regression Closure / 快速回归闭环**: Regression work must choose the fastest module-scoped loop that proves the changed behavior and minimize the selected scope. Run the complete regression only after every implementation, migration, document, and targeted check is confirmed effective. Repeated complete-regression runs during development are forbidden because they consume shared resources and disrupt parallel agents.

## Development Specifications

### Code Facts First

- Document conclusions must be traceable to current code, manifests, configs, operation registries, state-machine definitions, or verifiers.
- Historical process documents, phase plans, old audit reports, and TODO drafts are not to be used as current sources of truth.
- New features should first clarify their owning module, then update operations, APIs, UI, docs, and verifiers.

### Module Boundaries

- The public platform layer does not reverse-depend on specialized business modules.
- HTTP adapters, console controllers, event buses, storage, work queues, and verifiers do not hold business facts.
- External services, agent frameworks, and model providers are boundary objects and are not treated as trusted internal modules.

### Feature Item Description Standards

Each feature item describes at least:

- Objective
- Input
- Processing
- Output
- Error/rejection paths
- Persistence or observability requirements
- Verification entry point

Feature items do not describe implementation plans alone; unimplemented portions are recorded in `docs/IMPLEMENTATION-GAP.md` instead of being documented as current functionality.

## Testing and Validation

### Native Credential Authorization Acceptance

- One user-initiated top-level workflow may create at most one interactive system-authorization request. Its secret reads, writes, replacement deletes, and cleanup operations reuse the same bounded native authorization context.
- A second associated operation while that context remains valid creates zero new prompts. A cancelled, timed-out, invalidated, locked, or changed-credential context fails closed; code must not silently retry with another interactive request.
- Touch ID or the platform biometric is the preferred mechanism. A system password/PIN fallback is acceptable only inside the OS-owned device-owner authentication flow. An application-built password field or application-collected credential is prohibited.
- Timer-driven polling, startup discovery, unit tests, CI, and ordinary non-interactive verification create zero authorization prompts. They use an already-authorized context or return an explicit authorization-required/fail-closed result for a later user gesture.
- Interactive acceptance must announce the single expected system sheet before it starts. Prompt accounting covers the complete workflow, including Keychain cleanup and failed-helper paths; report fields must be observed or structurally enforced and must not be hard-coded as proof.
- A macOS acceptance helper must not run a second interactive fallback process after a signed helper fails. Every post-authorization Keychain query must attach the shared `LAContext` and disallow additional UI; a fresh non-interactive context separately proves fail-closed access.

### Commit-Ready Gate

After completing a new feature or feature migration, run the smallest verification set that proves both the feature and its upstream/downstream adaptations work together. The feature can be committed only after it is a complete rollback point.

Minimum commit-ready requirements:

- The feature boundary, user-visible behavior, and owning module are complete.
- Upstream and downstream entry points are adapted: API/CLI/UI callers, runtime providers, configs, registries, docs, tests, fixtures, generated artifacts, and external/platform adapters that participate in the behavior.
- The smallest relevant verifier has passed, and the selected command would fail if the new behavior or upstream/downstream adaptation were incomplete.
- Any skipped verification is backed by objective evidence: environment/platform gap, missing credential, unavailable external service, required collaborator, or hardware/OS limitation, plus the command that should be run later.
- Before committing, run `npm run repo:commit-ready`. In non-interactive flows, pass `--yes --verified-command "<command>"` for completed checks or `--blocker-evidence <path>` for documented objective blockers.

### Repository Submission Workflow

The public repository uses three long-lived branches: `nightly`, `stable`, and `release`. The default branch is `nightly`; `stable` and `release` are promotion branches. `main` is not an active branch for this repository.

Recommended development flow:

1. Start from the current `nightly` branch.
2. Create a temporary topic branch with a descriptive name.
3. Commit code only on that temporary branch.
4. Run the smallest relevant verifier, `npm run repo:local-info-hygiene`, and `npm run repo:commit-ready` before publishing the branch.
5. Push the temporary branch and open a pull request into `nightly`.
6. Merge only after `licolite-audit-gate`, CI, review, and required conversation resolution pass.
7. Delete the temporary branch after merge.

Promotion flow:

- Promote `nightly` to `stable` through a pull request whose source branch is the repository-owned `nightly`.
- Promote `stable` to `release` through a pull request whose source branch is the repository-owned `stable`.
- Do not push directly to `nightly`, `stable`, or `release` from a local checkout.
- Do not create tags, release assets, registry publications, or container images unless the release gate explicitly calls for them.

GitHub rulesets are the remote enforcement layer for protected branches. The repository `licolite-audit-gate` workflow must remain the required privacy/security gate for protected-branch updates, and the audit implementation must come from the current `LicoLite/licolite-audit` `only` branch.

### Product-Line Delivery Gate

The authoritative product scope is `PRODUCT.md` plus
`docs/plan/product-scope/Requirements.md`. Default delivery is accepted per
independent foundation or scenario only when its dedicated regression and every
declared integration edge pass. A product-line claim requires all four foundation
capabilities, all six default scenarios, and the selected platform set to be
verified. Partial implementation remains visible as progress and is not a complete
product-line claim.

Optional LicoLite collaboration is reported separately. Its absence, disablement,
or uninstalled state cannot block the default product. It can be accepted only
after disabled-by-default, manual GitHub installation, composition selection,
manual MCP installation, and per-file approval negative tests pass.

### Artifact Verification and Platform Publication

Development, ordinary builds, and GitHub Releases do not require production publisher credentials, notarization, store submission, public store download, or store update/rollback continuity. GitHub Release artifacts publish only minimum consumer-verification metadata: artifact identity, target/version, cryptographic digest, signature or attestation, and any public verification material required to validate the exact official package. Do not publish publisher account, team/store identifier, stable certificate identity, credential, private-key, custody, operator-machine, private-host, or private-channel metadata.

When a signed auto-update or named platform/store publication is requested, protected production resources are represented only by a redacted channel-status receipt. It records pass/fail proof classes, artifact digests, and verifier results without exposing the publishing identity or infrastructure. A missing receipt means only that channel is not ready; it is not a source-development, ordinary-build, client-functionality, or GitHub Release blocker.

GitHub Release target selection is independent from platform/store update trains and the all-platform product claim. A release declares an exact non-empty target subset and accepts only source/version-bound build artifacts whose canonical checksum and, where applicable, detached signature or public verification key validate. Unsupported targets cannot enter the workflow. Physical custody, device install/launch, KT/MLS authority, independent cryptographic review, and broad Secure Mesh evidence are inputs only to `npm run client:verify:product-line-security`; they never change the GitHub artifact verdict. Store, notarization, registry, public-store download, and update/rollback receipts remain optional channel guidance. Use `npm run client:verify:update-release` only for the separate signed-update feature contract and `LICO_CLIENT_RELEASE_TARGETS=<target-id[,target-id...]> npm run client:verify:github-release` for the artifact-only GitHub Release gate. The publisher emits exactly one `LicoArc-consumer-verification.json` plus the selected packages and their required verification files.

GitHub Release build jobs run `npm run client:verify:source`. This gate covers source hygiene, architecture, contracts, formatting, dependency checks, Flutter/Rust tests, and artifact-policy self-tests only. It deliberately excludes physical-device matrices, platform custody, KT/MLS authority, independent review, and the product-line reducer.

Release closure hardening is fail-closed: source roots are code-owned and include
root dependency locks; Android release verification requires the checked-in
host toolchain digest allowlist; macOS requires exact outer entitlements,
Hardened Runtime, and recursively minimal nested-code entitlements; Linux
archives are directly verified and resource-bounded before extraction. Run the
side-effect-free boundary suites before any physical platform action:

```bash
npm run client:verify:release-artifact-io:self-test
npm run client:verify:source-state-digest:self-test
npm run client:verify:linux-tar-resource-bounds:self-test
npm run client:verify:android-apk-zip-facts:self-test
npm run client:verify:android-release-toolchain:self-test
npm run client:verify:review-signoff:self-test
npm run client:verify:release-target-evidence:self-test
npm run client:verify:artifact-verification-receipts:self-test
npm run client:verify:client-release-acceptance:self-test
```

Every client version must also publish the generated platform-by-capability report at `docs/releases/client-support-matrix.md`. Run `npm run client:support-matrix:sync` after changing the product version, release targets, or capability catalog, then run `npm run client:support-matrix:check`. The version verification command includes this freshness check. Manual integrations are absent by default and never block a selected client platform release; unsupported, deferred, and unverified rows must remain explicit and must not be described as supported. Capability status never grants external-transfer authority: each transfer still requires direct, exact-operation user approval.

### Plan Governance Gate

Before adding or changing a plan document, read
`docs/plan/product-scope/Requirements.md` and `docs/plan/Manifest.json`.

Minimum plan requirements:

- Current plan documents live under `docs/plan/`.
- Every plan entry point names the canonical product-scope plan as its upper
  constraint.
- Each plan includes `## Prerequisites` before `## Acceptance Criteria`.
- Prerequisites name product-scope dependencies, serial/parallel boundaries, and
  subagent boundaries.
- Acceptance criteria name verifier commands, evidence, or concrete pass conditions.
- A child plan cannot add a default scenario, background service, external data
  transfer, or LicoLite dependency that the product-scope plan does not authorize.

Run:

```bash
npm run client:verify:plan
```

### Document Maintenance Gate

Before creating or changing documentation, run `lico-dev context <changed-path>`.
Repository agent guidance lives in the lico-dev skill `lico-arc-repository`.

Minimum document requirements:

- Search existing docs and ADRs before creating a Markdown file.
- Use Update Existing First: update the canonical document that already owns the responsibility, feature boundary, or decision boundary.
- Use the Documentation Language Policy: development documents, ADRs, plans, runbooks, skill instructions, verifier guidance, and other repository-maintained engineering docs are written in English. Chinese prose is allowed only in explicit translation/localization or user-facing product-promotion artifacts, such as localized README or product pages. User-facing conversation replies use the user's language.
- ADRs follow Current Decision Only: state the current accepted decision directly and rely on git history for replaced wording.
- Use No Version-Named Boundaries: name features, modules, ADRs, plans, and refactor documents by functional boundary or change summary, not by `v2`, `version-3`, or release numbers.
- Keep each document single-purpose; one feature should not create several parallel docs.
- If a new canonical plan is justified, update `docs/plan/Manifest.json` in the
  same change.

Run:

```bash
npm run repo:client-boundary
```

### Repo Local-Info Hygiene Gate

Run the repository-level privacy scan before commit readiness:

```bash
npm run repo:local-info-hygiene:self-test
npm run repo:local-info-hygiene
```

The gate invokes the authoritative `lico-dev privacy scan .` scanner and writes only redacted reason codes, repository-relative paths, and irreversible digests to `build/reports/repo-local-info-hygiene.json`. It also checks first-party evidence, reports, and receipts for device or runtime identity fields. Missing `lico-dev`, malformed scanner output, secrets, credential tokens, private keys, workstation paths, personal email addresses, and raw device or runtime identifiers all fail closed. The self-test uses runtime-generated canaries and verifies that no matched value is copied into its report. Clean real details to placeholders such as `<repo-root>`, `<user-home>`, `<server-url>`, `<external-service-url>`, `<public-api-host>`, `<origin-ipv4>`, `<admin-host>`, `<input-file>`, and `<output-file>`.

### Skill Local-Info Hygiene Gate

Authoritative LicoLite skills live only in the sibling `lico-dev` repository and
are exposed to agents through the shared skills directory. Do not add skill
copies to LicoArc. Skill prose, examples, bundled references, prompts, and helper
usage text must not contain developer-machine user names, absolute home paths,
Windows drive paths, private network hosts, real public endpoints, admin SSH
endpoints, real email domains, or provider resource IDs.

Use placeholders such as:

- `<repo-root>`
- `<server-url>`
- `<server-data-dir>`
- `<external-service-url>`
- `<input-file>`
- `<output-file>`

Run before sharing repository or workflow evidence:

```bash
lico-dev privacy scan .
```

### Feature Migration Gate

For a refactor, rename, ownership move, route move, or schema migration, use the
installed `$lico-migration-completion` skill and complete the migration before
running the verification closure. Ordinary feature changes do not need a
migration-only absence gate.

Minimum pre-test self-check:

- Name the feature boundary, ordinary entry points, callers, config/data paths, and user-visible behavior.
- Confirm the sequence is complete: feature optimization -> full migration to the new behavior -> retired compatibility removal.
- Confirm the feature, module, docs, ADR, and plan names use functional-boundary names instead of version-numbered names.
- Search direct callers and touched areas for `legacy`, `fallback`, `compat`, `deprecated`, `old`, `shim`, `redirect`, `bridge`, and `TODO`.
- Update or remove docs, registries, fixtures, generated artifacts, and tests that still point to the retired path.
- For a retired product name, reset persisted user state directly: initialize only the current-name root/namespace and do not discover, import, rename, copy, translate, prompt for, fixture, or gate the retired-name state.
- Keep an old path only when it is still a current product requirement, and record why it remains part of the current implementation.
- Select tests that would fail if the ordinary path still bypassed the new implementation.

### Client-side

开发期先用 `npm run client:regression:list` 查看模块，并通过 `npm run client:regression -- --module <module-id>` 或 `npm run client:regression -- --changed-from <ref>` 做最小回归；在执行前可追加 `--dry-run` 预览选择结果。只有所有改动确认有效后才执行一次全量 `npm run client:verify`，严禁在开发过程中反复运行全量回归并占用并行开发资源。

| Scope of Change | Minimum Verification |
| --- | --- |
| Client Version Governance | `npm run client:version:check`, `npm run client:version:sync` |
| Workspace Cache/Data Boundary | `npm run repo:workspace-cache-boundary` |
| Flutter UI | `npm run client:analyze`, `npm run client:test` |
| Rust sidecar | `npm run client:native:test` |
| Native Smoke | `npm run client:native:smoke` |
| Client Contracts | `npm run client:contracts:test` |
| Module-scoped Client Regression | `npm run client:regression:list`, `npm run client:regression -- --module <module-id>`, `npm run client:regression -- --changed-from <ref> --dry-run` |
| Client Architecture (local state, target adapters, Rust task queue, ACP/MCP adapters, Skill Hub) | `npm run client:verify:architecture` |
| Local Data Egress Boundary (reviewed network-capable source allowlist and GET-only GitHub package fetchers) | `npm run client:verify:local-data-egress-boundary` |
| Native Agent Conversation Parity (inventory, evidence reduction, exact-session/history contract, ACP protocol self-test) | `npm run client:verify:agent-conversation-parity` |
| Client Plan Gates | `npm run client:verify:plan` |
| Agent Usage Metering | `npm run client:verify:agent-usage` |
| Secure Client Relay protocol Mock | `npm run client:verify:secure-client-relay-mock-e2e` |
| Mobile Relay Native RPC (automated, zero prompts) | `npm run client:verify:mobile-relay-native-rpc-self-test` |
| Android Native Cryptography Bridge | `npm run client:test:android:native` |
| Android Physical Install/Launch | `npm run client:verify:android-physical-install-launch` |
| Selected-Target Consumer Verification Receipt | `npm run client:verify:artifact-verification-receipts` |
| Selected-Target Consumer Verification Self-Test | `npm run client:verify:artifact-verification-receipts:self-test` |
| Release Artifact Filesystem Self-Test | `npm run client:verify:release-artifact-io:self-test` |
| iOS Simulator Client Closure | `npm run client:verify:mobile-simulator-closure:ios` |
| Secure Mesh Pairwise/Content Audit | `npm run client:verify:secure-mesh-pairwise-content-audit` |
| Secure Mesh Platform Secret-Store Matrix | `npm run client:verify:secure-mesh-platform-secret-store-matrix` |
| Secure Mesh Physical Device Matrix | `npm run client:verify:secure-mesh-physical-device-matrix` |
| Secure Client Relay Mock Protocol | `npm run client:verify:secure-client-relay-mock-e2e` |
| Android Native Cryptography Bridge | `npm run client:test:android:native` |
| Secure Mesh Encrypted File Handoff | `npm run client:verify:secure-mesh-encrypted-file-handoff` |
| Secure Mesh ACP Relay Governed Baseline | `npm run client:verify:secure-mesh-acp-relay-governed-baseline` |
| Secure Mesh ACP Archive Release Proof | `npm run client:verify:secure-mesh-acp-archive-release-proof` |
| Secure Mesh Trust UX Selected-Target Reducer Self-Test | `npm run client:verify:secure-mesh-trust-ux:self-test` |
| Secure Mesh Trust UX | `npm run client:verify:secure-mesh-trust-ux` |
| Secure Mesh Report Redaction | `npm run client:verify:secure-mesh-report-redaction` |
| Secure Mesh Report Redaction Self-Test | `npm run client:verify:secure-mesh-report-redaction:self-test` |
| Secure Mesh Release Proof Bundle | `npm run client:verify:secure-mesh-release-proof-bundle` |
| Secure Mesh E2EE Evidence Contract Binding | `npm run client:verify:secure-mesh-e2ee-evidence:contract-binding` |
| Secure Mesh E2EE Authority Proof Self-Test | `npm run client:verify:secure-mesh-e2ee-evidence:authority-proof-self-test` |
| Secure Mesh E2EE Readiness Self-Test | `npm run client:verify:secure-mesh-e2ee-evidence:readiness-self-test` |
| Secure Mesh E2EE Evidence Leak Scan Self-Test | `npm run client:verify:secure-mesh-e2ee-evidence:leak-scan-self-test` |
| Secure Mesh E2EE Evidence Diagnostic Handoff | `npm run client:verify:secure-mesh-e2ee-evidence:diagnostic` |
| Secure Mesh E2EE Evidence Release Gate | `npm run client:verify:secure-mesh-e2ee-evidence` |
| Update Release Channel | `npm run client:verify:update-release` |
| Windows File Security | `npm run client:verify:windows-file-security` |
| macOS Bundle | `npm run client:verify:macos-bundle` |
| macOS Keychain User-Presence Proof (explicit operator step, at most one OS sheet) | `npm run client:verify:secure-mesh-macos-keychain-user-presence` |
| Linux ARM64 CLI VM / Current Product Archive | `npm run client:cli:vm:list`, `npm run client:cli:vm:prepare`, `npm run client:cli:vm:verify`, `npm run client:cli:vm:linux-product-bootstrap -- --distro ubuntu`, `npm run client:cli:vm:linux-product -- --distro ubuntu` |
| Full Client | `npm run client:verify` |

`client:cli:vm:linux-product-bootstrap` verifies the pinned, checksummed Ubuntu
ARM64 Node/Rust/Flutter/Docker toolchain without syncing product source or
creating release evidence. The authoritative Flutter toolchain is release
`3.44.2` at commit `c9a6c484230f8b5e408ec57be1ef71dee1e77020`; the Docker
x64 archive fallback is accepted only with SHA-256
`b0de1d19754688ec6769c9a067db3b0594479d3d767f971bfecfc132904c8d5e`.
`client:cli:vm:linux-product` then freezes the
current client source state, builds and validation-signs the ARM64 archive,
installs and launches it in X11, runs smoke checks, and exercises three isolated
current-client nodes through an opaque in-memory relay. A source change at any
point invalidates ready artifacts. The validation-only key is ephemeral and is
not a production-signing claim; the VM is stopped after the run unless an
explicit diagnostic invocation requests otherwise.

`client:verify` is non-interactive and must never invoke the two explicit macOS physical authorization commands above. Before either physical command is run, the operator must be told that one macOS-owned sheet may appear. Touch ID is preferred; if it cannot complete, entering the system password once in that same sheet is an allowed fallback. A second prompt is a failed acceptance result and the run must stop.

## Release Gates

- Release declarations are based on current verifiers and do not reference historical process reports.
- Production deployments use HTTPS reverse proxies, network isolation, key management, audit archiving, and backup recovery strategies.
- Version changes update `docs/VERSION.md`, `CHANGELOG.md`, and version registry artifacts, and evidence references must exist.
- External service candidate catalog promotions must pass the Tool Adoption Gate, contract verification, egress policy, secret injection, quota/bulkhead, output governance, and rollback plan.
- High-risk writes, external side effects, grant changes, and destructive operations require approval or explicit safety confirmation.

## Documentation Governance

### Path Rules

| Content | Target Path |
| --- | --- |
| Architecture | `docs/architecture/ARCHITECTURE.md` |
| Terms | `docs/TERM.md` |
| Functional Modules | `docs/functionality/*.md` |
| Script/CLI Usages | `docs/USAGES.md` |
| Frontend Design and Colors | `docs/DESIGN.md` |
| Compatibility Targets | `docs/COMPATIBILITY.md` |
| Agent Guidelines | lico-dev skill `lico-arc-repository` |
| Development Rules/Testing/Release Gates | `docs/RUNBOOK.md` |
| Plan Governance and Product Scope | `docs/plan/product-scope/`, `docs/plan/Manifest.json`, `docs/plan/**/*.md` |
| Versioning | `docs/VERSION.md` |
| State Machines | `docs/state-machine/STATE-MACHINES.md` |
| Protocols | `docs/protocols/PROTOCOLS.md` |
| Implementation Gaps | `docs/IMPLEMENTATION-GAP.md` |
| Long-term Decisions | `docs/adr/`, `docs/adr/README.md` |

### Deletion Rules

- Historical process documents must be deleted; `history/` or `reports/` are not retained as current facts.
- `docs/scenarios/` is adjacent input directory for scenario verifiers; gaps are still classified under `docs/IMPLEMENTATION-GAP.md`.
- Professional terms must be registered in `docs/TERM.md` before entering current documentation.
- Search existing docs before creating a Markdown file; update the owning canonical document first.
- English Engineering Docs: development documents, ADRs, plans, runbooks, skill instructions, verifier guidance, scenario docs, implementation decision rollups, generated engineering docs, and other repository-maintained engineering docs are written in English. Chinese prose is allowed only in explicit translation/localization or user-facing product-promotion artifacts, such as localized README or product pages. A file that needs Chinese must declare that translation/localization or product-promotion purpose instead of relying on implicit mixed-language prose. User-facing conversation replies use the user's language.
- ADRs are current decision records. Use `docs/adr/README.md`, update the existing ADR when it owns the same decision boundary, and avoid document-local previous/current decision splits.
- Use No Version-Named Boundaries for documentation names: `v2`, `version-3`, release numbers, and previous/current labels are facts only when the owning release, protocol, dependency, artifact, contract, or audit record needs them.
- When plans are implemented, long-term decisions enter ADR, operational details enter runbook, and functional facts enter functionality, and the original plan files are deleted.
- Horizontal drafts, checklists, progress summaries, dated audits, implementation plans, and temporary reports do not enter `docs/`.

### Metadata Rules

Each current Markdown document under `docs/` must place the following block directly after the H1 header:

```markdown
## Metadata / 元数据

- Last updated: YYYY-MM-DD
- Status: ...
- Scope: ...
- Staleness check: ...
```

Before submitting, run:

```bash
npm run repo:client-boundary
npm run client:verify:plan
```

## Security Standards

- Do not commit secrets, tokens, cookies, OAuth codes, grant tokens, claim tokens, or private keys.
- Examples use environment variables, stdin, `secretRef`, or placeholders.
- Calls to external services record anonymized receipts without retaining original headers, query params, body, stack traces, or stream chunks.
- Local stdio is not a public Lico Arc protocol surface; stdio operations must use controlled ACP/MCP adapters or explicit development modes.
## Agent conversation verification

Use the canonical wrapper instead of running adapter checks by hand:

```bash
npm run client:verify:agent-conversations
npm run client:verify:agent-conversations:live
npm run client:verify:agent-conversations:release-ui
```

Limit a live run with `-- --agent <agent-id>`. Static mode runs native platform
tests, reducer contracts, readiness validation, and the parity harness self-test.
Live mode runs the strict native-session continuation harness. Release-UI mode
also requests canonical evidence suitable for readiness reduction. The redacted
JSON report is written to
`build/reports/agent-conversation-verification.json`; raw prompts, responses,
session identifiers, local paths, credentials, and runtime output are never
copied into the report.

The canonical validation model policy is: Codex uses
`gpt-5.3-codex-spark`, Cursor uses `Auto`, Kilo Code uses `Kilo Auto Free`,
and OpenCode plus all remaining adapters use their current agent default.
