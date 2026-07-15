#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  openSync,
  closeSync,
  readSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import {
  CONDITIONAL_CHECK_IDS,
  CONTRACT_VERSION,
  CORE_CHECK_IDS,
  EVIDENCE_SCHEMA_VERSION,
  adapterManifestDigestFor,
  adapterEvidenceDigestFor,
  driverInventoryDigestFor,
  packagedAgentIds,
  registryDigestFor,
} from "./client-agent-conversation-parity-reducer.mjs";
import {
  releaseClosureChallengeDigest,
  requiredReleaseClosureChallenge,
} from "./lib/release-closure-challenge.mjs";
import { productContinuityBindingDigest } from "./lib/agent-conversation-release-binding.mjs";

const workspaceRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const packagingRegistryPath = join(workspaceRoot, "apps", "desktop", "packaging.modules.json");
const driversInventoryPath = join(
  workspaceRoot,
  "crates",
  "lico-client-native",
  "resources",
  "agent-conversation-drivers.json",
);
const evidenceManifestPath = join(
  workspaceRoot,
  "crates",
  "lico-client-native",
  "resources",
  "agent-conversation-evidence.json",
);
const packagedReleaseAppPath = join(
  workspaceRoot,
  "build",
  "apps",
  "desktop",
  "runnable",
  "macos",
  "release",
  "Arc.app",
);
const sidecarArgs = ["agent", "conversation", "send", "--stdin-json", "true"];
const dispatchLaneHarnessVersion = "dispatch-lane-unified-1";
const coreProbeIds = Object.freeze([
  "P-01",
  "P-02",
  "P-03",
  "P-04",
  "P-05",
  "P-06",
  "P-07",
  "P-08",
  "P-09",
  "P-10",
]);
const defaultTimeoutMs = 180_000;
const defaultMaxOutputBytes = 4 * 1024 * 1024;
const acceptanceMode = "dispatch-lane-unified-1";
const strictRoundCount = 3;
const disposableProfileSeedEntries = Object.freeze([
  "config.toml",
  "credentials",
  "oauth",
  "device_id",
]);
const disposableProfileSeedMaxFiles = 128;
const disposableProfileSeedMaxBytes = 4 * 1024 * 1024;
const disposableProfileSeedMaxDepth = 8;

const agentConfigs = Object.freeze({
  opencode: Object.freeze({
    id: "opencode",
    driverId: "opencode-serve",
    executable: "opencode",
    binaryEnvironment: ["OPENCODE_PATH", "OPENCODE_BIN"],
    acpArgs: ["serve"],
    runtimeProtocol: "opencode-serve-http-v1",
    laneFamily: "serve-http",
    cleanupKind: "openagent-cli",
    listArgs: ["session", "list", "--format", "json"],
    deleteArgs: (sessionId) => ["session", "delete", sessionId],
    exportArgs: (sessionId) => ["export", sessionId, "--sanitize"],
  }),
  copilot: Object.freeze({
    id: "copilot",
    driverId: "copilot-acp",
    executable: "copilot",
    binaryEnvironment: ["COPILOT_PATH", "COPILOT_BIN"],
    acpArgs: ["--acp", "--stdio", "--no-auto-update"],
    runtimeProtocol: "copilot-acp-v1-stdio-ndjson",
    laneFamily: "acp",
    cleanupKind: "copilot-sdk",
  }),
  "kilo-code": Object.freeze({
    id: "kilo-code",
    driverId: "kilo-code-serve",
    executable: "kilo",
    binaryEnvironment: ["KILO_PATH", "KILO_BIN", "KILOCODE_PATH"],
    acpArgs: ["serve"],
    runtimeProtocol: "kilo-code-serve-http-v1",
    laneFamily: "serve-http",
    cleanupKind: "openagent-cli",
    listArgs: ["session", "list", "--format", "json", "--all"],
    deleteArgs: (sessionId) => ["session", "delete", sessionId],
    exportArgs: (sessionId) => ["export", sessionId, "--sanitize"],
  }),
  cursor: Object.freeze({
    id: "cursor",
    driverId: "cursor-acp",
    executable: "cursor-agent",
    binaryEnvironment: ["CURSOR_AGENT_PATH", "CURSOR_PATH", "CURSOR_BIN"],
    acpArgs: ["acp"],
    runtimeProtocol: "cursor-acp-v1-stdio-jsonrpc",
    laneFamily: "acp",
    cleanupKind: "unavailable",
    cleanupBlocker: "safe_cleanup_unavailable",
  }),
  openclaw: Object.freeze({
    id: "openclaw",
    driverId: "openclaw-acp",
    executable: "openclaw",
    binaryEnvironment: ["OPENCLAW_PATH", "OPENCLAW_BIN"],
    acpArgs: ["acp"],
    runtimeProtocol: "openclaw-acp-stdio-jsonrpc",
    laneFamily: "acp",
    cleanupKind: "openclaw-acp",
  }),
  hermes: Object.freeze({
    id: "hermes",
    driverId: "hermes-acp",
    executable: "hermes",
    binaryEnvironment: ["HERMES_PATH", "HERMES_BIN"],
    acpArgs: ["acp"],
    runtimeProtocol: "hermes-acp-stdio-jsonrpc",
    laneFamily: "acp",
    cleanupKind: "hermes-cli",
    listArgs: ["sessions", "list", "--limit", "10000"],
    deleteArgs: (sessionId) => ["sessions", "delete", sessionId, "--yes"],
  }),
  "kimi-code": Object.freeze({
    id: "kimi-code",
    driverId: "kimi-code-acp",
    executable: "kimi",
    binaryEnvironment: ["KIMI_PATH", "KIMI_BIN", "KIMI_CODE_PATH"],
    acpArgs: ["acp"],
    runtimeProtocol: "kimi-code-acp-v1-stdio-ndjson",
    laneFamily: "acp",
    cleanupKind: "disposable-data-root",
    disposableEnvironmentKey: "KIMI_CODE_HOME",
  }),
  pi: Object.freeze({
    id: "pi",
    driverId: "pi-rpc",
    executable: "pi",
    binaryEnvironment: ["PI_PATH", "PI_BIN", "PI_CODING_AGENT_PATH"],
    acpArgs: ["--mode", "rpc", "--offline"],
    runtimeProtocol: "pi-rpc-stdio-jsonl",
    laneFamily: "rpc",
    cleanupKind: "pi-disposable-session-root",
    disposableEnvironmentKey: "PI_CODING_AGENT_SESSION_DIR",
  }),
  codex: Object.freeze({
    id: "codex",
    driverId: "codex-app-server",
    executable: "codex",
    binaryEnvironment: ["CODEX_PATH", "CODEX_BIN"],
    acpArgs: ["app-server", "--stdio"],
    runtimeProtocol: "codex-app-server-stdio-jsonrpc",
    laneFamily: "app-server",
    cleanupKind: "codex-app-server",
  }),
  "claude-code": Object.freeze({
    id: "claude-code",
    driverId: "claude-code-stream-json",
    executable: "claude",
    binaryEnvironment: ["CLAUDE_PATH", "CLAUDE_BIN"],
    acpArgs: [
      "--print", "--input-format", "stream-json", "--output-format", "stream-json",
      "--verbose", "--include-partial-messages", "--no-session-persistence",
    ],
    runtimeProtocol: "claude-code-cli-stream-json",
    laneFamily: "stream-json",
    cleanupKind: "unavailable",
    cleanupBlocker: "safe_cleanup_unavailable",
  }),
  antigravity: Object.freeze({
    id: "antigravity",
    driverId: "antigravity-cli",
    executable: "agy",
    binaryEnvironment: ["ANTIGRAVITY_PATH", "AGY_PATH"],
    acpArgs: [],
    runtimeProtocol: "antigravity-cli-structured-transport-unavailable",
    laneFamily: "unavailable",
    cleanupKind: "unavailable",
    cleanupBlocker: "antigravity_cli_structured_transport_unavailable",
  }),
});

class AcceptanceError extends Error {
  constructor(code, details = {}) {
    super(code);
    this.code = safeErrorCode(code);
    this.details = details;
  }
}

function safeErrorCode(value) {
  const normalized = String(value || "unexpected_failure").toLowerCase();
  return /^[a-z0-9][a-z0-9_-]{0,95}$/u.test(normalized)
    ? normalized
    : "unexpected_failure";
}

function requireFact(condition, code, details = {}) {
  if (!condition) {
    throw new AcceptanceError(code, details);
  }
}

function digest(value) {
  return createHash("sha256").update(stableJson(value)).digest("hex");
}

function stableJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(stableJson).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function parseArguments(argv) {
  const parsed = {
    agent: "",
    strict: false,
    selfTest: false,
    releaseUi: false,
    printLiveGate: false,
    binary: "",
    sidecar: "",
    productReceipt: "",
    cleanupProductSession: "",
    timeoutMs: Number(process.env.LICO_ACP_PARITY_TIMEOUT_MS || defaultTimeoutMs),
    maxOutputBytes: Number(process.env.LICO_ACP_PARITY_MAX_OUTPUT_BYTES || defaultMaxOutputBytes),
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--strict") {
      parsed.strict = true;
    } else if (argument === "--self-test") {
      parsed.selfTest = true;
    } else if (argument === "--release-ui") {
      parsed.releaseUi = true;
    } else if (argument === "--print-live-gate") {
      parsed.printLiveGate = true;
    } else if (["--agent", "--binary", "--sidecar", "--product-receipt", "--cleanup-product-session", "--timeout-ms", "--max-output-bytes"].includes(argument)) {
      const value = argv[index + 1];
      requireFact(typeof value === "string" && value.length > 0, "cli_argument_missing");
      index += 1;
      if (argument === "--agent") parsed.agent = normalizeAgentId(value);
      if (argument === "--binary") parsed.binary = value;
      if (argument === "--sidecar") parsed.sidecar = value;
      if (argument === "--product-receipt") parsed.productReceipt = resolve(value);
      if (argument === "--cleanup-product-session") parsed.cleanupProductSession = resolve(value);
      if (argument === "--timeout-ms") parsed.timeoutMs = Number(value);
      if (argument === "--max-output-bytes") parsed.maxOutputBytes = Number(value);
    } else {
      throw new AcceptanceError("cli_argument_unsupported");
    }
  }
  requireFact(Number.isFinite(parsed.timeoutMs) && parsed.timeoutMs >= 1_000, "timeout_invalid");
  requireFact(
    Number.isSafeInteger(parsed.maxOutputBytes)
      && parsed.maxOutputBytes >= 4 * 1024
      && parsed.maxOutputBytes <= 16 * 1024 * 1024,
    "output_limit_invalid",
  );
  if (parsed.releaseUi) {
    requireFact(parsed.strict, "release_ui_requires_strict");
    requireFact(parsed.productReceipt.length > 0, "release_ui_product_receipt_required");
  }
  if (!parsed.selfTest && !parsed.printLiveGate) {
    requireFact(parsed.agent.length > 0, "agent_required");
  }
  return parsed;
}

const readyCandidateAgentIds = Object.freeze([
  "openclaw",
  "codex",
  "opencode",
  "copilot",
  "kilo-code",
  "cursor",
  "hermes",
  "kimi-code",
  "pi",
]);

function releaseSidecarCandidates() {
  return [
    join(workspaceRoot, "build", "apps", "desktop", "runnable", "macos", "release", "Arc.app", "Contents", "MacOS", "lico-client"),
    join(workspaceRoot, "apps", "desktop", "build", "macos", "Build", "Products", "Release", "flutter_client.app", "Contents", "MacOS", "lico-client"),
  ];
}

function printLiveGateChecklist() {
  const packaged = readPackagedAgents();
  const inventory = JSON.parse(readFileSync(driversInventoryPath, "utf8"));
  const evidence = JSON.parse(readFileSync(evidenceManifestPath, "utf8"));
  const evidenceAgents = new Set(
    (Array.isArray(evidence?.adapters) ? evidence.adapters : [])
      .map((row) => row?.agentId)
      .filter((value) => typeof value === "string"),
  );
  const gates = readyCandidateAgentIds.map((agentId) => {
    const config = agentConfigs[agentId];
    const driver = inventory.drivers.find((row) => row.agentId === agentId);
    const binary = resolveExecutable("", config);
    const cleanupReady = config.cleanupKind !== "unavailable";
    return {
      agentId,
      packaged: packaged.has(agentId),
      executablePresent: Boolean(binary),
      cleanupKind: config.cleanupKind,
      cleanupReady,
      laneFamily: config.laneFamily,
      officialLane: driver?.capabilityMatrix?.officialLane === true,
      evidenceRowPresent: evidenceAgents.has(agentId),
      // Core A/B never alone promotes ready / P-10 / consecutivePasses.
      remainingLiveGate: [
        !packaged.has(agentId) ? "package_adapter" : null,
        !cleanupReady ? "implement_safe_cleanup" : null,
        !binary ? "install_agent_binary" : null,
        "authorize_side_effects",
        `node tools/scripts/client-acp-conversation-parity.mjs --agent ${agentId} --strict`,
        "npm run client:run:macos  # release .app sidecar for P-10",
        `node tools/scripts/client-acp-conversation-parity.mjs --agent ${agentId} --strict --release-ui`,
        "repeat release-ui paired runs until consecutivePasses=3 (both directions each run)",
        "node tools/scripts/client-agent-conversation-parity-reducer.mjs --write",
      ].filter(Boolean),
      neverAloneEstablishesReady: [
        "npm run client:verify:agent-conversation-parity",
        "fixture/self-test rounds",
        "core-only --strict without --release-ui",
        agentId === "codex" ? "npm run client:verify:codex-conversation:live" : null,
      ].filter(Boolean),
    };
  });
  return {
    status: "live-gate-checklist",
    cl06Ready: false,
    releaseUiPassed: false,
    contractVersion: "CL-06",
    harnessVersion: dispatchLaneHarnessVersion,
    minimumConsecutivePasses: strictRoundCount,
    note: "Core/fixture passes never set ready or sendEnabled; only reducer-backed release-UI evidence can.",
    adapters: gates,
  };
}

function normalizeAgentId(value) {
  const normalized = String(value).trim().toLowerCase().replaceAll("_", "-");
  const aliases = {
    kilo: "kilo-code",
    kilocode: "kilo-code",
    "github-copilot": "copilot",
    "hermes-agent": "hermes",
    "cursor-agent": "cursor",
    kimicode: "kimi-code",
  };
  return aliases[normalized] || normalized;
}

function parityModelForAgent(agentId) {
  const environmentKey = `LICO_${agentId.toUpperCase().replaceAll("-", "_")}_PARITY_MODEL`;
  if (process.env[environmentKey]) return process.env[environmentKey];
  if (agentId === "codex") return "";
  if (agentId === "cursor") return "Auto";
  if (agentId === "kilo-code") return "Kilo Auto Free";
  return "";
}

function readPackagedAgents() {
  let registry;
  try {
    registry = JSON.parse(readFileSync(packagingRegistryPath, "utf8"));
  } catch {
    throw new AcceptanceError("packaging_registry_invalid");
  }
  const packaged = registry?.modules?.["target-adapters"]?.targetAdapters;
  requireFact(Array.isArray(packaged), "packaging_registry_invalid");
  return new Set(packaged.filter((value) => typeof value === "string"));
}

function requireExactFields(value, fields, code) {
  requireFact(value && typeof value === "object" && !Array.isArray(value), code);
  requireFact(Object.keys(value).every((key) => fields.has(key)), code);
}

function readBoundedJson(path, maxBytes, code) {
  requireFact(typeof path === "string" && path.length > 0 && existsSync(path), code);
  const metadata = lstatSync(path);
  requireFact(metadata.isFile() && !metadata.isSymbolicLink() && metadata.size <= maxBytes, code);
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new AcceptanceError(code);
  }
}

function releaseBundleDigest(appBundle) {
  requireFact(existsSync(appBundle) && lstatSync(appBundle).isDirectory(), "release_app_missing");
  const hash = createHash("sha256");
  let fileCount = 0;
  const visit = (directory) => {
    const entries = readdirSync(directory, { withFileTypes: true })
      .sort((left, right) => left.name.localeCompare(right.name, "en"));
    for (const entry of entries) {
      const path = join(directory, entry.name);
      const name = relative(appBundle, path).replaceAll("\\", "/");
      const metadata = lstatSync(path);
      if (metadata.isDirectory()) {
        hash.update(`d\0${name}\0`);
        visit(path);
      } else if (metadata.isSymbolicLink()) {
        hash.update(`l\0${name}\0${readlinkSync(path)}\0`);
        fileCount += 1;
      } else if (metadata.isFile()) {
        hash.update(`f\0${name}\0`);
        hash.update(readFileSync(path));
        fileCount += 1;
      }
    }
  };
  visit(appBundle);
  return { digest: `sha256:${hash.digest("hex")}`, fileCount };
}

function validateProductReceipt(path, expectedAgent) {
  const report = readBoundedJson(path, 256 * 1024, "release_ui_product_receipt_invalid");
  requireExactFields(report, new Set([
    "schemaVersion", "status", "receiptKind", "platform", "buildMode",
    "productHarnessKind", "fixtureBackend", "productLivePassed", "releaseUiPassed",
    "cleanupPassed", "coreJoinRequired", "externalRuntimeInvoked", "testedAgents",
    "testedAgentCount", "composerSubmitted", "progressiveTimelineVisible",
    "sameNativeSessionId", "historyReadback", "artifactDigest", "artifactFileCount",
    "artifactName",
    "invocationChallengeDigest",
  ]), "release_ui_product_receipt_unbounded");
  requireFact(
    report.schemaVersion === "lico-agent-conversation-product-e2e-report-v3"
      && report.status === "passed"
      && report.receiptKind === "release-ui-live-product"
      && report.platform === "macos"
      && report.buildMode === "release"
      && report.productHarnessKind === "packaged-release-app-live-runtime"
      && report.fixtureBackend === false
      && report.productLivePassed === true
      && report.releaseUiPassed === false
      && report.cleanupPassed === true
      && report.coreJoinRequired === true
      && report.externalRuntimeInvoked === true
      && report.composerSubmitted === true
      && report.progressiveTimelineVisible === true
      && report.sameNativeSessionId === true
      && report.historyReadback === true
      && report.artifactName === "Arc.app"
      && report.invocationChallengeDigest === releaseClosureChallengeDigest(
        requiredReleaseClosureChallenge(process.env),
      )
      && Array.isArray(report.testedAgents)
      && report.testedAgentCount === report.testedAgents.length,
    "release_ui_product_receipt_incomplete",
  );
  const rows = report.testedAgents.filter((row) => row?.agentId === expectedAgent);
  requireFact(rows.length === 1, "release_ui_product_agent_receipt_missing");
  const row = rows[0];
  requireExactFields(row, new Set([
    "agentId", "model", "turnCount", "productLivePassed", "releaseUiPassed",
    "cleanupPassed", "nativeContinuityDigest", "productContinuityBindingDigest",
  ]), "release_ui_product_agent_receipt_unbounded");
  const expectedModel = parityModelForAgent(expectedAgent);
  requireFact(
    row.productLivePassed === true
      && row.releaseUiPassed === false
      && row.cleanupPassed === true
      && row.turnCount === 2
      && (!expectedModel || row.model === expectedModel)
      && /^sha256:[a-f0-9]{64}$/u.test(row.nativeContinuityDigest)
      && /^sha256:[a-f0-9]{64}$/u.test(row.productContinuityBindingDigest),
    "release_ui_product_agent_receipt_incomplete",
  );
  const artifact = releaseBundleDigest(packagedReleaseAppPath);
  requireFact(
    report.artifactDigest === artifact.digest && report.artifactFileCount === artifact.fileCount,
    "release_ui_product_artifact_mismatch",
  );
  const expectedContinuityBinding = productContinuityBindingDigest({
    artifactDigest: artifact.digest,
    invocationChallengeDigest: report.invocationChallengeDigest,
    agentId: row.agentId,
    model: row.model,
    nativeDigest: row.nativeContinuityDigest,
  });
  requireFact(
    row.productContinuityBindingDigest === expectedContinuityBinding,
    "release_ui_product_continuity_binding_mismatch",
  );
  return {
    artifactDigest: artifact.digest,
    continuityBindingDigest: row.productContinuityBindingDigest,
  };
}

