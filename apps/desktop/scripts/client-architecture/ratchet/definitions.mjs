/**
 * Declared scope, ownership and allowlist data for the architecture ratchet
 * (QA-05, AR-05, EX-05).
 *
 * This file is the single declaration point for facts the static measurements
 * cannot derive from the repository, and it is intentionally explicit:
 *
 * - `OPTIONAL_CAPABILITY_CRATES` maps a capability package declared in
 *   `crates/licoup-extension-contracts/src/deployment.rs` to the first-party
 *   crate that implements it. `OPTIONAL_CAPABILITY_ARTIFACTS` and
 *   `OPTIONAL_CAPABILITY_BUNDLES` map the same package to the binaries that
 *   carry it and the packaging modules that currently bundle them. The
 *   measurement fails when a declared optional package has no entry, so a
 *   new optional capability cannot slip through as "unknown ownership".
 * - `DEVELOPER_TOOL_ALLOWLIST` names every runtime execution site that may
 *   reference `node`, `npm`, `npx`, `python3`, `python`, `uvx`, `pip` or
 *   `pip3`, together with its justification. A new execution site fails until
 *   it is either removed or justified here.
 *
 * Definitions are code, not baseline: changing them changes what is measured.
 * The measurement values live beside this file in `baseline.json`, which is
 * recorded on the integrated candidate. Tracked values move only in the
 * improving direction; the operating procedure is documented in the
 * "Static architecture metrics" section of `docs/RUNBOOK.md`, and the
 * comparison and recording semantics live in `baseline.mjs`.
 */

export const RATCHET_SCHEMA = "licoup-architecture-ratchet.v1";
export const BASELINE_SCHEMA = "licoup-architecture-ratchet-baseline.v1";

/** Baseline location, relative to the repository root. */
export const BASELINE_PATH =
  "apps/desktop/scripts/client-architecture/ratchet/baseline.json";

/** Recommended command to record the initial comparable baseline. */
export const BASELINE_RECORD_COMMAND =
  "node apps/desktop/scripts/verify-client-architecture.mjs --record-ratchet-baseline";

/**
 * Runtime source scope for the developer-tool scan. These are the first-party
 * sources executed by the installed client or by user-facing tools that ship
 * with it. Crate workspaces contribute only their `src` trees, so build
 * scripts, benches and crate-root files are out of scope. Developer machines,
 * build scripts and test sources are out of scope because EX-05 constrains
 * what runs on the user's device.
 */
export const RUNTIME_SOURCE_ROOTS = Object.freeze([
  Object.freeze({ root: "crates", extension: ".rs", layout: "crate-src" }),
  Object.freeze({ root: "components", extension: ".rs", layout: "crate-src" }),
  Object.freeze({ root: "sdk", extension: ".rs", layout: "crate-src" }),
  Object.freeze({ root: "apps/desktop/lib", extension: ".dart", layout: "tree" }),
]);

/**
 * First-party crate workspaces scanned for Cargo edges. Path dependencies may
 * legitimately point outside these roots; the manifest graph follows any
 * repository path it is given.
 */
export const FIRST_PARTY_CRATE_ROOTS = Object.freeze(["crates", "components", "sdk"]);

/** The client host crate the kernel build closure starts from. */
export const KERNEL_HOST_CRATE = "licoup-native";

/**
 * Optional capability package -> first-party crate implementation.
 *
 * Every `PackOwnership::Optional` package in deployment.rs must appear here.
 * An empty `crates` list is an explicit statement that no separate crate
 * implements the package at this baseline; the entry still prevents the
 * package from being unknown. Crates are matched by their Cargo package name.
 */
export const OPTIONAL_CAPABILITY_CRATES = Object.freeze({
  "org.licoland.feature.analytics": Object.freeze({
    crates: Object.freeze(["licoup-analytics"]),
    evidence:
      "components/analytics/Cargo.toml declares org.licoland.feature.analytics in its package description.",
  }),
  "org.licoland.feature.mcp": Object.freeze({
    crates: Object.freeze(["licoup-mcp"]),
    evidence:
      "crates/licoup-mcp builds the lico-subagent-mcp binary bundled by the subagents-mcp packaging module.",
  }),
  "org.licoland.feature.workflow": Object.freeze({
    crates: Object.freeze(["licoup-workflow"]),
    evidence:
      "crates/licoup-workflow implements the workflow capability; AR-05 currently keeps the workflow/flywheel in the kernel and M4 owns the ownership-table correction.",
  }),
  "org.licoland.adapter.generic": Object.freeze({
    crates: Object.freeze([]),
    evidence:
      "No separate crate at this baseline; the generic PTY/CLI adapter is compiled into licoup-native (AR-05 kernel scope).",
  }),
  "org.licoland.provider.compat": Object.freeze({
    crates: Object.freeze([]),
    evidence: "No separate first-party crate implements this package at this baseline.",
  }),
  "org.licoland.feature.gateway": Object.freeze({
    crates: Object.freeze([]),
    evidence:
      "No separate crate at this baseline; the gateway runtime ships as the lico-gateway binary inside licoup-native.",
  }),
  "org.licoland.feature.collaboration": Object.freeze({
    crates: Object.freeze([]),
    evidence: "No separate first-party crate implements this package at this baseline.",
  }),
  "org.licoland.feature.channels": Object.freeze({
    crates: Object.freeze([]),
    evidence:
      "No separate crate at this baseline; channels ship inside the gateway sidecar.",
  }),
});

