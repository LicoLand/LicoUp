#!/usr/bin/env node

/**
 * Nightly upstream-latest observation probe for the 13 packaged agent adapters.
 *
 * This tool extends the staged client-module regression tooling with a strictly
 * READ-ONLY observation job. It never starts a conversation, never injects a
 * prompt, and never opens, resumes, streams, or cancels a session: a healthy
 * agent may be busy, and forced-reply probes are a serious logic hole. Observed
 * facts are:
 *
 *   install     presence of the configured agent executable (environment and
 *               PATH candidates, plus the authoritative regression entry probe
 *               that scans the LicoUp sidecar inventory). The agent executable
 *               itself is never executed.
 *   version     declared upstream facts only: the adapter manifest
 *               officialCapabilityAssessment.assessedVersion and the last
 *               successful evidence-bind recorded in
 *               crate resources agent-conversation-evidence.json.
 *   capability  driver inventory capability matrix and adapter manifest
 *               presence/driver binding (conformance is enforced by
 *               client-agent-adapter-standard.mjs in the staged regression).
 *   handshake   the LicoUp sidecar `agent conversation capabilities` dispatch
 *               handshake (bounded, fixture-free, no session). Only a built
 *               local sidecar is queried; absent hardware degrades to
 *               "unverified", never to a fake pass.
 *
 * Report contract: privacy-safe — public agent ids plus anonymous indexes,
 * allowlisted reason codes, and booleans. No repository paths, no captured
 * output, no environment values are ever persisted.
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  AGENT_REGRESSION_ENTRIES,
  validateClientRegressionEntries,
} from "../regression/client-regression-entries/index.mjs";
import {
  agentConfigs,
  dispatchLaneHarnessVersion,
  driversInventoryPath,
  evidenceManifestPath,
  workspaceRoot,
} from "../../tests/product-e2e/cli/agent-conversations/support/parity/constants.mjs";
import {
  resolveExecutable,
  resolveSidecar,
  runDispatchLaneCli,
} from "../../tests/product-e2e/cli/agent-conversations/support/parity/sidecar.mjs";

const manifestDirectory = path.resolve(
  workspaceRoot,
  "packages",
  "contracts",
  "client",
  "fixtures",
  "agent-conversation-adapter",
  "manifests",
);
const defaultReportPath = path.resolve(workspaceRoot, "build/reports/upstream-agent-probe.json");

const reasonCodes = new Set([
  "adapter_manifest_missing",
  "agent_binary_unavailable",
  "agent_executable_unavailable",
  "capabilities_handshake_failed",
  "deepseek_harness_jsonrpc_carrier_unverified",
  "dispatch_lane_family_drift",
  "lico_client_executable_unavailable",
  "runtime_protocol_drift",
  "upstream_evidence_missing",
]);

function safeReason(value, fallback) {
  return typeof value === "string" && reasonCodes.has(value) ? value : fallback;
}

function parseArgs(argv) {
  const options = { reportPath: defaultReportPath };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--output") {
      const value = argv[++index];
      if (!value) throw new Error("upstream agent probe output path is required");
      const relative = path.posix.normalize(value.replaceAll("\\", "/").replace(/^\.\//u, ""));
      if (relative.startsWith("/") || relative.startsWith("../") || !relative.startsWith("build/reports/")) {
        throw new Error("upstream agent probe reports must stay under build/reports");
      }
      options.reportPath = path.resolve(workspaceRoot, relative);
    } else {
      throw new Error("unknown upstream agent probe option");
    }
  }
  return options;
}

function readJson(relativePath) {
  return JSON.parse(readFileSync(path.resolve(workspaceRoot, relativePath), "utf8"));
}

function manifestFor(agentId) {
  const candidate = path.resolve(manifestDirectory, `${agentId}.json`);
  try {
    return JSON.parse(readFileSync(candidate, "utf8"));
  } catch {
    return null;
  }
}

async function observeAgent({ entry, driver, evidenceRows, manifest }) {
  const config = agentConfigs[entry.id];
  const row = {
    index: 0,
    agentId: entry.id,
    status: "unverified",
    reasonCode: null,
    install: {
      executablePresent: Boolean(config && resolveExecutable("", config)),
      source: config ? "configured" : "unavailable",
      registryProbeEligible: false,
      registryProbeReason: null,
    },
    version: {
      assessedVersionDeclared: Boolean(manifest?.officialCapabilityAssessment?.assessedVersion),
      versionProbeDeclared: Boolean(manifest?.officialCapabilityAssessment?.versionProbe),
      evidenceRowBound: evidenceRows.has(entry.id),
      harnessCurrent: evidenceRows.get(entry.id)?.harnessVersion === dispatchLaneHarnessVersion,
    },
    capability: {
      manifestPresent: Boolean(manifest),
      manifestDriverBound: Boolean(
        manifest && driver && manifest.identity?.driverId === driver.driverId,
      ),
      driverMode: driver?.driverMode || null,
      laneFamily: driver?.capabilityMatrix?.laneFamily || null,
      officialLane: driver?.capabilityMatrix?.officialLane === true,
    },
    handshake: {
      observed: false,
      laneFamilyMatched: null,
      runtimeProtocolMatched: null,
    },
  };

  const entryProbe = await entry.probe();
  row.install.registryProbeEligible = entryProbe.eligible === true;
  row.install.registryProbeReason = entryProbe.eligible ? null : safeReason(entryProbe.reason, null);

  // Subset of the inventory that the sidecar should report for this agent.
  const sidecar = resolveSidecar("", {});
  if (sidecar) {
    const capabilities = runDispatchLaneCli(sidecar, "capabilities", { agent: entry.id });
    const observed = capabilities?.ok === true && typeof capabilities?.laneFamily === "string";
    row.handshake.observed = observed;
    if (observed) {
      row.handshake.laneFamilyMatched = capabilities.laneFamily === driver?.capabilityMatrix?.laneFamily;
      row.handshake.runtimeProtocolMatched =
        typeof capabilities?.runtimeProtocol === "string" &&
        capabilities.runtimeProtocol === driver?.runtimeProtocol;
    }
  }

  const missingManifest = !manifest || !driver || !row.capability.manifestDriverBound;
  if (missingManifest) {
    row.status = "breakage";
    row.reasonCode = "adapter_manifest_missing";
  } else if (entry.id === "deepseek-harness") {
    row.status = "unverified";
    row.reasonCode = "deepseek_harness_jsonrpc_carrier_unverified";
  } else if (!row.install.executablePresent) {
    row.status = "unverified";
    row.reasonCode = "agent_binary_unavailable";
  } else if (!sidecar) {
    row.status = "unverified";
    row.reasonCode = "lico_client_executable_unavailable";
  } else if (!row.handshake.observed) {
    row.status = "breakage";
    row.reasonCode = "capabilities_handshake_failed";
  } else if (row.handshake.laneFamilyMatched !== true) {
    row.status = "breakage";
    row.reasonCode = "dispatch_lane_family_drift";
  } else if (row.handshake.runtimeProtocolMatched !== true) {
    row.status = "breakage";
    row.reasonCode = "runtime_protocol_drift";
  } else if (!row.version.evidenceRowBound) {
    row.status = "unverified";
    row.reasonCode = "upstream_evidence_missing";
  } else {
    row.status = "verified";
    row.reasonCode = null;
  }
  return row;
}

export function createUpstreamAgentProbeReport(rows, summary) {
  return Object.freeze({
    schemaVersion: "licoup.upstream-agent-probe.v1",
    generatedAt: new Date().toISOString(),
    harnessClass: dispatchLaneHarnessVersion,
    agentCount: rows.length,
    status: summary.breakage > 0 ? "breakage" : summary.verified > 0 ? "verified" : "unverified",
    summary,
    agents: Object.freeze(rows.map((row) => Object.freeze({
      index: row.index,
      agentId: row.agentId,
      status: row.status,
      reasonCode: row.reasonCode,
      install: Object.freeze({ ...row.install }),
      version: Object.freeze({ ...row.version }),
      capability: Object.freeze({ ...row.capability }),
      handshake: Object.freeze({ ...row.handshake }),
    }))),
    breakage: Object.freeze(rows
      .filter((row) => row.status === "breakage")
      .map((row) => Object.freeze({ index: row.index, agentId: row.agentId, reasonCode: row.reasonCode }))),
  });
}

async function main(argv = process.argv.slice(2), output = process.stdout, error = process.stderr) {
  try {
    validateClientRegressionEntries();
    const options = parseArgs(argv);
    const inventory = readJson("crates/licoup-native/resources/agent-conversation-drivers.json");
    const evidence = readJson("crates/licoup-native/resources/agent-conversation-evidence.json");
    const driverByAgent = new Map(inventory.drivers.map((driver) => [driver.agentId, driver]));
    const evidenceRows = new Map((evidence.adapters || []).map((row) => [row.agentId, row]));
    const rows = [];
    for (const [index, entry] of AGENT_REGRESSION_ENTRIES.entries()) {
      rows.push(await observeAgent({
        entry,
        driver: driverByAgent.get(entry.id),
        evidenceRows,
        manifest: manifestFor(entry.id),
      }));
    }
    rows.forEach((row, index) => { row.index = index; });
    if (rows.length !== 13) throw new Error("upstream agent probe inventory is incomplete");
    const summary = {
      verified: rows.filter((row) => row.status === "verified").length,
      breakage: rows.filter((row) => row.status === "breakage").length,
      unverified: rows.filter((row) => row.status === "unverified").length,
    };
    const report = createUpstreamAgentProbeReport(rows, summary);
    mkdirSync(path.dirname(options.reportPath), { recursive: true });
    writeFileSync(options.reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
    output.write(`${JSON.stringify(report)}\n`);
    return summary.breakage > 0 ? 1 : 0;
  } catch (failure) {
    error.write(`${JSON.stringify({
      schemaVersion: "licoup.upstream-agent-probe.v1",
      status: "failed",
      reasonCode: /^[a-z0-9_.:+-]{1,96}$/u.test(failure?.message || "")
        ? failure.message
        : "upstream_probe_failed",
    })}\n`);
    return 2;
  }
}

const invoked = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invoked) process.exitCode = await main();