function resolveExecutable(explicit, config) {
  const candidates = [explicit, ...config.binaryEnvironment.map((key) => process.env[key])].filter(Boolean);
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  const located = spawnSync("which", [config.executable], {
    encoding: "utf8",
    maxBuffer: 64 * 1024,
  });
  if (located.status === 0 && located.stdout.trim()) return located.stdout.trim();
  return "";
}

function sidecarSupportsDispatchLane(executable) {
  if (!executable || !existsSync(executable)) return false;
  const probe = spawnSync(
    executable,
    ["agent", "conversation", "capabilities", "--stdin-json", "true"],
    {
      input: `${JSON.stringify({ agent: "opencode" })}\n`,
      encoding: "utf8",
      maxBuffer: 256 * 1024,
      timeout: 15_000,
    },
  );
  if (probe.error || probe.status !== 0) return false;
  try {
    const parsed = JSON.parse(String(probe.stdout || "").trim());
    return parsed?.ok === true && typeof parsed?.laneFamily === "string";
  } catch {
    return false;
  }
}

function resolveSidecar(explicit, options = {}) {
  const releaseOnly = options.releaseUi === true;
  const releaseCandidates = releaseSidecarCandidates();
  const normalizedExplicit = explicit ? resolve(workspaceRoot, explicit) : "";
  const normalizedEnvironment = process.env.LICO_CLIENT_PATH
    ? resolve(workspaceRoot, process.env.LICO_CLIENT_PATH)
    : "";
  const debugCandidates = [
    // Prefer the workspace CARGO_TARGET_DIR debug build, then other debug
    // artifacts, ahead of packaged/release copies that may lag the checkout.
    // Skip binaries that do not yet expose agent.conversation.* (stale target/).
    join(workspaceRoot, "build", "crates", "lico-client-native", "target", "debug", "lico-client"),
    join(workspaceRoot, "crates", "lico-client-native", "target", "debug", "lico-client"),
    join(workspaceRoot, "target", "debug", "lico-client"),
    join(workspaceRoot, "build", "crates", "lico-client-native", "target", "release", "lico-client"),
    join(workspaceRoot, "target", "release", "lico-client"),
    join(workspaceRoot, "crates", "lico-client-native", "target", "release", "lico-client"),
  ];
  const candidates = [
    normalizedExplicit,
    normalizedEnvironment,
    ...(releaseOnly ? releaseCandidates : [...debugCandidates, ...releaseCandidates]),
  ].filter(Boolean);
  const matched = candidates.find((candidate) => sidecarSupportsDispatchLane(candidate)) || "";
  if (releaseOnly && matched) {
    const allowed = new Set([
      normalizedExplicit,
      normalizedEnvironment,
      ...releaseCandidates,
    ].filter(Boolean));
    if (!allowed.has(matched)) return "";
  }
  return matched;
}

function runDispatchLaneCli(sidecar, operation, params) {
  const result = spawnSync(
    sidecar,
    ["agent", "conversation", operation, "--stdin-json", "true"],
    {
      input: `${JSON.stringify(params)}\n`,
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
      timeout: 30_000,
    },
  );
  if (result.error || result.status !== 0) {
    return { ok: false, errorCode: "dispatch_lane_cli_failed" };
  }
  try {
    return JSON.parse(String(result.stdout || "").trim());
  } catch {
    return { ok: false, errorCode: "dispatch_lane_cli_invalid_json" };
  }
}

function assertEvidenceHygiene(evidence) {
  const text = JSON.stringify(evidence);
  const forbidden = [
    ["", "Users", ""].join("/"),
    ["", "home", ""].join("/"),
    "BEGIN PRIVATE",
    "password",
    "Authorization:",
  ];
  for (const needle of forbidden) {
    requireFact(!text.includes(needle), "evidence_hygiene_failed");
  }
}

function createSanitizedSelfTestEvidenceReceipt(probeStamp) {
  // Fixture/self-test evidence is diagnostic only. It must never mutate the
  // checked-in live-evidence authority or make the readiness reducer stale.
  let existingAdapters = [];
  try {
    const existing = JSON.parse(readFileSync(evidenceManifestPath, "utf8"));
    if (Array.isArray(existing?.adapters)) {
      existingAdapters = existing.adapters;
    }
  } catch {
    existingAdapters = [];
  }
  const evidence = {
    schemaVersion: "v0.0.1:client-agent-conversation-parity-evidence-1",
    contractVersion: "CL-06",
    harnessVersion: dispatchLaneHarnessVersion,
    toolVersionClass: probeStamp.toolVersionClass || dispatchLaneHarnessVersion,
    generatedAt: probeStamp.generatedAt || new Date().toISOString(),
    adapters: existingAdapters,
  };
  assertEvidenceHygiene(evidence);
  assertEvidenceHygiene(probeStamp);
  return {
    persisted: false,
    harnessVersion: evidence.harnessVersion,
    generatedAt: evidence.generatedAt,
    toolVersionClass: evidence.toolVersionClass,
    laneFamiliesCovered: probeStamp.laneFamiliesCovered,
    coreProbesCovered: probeStamp.coreProbesCovered,
    adapterCount: existingAdapters.length,
  };
}

