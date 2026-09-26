# ADR 0006: Capability-aware parallel client regression

Updated: 2026-09-25

Status: implemented · Current authorities:
`tools/regression/client-module-catalog.mjs` and the registered regression runner

## Decision

Client regression is a staged dependency graph: common preflight, shared
foundations, parallel frontend/backend collections, interface integration, core
scenarios, and a bounded compatibility frontier for locally eligible platform
and Agent lanes. A failure blocks only success-dependent descendants; independent
work settles and remains visible.

The scheduler uses static arguments with `shell: false`, a global capacity, and
separate Rust, Node, Flutter, and Gradle resource pools. Commands declare every
toolchain and single-owner cache they use. Compatible complete selections batch
at the Cargo target, Node test-file, Flutter path, or Gradle task boundary;
focused and incompatible selections retain their exact commands.

Every platform and Agent has its own capability probe and validation entry.
Missing optional SDKs, devices, hosts, or Agent runtimes are `unverified` with a
stable reason; they are not passes and do not fail unrelated core checks. Retry
selection includes failed or attribution-pending members and newly eligible
descendants without repeating unrelated successes.

Reports retain allowlisted identifiers, statuses, counts, timings, anonymous
resource measurements, concurrency peaks, failure codes, and compatibility
rows. They do not retain command output, arguments, environment, paths, PIDs,
machine/user identity, credentials, device identities, prompts, or runtime
payloads. Unavailable measurements remain unavailable instead of becoming zero.

## Trade-off

Batching removes repeated toolchain startup while resource pools prevent nested
parallel runners from oversubscribing the host. Per-target isolation keeps a
missing optional capability from hiding or blocking independent evidence.
Numeric input-index attribution lets the runner retry failed Node members without
persisting test names, paths, stacks, or raw output.

Executable registries and tests own exact stages, resources, batching keys,
report fields, and retry behavior.
