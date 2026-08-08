import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { normalizeAgentId } from "../client-acp-conversation-parity/agent-ids.mjs";
import { defaultMaxStdoutBytes, probeAgentAuthentication } from "./probe.mjs";

const scriptRoot = dirname(fileURLToPath(import.meta.url));
const workspaceRoot = resolve(scriptRoot, "../../..");
const manifestDirectory = join(
  workspaceRoot,
  "packages",
  "contracts",
  "client",
  "fixtures",
  "agent-conversation-adapter",
  "manifests",
);
const registryPath = join(scriptRoot, "probes.json");
const maxJsonBytes = 256 * 1024;
const defaultTimeoutMs = 5_000;

function requireFact(condition, code) {
  if (!condition) throw new Error(code);
}

function readBoundedJson(path) {
  requireFact(statSync(path).size <= maxJsonBytes, "auth_probe_json_too_large");
  return JSON.parse(readFileSync(path, "utf8"));
}

function exactKeys(value, expected, code) {
  requireFact(value && typeof value === "object" && !Array.isArray(value), code);
  const keys = Object.keys(value).sort();
  const sortedExpected = [...expected].sort();
  requireFact(keys.length === sortedExpected.length
    && keys.every((key, index) => key === sortedExpected[index]), code);
}

function prefixesOverlap(left, right) {
  return left === right || left.startsWith(`${right} `) || right.startsWith(`${left} `);
}

export function validateProbeRegistry(registry, canonicalAgentIds) {
  exactKeys(registry, ["schemaVersion", "probes"], "auth_probe_registry_invalid");
  requireFact(registry.schemaVersion === "lico.agent-auth-probes.v1", "auth_probe_registry_invalid");
  requireFact(registry.probes && typeof registry.probes === "object" && !Array.isArray(registry.probes), "auth_probe_registry_invalid");
  for (const [agentId, probe] of Object.entries(registry.probes)) {
    requireFact(canonicalAgentIds.has(agentId), "auth_probe_agent_unknown");
    exactKeys(
      probe,
      [
        "kind",
        "executable",
        "arguments",
        "authenticatedExitCodes",
        "unauthenticatedExitCodes",
        "authenticatedStdoutPrefixes",
        "unauthenticatedStdoutPrefixes",
      ],
      "auth_probe_contract_invalid",
    );
    requireFact(probe.kind === "exit-status", "auth_probe_contract_invalid");
    requireFact(typeof probe.executable === "string" && /^[a-z0-9][a-z0-9._-]{0,63}$/u.test(probe.executable), "auth_probe_contract_invalid");
    requireFact(Array.isArray(probe.arguments) && probe.arguments.length > 0 && probe.arguments.length <= 8, "auth_probe_contract_invalid");
    requireFact(probe.arguments.every((value) => typeof value === "string" && value.length > 0 && value.length <= 64), "auth_probe_contract_invalid");
    for (const key of ["authenticatedExitCodes", "unauthenticatedExitCodes"]) {
      requireFact(Array.isArray(probe[key]) && probe[key].length > 0 && probe[key].length <= 8, "auth_probe_contract_invalid");
      requireFact(probe[key].every((value) => Number.isInteger(value) && value >= 0 && value <= 255), "auth_probe_contract_invalid");
    }
    for (const key of ["authenticatedStdoutPrefixes", "unauthenticatedStdoutPrefixes"]) {
      requireFact(Array.isArray(probe[key]) && probe[key].length <= 8, "auth_probe_contract_invalid");
      requireFact(
        probe[key].every((value) => typeof value === "string" && value.length > 0 && value.length <= 128),
        "auth_probe_contract_invalid",
      );
    }
    requireFact(
      (probe.authenticatedStdoutPrefixes.length === 0)
        === (probe.unauthenticatedStdoutPrefixes.length === 0),
      "auth_probe_output_evidence_asymmetric",
    );
    const overlap = probe.authenticatedExitCodes.some((code) => probe.unauthenticatedExitCodes.includes(code));
    requireFact(!overlap, "auth_probe_exit_code_overlap");
    const outputOverlap = probe.authenticatedStdoutPrefixes.some((authenticated) => (
      probe.unauthenticatedStdoutPrefixes.some((unauthenticated) => (
        prefixesOverlap(authenticated, unauthenticated)
      ))
    ));
    requireFact(!outputOverlap, "auth_probe_output_prefix_overlap");
  }
  return registry;
}

export function loadProbeRegistry(canonicalAgentIds) {
  return validateProbeRegistry(readBoundedJson(registryPath), canonicalAgentIds);
}