function binaryDigest(binaryPath) {
  if (!binaryPath || !existsSync(binaryPath)) {
    return `sha256:${"0".repeat(64)}`;
  }
  const bytes = readFileSync(binaryPath);
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function conditionalResultForSupported(proven) {
  if (proven === true) return "pass";
  if (proven === false) return "fail";
  return "unverified";
}

function conditionalChecksFromMatrix(matrix, probes = {}) {
  const supportedStreaming = matrix?.streaming === true;
  const supportedApprovals = matrix?.approvals === true;
  const supportedMultimodal = matrix?.multimodal === true;
  const supportedUsage = matrix?.usageStatus === true;
  const supportedStructured = matrix?.structuredEvents === true;
  // Supported conditionals stay unverified until this harness records a direct
  // release-UI stream probe — never inherit external CLI-only streamingSeen.
  return {
    "C-01": supportedStreaming
      ? {
        nativeSupport: "supported",
        result: conditionalResultForSupported(probes.streaming),
      }
      : { nativeSupport: "unsupported", result: "unsupported-by-native" },
    "C-02": supportedStructured
      ? {
        nativeSupport: "supported",
        result: conditionalResultForSupported(probes.structured),
      }
      : { nativeSupport: "unsupported", result: "unsupported-by-native" },
    "C-03": supportedApprovals
      ? { nativeSupport: "supported", result: "unverified" }
      : { nativeSupport: "unsupported", result: "unsupported-by-native" },
    "C-04": supportedMultimodal
      ? { nativeSupport: "supported", result: "unverified" }
      : { nativeSupport: "unsupported", result: "unsupported-by-native" },
    "C-05": { nativeSupport: "unsupported", result: "unsupported-by-native" },
    "C-06": supportedUsage
      ? { nativeSupport: "supported", result: "unverified" }
      : { nativeSupport: "unsupported", result: "unsupported-by-native" },
  };
}

function coreChecksFromAggregate(aggregate) {
  const passOrFail = (ready) => (ready ? "pass" : "fail");
  return {
    "P-01": passOrFail(aggregate.officialNativeLane === true),
    "P-02": passOrFail(aggregate.realSessionIds === true),
    "P-03": passOrFail(aggregate.nativeToArc === true && aggregate.arcToNative === true),
    "P-04": passOrFail(aggregate.finalCanaries === true),
    "P-05": passOrFail(aggregate.settingsParity === true && aggregate.cwdParity === true),
    "P-06": passOrFail(aggregate.historyReadback === true),
    "P-07": passOrFail(
      aggregate.errorFailClosed === true && aggregate.permissionFailClosed === true,
    ),
    "P-08": passOrFail(aggregate.privacyPassed === true),
    "P-09": passOrFail(aggregate.cleanupPassed === true),
    "P-10": passOrFail(aggregate.releaseUiPassed === true),
  };
}

function writeReleaseUiAdapterEvidence(aggregate, context) {
  // Core-only CLI receipts (exactContinue/streamingSeen) never write here.
  // Only a full release-UI paired aggregate may upsert an adapter evidence row.
  if (aggregate?.status !== "release-ui-passed" || aggregate?.releaseUiPassed !== true) {
    return { written: false, reason: "release_ui_not_passed" };
  }
  if (aggregate.consecutivePasses < strictRoundCount) {
    return { written: false, reason: "consecutive_passes_incomplete" };
  }
  const packagingRegistry = JSON.parse(readFileSync(packagingRegistryPath, "utf8"));
  const inventory = JSON.parse(readFileSync(driversInventoryPath, "utf8"));
  const driver = inventory.drivers.find((row) => row.agentId === aggregate.agent);
  requireFact(Boolean(driver), "driver_inventory_missing_agent");
  const agentIds = packagedAgentIds(packagingRegistry);
  const registryDigest = registryDigestFor(agentIds);
  const inventoryDigest = driverInventoryDigestFor(inventory);
  const capabilitySnapshotDigest = `sha256:${digest(driver.capabilityMatrix)}`;
  const runtimeVersionDigest = binaryDigest(context.binary);
  const sidecarDigest = binaryDigest(context.sidecar);
  const conditionalRaw = conditionalChecksFromMatrix(driver.capabilityMatrix, {
    streaming: aggregate.streamingProven === true
      ? true
      : (aggregate.streamingProven === false ? false : undefined),
    structured: aggregate.structuredProven === true
      ? true
      : (aggregate.structuredProven === false ? false : undefined),
  });
  const conditionalChecks = Object.fromEntries(
    CONDITIONAL_CHECK_IDS.map((id) => [id, conditionalRaw[id]]),
  );
  const adapter = {
    agentId: aggregate.agent,
    driverId: driver.driverId,
    runtimeProtocol: driver.runtimeProtocol,
    harnessVersion: dispatchLaneHarnessVersion,
    runtimeVersionClass: "verified-release",
    runtimeVersionDigest,
    capabilitySnapshotDigest,
    adapterManifestDigest: adapterManifestDigestFor(aggregate.agent),
    releaseArtifactDigest: aggregate.productArtifactDigest,
    releaseSidecarDigest: sidecarDigest,
    productContinuityBindingDigest: aggregate.productContinuityBindingDigest,
    runtimeSourceClass: "discovered-binary",
    registryDigest,
    driverInventoryDigest: inventoryDigest,
    evidenceDigest: "",
    officialNativeLane: aggregate.officialNativeLane === true,
    consecutivePasses: aggregate.consecutivePasses,
    releaseUiPassed: true,
    cleanupPassed: aggregate.cleanupPassed === true,
    privacyPassed: aggregate.privacyPassed === true,
    coreChecks: coreChecksFromAggregate(aggregate),
    conditionalChecks,
  };
  adapter.evidenceDigest = adapterEvidenceDigestFor(adapter);
  assertEvidenceHygiene(adapter);
  requireFact(
    CORE_CHECK_IDS.every((id) => Object.hasOwn(adapter.coreChecks, id)),
    "evidence_core_checks_incomplete",
  );
  requireFact(
    CONDITIONAL_CHECK_IDS.every((id) => Object.hasOwn(adapter.conditionalChecks, id)),
    "evidence_conditional_checks_incomplete",
  );

  let evidence;
  try {
    evidence = JSON.parse(readFileSync(evidenceManifestPath, "utf8"));
  } catch {
    evidence = {
      schemaVersion: EVIDENCE_SCHEMA_VERSION,
      contractVersion: CONTRACT_VERSION,
      harnessVersion: dispatchLaneHarnessVersion,
      toolVersionClass: dispatchLaneHarnessVersion,
      generatedAt: new Date().toISOString(),
      adapters: [],
    };
  }
  if (!Array.isArray(evidence.adapters)) evidence.adapters = [];
  evidence.schemaVersion = EVIDENCE_SCHEMA_VERSION;
  evidence.contractVersion = CONTRACT_VERSION;
  evidence.harnessVersion = dispatchLaneHarnessVersion;
  evidence.toolVersionClass = dispatchLaneHarnessVersion;
  evidence.generatedAt = new Date().toISOString();
  evidence.adapters = [
    ...evidence.adapters.filter((row) => row?.agentId !== aggregate.agent),
    adapter,
  ].sort((left, right) => String(left.agentId).localeCompare(String(right.agentId)));
  assertEvidenceHygiene(evidence);
  const temporaryEvidencePath = `${evidenceManifestPath}.tmp-${process.pid}-${randomUUID()}`;
  writeFileSync(temporaryEvidencePath, `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporaryEvidencePath, evidenceManifestPath);
  return {
    written: true,
    agentId: aggregate.agent,
    consecutivePasses: aggregate.consecutivePasses,
    evidenceDigest: adapter.evidenceDigest,
  };
}

function probeDispatchLaneFamilies(sidecar) {
  const inventory = JSON.parse(readFileSync(driversInventoryPath, "utf8"));
  const families = new Set();
  const results = [];
  for (const driver of inventory.drivers) {
    const family = driver.capabilityMatrix?.laneFamily || "unknown";
    families.add(family);
    const caps = runDispatchLaneCli(sidecar, "capabilities", { agent: driver.agentId });
    const openNew = runDispatchLaneCli(sidecar, "open", { agent: driver.agentId });
    const stream = runDispatchLaneCli(sidecar, "stream", { agent: driver.agentId });
    const cancel = runDispatchLaneCli(sidecar, "cancel", { agent: driver.agentId });
    const resumeProbe = runDispatchLaneCli(sidecar, "open", {
      agent: driver.agentId,
      sessionId: "fixture-native-id",
    });
    const exactResume = driver.capabilityMatrix?.exactResume === true;
    const resumeFailClosed = exactResume
      ? true
      : resumeProbe?.ok === false && typeof resumeProbe?.error?.code === "string";
    const resumeOkWhenSupported = exactResume
      ? resumeProbe?.ok === true || typeof resumeProbe?.error?.code === "string"
      : true;
    results.push({
      agentId: driver.agentId,
      laneFamily: family,
      capabilitiesOk: caps?.ok === true && caps?.laneFamily === family,
      openNewOk: openNew?.ok === true || family === "unavailable",
      streamStructured: stream?.ok === true || typeof stream?.error?.code === "string",
      cancelStructured: typeof cancel?.error?.code === "string" || cancel?.ok === true,
      resumeFailClosed,
      resumeOkWhenSupported,
      // Fixture-mode P-map: dispatch-lane contract coverage only. Live A/B still
      // owns full P-01..P-10 promotion; synthetic runs never set ready.
      coreProbeMap: {
        "P-01": caps?.ok === true,
        "P-02": openNew?.ok === true || family === "unavailable",
        "P-03": resumeFailClosed && resumeOkWhenSupported,
        "P-04": stream?.ok === true || typeof stream?.error?.code === "string",
        "P-05": caps?.capabilities?.officialLane !== undefined,
        "P-06": typeof caps?.runtimeProtocol === "string",
        "P-07": typeof cancel?.error?.code === "string" || cancel?.ok === true,
        "P-08": !JSON.stringify({ caps, openNew, cancel, resumeProbe }).includes(["", "Users", ""].join("/")),
        "P-09": true,
        "P-10": false,
      },
    });
  }
  const requiredFamilies = ["acp", "app-server", "stream-json", "unavailable"];
  const covered = requiredFamilies.every((family) => families.has(family));
  const allPassed = covered && results.every(
    (row) =>
      row.capabilitiesOk
      && row.openNewOk
      && row.streamStructured
      && row.cancelStructured
      && row.resumeFailClosed
      && row.resumeOkWhenSupported
      && coreProbeIds.every((id) => id === "P-10" || row.coreProbeMap[id] === true),
  );
  return {
    ok: allPassed,
    laneFamiliesCovered: [...families].sort(),
    coreProbesCovered: coreProbeIds.filter((id) => id !== "P-10"),
    toolVersionClass: dispatchLaneHarnessVersion,
    generatedAt: new Date().toISOString(),
    rows: results.length,
  };
}

function createPrivateWrapper(directory, realBinary) {
  const wrapperPath = join(directory, "acp-runtime-wrapper");
  const capturePath = join(directory, "argv-capture");
  writeFileSync(wrapperPath, [
    "#!/bin/sh",
    "{",
    "  printf '%s\\n' '__INVOCATION__'",
    "  for argument in \"$@\"; do printf '%s\\n' \"$argument\"; done",
    "} >> \"$LICO_ACP_ARGV_CAPTURE\"",
    "exec \"$LICO_ACP_REAL_BINARY\" \"$@\"",
    "",
  ].join("\n"), { mode: 0o700 });
  chmodSync(wrapperPath, 0o700);
  return {
    wrapperPath,
    capturePath,
    environment: {
      ...process.env,
      LICO_ACP_ARGV_CAPTURE: capturePath,
      LICO_ACP_REAL_BINARY: realBinary,
    },
  };
}

function copyDisposableProfileSeed(source, destination, state, depth = 0) {
  requireFact(depth <= disposableProfileSeedMaxDepth, "disposable_profile_seed_limit");
  const metadata = lstatSync(source);
  requireFact(!metadata.isSymbolicLink(), "disposable_profile_seed_symlink");
  if (metadata.isDirectory()) {
    mkdirSync(destination, { recursive: true, mode: 0o700 });
    chmodSync(destination, 0o700);
    for (const name of readdirSync(source)) {
      copyDisposableProfileSeed(
        join(source, name),
        join(destination, name),
        state,
        depth + 1,
      );
    }
    return;
  }
  requireFact(metadata.isFile(), "disposable_profile_seed_unsupported");
  requireFact(
    state.files < disposableProfileSeedMaxFiles
      && state.bytes + metadata.size <= disposableProfileSeedMaxBytes,
    "disposable_profile_seed_limit",
  );
  const contents = readFileSync(source);
  state.files += 1;
  state.bytes += contents.length;
  writeFileSync(destination, contents, { mode: 0o600 });
  chmodSync(destination, 0o600);
}

function seedDisposableProfile(context) {
  if (!context.disposableDataRoot) return false;
  requireFact(
    dirname(context.disposableDataRoot) === context.temporaryDirectory,
    "disposable_profile_path_unsafe",
  );
  mkdirSync(context.disposableDataRoot, { recursive: true, mode: 0o700 });
  chmodSync(context.disposableDataRoot, 0o700);
  const sourceRoot = context.disposableSeedSource;
  if (!sourceRoot || !existsSync(sourceRoot)) return false;
  requireFact(
    resolve(sourceRoot) !== resolve(context.disposableDataRoot),
    "disposable_profile_seed_unsafe",
  );
  const sourceMetadata = lstatSync(sourceRoot);
  requireFact(
    sourceMetadata.isDirectory() && !sourceMetadata.isSymbolicLink(),
    "disposable_profile_seed_unsafe",
  );
  const state = { files: 0, bytes: 0 };
  for (const name of disposableProfileSeedEntries) {
    const source = join(sourceRoot, name);
    if (!existsSync(source)) continue;
    copyDisposableProfileSeed(
      source,
      join(context.disposableDataRoot, name),
      state,
    );
  }
  return state.files > 0;
}

function runBoundedProcess(executable, args, options = {}) {
  const timeoutMs = options.timeoutMs || defaultTimeoutMs;
  const maxOutputBytes = options.maxOutputBytes || defaultMaxOutputBytes;
  const stdinText = options.stdinText || "";
  return new Promise((resolveRun, rejectRun) => {
    let stdout = Buffer.alloc(0);
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let settled = false;
    let limitExceeded = false;
    const child = spawn(executable, args, {
      cwd: options.cwd || workspaceRoot,
      env: options.environment || process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const finishError = (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill();
      rejectRun(new AcceptanceError(code));
    };
    const timer = setTimeout(() => finishError("process_timeout"), timeoutMs);
    child.once("error", () => finishError("process_start_failed"));
    child.stdout.on("data", (chunk) => {
      stdoutBytes += chunk.length;
      if (stdoutBytes > maxOutputBytes) {
        limitExceeded = true;
        child.kill();
        return;
      }
      stdout = Buffer.concat([stdout, chunk]);
    });
    child.stderr.on("data", (chunk) => {
      stderrBytes += chunk.length;
      if (stderrBytes > maxOutputBytes) {
        limitExceeded = true;
        child.kill();
      }
    });
    child.once("close", (statusCode) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (limitExceeded) {
        rejectRun(new AcceptanceError("process_output_limit"));
        return;
      }
      resolveRun({
        statusCode,
        stdout: stdout.toString("utf8"),
        stdoutBytes,
        stderrBytes,
      });
    });
    child.stdin.on("error", () => {});
    child.stdin.end(stdinText);
  });
}

class AcpClient {
  constructor(executable, args, options) {
    this.timeoutMs = options.timeoutMs;
    this.maxOutputBytes = options.maxOutputBytes;
    this.outputBytes = 0;
    this.stderrBytes = 0;
    this.nextId = 1;
    this.pending = new Map();
    this.notifications = [];
    this.failure = null;
    this.closed = false;
    this.permissionRequests = 0;
    this.unsupportedRequests = 0;
    this.child = spawn(executable, args, {
      cwd: options.cwd,
      env: options.environment,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.once("error", () => this.abort("acp_start_failed"));
    this.child.once("close", () => {
      if (!this.closed && !this.failure) this.abort("acp_exited_early");
    });
    this.child.stderr.on("data", (chunk) => {
      this.stderrBytes += chunk.length;
      if (this.stderrBytes > this.maxOutputBytes) this.abort("acp_stderr_limit");
    });
    const lines = createInterface({ input: this.child.stdout });
    lines.on("line", (line) => {
      this.outputBytes += Buffer.byteLength(line) + 1;
      if (this.outputBytes > this.maxOutputBytes) {
        this.abort("acp_stdout_limit");
        return;
      }
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.abort("acp_invalid_json");
        return;
      }
      this.handleMessage(message);
    });
  }

  handleMessage(message) {
    if (message && Object.hasOwn(message, "id") && typeof message.method === "string") {
      this.handleServerRequest(message);
      return;
    }
    if (message && Object.hasOwn(message, "id")) {
      const pending = this.pending.get(String(message.id));
      if (!pending) return;
      this.pending.delete(String(message.id));
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(new AcceptanceError("acp_request_rejected"));
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    if (message && typeof message.method === "string") this.notifications.push(message);
  }

  handleServerRequest(message) {
    const method = message.method;
    const responseId = message.id;
    if (method === "session/request_permission") {
      this.permissionRequests += 1;
      this.write({
        jsonrpc: "2.0",
        id: responseId,
        result: { outcome: { outcome: "cancelled" } },
      });
      const sessionId = message?.params?.sessionId;
      if (typeof sessionId === "string" && sessionId.length > 0) {
        this.write({
          jsonrpc: "2.0",
          method: "session/cancel",
          params: { sessionId },
        });
      }
      this.abort("acp_permission_required");
      return;
    }
    this.unsupportedRequests += 1;
    this.write({
      jsonrpc: "2.0",
      id: responseId,
      error: { code: -32601, message: "Client capability is unavailable." },
    });
    this.abort("acp_client_request_unsupported");
  }

  write(message) {
    if (this.failure || !this.child.stdin.writable) {
      throw new AcceptanceError(this.failure || "acp_stdin_closed");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params) {
    const id = this.nextId++;
    return new Promise((resolveRequest, rejectRequest) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        rejectRequest(new AcceptanceError("acp_request_timeout"));
        this.abort("acp_request_timeout");
      }, this.timeoutMs);
      this.pending.set(String(id), { resolve: resolveRequest, reject: rejectRequest, timer });
      try {
        this.write({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(String(id));
        rejectRequest(error);
      }
    });
  }

  abort(code) {
    if (this.failure) return;
    this.failure = safeErrorCode(code);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new AcceptanceError(this.failure));
    }
    this.pending.clear();
    this.child.kill();
  }

  async initialize() {
    const result = await this.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {
        fs: { readTextFile: false, writeTextFile: false },
        terminal: false,
        auth: { terminal: false },
      },
      clientInfo: { name: "lico-arc-parity", title: "Lico Arc Parity", version: "1" },
    });
    requireFact(result?.protocolVersion === 1, "acp_protocol_version_mismatch");
    requireFact(result?.agentCapabilities?.loadSession === true, "acp_load_session_unavailable");
    return result;
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.child.stdin.end();
    if (this.child.exitCode === null) this.child.kill();
    await Promise.race([
      new Promise((resolveClose) => this.child.once("close", resolveClose)),
      new Promise((resolveClose) => setTimeout(resolveClose, 1_000)),
    ]);
  }
}

class PiRpcClient {
  constructor(executable, options) {
    this.timeoutMs = options.timeoutMs;
    this.maxOutputBytes = options.maxOutputBytes;
    this.outputBytes = 0;
    this.stderrBytes = 0;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    this.eventWaiters = [];
    this.buffer = Buffer.alloc(0);
    this.failure = null;
    this.closed = false;
    this.permissionRequests = 0;
    this.unsupportedRequests = 0;
    this.child = spawn(executable, ["--mode", "rpc", "--offline"], {
      cwd: options.cwd,
      env: options.environment,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.once("error", () => this.abort("pi_rpc_start_failed"));
    this.child.once("close", () => {
      if (!this.closed && !this.failure) this.abort("pi_rpc_exited_early");
    });
    this.child.stderr.on("data", (chunk) => {
      this.stderrBytes += chunk.length;
      if (this.stderrBytes > this.maxOutputBytes) this.abort("pi_rpc_stderr_limit");
    });
    this.child.stdout.on("data", (chunk) => this.handleChunk(chunk));
  }

  handleChunk(chunk) {
    this.outputBytes += chunk.length;
    if (this.outputBytes > this.maxOutputBytes) {
      this.abort("pi_rpc_stdout_limit");
      return;
    }
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const newline = this.buffer.indexOf(0x0a);
      if (newline < 0) break;
      let frame = this.buffer.subarray(0, newline);
      this.buffer = this.buffer.subarray(newline + 1);
      if (frame.at(-1) === 0x0d) frame = frame.subarray(0, frame.length - 1);
      if (frame.length === 0) continue;
      let message;
      try {
        message = JSON.parse(frame.toString("utf8"));
      } catch {
        this.abort("pi_rpc_invalid_json");
        return;
      }
      this.handleMessage(message);
    }
  }

  handleMessage(message) {
    if (message?.type === "extension_ui_request") {
      this.permissionRequests += 1;
      this.abort("pi_rpc_interaction_required");
      return;
    }
    if (message?.type === "response") {
      const pending = this.pending.get(String(message.id));
      if (!pending) return;
      this.pending.delete(String(message.id));
      clearTimeout(pending.timer);
      if (message.success !== true || message.command !== pending.command) {
        pending.reject(new AcceptanceError("pi_rpc_request_rejected"));
      } else {
        pending.resolve(message.data ?? {});
      }
      return;
    }
    const waiterIndex = this.eventWaiters.findIndex((waiter) => waiter.matches(message));
    if (waiterIndex >= 0) {
      const [waiter] = this.eventWaiters.splice(waiterIndex, 1);
      clearTimeout(waiter.timer);
      waiter.resolve(message);
    }
    this.events.push(message);
  }

  write(message) {
    if (this.failure || !this.child.stdin.writable) {
      throw new AcceptanceError(this.failure || "pi_rpc_stdin_closed");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(command, fields = {}) {
    const id = `lico-pi-${this.nextId++}`;
    return new Promise((resolveRequest, rejectRequest) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectRequest(new AcceptanceError("pi_rpc_request_timeout"));
        this.abort("pi_rpc_request_timeout");
      }, this.timeoutMs);
      this.pending.set(id, { command, resolve: resolveRequest, reject: rejectRequest, timer });
      try {
        this.write({ id, type: command, ...fields });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        rejectRequest(error);
      }
    });
  }

  waitForEvent(matches) {
    const queued = this.events.find(matches);
    if (queued) return Promise.resolve(queued);
    return new Promise((resolveEvent, rejectEvent) => {
      const waiter = { matches, resolve: resolveEvent, reject: rejectEvent, timer: null };
      waiter.timer = setTimeout(() => {
        const index = this.eventWaiters.indexOf(waiter);
        if (index >= 0) this.eventWaiters.splice(index, 1);
        rejectEvent(new AcceptanceError("pi_rpc_event_timeout"));
        this.abort("pi_rpc_event_timeout");
      }, this.timeoutMs);
      this.eventWaiters.push(waiter);
    });
  }

  abort(code) {
    if (this.failure) return;
    this.failure = safeErrorCode(code);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new AcceptanceError(this.failure));
    }
    this.pending.clear();
    for (const waiter of this.eventWaiters) {
      clearTimeout(waiter.timer);
      waiter.reject(new AcceptanceError(this.failure));
    }
    this.eventWaiters = [];
    if (this.child.exitCode === null) this.child.kill();
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.child.stdin.end();
    if (this.child.exitCode === null) this.child.kill();
    await Promise.race([
      new Promise((resolveClose) => this.child.once("close", resolveClose)),
      new Promise((resolveClose) => setTimeout(resolveClose, 1_000)),
    ]);
  }
}

class AppServerClient {
  constructor(executable, args, options) {
    this.timeoutMs = options.timeoutMs;
    this.maxOutputBytes = options.maxOutputBytes;
    this.outputBytes = 0;
    this.stderrBytes = 0;
    this.nextId = 1;
    this.pending = new Map();
    this.notifications = [];
    this.notificationWaiters = [];
    this.failure = null;
    this.closed = false;
    this.permissionRequests = 0;
    this.unsupportedRequests = 0;
    this.child = spawn(executable, args, {
      cwd: options.cwd,
      env: options.environment,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.once("error", () => this.abort("app_server_start_failed"));
    this.child.once("close", () => {
      if (!this.closed && !this.failure) this.abort("app_server_exited_early");
    });
    this.child.stderr.on("data", (chunk) => {
      this.stderrBytes += chunk.length;
      if (this.stderrBytes > this.maxOutputBytes) this.abort("app_server_stderr_limit");
    });
    const lines = createInterface({ input: this.child.stdout });
    lines.on("line", (line) => {
      this.outputBytes += Buffer.byteLength(line) + 1;
      if (this.outputBytes > this.maxOutputBytes) {
        this.abort("app_server_stdout_limit");
        return;
      }
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.abort("app_server_invalid_json");
        return;
      }
      this.handleMessage(message);
    });
  }

  handleMessage(message) {
    if (message && Object.hasOwn(message, "id") && typeof message.method === "string") {
      this.permissionRequests += 1;
      this.write({
        id: message.id,
        error: { code: -32001, message: "Parity acceptance does not approve interactions." },
      });
      this.abort("app_server_interaction_required");
      return;
    }
    if (message && Object.hasOwn(message, "id")) {
      const pending = this.pending.get(String(message.id));
      if (!pending) return;
      this.pending.delete(String(message.id));
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(new AcceptanceError("app_server_request_failed"));
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    if (!message?.method) return;
    const waiterIndex = this.notificationWaiters.findIndex((waiter) => waiter.matches(message));
    if (waiterIndex >= 0) {
      const [waiter] = this.notificationWaiters.splice(waiterIndex, 1);
      clearTimeout(waiter.timer);
      waiter.resolve(message);
    } else {
      this.notifications.push(message);
    }
  }

  write(message) {
    if (this.failure || !this.child.stdin.writable) {
      throw new AcceptanceError(this.failure || "app_server_stdin_closed");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolveRequest, rejectRequest) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        rejectRequest(new AcceptanceError("app_server_request_timeout"));
        this.abort("app_server_request_timeout");
      }, this.timeoutMs);
      this.pending.set(String(id), { resolve: resolveRequest, reject: rejectRequest, timer });
      try {
        this.write({ id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(String(id));
        rejectRequest(error);
      }
    });
  }

  notify(method, params = undefined) {
    this.write(params === undefined ? { method } : { method, params });
  }

  waitForNotification(matches) {
    const queuedIndex = this.notifications.findIndex(matches);
    if (queuedIndex >= 0) {
      return Promise.resolve(this.notifications.splice(queuedIndex, 1)[0]);
    }
    return new Promise((resolveNotification, rejectNotification) => {
      const waiter = {
        matches,
        resolve: resolveNotification,
        reject: rejectNotification,
        timer: null,
      };
      waiter.timer = setTimeout(() => {
        const index = this.notificationWaiters.indexOf(waiter);
        if (index >= 0) this.notificationWaiters.splice(index, 1);
        rejectNotification(new AcceptanceError("app_server_notification_timeout"));
        this.abort("app_server_notification_timeout");
      }, this.timeoutMs);
      this.notificationWaiters.push(waiter);
    });
  }

  abort(code) {
    if (this.failure) return;
    this.failure = safeErrorCode(code);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new AcceptanceError(this.failure));
    }
    this.pending.clear();
    for (const waiter of this.notificationWaiters) {
      clearTimeout(waiter.timer);
      waiter.reject(new AcceptanceError(this.failure));
    }
    this.notificationWaiters = [];
    this.child.kill();
  }

  async initialize() {
    await this.request("initialize", {
      clientInfo: { name: "lico-arc-parity", title: "Lico Arc Parity", version: "1" },
      capabilities: { experimentalApi: true },
    });
    this.notify("initialized");
    return { protocolVersion: 1 };
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.child.stdin.end();
    if (this.child.exitCode === null) this.child.kill();
    await Promise.race([
      new Promise((resolveClose) => this.child.once("close", resolveClose)),
      new Promise((resolveClose) => setTimeout(resolveClose, 1_000)),
    ]);
  }
}

function appServerFinalMessage(turn) {
  const items = Array.isArray(turn?.items) ? turn.items : [];
  for (let index = items.length - 1; index >= 0; index -= 1) {
    if (items[index]?.type === "agentMessage" && typeof items[index].text === "string") {
      return items[index].text.trim();
    }
  }
  return "";
}

function appServerSettings(threadResult, cwd, expectedModel = "", expectedEffort = "") {
  return {
    cwd,
    // `turn/start` can override the thread defaults. Parity is defined over
    // the settings of the completed turn, so an explicit turn request wins.
    // The current app-server schema does not expose the resolved default
    // model/effort on Turn. Compare only an explicit acceptance override;
    // otherwise report the selection as runtime-owned instead of inferring it
    // from optional thread response extensions that differ on start/resume.
    model: expectedModel || null,
    reasoningEffort: expectedEffort || null,
    mode: null,
    runtimeAgent: null,
    allowAll: null,
  };
}

async function withAppServer(context, operation) {
  const client = new AppServerClient(
    context.wrapper.wrapperPath,
    context.config.acpArgs,
    { ...context, environment: context.wrapper.environment },
  );
  try {
    await client.initialize();
    return await operation(client);
  } finally {
    await client.close();
  }
}

async function runAppServerTurn(client, threadId, prompt, model = "", effort = "") {
  const result = await client.request("turn/start", {
    threadId,
    input: [{ type: "text", text: prompt }],
    ...(model ? { model } : {}),
    ...(effort ? { effort } : {}),
  });
  const turnId = result?.turn?.id;
  requireFact(typeof turnId === "string" && turnId.length > 0, "native_turn_id_missing");
  let completed;
  try {
    completed = await client.waitForNotification(
      (message) => message.method === "turn/completed"
        && message.params?.threadId === threadId
        && message.params?.turn?.id === turnId,
    );
  } catch (error) {
    if (!(error instanceof AcceptanceError)
      || error.code !== "app_server_notification_timeout") throw error;
    const saw = (method) => client.notifications.some((message) => message.method === method);
    const diagnosticMask = [
      saw("turn/started"),
      saw("item/agentMessage/delta"),
      saw("item/completed"),
      saw("turn/completed"),
    ].map((value) => value ? "1" : "0").join("");
    throw new AcceptanceError(`app_server_terminal_timeout_m${diagnosticMask}`);
  }
  const turnStatus = String(completed.params?.turn?.status || "").toLowerCase();
  requireFact(turnStatus === "completed", "native_turn_not_completed");
  const completedItems = client.notifications
    .filter((message) => message.method === "item/completed"
      && message.params?.threadId === threadId
      && message.params?.turnId === turnId)
    .map((message) => message.params?.item)
    .filter(Boolean);
  return {
    ...completed.params.turn,
    items: [
      ...(Array.isArray(completed.params.turn.items) ? completed.params.turn.items : []),
      ...completedItems,
    ],
  };
}

async function nativeAppServerTurn(context, requestedSessionId, prompt) {
  const forcedModel = context.config.id === "codex"
    ? (process.env.LICO_CODEX_PARITY_MODEL || "")
    : "";
  const forcedEffort = context.config.id === "codex"
    ? (process.env.LICO_CODEX_PARITY_REASONING_EFFORT
      || (String(forcedModel).toLowerCase().includes("spark") ? "low" : ""))
    : "";
  return withAppServer(context, async (client) => {
    let threadResult;
    let sessionId = requestedSessionId;
    if (requestedSessionId) {
      threadResult = await client.request("thread/resume", { threadId: requestedSessionId });
      sessionId = threadResult?.thread?.id || requestedSessionId;
    } else {
      threadResult = await client.request("thread/start", {
        cwd: context.cwd,
        ...(forcedModel ? { model: forcedModel } : {}),
      });
      sessionId = threadResult?.thread?.id || "";
    }
    requireFact(typeof sessionId === "string" && sessionId.length > 0, "native_session_id_missing");
    requireFact(
      !requestedSessionId || sessionId === requestedSessionId,
      "native_session_identity_mismatch",
    );
    context.observedSessions?.add(sessionId);
    const turn = await runAppServerTurn(client, sessionId, prompt, forcedModel, forcedEffort);
    const output = appServerFinalMessage(turn);
    requireFact(output.length > 0, "native_final_message_missing");
    return {
      sessionId,
      output,
      historyNotifications: [],
      settings: appServerSettings(
        threadResult,
        context.cwd,
        forcedModel,
        forcedEffort,
      ),
      protocolVersion: 1,
      permissionRequests: client.permissionRequests,
      unsupportedRequests: client.unsupportedRequests,
      boundedOutput: client.outputBytes <= context.maxOutputBytes
        && client.stderrBytes <= context.maxOutputBytes,
    };
  });
}

async function nativeAppServerReadback(context, sessionId) {
  const forcedModel = context.config.id === "codex"
    ? (process.env.LICO_CODEX_PARITY_MODEL || "")
    : "";
  const forcedEffort = context.config.id === "codex"
    ? (process.env.LICO_CODEX_PARITY_REASONING_EFFORT
      || (String(forcedModel).toLowerCase().includes("spark") ? "low" : ""))
    : "";
  return withAppServer(context, async (client) => {
    const result = await client.request("thread/read", {
      threadId: sessionId,
      includeTurns: true,
    });
    requireFact(result?.thread?.id === undefined || result.thread.id === sessionId, "readback_session_identity_mismatch");
    const turns = Array.isArray(result?.thread?.turns) ? result.thread.turns : [];
    const text = turns
      .flatMap((turn) => Array.isArray(turn?.items) ? turn.items : [])
      .filter((item) => item?.type === "agentMessage" && typeof item.text === "string")
      .map((item) => item.text)
      .join("");
    return {
      text,
      settings: appServerSettings(result, context.cwd, forcedModel, forcedEffort),
      boundedOutput: client.outputBytes <= context.maxOutputBytes
        && client.stderrBytes <= context.maxOutputBytes,
    };
  });
}

function sessionSettings(result, cwd) {
  const options = Array.isArray(result?.configOptions) ? result.configOptions : [];
  const optionValue = (ids) => {
    const option = options.find((candidate) => ids.includes(candidate?.id));
    if (!option) return null;
    if (Object.hasOwn(option, "currentValue")) return option.currentValue;
    if (Object.hasOwn(option, "value")) return option.value;
    return null;
  };
  return {
    cwd,
    model: optionValue(["model"]) ?? result?.models?.currentModelId ?? null,
    reasoningEffort: optionValue(["reasoning_effort", "variant"]) ?? null,
    mode: optionValue(["mode"]) ?? result?.modes?.currentModeId ?? null,
    runtimeAgent: optionValue(["agent"]) ?? null,
    allowAll: optionValue(["allow_all"]),
  };
}

function arcSettings(result) {
  const effective = result?.effective || {};
  return {
    cwd: effective.cwd ?? result?.workingDirectory ?? result?.cwd ?? null,
    model: effective.model ?? result?.model ?? null,
    reasoningEffort: effective.reasoningEffort ?? result?.reasoningEffort ?? null,
    mode: effective.mode ?? null,
    runtimeAgent: effective.runtimeAgent ?? null,
    allowAll: effective.allowAll ?? null,
  };
}

function notificationTexts(notifications, expectedSessionId = "") {
  const matched = [];
  let sessionMismatch = false;
  for (const notification of notifications) {
    if (notification?.method !== "session/update") continue;
    const notificationSessionId = notification?.params?.sessionId;
    if (expectedSessionId && notificationSessionId !== expectedSessionId) {
      sessionMismatch = true;
      continue;
    }
    const update = notification?.params?.update;
    const kind = update?.sessionUpdate;
    if (["agent_message_chunk", "agent_message"].includes(kind)) {
      const text = update?.content?.text;
      if (typeof text === "string") matched.push(text);
    }
  }
  return { text: matched.join(""), sessionMismatch };
}

function piSessionFiles(root, limit = 4096) {
  const files = [];
  const stack = [root];
  while (stack.length > 0 && files.length < limit) {
    const directory = stack.pop();
    if (!existsSync(directory)) continue;
    for (const name of readdirSync(directory).sort()) {
      const path = join(directory, name);
      const metadata = lstatSync(path);
      if (metadata.isSymbolicLink()) continue;
      if (metadata.isDirectory()) stack.push(path);
      else if (metadata.isFile() && name.endsWith(".jsonl")) files.push(path);
      if (files.length >= limit) break;
    }
  }
  return files;
}

function piSessionHeader(path) {
  const metadata = lstatSync(path);
  requireFact(metadata.isFile() && !metadata.isSymbolicLink(), "pi_session_file_unsafe");
  const bytes = Buffer.alloc(64 * 1024);
  const descriptor = openSync(path, "r");
  let count;
  try {
    count = readSync(descriptor, bytes, 0, bytes.length, 0);
  } finally {
    closeSync(descriptor);
  }
  const newline = bytes.subarray(0, count).indexOf(0x0a);
  if (newline < 0) return null;
  const first = bytes.subarray(0, newline).toString("utf8").replace(/\r$/u, "");
  try {
    const header = JSON.parse(first);
    return header?.type === "session" && typeof header?.id === "string" ? header : null;
  } catch {
    return null;
  }
}

function piSessionPath(context, sessionId) {
  const matches = piSessionFiles(context.disposableDataRoot)
    .filter((path) => piSessionHeader(path)?.id === sessionId);
  requireFact(matches.length === 1, matches.length === 0
    ? "pi_session_not_found"
    : "pi_session_identity_ambiguous");
  return matches[0];
}

function piModelIdentity(model) {
  if (!model || typeof model !== "object") return null;
  const provider = typeof model.provider === "string" ? model.provider : "";
  const id = typeof model.id === "string" ? model.id
    : (typeof model.modelId === "string" ? model.modelId : "");
  return provider && id ? `${provider}/${id}` : null;
}

function piSettings(state, cwd) {
  return {
    cwd,
    model: piModelIdentity(state?.model),
    reasoningEffort: typeof state?.thinkingLevel === "string" ? state.thinkingLevel : null,
    mode: null,
    runtimeAgent: null,
    allowAll: null,
  };
}

function piMessageText(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(piMessageText).join("");
  if (!value || typeof value !== "object") return "";
  if (value.type === "text" && typeof value.text === "string") return value.text;
  return piMessageText(value.content || value.message || []);
}

async function withPiRpc(context, operation) {
  const client = new PiRpcClient(context.wrapper.wrapperPath, {
    ...context,
    environment: context.wrapper.environment,
  });
  try {
    return await operation(client);
  } finally {
    await client.close();
  }
}

async function nativePiTurn(context, requestedSessionId, prompt) {
  return withPiRpc(context, async (client) => {
    if (requestedSessionId) {
      const switched = await client.request("switch_session", {
        sessionPath: piSessionPath(context, requestedSessionId),
      });
      requireFact(switched?.cancelled !== true, "pi_session_switch_cancelled");
    }
    const state = await client.request("get_state");
    const sessionId = state?.sessionId || "";
    requireFact(typeof sessionId === "string" && sessionId.length > 0, "native_session_id_missing");
    requireFact(!requestedSessionId || sessionId === requestedSessionId, "native_session_identity_mismatch");
    context.observedSessions?.add(sessionId);
    const eventStart = client.events.length;
    await client.request("prompt", { message: prompt });
    await client.waitForEvent((event) => event?.type === "agent_settled");
    const final = await client.request("get_last_assistant_text");
    const output = typeof final?.text === "string" ? final.text.trim() : "";
    requireFact(output.length > 0, "native_final_message_missing");
    const turnEvents = client.events.slice(eventStart);
    requireFact(
      turnEvents.some((event) => event?.type === "message_update"
        && event?.assistantMessageEvent?.type === "text_delta"),
      "native_streaming_missing",
    );
    return {
      sessionId,
      output,
      historyNotifications: [],
      settings: piSettings(state, context.cwd),
      protocolVersion: 1,
      permissionRequests: client.permissionRequests,
      unsupportedRequests: client.unsupportedRequests,
      boundedOutput: client.outputBytes <= context.maxOutputBytes
        && client.stderrBytes <= context.maxOutputBytes,
    };
  });
}

async function nativePiReadback(context, sessionId) {
  return withPiRpc(context, async (client) => {
    const switched = await client.request("switch_session", {
      sessionPath: piSessionPath(context, sessionId),
    });
    requireFact(switched?.cancelled !== true, "pi_session_switch_cancelled");
    const state = await client.request("get_state");
    requireFact(state?.sessionId === sessionId, "readback_session_identity_mismatch");
    const result = await client.request("get_messages");
    return {
      text: piMessageText(result?.messages || []),
      settings: piSettings(state, context.cwd),
      boundedOutput: client.outputBytes <= context.maxOutputBytes
        && client.stderrBytes <= context.maxOutputBytes,
    };
  });
}

async function nativeTurn(context, requestedSessionId, prompt) {
  if (context.config.laneFamily === "app-server") {
    return nativeAppServerTurn(context, requestedSessionId, prompt);
  }
  if (context.config.laneFamily === "rpc") {
    return nativePiTurn(context, requestedSessionId, prompt);
  }
  const client = new AcpClient(
    context.wrapper.wrapperPath,
    context.config.acpArgs,
    { ...context, environment: context.wrapper.environment },
  );
  try {
    const initializeResult = await client.initialize();
    const historyStart = client.notifications.length;
    const method = requestedSessionId ? "session/load" : "session/new";
    const params = { cwd: context.cwd, mcpServers: [] };
    if (requestedSessionId) params.sessionId = requestedSessionId;
    const sessionResult = await client.request(method, params);
    const sessionId = requestedSessionId || sessionResult?.sessionId || "";
    requireFact(typeof sessionId === "string" && sessionId.length > 0, "native_session_id_missing");
    requireFact(
      !requestedSessionId || sessionResult?.sessionId === undefined || sessionResult.sessionId === requestedSessionId,
      "native_session_identity_mismatch",
    );
    context.observedSessions?.add(sessionId);
    const forcedModel = parityModelForAgent(context.config.id);
    if (forcedModel) {
      await client.request("session/set_config_option", {
        sessionId,
        configId: "model",
        value: forcedModel,
      });
    }
    const historyNotifications = client.notifications.slice(historyStart);
    const promptStart = client.notifications.length;
    const promptResult = await client.request("session/prompt", {
      sessionId,
      messageId: randomUUID(),
      prompt: [{ type: "text", text: prompt }],
    });
    requireFact(promptResult?.stopReason === "end_turn", "native_turn_not_completed");
    const turnNotifications = client.notifications.slice(promptStart);
    const final = notificationTexts(turnNotifications, sessionId);
    requireFact(!final.sessionMismatch, "native_event_session_mismatch");
    requireFact(final.text.length > 0, "native_final_message_missing");
    return {
      sessionId,
      output: final.text.trim(),
      historyNotifications,
      settings: sessionSettings(sessionResult, context.cwd),
      protocolVersion: initializeResult.protocolVersion,
      permissionRequests: client.permissionRequests,
      unsupportedRequests: client.unsupportedRequests,
      boundedOutput: client.outputBytes <= context.maxOutputBytes
        && client.stderrBytes <= context.maxOutputBytes,
    };
  } finally {
    await client.close();
  }
}

async function nativeReadback(context, sessionId) {
  if (context.config.laneFamily === "app-server") {
    return nativeAppServerReadback(context, sessionId);
  }
  if (context.config.laneFamily === "rpc") {
    return nativePiReadback(context, sessionId);
  }
  const client = new AcpClient(
    context.wrapper.wrapperPath,
    context.config.acpArgs,
    { ...context, environment: context.wrapper.environment },
  );
  try {
    await client.initialize();
    const start = client.notifications.length;
    const result = await client.request("session/load", {
      sessionId,
      cwd: context.cwd,
      mcpServers: [],
    });
    requireFact(result?.sessionId === undefined || result.sessionId === sessionId, "readback_session_identity_mismatch");
    const notifications = client.notifications.slice(start);
    const text = notificationTexts(notifications, sessionId);
    requireFact(!text.sessionMismatch, "readback_event_session_mismatch");
    return {
      text: text.text,
      settings: sessionSettings(result, context.cwd),
      boundedOutput: client.outputBytes <= context.maxOutputBytes
        && client.stderrBytes <= context.maxOutputBytes,
    };
  } finally {
    await client.close();
  }
}

function parseSidecarStreamStdout(stdout) {
  const events = [];
  let result = null;
  for (const line of String(stdout || "").split(/\r?\n/u)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let parsed;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      throw new AcceptanceError("sidecar_invalid_json");
    }
    const eventKind = typeof parsed?.event === "string" ? parsed.event : "";
    if (eventKind && eventKind !== "done") {
      events.push(eventKind);
    }
    if (parsed?.event === "done" || Object.hasOwn(parsed || {}, "ok")) {
      result = parsed;
    }
  }
  if (!result) {
    throw new AcceptanceError("sidecar_invalid_json");
  }
  const streamingSeen = events.includes("agent.message.chunk");
  const structuredSeen = events.includes("agent.message.completed")
    && (events.includes("dispatch.turn.started") || events.includes("agent.message.chunk"));
  return { result, events, streamingSeen, structuredSeen };
}

async function runSidecar(context, request) {
  const streamEvents = request?.streamEvents === true;
  const args = streamEvents
    ? [...sidecarArgs, "--stream-events", "true"]
    : sidecarArgs;
  const run = await runBoundedProcess(
    context.sidecar,
    args,
    {
      cwd: context.cwd,
      environment: context.wrapper.environment,
      timeoutMs: context.timeoutMs,
      maxOutputBytes: context.maxOutputBytes,
      stdinText: JSON.stringify({ ...request, acceptanceMode }),
    },
  );
  let result;
  let streamingSeen = false;
  let structuredSeen = false;
  try {
    if (streamEvents) {
      const parsed = parseSidecarStreamStdout(run.stdout);
      result = parsed.result;
      streamingSeen = parsed.streamingSeen;
      structuredSeen = parsed.structuredSeen;
    } else {
      result = JSON.parse(run.stdout);
    }
  } catch {
    throw new AcceptanceError(
      run.statusCode === 0 ? "sidecar_invalid_json" : "sidecar_process_failed",
    );
  }
  if (result?.ok !== true) {
    const code = safeErrorCode(result?.error?.code || "sidecar_rejected");
    throw new AcceptanceError(code);
  }
  requireFact(run.statusCode === 0, "sidecar_process_failed");
  requireFact(result?.schemaVersion === 3, "sidecar_schema_mismatch");
  requireFact(result?.adapterId === context.config.id, "sidecar_adapter_mismatch");
  requireFact(result?.driverId === context.config.driverId, "sidecar_driver_mismatch");
  requireFact(result?.runtimeProtocol === context.config.runtimeProtocol, "sidecar_protocol_mismatch");
  requireFact(
    result?.turnStatus === "end_turn" || result?.turnStatus === "completed",
    "sidecar_turn_not_completed",
  );
  const nativeSessionId = result?.nativeSessionId || result?.sessionId || "";
  if (typeof nativeSessionId === "string" && nativeSessionId.length > 0) {
    context.observedSessions?.add(nativeSessionId);
  }
  return {
    result,
    streamingSeen,
    structuredSeen,
    boundedOutput: run.stdoutBytes <= context.maxOutputBytes
      && run.stderrBytes <= context.maxOutputBytes,
  };
}

function collectSessionRecords(value, records = new Map()) {
  if (Array.isArray(value)) {
    for (const entry of value) collectSessionRecords(entry, records);
    return records;
  }
  if (!value || typeof value !== "object") return records;
  const id = [value.id, value.sessionId, value.sessionID].find(
    (candidate) => typeof candidate === "string" && candidate.length > 0,
  );
  if (id) records.set(id, stableJson(value));
  for (const child of Object.values(value)) collectSessionRecords(child, records);
  return records;
}

function readDisposableKimiHistory(context, sessionId) {
  requireFact(
    typeof sessionId === "string"
      && /^[a-z0-9][a-z0-9._-]{0,255}$/iu.test(sessionId),
    "history_session_id_unsafe",
  );
  const sessionsRoot = join(context.disposableDataRoot, "sessions");
  if (!existsSync(sessionsRoot)) return "";
  const chunks = [];
  for (const workspaceName of readdirSync(sessionsRoot)) {
    const workspacePath = join(sessionsRoot, workspaceName);
    const workspaceMetadata = lstatSync(workspacePath);
    if (!workspaceMetadata.isDirectory() || workspaceMetadata.isSymbolicLink()) {
      continue;
    }
    const wirePath = join(
      workspacePath,
      sessionId,
      "agents",
      "main",
      "wire.jsonl",
    );
    if (!existsSync(wirePath)) continue;
    const wireMetadata = lstatSync(wirePath);
    requireFact(
      wireMetadata.isFile()
        && !wireMetadata.isSymbolicLink()
        && wireMetadata.size <= context.maxOutputBytes,
      "session_export_limit",
    );
    chunks.push(readFileSync(wirePath, "utf8"));
  }
  return chunks.join("\n");
}

class CopilotSdkRpcClient {
  constructor(context, launchArgs) {
    this.context = context;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.stdoutBytes = 0;
    this.stderrBytes = 0;
    this.failure = null;
    this.closed = false;
    this.child = spawn(context.binary, launchArgs, {
      cwd: context.cwd,
      env: context.environment,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.once("error", () => this.abort("copilot_sdk_start_failed"));
    this.child.once("close", () => {
      if (!this.closed && !this.failure) this.abort("copilot_sdk_exited_early");
    });
    this.child.stderr.on("data", (chunk) => {
      this.stderrBytes += chunk.length;
      if (this.stderrBytes > context.maxOutputBytes) this.abort("copilot_sdk_stderr_limit");
    });
    this.child.stdout.on("data", (chunk) => this.handleChunk(chunk));
  }

  handleChunk(chunk) {
    this.stdoutBytes += chunk.length;
    if (this.stdoutBytes > this.context.maxOutputBytes) {
      this.abort("copilot_sdk_stdout_limit");
      return;
    }
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const header = this.buffer.subarray(0, headerEnd).toString("ascii");
      const match = header.match(/(?:^|\r\n)Content-Length:\s*(\d+)(?:\r\n|$)/iu);
      if (!match) {
        this.abort("copilot_sdk_invalid_frame");
        return;
      }
      const bodyLength = Number(match[1]);
      if (!Number.isSafeInteger(bodyLength) || bodyLength < 0 || bodyLength > this.context.maxOutputBytes) {
        this.abort("copilot_sdk_frame_limit");
        return;
      }
      const bodyStart = headerEnd + 4;
      if (this.buffer.length < bodyStart + bodyLength) return;
      const body = this.buffer.subarray(bodyStart, bodyStart + bodyLength);
      this.buffer = this.buffer.subarray(bodyStart + bodyLength);
      let message;
      try {
        message = JSON.parse(body.toString("utf8"));
      } catch {
        this.abort("copilot_sdk_invalid_json");
        return;
      }
      this.handleMessage(message);
    }
  }

  handleMessage(message) {
    if (message && Object.hasOwn(message, "id") && typeof message.method === "string") {
      this.write({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32601, message: "Client capability is unavailable." },
      });
      this.abort("copilot_sdk_client_request_unsupported");
      return;
    }
    if (!message || !Object.hasOwn(message, "id")) return;
    const pending = this.pending.get(String(message.id));
    if (!pending) return;
    this.pending.delete(String(message.id));
    clearTimeout(pending.timer);
    if (message.error) {
      pending.reject(new AcceptanceError("copilot_sdk_request_rejected", {
        rpcCode: Number(message.error.code),
      }));
    } else {
      pending.resolve(message.result);
    }
  }

  write(message) {
    if (this.failure || !this.child.stdin.writable) {
      throw new AcceptanceError(this.failure || "copilot_sdk_stdin_closed");
    }
    const body = Buffer.from(JSON.stringify(message), "utf8");
    const header = Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, "ascii");
    this.child.stdin.write(Buffer.concat([header, body]));
  }

  request(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolveRequest, rejectRequest) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        rejectRequest(new AcceptanceError("copilot_sdk_request_timeout"));
        this.abort("copilot_sdk_request_timeout");
      }, Math.min(this.context.timeoutMs, 30_000));
      this.pending.set(String(id), { resolve: resolveRequest, reject: rejectRequest, timer });
      try {
        this.write({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(String(id));
        rejectRequest(error);
      }
    });
  }

  async connect() {
    let result;
    try {
      result = await this.request("connect", { enableGitHubTelemetryForwarding: false });
    } catch (error) {
      if (!(error instanceof AcceptanceError) || error.details?.rpcCode !== -32601) throw error;
      result = await this.request("ping", {});
    }
    requireFact(Number.isInteger(result?.protocolVersion), "copilot_sdk_protocol_missing");
  }

  abort(code) {
    if (this.failure) return;
    this.failure = safeErrorCode(code);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new AcceptanceError(this.failure));
    }
    this.pending.clear();
    this.child.kill();
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.child.stdin.end();
    if (this.child.exitCode === null) this.child.kill();
    await Promise.race([
      new Promise((resolveClose) => this.child.once("close", resolveClose)),
      new Promise((resolveClose) => setTimeout(resolveClose, 1_000)),
    ]);
  }
}

async function withCopilotSdkRpc(context, operation) {
  const launchVariants = context.copilotSdkLaunchArgs
    ? [context.copilotSdkLaunchArgs]
    : [
      ["--server", "--stdio", "--no-auto-update"],
      ["--headless", "--no-auto-update", "--stdio"],
    ];
  let lastError = new AcceptanceError("copilot_sdk_start_failed");
  for (const launchArgs of launchVariants) {
    const client = new CopilotSdkRpcClient(context, launchArgs);
    try {
      await client.connect();
      context.copilotSdkLaunchArgs = launchArgs;
      try {
        return await operation(client);
      } finally {
        await client.close();
      }
    } catch (error) {
      lastError = error instanceof AcceptanceError ? error : lastError;
      await client.close();
    }
  }
  throw lastError;
}

async function withOpenClawAcp(context, operation) {
  const client = new AcpClient(
    context.wrapper.wrapperPath,
    context.config.acpArgs,
    { ...context, environment: context.wrapper.environment },
  );
  try {
    const initialized = await client.initialize();
    return await operation(client, initialized);
  } finally {
    await client.close();
  }
}

function codexThreadListItems(result) {
  if (Array.isArray(result?.threads)) return result.threads;
  if (Array.isArray(result?.data)) return result.data;
  return null;
}

async function listSessions(context) {
  if (context.config.cleanupKind === "pi-disposable-session-root") {
    const records = new Map();
    for (const path of piSessionFiles(context.disposableDataRoot)) {
      const header = piSessionHeader(path);
      if (header?.id) records.set(header.id, stableJson({ id: header.id }));
    }
    return records;
  }
  if (context.config.cleanupKind === "disposable-data-root") {
    const records = new Map();
    for (const sessionId of context.observedSessions || []) {
      if (!context.cleanedSessions?.has(sessionId)) records.set(sessionId, "isolated-session");
    }
    return records;
  }
  if (context.config.cleanupKind === "codex-app-server") {
    return withAppServer(context, async (client) => {
      const result = await client.request("thread/list", {});
      const threads = codexThreadListItems(result);
      requireFact(Array.isArray(threads), "codex_app_server_list_unavailable");
      return collectSessionRecords(
        threads.map((thread) => ({
          id: thread?.id || thread?.threadId || thread?.sessionId,
          sessionId: thread?.id || thread?.threadId || thread?.sessionId,
        })),
      );
    });
  }
  if (context.config.cleanupKind === "copilot-sdk") {
    return withCopilotSdkRpc(context, async (client) => {
      const result = await client.request("session.list", {});
      return collectSessionRecords(result?.sessions || []);
    });
  }
  if (context.config.cleanupKind === "openclaw-acp") {
    return withOpenClawAcp(context, async (client) => {
      const result = await client.request("session/list", { cwd: context.cwd });
      return collectSessionRecords(result?.sessions || []);
    });
  }
  const run = await runBoundedProcess(context.binary, context.config.listArgs, {
    cwd: context.cwd,
    environment: context.environment,
    timeoutMs: Math.min(context.timeoutMs, 30_000),
    maxOutputBytes: context.maxOutputBytes,
  });
  requireFact(run.statusCode === 0, "session_list_failed");
  if (context.config.cleanupKind === "openagent-cli") {
    let parsed;
    try {
      parsed = JSON.parse(run.stdout);
    } catch {
      throw new AcceptanceError("session_list_invalid_json");
    }
    return collectSessionRecords(parsed);
  }
  const records = new Map();
  for (const line of run.stdout.split(/\r?\n/u)) {
    const id = line.trim().split(/\s+/u).at(-1) || "";
    if (/^\d{8}_\d{6}_[a-f0-9]{6,}$/iu.test(id)) records.set(id, line);
  }
  return records;
}

async function officialHistory(context, sessionId, temporaryDirectory) {
  if (context.config.cleanupKind === "pi-disposable-session-root") {
    const path = piSessionPath(context, sessionId);
    const metadata = lstatSync(path);
    requireFact(metadata.size <= context.maxOutputBytes, "session_export_limit");
    return readFileSync(path, "utf8");
  }
  if (context.config.cleanupKind === "disposable-data-root") {
    return readDisposableKimiHistory(context, sessionId);
  }
  if (context.config.cleanupKind === "codex-app-server") {
    return withAppServer(context, async (client) => {
      const result = await client.request("thread/read", {
        threadId: sessionId,
        includeTurns: true,
      });
      const turns = Array.isArray(result?.thread?.turns) ? result.thread.turns : [];
      return turns
        .flatMap((turn) => Array.isArray(turn?.items) ? turn.items : [])
        .filter((item) => item?.type === "agentMessage" && typeof item.text === "string")
        .map((item) => item.text)
        .join("\n");
    });
  }
  if (context.config.cleanupKind === "openagent-cli") {
    const run = await runBoundedProcess(context.binary, context.config.exportArgs(sessionId), {
      cwd: context.cwd,
      environment: context.environment,
      timeoutMs: Math.min(context.timeoutMs, 30_000),
      maxOutputBytes: context.maxOutputBytes,
    });
    requireFact(run.statusCode === 0, "session_export_failed");
    return run.stdout;
  }
  if (context.config.cleanupKind === "hermes-cli") {
    const destination = join(temporaryDirectory, `history-${randomUUID()}.jsonl`);
    const run = await runBoundedProcess(
      context.binary,
      ["sessions", "export", destination, "--session-id", sessionId, "--redact"],
      {
        cwd: context.cwd,
        environment: context.environment,
        timeoutMs: Math.min(context.timeoutMs, 30_000),
        maxOutputBytes: context.maxOutputBytes,
      },
    );
    requireFact(run.statusCode === 0 && existsSync(destination), "session_export_failed");
    requireFact(statSync(destination).size <= context.maxOutputBytes, "session_export_limit");
    return readFileSync(destination, "utf8");
  }
  return "";
}

async function cleanupSession(context, sessionId, temporaryDirectory) {
  try {
    if (context.config.cleanupKind === "pi-disposable-session-root") {
      requireFact(
        context.disposableDataRoot && dirname(context.disposableDataRoot) === context.temporaryDirectory,
        "disposable_profile_path_unsafe",
      );
      rmSync(context.disposableDataRoot, { recursive: true, force: true });
      mkdirSync(context.disposableDataRoot, { recursive: true, mode: 0o700 });
      for (const observed of context.observedSessions || []) context.cleanedSessions.add(observed);
      context.cleanedSessions.add(sessionId);
      return true;
    }
    if (context.config.cleanupKind === "disposable-data-root") {
      requireFact(
        context.disposableDataRoot && dirname(context.disposableDataRoot) === context.temporaryDirectory,
        "disposable_profile_path_unsafe",
      );
      rmSync(context.disposableDataRoot, { recursive: true, force: true });
      mkdirSync(context.disposableDataRoot, { recursive: true, mode: 0o700 });
      seedDisposableProfile(context);
      context.cleanedSessions.add(sessionId);
      return true;
    }
    if (context.config.cleanupKind === "codex-app-server") {
      await withAppServer(context, async (client) => {
        await client.request("thread/delete", { threadId: sessionId });
        const result = await client.request("thread/list", {});
        const threads = codexThreadListItems(result);
        requireFact(Array.isArray(threads), "codex_app_server_list_unavailable");
        const remaining = collectSessionRecords(
          threads.map((thread) => ({
            id: thread?.id || thread?.threadId || thread?.sessionId,
            sessionId: thread?.id || thread?.threadId || thread?.sessionId,
          })),
        );
        requireFact(!remaining.has(sessionId), "session_cleanup_not_verified");
      });
      return true;
    }
    if (context.config.cleanupKind === "copilot-sdk") {
      await withCopilotSdkRpc(context, async (client) => {
        await client.request("session.delete", { sessionId });
        const result = await client.request("session.list", {});
        requireFact(
          !collectSessionRecords(result?.sessions || []).has(sessionId),
          "session_cleanup_not_verified",
        );
      });
      return true;
    }
    if (context.config.cleanupKind === "openclaw-acp") {
      await withOpenClawAcp(context, async (client) => {
        await client.request("session/close", { sessionId });
        // OpenClaw documents duplicate close as part of the ACP lifecycle
        // smoke contract. Requiring it here proves cleanup is idempotent.
        await client.request("session/close", { sessionId });
        const result = await client.request("session/list", {
          cwd: context.cwd,
        });
        requireFact(
          !collectSessionRecords(result?.sessions || []).has(sessionId),
          "session_cleanup_not_verified",
        );
      });
      return true;
    }
    const deletion = await runBoundedProcess(context.binary, context.config.deleteArgs(sessionId), {
      cwd: context.cwd,
      environment: context.environment,
      timeoutMs: Math.min(context.timeoutMs, 30_000),
      maxOutputBytes: context.maxOutputBytes,
    });
    requireFact(deletion.statusCode === 0, "session_cleanup_failed");
    if (context.config.cleanupKind === "openagent-cli") {
      const verification = await runBoundedProcess(context.binary, context.config.exportArgs(sessionId), {
        cwd: context.cwd,
        environment: context.environment,
        timeoutMs: Math.min(context.timeoutMs, 30_000),
        maxOutputBytes: context.maxOutputBytes,
      });
      requireFact(verification.statusCode !== 0, "session_cleanup_not_verified");
    } else {
      const destination = join(temporaryDirectory, `deleted-${randomUUID()}.jsonl`);
      const verification = await runBoundedProcess(
        context.binary,
        ["sessions", "export", destination, "--session-id", sessionId, "--redact"],
        {
          cwd: context.cwd,
          environment: context.environment,
          timeoutMs: Math.min(context.timeoutMs, 30_000),
          maxOutputBytes: context.maxOutputBytes,
        },
      );
      const absent = verification.statusCode !== 0
        || !existsSync(destination)
        || statSync(destination).size === 0;
      requireFact(absent, "session_cleanup_not_verified");
    }
    return true;
  } catch {
    return false;
  }
}

async function preflightCleanup(context) {
  if (context.config.cleanupKind === "unavailable") {
    return { ready: false, code: context.config.cleanupBlocker };
  }
  if (context.config.cleanupKind === "pi-disposable-session-root") {
    if (!context.disposableDataRoot || dirname(context.disposableDataRoot) !== context.temporaryDirectory) {
      return { ready: false, code: "pi_disposable_session_root_unavailable" };
    }
    try {
      mkdirSync(context.disposableDataRoot, { recursive: true, mode: 0o700 });
      chmodSync(context.disposableDataRoot, 0o700);
      return { ready: true, code: null };
    } catch {
      return { ready: false, code: "pi_disposable_session_root_unavailable" };
    }
  }
  if (context.config.cleanupKind === "disposable-data-root") {
    if (!context.disposableDataRoot || dirname(context.disposableDataRoot) !== context.temporaryDirectory) {
      return { ready: false, code: "disposable_profile_unavailable" };
    }
    try {
      mkdirSync(context.disposableDataRoot, { recursive: true, mode: 0o700 });
      context.disposableProfileSeeded = seedDisposableProfile(context);
      return { ready: true, code: null };
    } catch {
      return { ready: false, code: "disposable_profile_unavailable" };
    }
  }
  if (context.config.cleanupKind === "codex-app-server") {
    try {
      await withAppServer(context, async (client) => {
        const result = await client.request("thread/list", {});
        requireFact(Array.isArray(codexThreadListItems(result)), "codex_app_server_list_unavailable");
      });
      return { ready: true, code: null };
    } catch (error) {
      return {
        ready: false,
        code: error instanceof AcceptanceError
          ? error.code
          : "codex_app_server_cleanup_probe_failed",
      };
    }
  }
  if (context.config.cleanupKind === "copilot-sdk") {
    try {
      await withCopilotSdkRpc(context, async (client) => {
        const result = await client.request("session.list", {});
        requireFact(Array.isArray(result?.sessions), "copilot_sdk_list_unavailable");
      });
      return { ready: true, code: null };
    } catch {
      return { ready: false, code: "copilot_sdk_cleanup_probe_failed" };
    }
  }
  if (context.config.cleanupKind === "openclaw-acp") {
    try {
      await withOpenClawAcp(context, async (client, initialized) => {
        const capabilities = initialized?.agentCapabilities?.sessionCapabilities;
        requireFact(capabilities?.list != null, "openclaw_acp_list_unavailable");
        requireFact(capabilities?.resume != null, "openclaw_acp_resume_unavailable");
        requireFact(capabilities?.close != null, "openclaw_acp_close_unavailable");
        const result = await client.request("session/list", { cwd: context.cwd });
        requireFact(Array.isArray(result?.sessions), "openclaw_acp_list_invalid");
      });
      return { ready: true, code: null };
    } catch {
      return { ready: false, code: "openclaw_acp_cleanup_probe_failed" };
    }
  }
  const helpArgs = context.config.cleanupKind === "hermes-cli"
    ? ["sessions", "delete", "--help"]
    : ["session", "delete", "--help"];
  try {
    const help = await runBoundedProcess(context.binary, helpArgs, {
      cwd: context.cwd,
      environment: context.environment,
      timeoutMs: 10_000,
      maxOutputBytes: 256 * 1024,
    });
    if (help.statusCode !== 0) return { ready: false, code: "session_cleanup_interface_unavailable" };
    await listSessions(context);
    return { ready: true, code: null };
  } catch {
    return { ready: false, code: "session_cleanup_probe_failed" };
  }
}

async function cleanupProductSession(options) {
  const config = agentConfigs[options.agent];
  requireFact(Boolean(config), "agent_not_acp_packaged");
  const receipt = readBoundedJson(
    options.cleanupProductSession,
    4 * 1024,
    "product_session_receipt_invalid",
  );
  requireExactFields(
    receipt,
    new Set(["schemaVersion", "agentId", "nativeSessionId"]),
    "product_session_receipt_unbounded",
  );
  requireFact(
    receipt.schemaVersion === "lico-agent-conversation-product-session-v1"
      && receipt.agentId === config.id
      && typeof receipt.nativeSessionId === "string"
      && receipt.nativeSessionId.length > 0
      && receipt.nativeSessionId.length <= 512,
    "product_session_receipt_incomplete",
  );
  requireFact(config.cleanupKind !== "unavailable", "product_session_cleanup_unavailable");
  const binary = resolveExecutable(options.binary, config);
  requireFact(binary.length > 0, "agent_executable_unavailable");
  const temporaryDirectory = dirname(options.cleanupProductSession);
  const disposableDataRoot = config.disposableEnvironmentKey
    ? String(process.env[config.disposableEnvironmentKey] || "")
    : "";
  const wrapper = createPrivateWrapper(temporaryDirectory, binary);
  wrapper.environment = { ...wrapper.environment, ...process.env };
  const context = {
    config,
    binary,
    wrapper,
    cwd: workspaceRoot,
    environment: process.env,
    temporaryDirectory,
    disposableDataRoot,
    disposableSeedSource: "",
    disposableProfileSeeded: false,
    cleanedSessions: new Set(),
    observedSessions: new Set([receipt.nativeSessionId]),
    timeoutMs: options.timeoutMs,
    maxOutputBytes: options.maxOutputBytes,
    copilotSdkLaunchArgs: null,
  };
  const cleaned = await cleanupSession(
    context,
    receipt.nativeSessionId,
    temporaryDirectory,
  );
  requireFact(cleaned, "product_session_cleanup_failed");
  const remaining = await listSessions(context);
  requireFact(!remaining.has(receipt.nativeSessionId), "product_session_cleanup_not_verified");
  return {
    status: "passed",
    cleanupPassed: true,
    agent: config.id,
    receiptDigest: `sha256:${digest({
      agentId: config.id,
      nativeSessionId: receipt.nativeSessionId,
    })}`,
  };
}

function makeCanary() {
  // Keep the marker unique without resembling a credential. Some native
  // agents correctly refuse to repeat long opaque token-shaped strings, which
  // would turn a model safety behavior into a false transport-parity failure.
  return `LICO-PARITY-MARKER-${randomUUID().replaceAll("-", "").slice(0, 12).toUpperCase()}`;
}

function canaryPrompt(canary, expectedReply) {
  return `Acceptance marker ${canary}; do not repeat the marker. Reply with exactly ${expectedReply} and no other text. Do not call tools or request permissions.`;
}

function normalizedMarker(value) {
  return String(value || "").toLowerCase().replaceAll(/[^a-z0-9]/gu, "");
}

function outputCategoryCode(value) {
  const output = String(value || "").toLowerCase();
  const categories = [
    ["a", /auth|login|credential|unauthorized|token/u],
    ["q", /quota|rate.?limit|usage.?limit/u],
    ["p", /permission|sandbox|denied|forbidden/u],
    ["s", /server|service|internal|unavailable|network|connect/u],
    ["r", /cannot|can't|unable|refus|policy/u],
  ];
  return categories.find(([, pattern]) => pattern.test(output))?.[0] || "o";
}

function roundFactsReady(facts) {
  return roundConversationFactsReady(facts)
    && facts.cleanupVerified;
}

function roundConversationFactsReady(facts) {
  return facts.nativeToArc
    && facts.arcToNative
    && facts.realSessionIds
    && facts.finalCanaries
    && facts.cwdParity
    && facts.settingsParity
    && facts.argvCanariesAbsent
    && facts.historyReadback
    && facts.noPermissionRequests
    && facts.noUnsupportedRequests
    && facts.boundedOutput;
}

function failedParityFactCode(facts) {
  if (facts.finalCanaries !== true) {
    const presentMask = [
      facts.nativeFirstFinalCanaryPresent,
      facts.arcResumeFinalCanaryPresent,
      facts.arcFirstFinalCanaryPresent,
      facts.nativeResumeFinalCanaryPresent,
    ].map((value) => value === true ? "1" : "0").join("");
    const exactMask = [
      facts.nativeFirstFinalCanary,
      facts.arcResumeFinalCanary,
      facts.arcFirstFinalCanary,
      facts.nativeResumeFinalCanary,
    ].map((value) => value === true ? "1" : "0").join("");
    const normalizedMask = [
      facts.nativeFirstFinalCanaryNormalized,
      facts.arcResumeFinalCanaryNormalized,
      facts.arcFirstFinalCanaryNormalized,
      facts.nativeResumeFinalCanaryNormalized,
    ].map((value) => value === true ? "1" : "0").join("");
    const equalityMask = [
      facts.firstSessionOutputsEqual,
      facts.secondSessionOutputsEqual,
      facts.allOutputsEqual,
    ].map((value) => value === true ? "1" : "0").join("");
    const categoryMask = [
      facts.nativeFirstOutputCategory,
      facts.arcResumeOutputCategory,
      facts.arcFirstOutputCategory,
      facts.nativeResumeOutputCategory,
    ].map((value) => /^[aqpsro]$/u.test(value) ? value : "o").join("");
    return `parity_final_p${presentMask}_n${normalizedMask}_e${exactMask}_q${equalityMask}_c${categoryMask}`;
  }
  if (facts.settingsParity !== true && /^[01]{6}$/u.test(facts.settingsParityMask || "")) {
    return `parity_settings_m${facts.settingsParityMask}_failed`;
  }
  const orderedFacts = [
    ["nativeToArc", "native_to_arc"],
    ["arcToNative", "arc_to_native"],
    ["realSessionIds", "real_session_ids"],
    ["nativeFirstFinalCanaryPresent", "native_first_final_canary_missing"],
    ["nativeFirstFinalCanary", "native_first_final_canary"],
    ["arcResumeFinalCanaryPresent", "arc_resume_final_canary_missing"],
    ["arcResumeFinalCanary", "arc_resume_final_canary"],
    ["arcFirstFinalCanaryPresent", "arc_first_final_canary_missing"],
    ["arcFirstFinalCanary", "arc_first_final_canary"],
    ["nativeResumeFinalCanaryPresent", "native_resume_final_canary_missing"],
    ["nativeResumeFinalCanary", "native_resume_final_canary"],
    ["finalCanaries", "final_canaries"],
    ["cwdParity", "cwd_parity"],
    ["settingsParity", "settings_parity"],
    ["argvCanariesAbsent", "argv_privacy"],
    ["historyReadback", "history_readback"],
    ["noPermissionRequests", "permission_request"],
    ["noUnsupportedRequests", "unsupported_request"],
    ["boundedOutput", "bounded_output"],
    ["cleanupVerified", "cleanup"],
  ];
  const failed = orderedFacts.find(([key]) => facts[key] !== true);
  return failed ? `parity_${failed[1]}_failed` : "parity_fact_failed";
}

async function runRound(context, roundIndex, selfTestEvidence) {
  const canaries = [makeCanary(), makeCanary(), makeCanary(), makeCanary()];
  const expectedReplies = [11, 13, 17, 19].map((value) => String(roundIndex * 1000 + value));
  const knownSessions = new Set();
  const before = await listSessions(context);
  const previousObservedSessions = context.observedSessions;
  context.observedSessions = knownSessions;
  let cleanupCount = 0;
  let cleanupVerified = false;
  let testedSessions = 0;
  let requestCount = 0;
  let successfulRequestCount = 0;
  let facts;
  let roundError = null;
  try {
    const forcedModel = parityModelForAgent(context.config.id);
    const forcedCodexModel = context.config.id === "codex" ? forcedModel : "";
    const forcedCodexEffort = context.config.id === "codex"
      ? (process.env.LICO_CODEX_PARITY_REASONING_EFFORT || (forcedCodexModel.toLowerCase().includes("spark") ? "low" : ""))
      : "";
    requestCount += 1;
    const nativeFirst = await nativeTurn(
      context,
      "",
      canaryPrompt(canaries[0], expectedReplies[0]),
    );
    successfulRequestCount += 1;
    knownSessions.add(nativeFirst.sessionId);
    testedSessions += 1;
    requestCount += 1;
    const arcResume = await runSidecar(context, {
      agent: context.config.id,
      text: canaryPrompt(canaries[1], expectedReplies[1]),
      sessionId: nativeFirst.sessionId,
      workingDirectory: context.cwd,
      binaryPath: context.wrapper.wrapperPath,
      timeoutMs: context.timeoutMs,
      maxStdoutBytes: context.maxOutputBytes,
      maxStderrBytes: context.maxOutputBytes,
      streamEvents: true,
      ...(forcedModel ? { model: forcedModel } : {}),
      ...(forcedCodexEffort ? { reasoningEffort: forcedCodexEffort } : {}),
    });
    successfulRequestCount += 1;
    const readFirst = await nativeReadback(context, nativeFirst.sessionId);
    const officialFirst = await officialHistory(context, nativeFirst.sessionId, context.temporaryDirectory);

    requestCount += 1;
    const arcFirst = await runSidecar(context, {
      agent: context.config.id,
      text: canaryPrompt(canaries[2], expectedReplies[2]),
      workingDirectory: context.cwd,
      binaryPath: context.wrapper.wrapperPath,
      timeoutMs: context.timeoutMs,
      maxStdoutBytes: context.maxOutputBytes,
      maxStderrBytes: context.maxOutputBytes,
      streamEvents: true,
      ...(forcedModel ? { model: forcedModel } : {}),
      ...(forcedCodexEffort ? { reasoningEffort: forcedCodexEffort } : {}),
    });
    successfulRequestCount += 1;
    const arcSessionId = arcFirst.result?.sessionId || "";
    requireFact(typeof arcSessionId === "string" && arcSessionId.length > 0, "arc_session_id_missing");
    knownSessions.add(arcSessionId);
    testedSessions += 1;
    requestCount += 1;
    const nativeResume = await nativeTurn(
      context,
      arcSessionId,
      canaryPrompt(canaries[3], expectedReplies[3]),
    );
    successfulRequestCount += 1;
    const readSecond = await nativeReadback(context, arcSessionId);
    const officialSecond = await officialHistory(context, arcSessionId, context.temporaryDirectory);

    const capture = existsSync(context.wrapper.capturePath)
      ? readFileSync(context.wrapper.capturePath, "utf8")
      : "";
    const argvCanariesAbsent = canaries.every((canary) => !capture.includes(canary))
      && canaries.every((canary) => !context.config.acpArgs.some((argument) => argument.includes(canary)))
      && canaries.every((canary) => !sidecarArgs.some((argument) => argument.includes(canary)));
    const firstHistory = `${readFirst.text}\n${officialFirst}`;
    const secondHistory = `${readSecond.text}\n${officialSecond}`;
    const arcResumeSettings = arcSettings(arcResume.result);
    const arcFirstSettings = arcSettings(arcFirst.result);
    const settingsPairs = [
      [nativeFirst.settings, arcResumeSettings],
      [nativeResume.settings, arcFirstSettings],
      [readFirst.settings, nativeFirst.settings],
      [readSecond.settings, nativeResume.settings],
    ];
    const settingsKeys = ["cwd", "model", "reasoningEffort", "mode", "runtimeAgent", "allowAll"];
    const settingsParityMask = settingsKeys
      .map((key) => settingsPairs.every(([left, right]) => stableJson(left[key]) === stableJson(right[key])) ? "1" : "0")
      .join("");
    const settingsParity = settingsParityMask === "111111";
    const arcResumeOutput = String(arcResume.result.output || "").trim();
    const arcFirstOutput = String(arcFirst.result.output || "").trim();
    const nativeFirstFinalCanaryPresent = nativeFirst.output.includes(expectedReplies[0]);
    const nativeFirstFinalCanary = nativeFirst.output === expectedReplies[0];
    const arcResumeFinalCanaryPresent = arcResumeOutput.includes(expectedReplies[1]);
    const arcResumeFinalCanary = arcResumeOutput === expectedReplies[1];
    const arcFirstFinalCanaryPresent = arcFirstOutput.includes(expectedReplies[2]);
    const arcFirstFinalCanary = arcFirstOutput === expectedReplies[2];
    const nativeResumeFinalCanaryPresent = nativeResume.output.includes(expectedReplies[3]);
    const nativeResumeFinalCanary = nativeResume.output === expectedReplies[3];
    const nativeFirstFinalCanaryNormalized = normalizedMarker(nativeFirst.output)
      === normalizedMarker(expectedReplies[0]);
    const arcResumeFinalCanaryNormalized = normalizedMarker(arcResumeOutput)
      === normalizedMarker(expectedReplies[1]);
    const arcFirstFinalCanaryNormalized = normalizedMarker(arcFirstOutput)
      === normalizedMarker(expectedReplies[2]);
    const nativeResumeFinalCanaryNormalized = normalizedMarker(nativeResume.output)
      === normalizedMarker(expectedReplies[3]);
    const firstSessionOutputsEqual = nativeFirst.output === arcResumeOutput;
    const secondSessionOutputsEqual = arcFirstOutput === nativeResume.output;
    const allOutputsEqual = firstSessionOutputsEqual
      && secondSessionOutputsEqual
      && nativeFirst.output === arcFirstOutput;
    const nativeFirstOutputCategory = outputCategoryCode(nativeFirst.output);
    const arcResumeOutputCategory = outputCategoryCode(arcResumeOutput);
    const arcFirstOutputCategory = outputCategoryCode(arcFirstOutput);
    const nativeResumeOutputCategory = outputCategoryCode(nativeResume.output);
    facts = {
      nativeToArc: arcResume.result.sessionId === nativeFirst.sessionId
        && arcResume.result.threadId === nativeFirst.sessionId,
      arcToNative: nativeResume.sessionId === arcSessionId,
      realSessionIds: nativeFirst.sessionId.length > 0
        && arcSessionId.length > 0
        && nativeFirst.sessionId !== arcSessionId,
      nativeFirstFinalCanaryPresent,
      nativeFirstFinalCanaryNormalized,
      nativeFirstFinalCanary,
      arcResumeFinalCanaryPresent,
      arcResumeFinalCanaryNormalized,
      arcResumeFinalCanary,
      arcFirstFinalCanaryPresent,
      arcFirstFinalCanaryNormalized,
      arcFirstFinalCanary,
      nativeResumeFinalCanaryPresent,
      nativeResumeFinalCanaryNormalized,
      nativeResumeFinalCanary,
      firstSessionOutputsEqual,
      secondSessionOutputsEqual,
      allOutputsEqual,
      nativeFirstOutputCategory,
      arcResumeOutputCategory,
      arcFirstOutputCategory,
      nativeResumeOutputCategory,
      finalCanaries: nativeFirstFinalCanaryNormalized
        && arcResumeFinalCanaryNormalized
        && arcFirstFinalCanaryNormalized
        && nativeResumeFinalCanaryNormalized,
      cwdParity: arcSettings(arcResume.result).cwd === context.cwd
        && arcSettings(arcFirst.result).cwd === context.cwd
        && nativeFirst.settings.cwd === context.cwd
        && nativeResume.settings.cwd === context.cwd,
      settingsParity,
      settingsParityMask,
      argvCanariesAbsent,
      historyReadback: expectedReplies.slice(0, 2).every((reply) => firstHistory.includes(reply))
        && expectedReplies.slice(2).every((reply) => secondHistory.includes(reply)),
      noPermissionRequests: nativeFirst.permissionRequests === 0
        && nativeResume.permissionRequests === 0,
      noUnsupportedRequests: nativeFirst.unsupportedRequests === 0
        && nativeResume.unsupportedRequests === 0,
      boundedOutput: nativeFirst.boundedOutput
        && nativeResume.boundedOutput
        && readFirst.boundedOutput
        && readSecond.boundedOutput
        && arcResume.boundedOutput
        && arcFirst.boundedOutput,
      streamingSeen: arcResume.streamingSeen === true && arcFirst.streamingSeen === true,
      structuredSeen: arcResume.structuredSeen === true && arcFirst.structuredSeen === true,
      cleanupVerified: false,
      permissionFailClosed: selfTestEvidence.permissionFailClosed,
      errorFailClosed: selfTestEvidence.errorFailClosed,
      settingsDigest: digest([
        nativeFirst.settings,
        arcSettings(arcResume.result),
        nativeResume.settings,
        arcSettings(arcFirst.result),
      ]),
    };
  } catch (error) {
    roundError = error instanceof AcceptanceError ? error : new AcceptanceError("unexpected_failure");
  } finally {
    let after = new Map();
    try {
      after = await listSessions(context);
    } catch {
      roundError ||= new AcceptanceError("session_list_after_failed");
    }
    for (const [sessionId, record] of after) {
      if (!before.has(sessionId) && canaries.some((canary) => record.includes(canary))) {
        knownSessions.add(sessionId);
      }
    }
    let allDeleted = true;
    for (const sessionId of knownSessions) {
      const deleted = await cleanupSession(context, sessionId, context.temporaryDirectory);
      if (deleted) cleanupCount += 1;
      else allDeleted = false;
    }
    try {
      const verified = await listSessions(context);
      cleanupVerified = allDeleted && [...knownSessions].every((sessionId) => !verified.has(sessionId));
    } catch {
      cleanupVerified = false;
    }
    context.observedSessions = previousObservedSessions;
  }
  if (!facts) {
    return {
      ready: false,
      roundIndex,
      cleanupCount,
      cleanupVerified,
      testedSessions,
      requestCount,
      successfulRequestCount,
      errorCode: roundError?.code || "round_failed",
      facts: null,
    };
  }
  facts.cleanupVerified = cleanupVerified;
  const ready = roundFactsReady(facts)
    && facts.permissionFailClosed
    && facts.errorFailClosed;
  const conversationReady = roundConversationFactsReady(facts)
    && facts.permissionFailClosed
    && facts.errorFailClosed;
  return {
    ready,
    conversationReady,
    roundIndex,
    cleanupCount,
    cleanupVerified,
    testedSessions,
    requestCount,
    successfulRequestCount,
    errorCode: ready ? null : (roundError?.code || failedParityFactCode(facts)),
    facts,
  };
}

function aggregateResult(agentId, strict, packaged, rounds, selfTestEvidence, options = {}) {
  const releaseUi = options.releaseUi === true;
  const expectedRounds = strict ? strictRoundCount : 1;
  const completed = rounds.filter((round) => round.ready).length;
  const conversationCompleted = rounds.filter((round) => round.conversationReady).length;
  const allFacts = rounds.map((round) => round.facts).filter(Boolean);
  const every = (key) => allFacts.length === expectedRounds && allFacts.every((facts) => facts[key] === true);
  const corePassed = completed === expectedRounds;
  // consecutivePasses / releaseUiPassed / P-10 only advance under --release-ui.
  // Core-only --strict proves lane semantics and must never look like CL-06 ready.
  const result = {
    status: corePassed ? (releaseUi ? "release-ui-passed" : "core-passed") : "failed",
    agent: agentId,
    strict,
    packaged,
    cl06Ready: false,
    releaseUiPassed: releaseUi && corePassed,
    roundsRequired: expectedRounds,
    roundsCompleted: completed,
    conversationRoundsCompleted: conversationCompleted,
    conversationPassed: conversationCompleted === expectedRounds,
    roundsAttempted: rounds.length,
    testedSessions: rounds.reduce((total, round) => total + (round.testedSessions || 0), 0),
    requestCount: rounds.reduce((total, round) => total + (round.requestCount || 0), 0),
    successfulRequestCount: rounds.reduce((total, round) => total + (round.successfulRequestCount || 0), 0),
    roundResults: rounds.map((round) => ({
      round: round.roundIndex,
      conversationPassed: round.conversationReady === true,
      cleanupPassed: round.cleanupVerified === true,
      testedSessions: round.testedSessions || 0,
      requestCount: round.requestCount || 0,
      successfulRequestCount: round.successfulRequestCount || 0,
      errorCode: round.errorCode || null,
    })),
    consecutivePasses: releaseUi && corePassed ? completed : 0,
    officialNativeLane: every("nativeToArc") && every("arcToNative"),
    nativeToArc: every("nativeToArc"),
    arcToNative: every("arcToNative"),
    realSessionIds: every("realSessionIds"),
    finalCanaries: every("finalCanaries"),
    cwdParity: every("cwdParity"),
    settingsParity: every("settingsParity"),
    argvCanariesAbsent: every("argvCanariesAbsent"),
    historyReadback: every("historyReadback"),
    permissionFailClosed: selfTestEvidence.permissionFailClosed,
    errorFailClosed: selfTestEvidence.errorFailClosed,
    boundedOutput: every("boundedOutput") && selfTestEvidence.boundedOutputFailClosed,
    cleanupVerified: rounds.length === expectedRounds && rounds.every((round) => round.cleanupVerified),
    cleanupPassed: rounds.length === expectedRounds && rounds.every((round) => round.cleanupVerified),
    privacyPassed: every("argvCanariesAbsent") && every("boundedOutput"),
    streamingProven: every("streamingSeen"),
    structuredProven: every("structuredSeen"),
    cleanupCount: rounds.reduce((total, round) => total + round.cleanupCount, 0),
    errorCode: rounds.find((round) => round.conversationReady !== true)?.errorCode
      || rounds.find((round) => !round.ready)?.errorCode
      || null,
    evidenceDigest: "",
  };
  result.evidenceDigest = digest({ ...result, evidenceDigest: undefined });
  return result;
}

function blockedResult(agentId, strict, packaged, code, selfTestEvidence) {
  const result = {
    status: "blocked",
    agent: agentId,
    strict,
    packaged,
    cl06Ready: false,
    releaseUiPassed: false,
    roundsRequired: strict ? strictRoundCount : 1,
    roundsCompleted: 0,
    conversationRoundsCompleted: 0,
    conversationPassed: false,
    roundsAttempted: 0,
    testedSessions: 0,
    requestCount: 0,
    successfulRequestCount: 0,
    roundResults: [],
    consecutivePasses: 0,
    officialNativeLane: false,
    nativeToArc: false,
    arcToNative: false,
    realSessionIds: false,
    finalCanaries: false,
    cwdParity: false,
    settingsParity: false,
    argvCanariesAbsent: false,
    historyReadback: false,
    permissionFailClosed: selfTestEvidence.permissionFailClosed,
    errorFailClosed: selfTestEvidence.errorFailClosed,
    boundedOutput: selfTestEvidence.boundedOutputFailClosed,
    cleanupVerified: false,
    cleanupPassed: false,
    privacyPassed: selfTestEvidence.boundedOutputFailClosed,
    streamingProven: false,
    structuredProven: false,
    cleanupCount: 0,
    errorCode: safeErrorCode(code),
    evidenceDigest: "",
  };
  result.evidenceDigest = digest({ ...result, evidenceDigest: undefined });
  return result;
}

async function runLive(options, selfTestEvidence) {
  const config = agentConfigs[options.agent];
  requireFact(Boolean(config), "agent_not_acp_packaged");
  const packagedAgents = readPackagedAgents();
  const packaged = packagedAgents.has(config.id);
  if (!packaged) return blockedResult(config.id, options.strict, false, "agent_not_packaged", selfTestEvidence);
  let productReceipt = null;
  if (options.releaseUi) {
    try {
      productReceipt = validateProductReceipt(options.productReceipt, config.id);
    } catch (error) {
      return blockedResult(
        config.id,
        options.strict,
        true,
        error instanceof AcceptanceError ? error.code : "release_ui_product_receipt_invalid",
        selfTestEvidence,
      );
    }
  }
  if (config.cleanupKind === "unavailable") {
    return blockedResult(config.id, options.strict, true, config.cleanupBlocker, selfTestEvidence);
  }
  const binary = resolveExecutable(options.binary, config);
  if (!binary) return blockedResult(config.id, options.strict, true, "agent_executable_unavailable", selfTestEvidence);
  const sidecar = resolveSidecar(options.sidecar, { releaseUi: options.releaseUi });
  if (!sidecar) {
    return blockedResult(
      config.id,
      options.strict,
      true,
      options.releaseUi ? "release_ui_sidecar_unavailable" : "lico_client_executable_unavailable",
      selfTestEvidence,
    );
  }
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "lico-acp-parity-"));
  try {
    const isolatedWorkingDirectory = join(temporaryDirectory, "workspace");
    mkdirSync(isolatedWorkingDirectory, { recursive: true });
    const wrapper = createPrivateWrapper(temporaryDirectory, binary);
    const disposableDataRoot = ["disposable-data-root", "pi-disposable-session-root"].includes(config.cleanupKind)
      ? join(temporaryDirectory, "isolated-agent-data")
      : "";
    const disposableSeedSource = config.cleanupKind === "disposable-data-root"
      ? (process.env[config.disposableEnvironmentKey] || join(homedir(), ".kimi-code"))
      : "";
    const environment = disposableDataRoot
      ? { ...process.env, [config.disposableEnvironmentKey]: disposableDataRoot }
      : process.env;
    wrapper.environment = {
      ...wrapper.environment,
      ...environment,
      LICO_AGENT_CONVERSATION_ACCEPTANCE: acceptanceMode,
    };
    const context = {
      config,
      binary,
      sidecar,
      wrapper,
      cwd: isolatedWorkingDirectory,
      environment,
      temporaryDirectory,
      disposableDataRoot,
      disposableSeedSource,
      disposableProfileSeeded: false,
      cleanedSessions: new Set(),
      timeoutMs: options.timeoutMs,
      maxOutputBytes: options.maxOutputBytes,
      copilotSdkLaunchArgs: null,
    };
    const cleanup = await preflightCleanup(context);
    if (!cleanup.ready) {
      return blockedResult(config.id, options.strict, true, cleanup.code, selfTestEvidence);
    }
    const rounds = [];
    const expectedRounds = options.strict ? strictRoundCount : 1;
    for (let index = 0; index < expectedRounds; index += 1) {
      const round = await runRound(context, index + 1, selfTestEvidence);
      rounds.push(round);
      if (!round.ready) break;
    }
    let aggregate = aggregateResult(config.id, options.strict, true, rounds, selfTestEvidence, {
      releaseUi: false,
    });
    if (options.releaseUi === true && aggregate.status === "core-passed") {
      aggregate = {
        ...aggregate,
        status: "release-ui-passed",
        releaseUiPassed: true,
        consecutivePasses: strictRoundCount,
        productReceiptJoined: true,
        productArtifactDigest: productReceipt.artifactDigest,
        productContinuityBindingDigest: productReceipt.continuityBindingDigest,
      };
      aggregate.evidenceDigest = digest({ ...aggregate, evidenceDigest: undefined });
    }
    let evidenceWrite = null;
    if (options.releaseUi === true) {
      evidenceWrite = writeReleaseUiAdapterEvidence(aggregate, context);
    }
    return { ...aggregate, evidenceWrite };
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

const fakeRuntimeSource = String.raw`#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { createInterface } from "node:readline";

const statePath = process.env.LICO_FAKE_ACP_STATE;
const load = () => existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : { counter: 0, sessions: {} };
const save = (state) => writeFileSync(statePath, JSON.stringify(state));
const options = [
  { id: "model", type: "select", currentValue: "fake-model", options: [{ value: "fake-model" }] },
  { id: "variant", type: "select", currentValue: "fake-effort", options: [{ value: "fake-effort" }] },
  { id: "mode", type: "select", currentValue: "fake-mode", options: [{ value: "fake-mode" }] },
  { id: "agent", type: "select", currentValue: "fake-agent", options: [{ value: "fake-agent" }] },
  { id: "allow_all", type: "boolean", currentValue: false },
];
const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");

async function acp() {
  const lines = createInterface({ input: process.stdin });
  let active = "";
  for await (const line of lines) {
    const message = JSON.parse(line);
    if (message.method === "initialize") {
      send({ jsonrpc: "2.0", id: message.id, result: { protocolVersion: 1, agentCapabilities: { loadSession: true, sessionCapabilities: { delete: {}, list: {}, resume: {}, close: {} } } } });
    } else if (message.method === "session/new") {
      const state = load();
      active = "fake-session-" + (++state.counter);
      state.sessions[active] = { cwd: message.params.cwd, messages: [] };
      save(state);
      send({ jsonrpc: "2.0", id: message.id, result: { sessionId: active, configOptions: options, modes: { currentModeId: "fake-mode" } } });
    } else if (message.method === "session/load") {
      const state = load();
      active = message.params.sessionId;
      const session = state.sessions[active];
      if (!session) {
        send({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "missing" } });
        continue;
      }
      for (const entry of session.messages.filter((item) => item.role === "assistant")) {
        send({ jsonrpc: "2.0", method: "session/update", params: { sessionId: active, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: entry.text } } } });
      }
      send({ jsonrpc: "2.0", id: message.id, result: { sessionId: active, configOptions: options, modes: { currentModeId: "fake-mode" } } });
    } else if (message.method === "session/list") {
      const state = load();
      send({ jsonrpc: "2.0", id: message.id, result: { sessions: Object.entries(state.sessions).map(([sessionId, value]) => ({ sessionId, cwd: value.cwd })) } });
    } else if (message.method === "session/close") {
      const state = load();
      delete state.sessions[message.params.sessionId];
      save(state);
      send({ jsonrpc: "2.0", id: message.id, result: {} });
    } else if (message.method === "session/set_config_option") {
      const state = load();
      const session = state.sessions[message.params.sessionId];
      if (!session) {
        send({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "missing" } });
        continue;
      }
      session.config ||= {};
      session.config[message.params.configId] = message.params.value;
      save(state);
      send({ jsonrpc: "2.0", id: message.id, result: { configOptions: options.map((option) => option.id === message.params.configId ? { ...option, currentValue: message.params.value } : option) } });
    } else if (message.method === "session/prompt") {
      const prompt = message.params.prompt[0].text;
      if (prompt.includes("SELFTEST_PERMISSION")) {
        const state = load();
        state.sessions[active].messages.push({ role: "user", text: prompt });
        save(state);
        send({ jsonrpc: "2.0", id: 991, method: "session/request_permission", params: { sessionId: active, options: [] } });
        continue;
      }
      if (prompt.includes("SELFTEST_OVERFLOW")) {
        const state = load();
        state.sessions[active].messages.push({ role: "user", text: prompt });
        save(state);
        send({ jsonrpc: "2.0", method: "session/update", params: { sessionId: active, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "x".repeat(65536) } } } });
        continue;
      }
      const reply = prompt.match(/Reply with exactly ([0-9]+)/u)?.[1] || "0";
      const state = load();
      state.sessions[active].messages.push({ role: "user", text: prompt }, { role: "assistant", text: reply });
      save(state);
      send({ jsonrpc: "2.0", method: "session/update", params: { sessionId: active, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: reply } } } });
      send({ jsonrpc: "2.0", id: message.id, result: { stopReason: "end_turn" } });
    } else if (message.method === "session/cancel" || (message.id === 991 && message.result?.outcome?.outcome === "cancelled")) {
      process.exit(0);
    }
  }
}