/**
 * Optional capability package -> packaging artifact ownership.
 *
 * An artifact is a binary target name. A kernel-compiled implementation is
 * declared here too: the binary is built by `licoup-native` while the
 * capability it carries is optional. Enabled packaging modules bundle
 * artifacts through `cargoBin`/`embeddedCargoBin`; a module bundling an
 * artifact that is neither a declared optional artifact nor a declared kernel
 * artifact fails, and derived bundles must match `OPTIONAL_CAPABILITY_BUNDLES`
 * exactly.
 */
export const OPTIONAL_CAPABILITY_ARTIFACTS = Object.freeze({
  "org.licoland.feature.analytics": Object.freeze({
    artifacts: Object.freeze([]),
    evidence:
      "components/analytics is an independent workspace and ships no binary target at this baseline.",
  }),
  "org.licoland.feature.mcp": Object.freeze({
    artifacts: Object.freeze(["lico-subagent-mcp"]),
    evidence:
      "crates/licoup-mcp builds lico-subagent-mcp; subagents-mcp bundles it and codex-plugin embeds it.",
  }),
  "org.licoland.feature.workflow": Object.freeze({
    artifacts: Object.freeze([]),
    evidence:
      "No separate bundled artifact; the workflow runtime is compiled into the native kernel sidecar.",
  }),
  "org.licoland.adapter.generic": Object.freeze({
    artifacts: Object.freeze([]),
    evidence:
      "No separate bundled artifact; the generic adapter is kernel code per AR-05.",
  }),
  "org.licoland.provider.compat": Object.freeze({
    artifacts: Object.freeze([]),
    evidence: "No separate bundled artifact at this baseline.",
  }),
  "org.licoland.feature.gateway": Object.freeze({
    artifacts: Object.freeze(["lico-gateway"]),
    evidence:
      "licoup-native builds the lico-gateway binary; gateway-sidecar bundles it as the gateway runtime.",
  }),
  "org.licoland.feature.collaboration": Object.freeze({
    artifacts: Object.freeze([]),
    evidence: "No separate bundled artifact at this baseline.",
  }),
  "org.licoland.feature.channels": Object.freeze({
    artifacts: Object.freeze(["lico-gateway"]),
    evidence:
      "gateway-sidecar bundles the communication-channel runtime carried by the lico-gateway binary.",
  }),
});

/**
 * Declared bundle expectations: optional capability -> enabled packaging
 * modules that currently bundle its artifact. The derived set must match this
 * declaration exactly, so replacing a bundled binary, adding a new host bundle
 * or silently dropping a debt fails instead of appearing as an improvement.
 */
export const OPTIONAL_CAPABILITY_BUNDLES = Object.freeze({
  "org.licoland.feature.analytics": Object.freeze([]),
  "org.licoland.feature.mcp": Object.freeze(["subagents-mcp", "codex-plugin"]),
  "org.licoland.feature.workflow": Object.freeze([]),
  "org.licoland.adapter.generic": Object.freeze([]),
  "org.licoland.provider.compat": Object.freeze([]),
  "org.licoland.feature.gateway": Object.freeze(["gateway-sidecar"]),
  "org.licoland.feature.collaboration": Object.freeze([]),
  "org.licoland.feature.channels": Object.freeze(["gateway-sidecar"]),
});

/**
 * Binary targets that are kernel artifacts and therefore may be packaged
 * without belonging to an optional capability package.
 */
export const KERNEL_PACKAGING_ARTIFACTS = Object.freeze([
  "licoup-cli",
  "lico-agent",
  "lico-llm-gateway",
]);

/**
 * Developer-tool names whose runtime execution is tracked by EX-05.
 * Matching accepts a whole string literal equal to the name or a path segment
 * such as `$HOME/.hermes/bin/python3`; prose occurrences are not matched.
 */
export const DEVELOPER_TOOL_NAMES = Object.freeze([
  "node",
  "npm",
  "npx",
  "python3",
  "python",
  "uvx",
  "pip",
  "pip3",
]);

/**
 * Exact reviews for source-resolved developer-tool targets only. File-wide
 * names never supply target identity. Runtime-selected interfaces are recorded
 * separately with exact source/provenance in runtime-interfaces.mjs; they are
 * counted and compared, not admitted through a tool-name or path exception.
 */
export const DEVELOPER_TOOL_ALLOWLIST = Object.freeze([]);

/**
 * The scan's deterministic execution classification. The token lists are
 * intentionally narrow: detection helpers such as `find_binary` and `which`
 * are not execution.
 */
export const EXECUTION_TOKENS = Object.freeze([
  "Command::new(",
  ".spawn(",
  ".output(",
  ".status(",
  "run_bounded_untrusted_agent_output(",
  "run_bounded_command_output(",
  "Process.run(",
  "Process.start(",
  "Process.runSync(",
]);

/** Markers of an embedded shell script that runs commands itself. */
export const EMBEDDED_SHELL_MARKERS = Object.freeze(["command -v", "$(", '"$']);

/**
 * Evidence that stays centrally assigned. These are not measured here; the
 * milestone records them from the integrated installed candidate.
 */
export const CENTRAL_DELIVERY_EVIDENCE = Object.freeze([
  "Installed size per platform after a fresh minimal install.",
  "Processes observed after a fresh minimal install.",
  "Listeners observed after a fresh minimal install.",
  "Login items observed after a fresh minimal install.",
]);