export function loadCanonicalAgentManifests() {
  const manifests = readdirSync(manifestDirectory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".json") && entry.name !== "template.json")
    .map((entry) => readBoundedJson(join(manifestDirectory, entry.name)))
    .sort((left, right) => left.identity.agentId.localeCompare(right.identity.agentId));
  const ids = new Set();
  for (const manifest of manifests) {
    const agentId = manifest?.identity?.agentId;
    requireFact(typeof agentId === "string" && agentId.length > 0 && !ids.has(agentId), "auth_probe_manifest_invalid");
    requireFact(Array.isArray(manifest?.configuration?.binaryEnvironmentKeys), "auth_probe_manifest_invalid");
    ids.add(agentId);
  }
  return manifests;
}

export function parseArguments(argv) {
  const options = { agents: [], selfTest: false, timeoutMs: defaultTimeoutMs };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--self-test") {
      options.selfTest = true;
    } else if (argument === "--agent" || argument === "--timeout-ms") {
      const value = argv[index + 1];
      requireFact(typeof value === "string" && value.length > 0, "auth_probe_argument_missing");
      index += 1;
      if (argument === "--agent") options.agents.push(normalizeAgentId(value));
      else options.timeoutMs = Number(value);
    } else {
      throw new Error("auth_probe_argument_unsupported");
    }
  }
  requireFact(Number.isSafeInteger(options.timeoutMs) && options.timeoutMs >= 100 && options.timeoutMs <= 60_000, "auth_probe_timeout_invalid");
  requireFact(!(options.selfTest && options.agents.length > 0), "auth_probe_self_test_conflict");
  return options;
}

export async function runSyntheticSelfTest() {
  const manifest = {
    identity: { agentId: "synthetic" },
    configuration: { binaryEnvironmentKeys: [] },
  };
  const probe = {
    kind: "exit-status",
    executable: "synthetic",
    arguments: ["status"],
    authenticatedExitCodes: [0],
    unauthenticatedExitCodes: [1],
    authenticatedStdoutPrefixes: [],
    unauthenticatedStdoutPrefixes: [],
  };
  const authenticated = await probeAgentAuthentication(manifest, probe, {
    execute: async () => ({ kind: "exit", code: 0 }),
  });
  const unauthenticated = await probeAgentAuthentication(manifest, probe, {
    execute: async () => ({ kind: "exit", code: 1 }),
  });
  const inconclusive = await probeAgentAuthentication(manifest, probe, {
    execute: async () => ({ kind: "exit", code: 2 }),
  });
  const unavailable = await probeAgentAuthentication(manifest, null);
  requireFact(authenticated.authenticationStatus === "authenticated", "auth_probe_self_test_failed");
  requireFact(unauthenticated.authenticationStatus === "unauthenticated", "auth_probe_self_test_failed");
  requireFact(inconclusive.authenticationStatus === "skipped", "auth_probe_self_test_failed");
  requireFact(unavailable.authenticationStatus === "skipped", "auth_probe_self_test_failed");
  return { schemaVersion: "lico.agent-auth-status-self-test.v1", status: "passed", checks: 4 };
}

export async function collectAgentAuthStatus(options, dependencies = {}) {
  const manifests = dependencies.manifests || loadCanonicalAgentManifests();
  const manifestMap = new Map(manifests.map((manifest) => [manifest.identity.agentId, manifest]));
  const canonicalAgentIds = new Set(manifestMap.keys());
  const registry = dependencies.registry
    ? validateProbeRegistry(dependencies.registry, canonicalAgentIds)
    : loadProbeRegistry(canonicalAgentIds);
  const selectedIds = options.agents.length > 0
    ? [...new Set(options.agents)]
    : [...manifestMap.keys()].sort();
  for (const agentId of selectedIds) requireFact(manifestMap.has(agentId), "auth_probe_agent_unknown");
  const agents = [];
  for (const agentId of selectedIds) {
    agents.push(await probeAgentAuthentication(
      manifestMap.get(agentId),
      registry.probes[agentId] || null,
      {
        environment: dependencies.environment || process.env,
        execute: dependencies.execute,
        timeoutMs: options.timeoutMs,
        maxStdoutBytes: defaultMaxStdoutBytes,
      },
    ));
  }
  return Object.freeze({
    schemaVersion: "lico.agent-auth-status.v1",
    status: "completed",
    agents,
  });
}

export async function runAgentAuthStatusCli(argv, dependencies = {}) {
  const write = dependencies.write || ((value) => process.stdout.write(value));
  const setExitCode = dependencies.setExitCode || ((value) => { process.exitCode = value; });
  try {
    const options = parseArguments(argv);
    const receipt = options.selfTest
      ? await (dependencies.selfTest || runSyntheticSelfTest)()
      : await (dependencies.collect || collectAgentAuthStatus)(options);
    write(`${JSON.stringify(receipt)}\n`);
  } catch (error) {
    const code = typeof error?.message === "string" && /^auth_probe_[a-z0-9_]+$/u.test(error.message)
      ? error.message
      : "auth_probe_failed";
    write(`${JSON.stringify({ schemaVersion: "lico.agent-auth-status-error.v1", status: "failed", errorCode: code })}\n`);
    setExitCode(1);
  }
}