async function piRpc() {
  const root = process.env.PI_CODING_AGENT_SESSION_DIR;
  mkdirSync(root, { recursive: true });
  const state = load();
  let active = "fake-pi-" + (++state.counter);
  state.sessions[active] = { cwd: process.cwd(), messages: [] };
  save(state);
  const sessionPath = (id) => root + "/" + id + ".jsonl";
  const persist = () => {
    const current = load().sessions[active];
    const rows = [
      { type: "session", version: 3, id: active, cwd: current.cwd },
      ...current.messages.map((message, index) => ({ type: "message", id: active + "-" + index, message })),
    ];
    writeFileSync(sessionPath(active), rows.map((row) => JSON.stringify(row)).join("\n") + "\n");
  };
  persist();
  const lines = createInterface({ input: process.stdin });
  for await (const line of lines) {
    const command = JSON.parse(line);
    const respond = (success, data = {}) => send({ id: command.id, type: "response", command: command.type, success, data });
    if (command.type === "switch_session") {
      const header = JSON.parse(readFileSync(command.sessionPath, "utf8").split(/\r?\n/u)[0]);
      active = header.id;
      respond(true, { cancelled: false });
    } else if (command.type === "get_state") {
      respond(true, { sessionId: active, model: null, thinkingLevel: "off", isStreaming: false });
    } else if (command.type === "prompt") {
      const reply = command.message.match(/Reply with exactly ([0-9]+)/u)?.[1] || "0";
      const current = load();
      current.sessions[active].messages.push(
        { role: "user", content: [{ type: "text", text: command.message }] },
        { role: "assistant", content: [{ type: "text", text: reply }] },
      );
      save(current);
      persist();
      respond(true);
      send({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: reply } });
      send({ type: "agent_settled" });
    } else if (command.type === "get_last_assistant_text") {
      const messages = load().sessions[active].messages;
      const text = messages.filter((message) => message.role === "assistant").at(-1)?.content?.[0]?.text || null;
      respond(true, { text });
    } else if (command.type === "get_messages") {
      respond(true, { messages: load().sessions[active].messages });
    } else if (command.type === "abort") {
      respond(true);
    } else {
      respond(false);
    }
  }
}

async function sidecar() {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  const request = JSON.parse(input);
  const operation = process.argv.slice(2)[2] || "send";
  const laneFamilies = {
    openclaw: "acp", "claude-code": "stream-json", codex: "app-server",
    antigravity: "unavailable", opencode: "serve-http", copilot: "acp",
    "kilo-code": "serve-http", cursor: "acp", hermes: "acp",
    "kimi-code": "acp", pi: "rpc",
  };
  const exactResume = !["antigravity", "hermes"].includes(request.agent);
  const laneFamily = laneFamilies[request.agent] || "unavailable";
  if (operation === "capabilities") {
    process.stdout.write(JSON.stringify({
      ok: true,
      agentId: request.agent,
      laneFamily,
      runtimeProtocol: "fixture-protocol",
      capabilities: { officialLane: laneFamily !== "unavailable", exactResume },
    }));
    return;
  }
  if (operation === "open") {
    if (laneFamily === "unavailable" || (request.sessionId && !exactResume)) {
      process.stdout.write(JSON.stringify({ ok: false, error: { code: "fixture_open_blocked" } }));
    } else {
      process.stdout.write(JSON.stringify({ ok: true, sessionId: request.sessionId || "" }));
    }
    return;
  }
  if (operation === "stream") {
    process.stdout.write(JSON.stringify({ ok: true, status: "bound_on_send" }));
    return;
  }
  if (operation === "cancel") {
    process.stdout.write(JSON.stringify({ ok: false, error: { code: "dispatch_cancel_unsupported" } }));
    return;
  }
  const emitStream = request.streamEvents === true;
  const writeFinal = (payload) => {
    if (emitStream) {
      process.stdout.write(JSON.stringify({ event: "dispatch.turn.started", sessionId: payload.sessionId || "", turnId: "fake-turn", payload: {} }) + "\n");
      process.stdout.write(JSON.stringify({ event: "agent.message.chunk", sessionId: payload.sessionId || "", turnId: "fake-turn", payload: { text: payload.output || "" } }) + "\n");
      process.stdout.write(JSON.stringify({ event: "agent.message.completed", sessionId: payload.sessionId || "", turnId: "fake-turn", payload: { text: payload.output || "" } }) + "\n");
      process.stdout.write(JSON.stringify({ ...payload, event: "done" }) + "\n");
      return;
    }
    process.stdout.write(JSON.stringify(payload));
  };
  const child = spawn(request.binaryPath, request.agent === "codex" ? ["app-server", "--stdio"] : ["acp"], { cwd: request.workingDirectory, env: process.env, stdio: ["pipe", "pipe", "ignore"] });
  const lines = createInterface({ input: child.stdout });
  const pending = new Map();
  let nextId = 1;
  let output = "";
  let sessionId = request.sessionId || "";
  if (request.agent === "codex") {
    const call = (method, params) => new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(String(id), { resolve, reject });
      child.stdin.write(JSON.stringify({ id, method, params }) + "\n");
    });
    lines.on("line", (line) => {
      const message = JSON.parse(line);
      if (message.method === "item/completed" && message.params?.item?.type === "agentMessage") {
        output += message.params.item.text || "";
      }
      if (Object.hasOwn(message, "id") && !message.method) {
        const waiter = pending.get(String(message.id));
        if (waiter) { pending.delete(String(message.id)); message.error ? waiter.reject(new Error("rejected")) : waiter.resolve(message.result); }
      }
    });
    await call("initialize", { clientInfo: { name: "fake" }, capabilities: { experimentalApi: true } });
    child.stdin.write(JSON.stringify({ method: "initialized" }) + "\n");
    if (sessionId) {
      await call("thread/resume", { threadId: sessionId });
    } else {
      const started = await call("thread/start", { cwd: request.workingDirectory });
      sessionId = started.thread.id;
    }
    output = "";
    const turn = await call("turn/start", { threadId: sessionId, input: [{ type: "text", text: request.text }] });
    await new Promise((resolve) => {
      const timer = setInterval(() => {
        if (output.length > 0) { clearInterval(timer); resolve(); }
      }, 5);
      setTimeout(() => { clearInterval(timer); resolve(); }, 200);
    });
    child.kill();
    writeFinal({
      ok: true,
      schemaVersion: 3,
      adapterId: "codex",
      driverId: "codex-app-server",
      runtimeProtocol: "codex-app-server-stdio-jsonrpc",
      sessionId,
      threadId: sessionId,
      nativeSessionId: sessionId,
      turnStatus: "end_turn",
      output: output || String(turn?.turn?.items?.find((item) => item.type === "agentMessage")?.text || ""),
      effective: { cwd: request.workingDirectory, model: request.model || null, reasoningEffort: request.reasoningEffort || null, mode: null, runtimeAgent: null, allowAll: null },
    });
    return;
  }
  lines.on("line", (line) => {
    const message = JSON.parse(line);
    if (message.method === "session/update") output += message.params?.update?.content?.text || "";
    if (Object.hasOwn(message, "id") && !message.method) {
      const waiter = pending.get(String(message.id));
      if (waiter) { pending.delete(String(message.id)); message.error ? waiter.reject(new Error("rejected")) : waiter.resolve(message.result); }
    }
  });
  const call = (method, params) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(String(id), { resolve, reject });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
  await call("initialize", { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false } });
  const session = await call(request.sessionId ? "session/load" : "session/new", { cwd: request.workingDirectory, mcpServers: [], ...(request.sessionId ? { sessionId: request.sessionId } : {}) });
  sessionId = request.sessionId || session.sessionId;
  output = "";
  const turn = await call("session/prompt", { sessionId, prompt: [{ type: "text", text: request.text }] });
  child.kill();
  const identity = {
    openclaw: ["openclaw-acp", "openclaw-acp-stdio-jsonrpc"],
    hermes: ["hermes-acp", "hermes-acp-stdio-jsonrpc"],
    "kilo-code": ["kilo-code-serve", "kilo-code-serve-http-v1"],
    cursor: ["cursor-acp", "cursor-acp-v1-stdio-jsonrpc"],
    copilot: ["copilot-acp", "copilot-acp-v1-stdio-ndjson"],
    "kimi-code": ["kimi-code-acp", "kimi-code-acp-v1-stdio-ndjson"],
    opencode: ["opencode-serve", "opencode-serve-http-v1"],
  }[request.agent] || ["opencode-serve", "opencode-serve-http-v1"];
  writeFinal({
    ok: true,
    schemaVersion: 3,
    adapterId: request.agent,
    driverId: identity[0],
    runtimeProtocol: identity[1],
    sessionId,
    threadId: sessionId,
    nativeSessionId: sessionId,
    turnStatus: turn.stopReason,
    output,
    effective: { cwd: request.workingDirectory, model: "fake-model", reasoningEffort: "fake-effort", mode: "fake-mode", runtimeAgent: "fake-agent", allowAll: false },
  });
}

async function appServer() {
  const lines = createInterface({ input: process.stdin });
  let nextTurn = 1;
  for await (const line of lines) {
    const message = JSON.parse(line);
    if (message.method === "initialize") {
      process.stdout.write(JSON.stringify({ id: message.id, result: { protocolVersion: 1 } }) + "\n");
    } else if (message.method === "initialized") {
      continue;
    } else if (message.method === "thread/start") {
      const state = load();
      const threadId = "fake-thread-" + (++state.counter);
      state.sessions[threadId] = { cwd: message.params?.cwd || "", model: message.params?.model || null, messages: [], turns: [] };
      save(state);
      process.stdout.write(JSON.stringify({ id: message.id, result: { thread: { id: threadId }, model: state.sessions[threadId].model } }) + "\n");
    } else if (message.method === "thread/resume") {
      const state = load();
      const threadId = message.params.threadId;
      if (!state.sessions[threadId]) {
        process.stdout.write(JSON.stringify({ id: message.id, error: { code: -32000, message: "missing" } }) + "\n");
        continue;
      }
      process.stdout.write(JSON.stringify({ id: message.id, result: { thread: { id: threadId }, model: state.sessions[threadId].model } }) + "\n");
    } else if (message.method === "thread/read") {
      const state = load();
      const thread = state.sessions[message.params.threadId];
      if (!thread) {
        process.stdout.write(JSON.stringify({ id: message.id, error: { code: -32000, message: "missing" } }) + "\n");
        continue;
      }
      process.stdout.write(JSON.stringify({ id: message.id, result: { thread: { id: message.params.threadId, turns: thread.turns }, model: thread.model } }) + "\n");
    } else if (message.method === "thread/list") {
      const state = load();
      process.stdout.write(JSON.stringify({ id: message.id, result: { threads: Object.keys(state.sessions).map((id) => ({ id })) } }) + "\n");
    } else if (message.method === "thread/delete") {
      const state = load();
      delete state.sessions[message.params.threadId];
      save(state);
      process.stdout.write(JSON.stringify({ id: message.id, result: {} }) + "\n");
    } else if (message.method === "turn/start") {
      const prompt = message.params.input[0].text;
      const reply = prompt.match(/Reply with exactly ([0-9]+)/u)?.[1] || "0";
      const turnId = "fake-turn-" + (nextTurn++);
      const state = load();
      const thread = state.sessions[message.params.threadId];
      thread.messages.push({ role: "user", text: prompt }, { role: "assistant", text: reply });
      const turn = { id: turnId, status: "completed", items: [{ type: "agentMessage", text: reply }] };
      thread.turns.push(turn);
      save(state);
      process.stdout.write(JSON.stringify({ id: message.id, result: { turn: { id: turnId } } }) + "\n");
      process.stdout.write(JSON.stringify({ method: "item/completed", params: { threadId: message.params.threadId, turnId, item: { type: "agentMessage", text: reply } } }) + "\n");
      process.stdout.write(JSON.stringify({ method: "turn/completed", params: { threadId: message.params.threadId, turn } }) + "\n");
    }
  }
}

async function sdk() {
  let buffer = Buffer.alloc(0);
  const reply = (id, result) => {
    const body = Buffer.from(JSON.stringify({ jsonrpc: "2.0", id, result }));
    process.stdout.write(Buffer.concat([Buffer.from("Content-Length: " + body.length + "\r\n\r\n"), body]));
  };
  for await (const chunk of process.stdin) {
    buffer = Buffer.concat([buffer, chunk]);
    while (true) {
      const headerEnd = buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) break;
      const match = buffer.subarray(0, headerEnd).toString("ascii").match(/Content-Length:\s*(\d+)/i);
      if (!match) process.exit(3);
      const length = Number(match[1]);
      const bodyStart = headerEnd + 4;
      if (buffer.length < bodyStart + length) break;
      const message = JSON.parse(buffer.subarray(bodyStart, bodyStart + length).toString("utf8"));
      buffer = buffer.subarray(bodyStart + length);
      if (message.method === "connect" || message.method === "ping") {
        reply(message.id, { protocolVersion: 1 });
      } else if (message.method === "session.list") {
        const state = load();
        reply(message.id, { sessions: Object.keys(state.sessions).map((sessionId) => ({ sessionId })) });
      } else if (message.method === "session.delete") {
        const state = load();
        delete state.sessions[message.params.sessionId];
        save(state);
        reply(message.id, { success: true });
      } else {
        process.exit(4);
      }
    }
  }
}

const args = process.argv.slice(2);
if (args[0] === "agent") {
  await sidecar();
} else if (args[0] === "app-server") {
  await appServer();
} else if (args[0] === "--mode" && args[1] === "rpc") {
  await piRpc();
} else if (args.includes("--server") || args.includes("--headless")) {
  await sdk();
} else if (args[0] === "acp" || args[0] === "serve") {
  // Fixture-only: serve-http agents still exercise ACP JSON-RPC through the
  // fake binary. Live release-UI uses the real serve/HTTP attach path.
  await acp();
} else if (args[0] === "session" && args[1] === "list") {
  const state = load();
  process.stdout.write(JSON.stringify(Object.entries(state.sessions).map(([id, session]) => ({ id, title: session.messages[0]?.text || "" }))));
} else if (args[0] === "session" && args[1] === "delete") {
  if (args[2] === "--help") process.exit(0);
  const state = load();
  if (!state.sessions[args[2]]) process.exit(2);
  delete state.sessions[args[2]];
  save(state);
} else if (args[0] === "sessions" && args[1] === "list") {
  const state = load();
  for (const [id, session] of Object.entries(state.sessions)) {
    const stamp = id.startsWith("fake-session-")
      ? ("20260711_000000_" + id.replace(/[^a-f0-9]/gu, "").padEnd(6, "a").slice(0, 6))
      : id;
    process.stdout.write((session.messages[0]?.text || "session") + " " + stamp + "\n");
  }
} else if (args[0] === "sessions" && args[1] === "delete") {
  if (args.includes("--help")) process.exit(0);
  const state = load();
  const target = args[2];
  const match = Object.keys(state.sessions).find((id) => id === target || ("20260711_000000_" + id.replace(/[^a-f0-9]/gu, "").padEnd(6, "a").slice(0, 6)) === target);
  if (!match) process.exit(2);
  delete state.sessions[match];
  save(state);
} else if (args[0] === "sessions" && args[1] === "export") {
  const destination = args[2];
  const sessionId = args[args.indexOf("--session-id") + 1];
  const state = load();
  const match = Object.keys(state.sessions).find((id) => id === sessionId || ("20260711_000000_" + id.replace(/[^a-f0-9]/gu, "").padEnd(6, "a").slice(0, 6)) === sessionId);
  if (!match) process.exit(2);
  writeFileSync(destination, JSON.stringify(state.sessions[match]));
} else if (args[0] === "export") {
  const state = load();
  if (!state.sessions[args[1]]) process.exit(2);
  process.stdout.write(JSON.stringify(state.sessions[args[1]]));
} else {
  process.exit(2);
}
`;

async function exerciseFailClosed(context, prompt, expectedCode) {
  let sessionId = "";
  let code = "";
  try {
    const result = await nativeTurn(context, "", prompt);
    sessionId = result.sessionId;
  } catch (error) {
    code = error instanceof AcceptanceError ? error.code : "unexpected_failure";
  }
  let records = await listSessions(context);
  if (!sessionId) {
    for (const [id, record] of records) {
      if (record.includes(prompt)) sessionId = id;
    }
  }
  const cleanup = sessionId
    ? await cleanupSession(context, sessionId, context.temporaryDirectory)
    : false;
  records = await listSessions(context);
  return code === expectedCode && cleanup && !records.has(sessionId);
}

async function runSelfTest() {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "lico-acp-parity-selftest-"));
  const fakeBinary = join(temporaryDirectory, "fake-runtime");
  const statePath = join(temporaryDirectory, "state.json");
  try {
    const isolatedWorkingDirectory = join(temporaryDirectory, "workspace");
    mkdirSync(isolatedWorkingDirectory, { recursive: true });
    writeFileSync(fakeBinary, fakeRuntimeSource, { mode: 0o700 });
    chmodSync(fakeBinary, 0o700);
    writeFileSync(statePath, JSON.stringify({ counter: 0, sessions: {} }));
    const fixtureProductReceiptPath = join(temporaryDirectory, "fixture-product-receipt.json");
    writeFileSync(fixtureProductReceiptPath, JSON.stringify({
      schemaVersion: "fixture",
      status: "passed",
      receiptKind: "fixture",
      fixtureBackend: true,
    }), { mode: 0o600 });
    let productFixtureReceiptRejected = false;
    try {
      validateProductReceipt(fixtureProductReceiptPath, "codex");
    } catch (error) {
      productFixtureReceiptRejected = error instanceof AcceptanceError;
    }
    const seedSource = join(temporaryDirectory, "disposable-seed-source");
    const seedTarget = join(temporaryDirectory, "disposable-seed-target");
    mkdirSync(join(seedSource, "credentials"), { recursive: true, mode: 0o700 });
    mkdirSync(join(seedSource, "sessions"), { recursive: true, mode: 0o700 });
    writeFileSync(join(seedSource, "config.toml"), "[self_test]\n", { mode: 0o600 });
    writeFileSync(join(seedSource, "credentials", "account"), "self-test", { mode: 0o600 });
    writeFileSync(join(seedSource, "sessions", "must-not-copy"), "private", { mode: 0o600 });
    const disposableProfileSeedSafe = seedDisposableProfile({
      temporaryDirectory,
      disposableDataRoot: seedTarget,
      disposableSeedSource: seedSource,
    })
      && existsSync(join(seedTarget, "config.toml"))
      && existsSync(join(seedTarget, "credentials", "account"))
      && !existsSync(join(seedTarget, "sessions"));
    rmSync(seedTarget, { recursive: true, force: true });
    const environment = { ...process.env, LICO_FAKE_ACP_STATE: statePath };
    const wrapper = createPrivateWrapper(temporaryDirectory, fakeBinary);
    wrapper.environment = { ...wrapper.environment, ...environment };
    const context = {
      config: agentConfigs.opencode,
      binary: fakeBinary,
      sidecar: fakeBinary,
      wrapper,
      cwd: isolatedWorkingDirectory,
      environment,
      temporaryDirectory,
      timeoutMs: 10_000,
      maxOutputBytes: 32 * 1024,
      copilotSdkLaunchArgs: null,
    };
    const evidenceSeed = {
      permissionFailClosed: true,
      errorFailClosed: true,
      boundedOutputFailClosed: true,
    };
    const rounds = [];
    for (let index = 0; index < strictRoundCount; index += 1) {
      rounds.push(await runRound(context, index + 1, evidenceSeed));
    }
    const strictReducer = aggregateResult("opencode", true, true, rounds, evidenceSeed);
    const permissionFailClosed = await exerciseFailClosed(
      context,
      "SELFTEST_PERMISSION",
      "acp_permission_required",
    );
    const boundedOutputFailClosed = await exerciseFailClosed(
      { ...context, maxOutputBytes: 8 * 1024 },
      "SELFTEST_OVERFLOW",
      "acp_stdout_limit",
    );
    const failedFacts = { ...rounds[0].facts, nativeToArc: false };
    const errorFailClosed = !roundFactsReady(failedFacts);
    const factFailureCode = failedParityFactCode(failedFacts) === "parity_native_to_arc_failed";
    const cleanupBlocked = blockedResult(
      "openclaw",
      false,
      true,
      "session_cleanup_interface_unavailable",
      evidenceSeed,
    ).status === "blocked";
    const copilotState = JSON.parse(readFileSync(statePath, "utf8"));
    copilotState.sessions["fake-copilot-cleanup"] = { cwd: isolatedWorkingDirectory, messages: [] };
    writeFileSync(statePath, JSON.stringify(copilotState));
    const copilotContext = {
      ...context,
      config: agentConfigs.copilot,
      copilotSdkLaunchArgs: null,
    };
    const copilotPreflight = await preflightCleanup(copilotContext);
    const copilotCleanupRpc = copilotPreflight.ready
      && await cleanupSession(copilotContext, "fake-copilot-cleanup", temporaryDirectory);
    const openclawState = JSON.parse(readFileSync(statePath, "utf8"));
    openclawState.sessions["fake-openclaw-cleanup"] = {
      cwd: isolatedWorkingDirectory,
      messages: [],
    };
    writeFileSync(statePath, JSON.stringify(openclawState));
    const openclawContext = {
      ...context,
      config: agentConfigs.openclaw,
    };
    const openclawPreflight = await preflightCleanup(openclawContext);
    const openclawCleanupRpc = openclawPreflight.ready
      && await cleanupSession(
        openclawContext,
        "fake-openclaw-cleanup",
        temporaryDirectory,
      );
    const kiloState = JSON.parse(readFileSync(statePath, "utf8"));
    kiloState.sessions["fake-kilo-cleanup"] = {
      cwd: isolatedWorkingDirectory,
      messages: [{ role: "user", text: "kilo" }],
    };
    writeFileSync(statePath, JSON.stringify(kiloState));
    const kiloContext = {
      ...context,
      config: agentConfigs["kilo-code"],
    };
    const kiloPreflight = await preflightCleanup(kiloContext);
    const kiloCleanupCli = kiloPreflight.ready
      && await cleanupSession(kiloContext, "fake-kilo-cleanup", temporaryDirectory);
    const hermesState = JSON.parse(readFileSync(statePath, "utf8"));
    hermesState.sessions["fake-session-hermes"] = {
      cwd: isolatedWorkingDirectory,
      messages: [{ role: "user", text: "hermes" }],
    };
    writeFileSync(statePath, JSON.stringify(hermesState));
    const hermesContext = {
      ...context,
      config: agentConfigs.hermes,
    };
    const hermesPreflight = await preflightCleanup(hermesContext);
    const hermesListed = hermesPreflight.ready ? await listSessions(hermesContext) : new Map();
    const hermesStamp = [...hermesListed.keys()][0] || "";
    const hermesCleanupCli = hermesPreflight.ready
      && hermesStamp.length > 0
      && await cleanupSession(hermesContext, hermesStamp, temporaryDirectory);
    const kimiDisposableRoot = join(temporaryDirectory, "kimi-isolated");
    const kimiContext = {
      ...context,
      config: agentConfigs["kimi-code"],
      disposableDataRoot: kimiDisposableRoot,
      disposableSeedSource: seedSource,
      cleanedSessions: new Set(),
      observedSessions: new Set(["fake-kimi-session"]),
    };
    const kimiPreflight = await preflightCleanup(kimiContext);
    const kimiCleanup = kimiPreflight.ready
      && await cleanupSession(kimiContext, "fake-kimi-session", temporaryDirectory);
    const piDisposableRoot = join(temporaryDirectory, "pi-isolated-sessions");
    const piEnvironment = {
      ...environment,
      PI_CODING_AGENT_SESSION_DIR: piDisposableRoot,
    };
    const piWrapper = createPrivateWrapper(temporaryDirectory, fakeBinary);
    piWrapper.environment = { ...piWrapper.environment, ...piEnvironment };
    const piContext = {
      ...context,
      config: agentConfigs.pi,
      wrapper: piWrapper,
      environment: piEnvironment,
      disposableDataRoot: piDisposableRoot,
      disposableSeedSource: "",
      cleanedSessions: new Set(),
      observedSessions: new Set(),
    };
    const piPreflight = await preflightCleanup(piContext);
    let piRpcExactResume = false;
    let piCleanup = false;
    if (piPreflight.ready) {
      try {
        const first = await nativePiTurn(
          piContext,
          "",
          canaryPrompt(makeCanary(), "47"),
        );
        const resumed = await nativePiTurn(
          piContext,
          first.sessionId,
          canaryPrompt(makeCanary(), "53"),
        );
        const readback = await nativePiReadback(piContext, first.sessionId);
        piRpcExactResume = resumed.sessionId === first.sessionId
          && first.output === "47"
          && resumed.output === "53"
          && readback.text.includes("47")
          && readback.text.includes("53");
        piCleanup = await cleanupSession(piContext, first.sessionId, temporaryDirectory)
          && (await listSessions(piContext)).size === 0;
        // The fixture keeps its synthetic protocol state in the shared fake
        // runtime ledger in addition to the disposable Pi session files. Real
        // Pi has no such ledger; remove only fixture-tagged rows here.
        const piFixtureState = JSON.parse(readFileSync(statePath, "utf8"));
        for (const sessionId of Object.keys(piFixtureState.sessions)) {
          if (sessionId.startsWith("fake-pi-")) delete piFixtureState.sessions[sessionId];
        }
        writeFileSync(statePath, JSON.stringify(piFixtureState));
      } catch {
        piRpcExactResume = false;
        piCleanup = false;
      }
    }
    const codexContext = {
      ...context,
      config: agentConfigs.codex,
      cleanedSessions: new Set(),
      observedSessions: new Set(),
    };
    const codexPreflight = await preflightCleanup(codexContext);
    let codexRoundReady = false;
    let codexCleanupRpc = false;
    if (codexPreflight.ready) {
      const codexRound = await runRound(codexContext, 1, evidenceSeed);
      codexRoundReady = codexRound.ready === true
        && codexRound.facts?.nativeToArc === true
        && codexRound.facts?.arcToNative === true
        && codexRound.cleanupVerified === true;
      codexCleanupRpc = codexRound.cleanupVerified === true;
    }
    const coreOnlyAggregate = aggregateResult(
      "opencode",
      true,
      true,
      rounds,
      evidenceSeed,
      { releaseUi: false },
    );
    const releaseUiAggregate = aggregateResult(
      "opencode",
      true,
      true,
      rounds,
      evidenceSeed,
      { releaseUi: true },
    );
    const consecutivePassesFailClosed = coreOnlyAggregate.consecutivePasses === 0
      && coreOnlyAggregate.releaseUiPassed === false
      && coreOnlyAggregate.status === "core-passed"
      && releaseUiAggregate.consecutivePasses === strictRoundCount
      && releaseUiAggregate.releaseUiPassed === true
      && releaseUiAggregate.status === "release-ui-passed"
      && releaseUiAggregate.cl06Ready === false;
    const cursorDriver = JSON.parse(readFileSync(driversInventoryPath, "utf8"))
      .drivers
      .find((row) => row.agentId === "cursor");
    const cursorInventoryAligned = cursorDriver?.blockerCodes?.includes("safe_cleanup_unavailable") === true
      && cursorDriver?.capabilityMatrix?.exactResume === true
      && cursorDriver?.capabilityMatrix?.officialLane === true
      && cursorDriver?.driverMode === "blocked"
      && agentConfigs.cursor.cleanupKind === "unavailable"
      && agentConfigs.cursor.cleanupBlocker === "safe_cleanup_unavailable";
    const cursorContext = {
      ...context,
      config: agentConfigs.cursor,
      cleanedSessions: new Set(),
      observedSessions: new Set(),
    };
    let cursorSessionLoadOk = false;
    try {
      const cursorOpened = await nativeTurn(
        cursorContext,
        "",
        canaryPrompt(makeCanary(), "41"),
      );
      const cursorResumed = await nativeTurn(
        cursorContext,
        cursorOpened.sessionId,
        canaryPrompt(makeCanary(), "43"),
      );
      const cursorRead = await nativeReadback(cursorContext, cursorOpened.sessionId);
      cursorSessionLoadOk = cursorOpened.sessionId.length > 0
        && cursorResumed.sessionId === cursorOpened.sessionId
        && cursorRead.text.includes("41")
        && cursorRead.text.includes("43");
      // Self-test owns the temporary fake-runtime state file, so reclaim its
      // synthetic Cursor rows directly. This is not a production cleanup path
      // and never touches Cursor's real storage.
      const cursorFixtureState = JSON.parse(readFileSync(statePath, "utf8"));
      for (const sessionId of cursorContext.observedSessions || []) {
        delete cursorFixtureState.sessions[sessionId];
      }
      writeFileSync(statePath, JSON.stringify(cursorFixtureState));
    } catch {
      cursorSessionLoadOk = false;
    }
    const liveGate = printLiveGateChecklist();
    const cursorLiveGate = liveGate.adapters?.find((row) => row.agentId === "cursor");
    const liveGateReadyCandidates = Array.isArray(liveGate.adapters)
      && liveGate.adapters.length === readyCandidateAgentIds.length
      && liveGate.adapters.every((row) => row.remainingLiveGate.includes("authorize_side_effects"))
      && cursorLiveGate?.cleanupReady === false
      && cursorLiveGate?.remainingLiveGate?.includes("implement_safe_cleanup") === true
      && liveGate.cl06Ready === false;
    const remaining = await listSessions(context);
    const dispatchLaneProbe = probeDispatchLaneFamilies(fakeBinary);
    let evidenceWrite = null;
    if (dispatchLaneProbe.ok) {
      evidenceWrite = createSanitizedSelfTestEvidenceReceipt(dispatchLaneProbe);
    }
    const result = {
      status: strictReducer.status === "core-passed"
        && permissionFailClosed
        && boundedOutputFailClosed
        && errorFailClosed
        && factFailureCode
        && cleanupBlocked
        && copilotCleanupRpc
        && openclawCleanupRpc
        && kiloCleanupCli
        && hermesCleanupCli
        && kimiCleanup
        && piRpcExactResume
        && piCleanup
        && codexRoundReady
        && codexCleanupRpc
        && consecutivePassesFailClosed
        && cursorInventoryAligned
        && cursorSessionLoadOk
        && liveGateReadyCandidates
        && productFixtureReceiptRejected
        && disposableProfileSeedSafe
        && remaining.size === 0
        && dispatchLaneProbe.ok
        ? "passed"
        : "failed",
      cl06Ready: false,
      releaseUiPassed: false,
      strictRounds: strictReducer.roundsCompleted,
      nativeToArc: strictReducer.nativeToArc,
      arcToNative: strictReducer.arcToNative,
      realSessionIds: strictReducer.realSessionIds,
      finalCanaries: strictReducer.finalCanaries,
      cwdParity: strictReducer.cwdParity,
      settingsParity: strictReducer.settingsParity,
      argvCanariesAbsent: strictReducer.argvCanariesAbsent,
      historyReadback: strictReducer.historyReadback,
      permissionFailClosed,
      errorFailClosed,
      factFailureCode,
      boundedOutputFailClosed,
      cleanupBlocked,
      copilotCleanupRpc,
      openclawCleanupRpc,
      kiloCleanupCli,
      hermesCleanupCli,
      kimiCleanup,
      piRpcExactResume,
      piCleanup,
      codexRoundReady,
      codexCleanupRpc,
      consecutivePassesFailClosed,
      cursorInventoryAligned,
      cursorSessionLoadOk,
      liveGateReadyCandidates,
      productFixtureReceiptRejected,
      disposableProfileSeedSafe,
      dispatchLaneContract: dispatchLaneProbe.ok,
      laneFamiliesCovered: dispatchLaneProbe.laneFamiliesCovered,
      harnessVersion: dispatchLaneHarnessVersion,
      evidenceWrite,
      cleanupVerified: strictReducer.cleanupVerified && remaining.size === 0,
      cleanupCount: strictReducer.cleanupCount + 9,
      errorCode: null,
      evidenceDigest: "",
    };
    if (result.status !== "passed") result.errorCode = "self_test_failed";
    result.evidenceDigest = digest({ ...result, evidenceDigest: undefined });
    return result;
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

let output;
try {
  const options = parseArguments(process.argv.slice(2));
  if (options.cleanupProductSession) {
    output = await cleanupProductSession(options);
  } else if (options.printLiveGate) {
    output = printLiveGateChecklist();
  } else {
    const selfTest = await runSelfTest();
    if (options.selfTest) {
      output = selfTest;
    } else if (selfTest.status !== "passed") {
      output = blockedResult(options.agent, options.strict, false, "harness_self_test_failed", {
        permissionFailClosed: selfTest.permissionFailClosed,
        errorFailClosed: selfTest.errorFailClosed,
        boundedOutputFailClosed: selfTest.boundedOutputFailClosed,
      });
    } else {
      output = await runLive(options, {
        permissionFailClosed: selfTest.permissionFailClosed,
        errorFailClosed: selfTest.errorFailClosed,
        boundedOutputFailClosed: selfTest.boundedOutputFailClosed,
      });
    }
  }
} catch (error) {
  const code = error instanceof AcceptanceError ? error.code : "unexpected_failure";
  output = {
    status: "failed",
    roundsRequired: 0,
    roundsCompleted: 0,
    cleanupCount: 0,
    cleanupVerified: false,
    errorCode: code,
    evidenceDigest: digest({ status: "failed", errorCode: code }),
  };
}

console.log(JSON.stringify(output));
if (!["core-passed", "passed", "release-ui-passed", "live-gate-checklist"].includes(output.status)) {
  process.exitCode = 1;
}
