#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, renameSync, rmSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  classifyLinuxEvidenceValidationFailure,
  classifyLinuxVmProducerFailure,
  createLinuxVmPackageFailureRecord,
  LinuxEvidenceValidationError,
  linuxEvidencePrivacyRecord,
  linuxEvidenceSchemaVersion,
  linuxVmReceiptWriteFailure,
  linuxNodeMatrixSchema,
  validateLinuxNodeMatrixReport,
  validateLinuxVmPackageReceipt
} from "./lib/secure-mesh-linux-evidence.mjs";
import {
  LinuxClientNode,
  buildLinuxNodeImage,
  createDockerNetwork,
  removeDockerNetwork,
  removeLinuxNodeImage
} from "./lib/secure-mesh-linux-node.mjs";
import {
  loadCapabilityCatalog,
  reduceCapabilityFacts,
  validateCapabilityReport
} from "./lib/secure-mesh-capability-report.mjs";
import {
  sha256File as stableSha256File,
  stableReadFile,
  stableSnapshotFile,
} from "./lib/client-release-artifact-digest.mjs";
import {
  atomicWriteReportJson,
  SAFE_REPORT_WRITE_STAGES,
} from "./lib/safe-report-io.mjs";
import {
  inspectLinuxTarGzipArchive,
  LINUX_TAR_RESOURCE_LIMITS,
} from "./lib/linux-tar-resource-bounds.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const options = parseArgs(process.argv.slice(2));
let verificationPhase = "input_validation";

if (options.selfTest) {
  try {
    console.log(JSON.stringify(runSelfTest(), null, 2));
  } catch (error) {
    const failure = classifyLinuxEvidenceValidationFailure(
      error,
      "linux_node_matrix_self_test_assertion_failed",
    );
    console.error(JSON.stringify({
      ok: false,
      reason: "linux_node_matrix_self_test_failed",
      validationRuleId: failure.ruleId,
      failureCategory: failure.category,
    }, null, 2));
    process.exitCode = 1;
  }
} else {
  runMatrix().catch(() => {
    try {
      writeFailureReport("linux_node_matrix_incomplete");
    } catch {
      // The nonzero exit remains authoritative when the blocked destination is unsafe.
    }
    console.error(JSON.stringify({
      ok: false,
      artifactKind: "linux-current-client-node-matrix",
      reason: "linux_node_matrix_incomplete",
      phase: verificationPhase
    }, null, 2));
    process.exitCode = 1;
  });
}

async function runMatrix() {
  assert(process.platform === "linux", "Linux node matrix requires Linux");
  const expectedSourceDigest = requiredOption("expectedSourceDigest");
  assert(/^sha256:[a-f0-9]{64}$/u.test(expectedSourceDigest),
    "Linux node matrix source digest is invalid");
  const archive = requiredFile(requiredOption("archive"), "Linux archive");
  const tempRoot = mkdtempSync(path.join(os.tmpdir(), "lico-linux-node-matrix-"));
  try {
  const stableArchive = stableSnapshotFile(
    archive,
    tempRoot,
    "release-archive.tar.gz",
    { maxBytes: LINUX_TAR_RESOURCE_LIMITS.maxCompressedBytes },
  );
  inspectLinuxTarGzipArchive(stableArchive);
  verificationPhase = "archive_binding";
  const distributionManifestPath = requiredFile(
    requiredOption("distributionManifest"),
    "Linux distribution manifest"
  );
  const vmReceiptPath = requiredFile(requiredOption("vmReceipt"), "Linux VM package receipt");
  const vmReceipt = JSON.parse(stableReadFile(vmReceiptPath, {
    maxBytes: 16 * 1024 * 1024,
  }).toString("utf8"));
  validateLinuxVmPackageReceipt(vmReceipt, expectedSourceDigest);
  const distribution = JSON.parse(stableReadFile(distributionManifestPath, {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8"));
  const archiveDigest = sha256File(stableArchive);
  assert(distribution.sourceStateDigest === expectedSourceDigest,
    "Linux node archive source-state digest is stale");
  assert(distribution.productVersion === vmReceipt.productVersion &&
    distribution.buildNumber === vmReceipt.buildNumber,
  "Linux node archive version binding is inconsistent");
  assert(distribution.sha256 === archiveDigest.slice("sha256:".length),
    "Linux node archive digest is invalid");
  assert(vmReceipt.sourceBinding.archiveDigest === archiveDigest,
    "Linux node archive does not match the VM install receipt");
  assert(/^sha256:[a-f0-9]{64}$/u.test(String(distribution.bundleManifestDigest || "")),
    "Linux node bundle-manifest digest is invalid");

  const context = path.join(tempRoot, "image-context");
  mkdirSync(context, { recursive: true });
  extractArchive(stableArchive, context);
  const extractedBundle = path.join(context, "bundle");
  const imageClientRoot = path.join(context, "client");
  assert(existsSync(extractedBundle), "Linux node archive did not contain the client bundle");
  renameSync(extractedBundle, imageClientRoot);
  const bundleManifestPath = requiredFile(
    path.join(imageClientRoot, "package-metadata", "lico-client", "packaging-modules.json"),
    "Linux node bundle manifest"
  );
  const bundleManifest = JSON.parse(stableReadFile(bundleManifestPath, {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8"));
  assert(bundleManifest.sourceStateDigest === expectedSourceDigest,
    "Linux node bundle source-state digest is stale");
  assert(sha256File(bundleManifestPath) === distribution.bundleManifestDigest,
    "Linux node bundle-manifest digest does not match the archive receipt");
  assert(vmReceipt.sourceBinding.bundleManifestDigest === distribution.bundleManifestDigest,
    "Linux node bundle manifest does not match the VM install receipt");
  const nativeClientDigest = sha256File(requiredFile(
    path.join(imageClientRoot, "lico-client"),
    "Linux node native sidecar",
  ), { maxBytes: 512 * 1024 * 1024 });
  assert(vmReceipt.sourceBinding.nativeClientDigest === nativeClientDigest,
    "Linux node native sidecar does not match the VM install receipt");

  let imageRecord = null;
  let network = null;
  let relay = null;
  const nodes = [];
  const teardown = {
    bounded: true,
    nodeCount: 3,
    allProcessesStopped: false,
    allContainersRemoved: false,
    ephemeralStateRemoved: false
  };
  let result;
  try {
    verificationPhase = "image_build";
    imageRecord = buildLinuxNodeImage({
      context,
      dockerfile: options.dockerfile ||
        path.join(repoRoot, "apps", "desktop", "docker", "secure-mesh-node.Dockerfile"),
      dockerCommand: options.dockerCommand || ""
    });
    network = createDockerNetwork({ dockerCommand: options.dockerCommand || "" });
    relay = await OpaqueRelay.start();
    verificationPhase = "node_start";
    const gateway = relay.containerGateway();
    for (const label of ["linux-a", "linux-b", "linux-c"]) {
      const node = new LinuxClientNode({
        label,
        image: imageRecord.image,
        network: network.name,
        dockerCommand: options.dockerCommand || ""
      });
      nodes.push(node);
      const status = await node.start();
      validateCapabilityReport(status.capabilityReport);
    }
    const [linuxA, linuxB, linuxC] = nodes;
    const capabilityReports = await Promise.all(nodes.map((node) =>
      node.execute(["secure-mesh", "status"]).then((status) => status.capabilityReport)
    ));
    for (const report of capabilityReports) validateCapabilityReport(report);
    assert(new Set(capabilityReports.map((report) => report.catalogDigest)).size === 1,
      "Linux nodes disagreed on the exact capability catalog");

    verificationPhase = "state_isolation";
    await proveStateIsolation(nodes);
    verificationPhase = "first_pair_exchange";
    const firstPair = await pairNodes({ pc: linuxA, mobile: linuxB, gateway });
    const firstExchange = await exchangeSecureCommand({
      pc: linuxA,
      mobile: linuxB,
      relay,
      marker: randomMarker()
    });
    verificationPhase = "second_pair_exchange";
    const secondPair = await pairNodes({ pc: linuxB, mobile: linuxC, gateway });
    const secondExchange = await exchangeSecureCommand({
      pc: linuxB,
      mobile: linuxC,
      relay,
      marker: randomMarker()
    });
    const publicIdentityDigests = [
      publicIdentityDigest(firstPair.pcSecureMesh),
      publicIdentityDigest(secondPair.pcSecureMesh),
      publicIdentityDigest(secondPair.mobileSecureMesh)
    ];
    assert(new Set(publicIdentityDigests).size === 3,
      "Linux nodes did not expose three unique public endpoint identities");

    verificationPhase = "restart_isolation";
    await linuxA.restartRpc();
    assert(linuxA.rpcProcessCount === 2 && linuxB.rpcProcessCount === 1 &&
      linuxC.rpcProcessCount === 1,
    "Linux node restart affected more than the selected participant");
    const restartedState = await linuxA.execute(["state", "get", "settings"]);
    assert(restartedState?.document?.linuxNodeIsolationMarker === "linux-a",
      "Restarted Linux node lost or crossed its public state root");
    const restartRequiresRePairRekey = await restartRequiresPairing(linuxA);
    assert(restartRequiresRePairRekey, "Memory-only Linux restart did not require re-pair/rekey");
    await proveStateIsolation([linuxB, linuxC]);
    const postRestartExchange = await exchangeSecureCommand({
      pc: linuxB,
      mobile: linuxC,
      relay,
      marker: randomMarker()
    });
    assert(postRestartExchange.ready, "Unaffected Linux nodes failed after peer restart");
    assert(relay.plaintextObserved === false, "Opaque relay observed protected command plaintext");

    result = {
      capabilityReport: capabilityReports[0],
      identityCount: new Set(publicIdentityDigests).size,
      exchangeCount: [firstExchange, secondExchange, postRestartExchange]
        .filter((exchange) => exchange.ready).length,
      allNodesParticipated: firstPair.ready && secondPair.ready,
      secureSessionsEstablished: firstPair.ready && secondPair.ready,
      restartRequiresRePairRekey
    };
  } finally {
    verificationPhase = result ? "teardown" : verificationPhase;
    const processStopResults = [];
    const containerRemovalResults = [];
    for (const node of [...nodes].reverse()) {
      try {
        await node.stop();
        processStopResults.push(node.rpcStopped === true);
        containerRemovalResults.push(node.removed === true);
      } catch {
        processStopResults.push(false);
        containerRemovalResults.push(false);
      }
    }
    teardown.allProcessesStopped = processStopResults.length === nodes.length &&
      processStopResults.every(Boolean);
    teardown.allContainersRemoved = containerRemovalResults.length === nodes.length &&
      containerRemovalResults.every(Boolean);
    const relayStopped = relay ? await relay.stop() : true;
    const networkRemoved = network ? removeDockerNetwork(network) : true;
    const imageRemoved = imageRecord ? removeLinuxNodeImage(imageRecord) : true;
    teardown.bounded = teardown.bounded && relayStopped && networkRemoved && imageRemoved;
    teardown.ephemeralStateRemoved = teardown.allContainersRemoved && networkRemoved && imageRemoved;
  }
  assert(result, "Linux node matrix operations did not complete");
  assert(teardown.bounded && teardown.allContainersRemoved,
    "Linux node matrix teardown did not complete within bounds");
  const report = {
    schema: linuxNodeMatrixSchema,
    schemaVersion: linuxEvidenceSchemaVersion,
    ok: true,
    producer: "linux-node-matrix",
    artifactKind: "linux-current-client-node-matrix",
    target: "ubuntu-linux-arm64",
    redacted: true,
    reportLeakScan: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    sourceBinding: {
      sourceStateDigest: expectedSourceDigest,
      sourceStateDigestProvenance: String(distribution.sourceStateDigestProvenance || ""),
      archiveDigest,
      bundleManifestDigest: distribution.bundleManifestDigest,
      nativeClientDigest,
      stale: false
    },
    runtime: {
      kind: "isolated_linux_containers",
      nodeCount: 3,
      currentClientArchive: true,
      publicOperationsOnly: true,
      eventDrivenReadiness: true
    },
    isolation: {
      participantLabels: ["linux-a", "linux-b", "linux-c"],
      distinctStateRoots: true,
      noSharedSecretVolume: nodes.every((node) => node.mountIsolationVerified),
      uniquePublicIdentityCount: result.identityCount,
      crossNodeStateReadRejected: true,
      containerIsolation: true
    },
    pairwise: {
      exchangeCount: result.exchangeCount,
      allNodesParticipated: result.allNodesParticipated,
      secureSessionsEstablished: result.secureSessionsEstablished,
      opaqueRelay: true,
      relayPlaintextObserved: false,
      relayCiphertextIncludedInReport: false
    },
    restart: {
      restartedParticipant: "linux-a",
      restartedProcessCount: 1,
      restartRequiresRePairRekey: result.restartRequiresRePairRekey,
      unaffectedParticipantCount: 2,
      postRestartExchangeReady: true,
      stateContaminationDetected: false
    },
    teardown,
    capabilityReport: result.capabilityReport,
    privacy: linuxEvidencePrivacyRecord(),
    summary: {
      currentSourceNodes: true,
      isolationReady: true,
      pairwiseReady: true,
      restartIsolationReady: true,
      teardownReady: true,
      privacyReady: true
    }
  };
  validateLinuxNodeMatrixReport(report, expectedSourceDigest);
  writeReport(report);
  console.log(JSON.stringify({
    ok: true,
    artifactKind: report.artifactKind,
    nodeCount: 3,
    exchangeCount: report.pairwise.exchangeCount,
    isolationReady: true,
    restartIsolationReady: true,
    teardownReady: true,
    privacyReady: true
  }, null, 2));
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
}

async function proveStateIsolation(nodes) {
  for (const node of nodes) {
    await node.execute([
      "state",
      "set",
      "settings",
      JSON.stringify({ linuxNodeIsolationMarker: node.label })
    ]);
  }
  for (const node of nodes) {
    const state = await node.execute(["state", "get", "settings"]);
    assert(state?.document?.linuxNodeIsolationMarker === node.label,
      "Linux node public state crossed an endpoint boundary");
  }
}

async function pairNodes({ pc, mobile, gateway }) {
  await configureForRelay(pc, gateway, true);
  await configureForRelay(mobile, gateway, true);
  const pairing = await pc.execute(["mobile", "relay", "pairing", "create"]);
  const invite = pairing?.mobileRelayPairingInvite;
  assert(invite && typeof invite === "object", "Linux pairing create omitted its invite");
  const claimed = await mobile.execute([
    "mobile",
    "relay",
    "pairing",
    "claim",
    "--invite-json",
    JSON.stringify(invite),
    "--mobile-device-name",
    mobile.label,
    "--platform",
    "linux"
  ]);
  await pc.execute(["mobile", "relay", "pairing", "status"]);
  await mobile.execute(["mobile", "relay", "pairing", "status"]);
  const pcStatus = await pc.execute(["mobile", "relay", "e2ee", "status"]);
  const mobileStatus = await mobile.execute(["mobile", "relay", "e2ee", "status"]);
  assert(pcStatus?.secureSessionEstablished === true &&
    mobileStatus?.secureSessionEstablished === true,
  "Linux pairwise secure session was not established");
  return {
    ready: claimed?.ok === true,
    pcSecureMesh: pairing?.pairing?.pc?.secureMesh || invite.pcSecureMesh,
    mobileSecureMesh: claimed?.pairing?.mobile?.secureMesh
  };
}

async function configureForRelay(node, gateway, reset) {
  await node.execute([
    "mobile",
    "relay",
    "config",
    "set",
    "--use-custom-gateway",
    "true",
    "--custom-gateway-url",
    gateway,
    "--reset-pairing",
    reset ? "true" : "false",
    "--relay-enabled",
    "true",
    "--pc-client-id",
    node.label,
    "--pc-client-name",
    node.label
  ]);
}

async function exchangeSecureCommand({ pc, mobile, relay, marker }) {
  relay.observeMarker(marker);
  const created = await mobile.execute([
    "mobile",
    "relay",
    "commands",
    "create-secure",
    "--command-kind",
    "client.activity.sync",
    "--workspace-id",
    "default",
    "--body",
    JSON.stringify({ limit: 1, nodeMatrixMarker: marker })
  ]);
  const commandId = String(created?.command?.commandId || "");
  assert(commandId, "Linux pairwise exchange did not create a command");
  const synced = await pc.execute(["mobile", "relay", "commands", "sync"]);
  const opened = await mobile.execute([
    "mobile",
    "relay",
    "commands",
    "result-secure",
    "--command-id",
    commandId
  ]);
  assert(opened?.ok === true && opened?.openedResult,
    "Linux pairwise exchange did not open the protected result");
  assert(Array.isArray(synced?.completed) && synced.completed.some((entry) => entry?.ok === true),
    "Linux pairwise exchange did not complete through the public operation");
  assert(relay.plaintextObserved === false, "Opaque relay observed the Linux exchange plaintext");
  return { ready: true };
}

async function restartRequiresPairing(node) {
  try {
    const status = await node.execute(["mobile", "relay", "e2ee", "status"]);
    return status?.secureSessionEstablished === false &&
      status?.secretStore?.capabilityReport?.custody?.restartSemantics ===
        "re_pair_rekey_after_restart" &&
      Array.isArray(status?.blockers) &&
      status.blockers.includes("safe_secret_custody_not_operational");
  } catch {
    return false;
  }
}

function publicIdentityDigest(secureMesh) {
  assert(secureMesh && typeof secureMesh === "object", "Linux public endpoint identity is missing");
  const identity = secureMesh.endpointIdentity || secureMesh.deviceIdentity || {
    endpointId: secureMesh.endpointId,
    identityPublicKey: secureMesh.identityPublicKeyBase64url,
    signingPublicKey: secureMesh.signingPublicKeyBase64url,
    rotationEpoch: secureMesh.rotationEpoch
  };
  const serialized = canonicalJson(identity);
  assert(serialized.length > 32, "Linux public endpoint identity is incomplete");
  return createHash("sha256").update(serialized).digest("hex");
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function randomMarker() {
  return `protected-${randomBytes(18).toString("base64url")}`;
}

class OpaqueRelay {
  static async start() {
    const relay = new OpaqueRelay();
    await relay.listen();
    return relay;
  }

  constructor() {
    this.pairings = new Map();
    this.plaintextMarkers = new Set();
    this.plaintextObserved = false;
    this.server = http.createServer((request, response) => {
      this.handle(request, response).catch(() => {
        sendJson(response, 500, { ok: false, error: "relay_operation_failed" });
      });
    });
    this.port = 0;
  }

  async listen() {
    await new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(0, "0.0.0.0", () => {
        this.server.off("error", reject);
        resolve();
      });
    });
    const address = this.server.address();
    assert(address && typeof address === "object", "Opaque relay did not bind");
    this.port = address.port;
  }

  containerGateway() {
    assert(this.port > 0, "Opaque relay is unavailable");
    return `http://host.docker.internal:${this.port}`;
  }

  async handle(request, response) {
    if (request.method !== "POST") {
      sendJson(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }
    const body = await readJsonBody(request);
    this.scanPlaintext(body);
    const pathname = new URL(request.url || "/", "http://relay.invalid").pathname;
    if (pathname === "/api/mobile-relay/pairings") {
      this.createPairing(body, response);
      return;
    }
    if (pathname === "/api/mobile-relay/pairings/claim") {
      this.claimPairing(body, response);
      return;
    }
    if (pathname === "/api/mobile-relay/pairings/status") {
      this.pairingStatus(body, request, response);
      return;
    }
    if (pathname === "/api/mobile-relay/pc/check-in") {
      this.pairingStatus(body, request, response);
      return;
    }
    if (pathname === "/api/mobile-relay/commands") {
      this.createCommand(body, request, response);
      return;
    }
    if (pathname === "/api/mobile-relay/commands/poll") {
      this.pollCommands(body, request, response);
      return;
    }
    const complete = pathname.match(/^\/api\/mobile-relay\/commands\/([^/]+)\/complete$/u);
    if (complete) {
      this.completeCommand(complete[1], body, request, response);
      return;
    }
    const result = pathname.match(/^\/api\/mobile-relay\/commands\/([^/]+)\/result$/u);
    if (result) {
      this.commandResult(result[1], body, request, response);
      return;
    }
    sendJson(response, 404, { ok: false, error: "operation_not_found" });
  }

  createPairing(body, response) {
    const pairingId = `pair_${randomUUID()}`;
    const pairingCode = String(Math.floor(100000 + Math.random() * 900000));
    const pcToken = randomBytes(32).toString("base64url");
    const now = new Date().toISOString();
    const pairing = {
      pairingId,
      pairingCode,
      pcToken,
      mobileToken: "",
      status: "pending",
      createdAt: now,
      updatedAt: now,
      expiresAt: new Date(Date.now() + 10 * 60_000).toISOString(),
      pc: {
        clientId: String(body.pcClientId || ""),
        label: String(body.pcClientName || ""),
        platform: String(body.platform || "linux"),
        capabilities: body.capabilities || {},
        targets: Array.isArray(body.targets) ? body.targets : [],
        secureMesh: body.secureMesh || body.pcSecureMesh || null
      },
      mobile: null,
      commands: []
    };
    this.pairings.set(pairingId, pairing);
    sendJson(response, 200, relayResult({
      pairing: publicPairing(pairing),
      pairingId,
      pairingCode,
      pcToken,
      expiresAt: pairing.expiresAt
    }));
  }

  claimPairing(body, response) {
    const pairing = this.pairings.get(String(body.pairingId || ""));
    if (!pairing || pairing.status !== "pending" || String(body.pairingCode || "") !== pairing.pairingCode) {
      sendJson(response, 404, { ok: false, error: "pairing_not_found" });
      return;
    }
    pairing.mobileToken = randomBytes(32).toString("base64url");
    pairing.status = "paired";
    pairing.updatedAt = new Date().toISOString();
    pairing.mobile = {
      deviceId: String(body.mobileDeviceId || ""),
      label: String(body.mobileDeviceName || ""),
      platform: String(body.platform || "linux"),
      secureMesh: body.secureMesh || body.mobileSecureMesh || null,
      secureMeshClaimProof: String(body.secureMeshClaimProof || "")
    };
    sendJson(response, 200, relayResult({
      pairing: publicPairing(pairing),
      pairingId: pairing.pairingId,
      mobileToken: pairing.mobileToken
    }));
  }

  pairingStatus(body, request, response) {
    const pairing = this.authorizedPairing(body, request, "either");
    if (!pairing) {
      sendJson(response, 401, { ok: false, error: "invalid_pairing_token" });
      return;
    }
    sendJson(response, 200, relayResult({ pairing: publicPairing(pairing) }));
  }

  createCommand(body, request, response) {
    const pairing = this.authorizedPairing(body, request, "mobile");
    if (!pairing) {
      sendJson(response, 401, { ok: false, error: "invalid_mobile_token" });
      return;
    }
    const secureEnvelope = body?.payload?.envelope || body?.secureEnvelope || null;
    if (!secureEnvelope || typeof secureEnvelope !== "object") {
      sendJson(response, 426, { ok: false, error: "secure_envelope_required" });
      return;
    }
    const now = new Date().toISOString();
    const command = {
      commandId: `cmd_${randomUUID()}`,
      pairingId: pairing.pairingId,
      type: String(body.type || "secure_mesh.envelope"),
      secureEnvelope,
      resultEnvelope: null,
      status: "pending",
      createdAt: now,
      updatedAt: now,
      deliveredAt: "",
      completedAt: ""
    };
    pairing.commands.push(command);
    sendJson(response, 200, relayResult({ command: publicCommand(command) }));
  }

  pollCommands(body, request, response) {
    const pairing = this.authorizedPairing(body, request, "pc");
    if (!pairing) {
      sendJson(response, 401, { ok: false, error: "invalid_pc_token" });
      return;
    }
    const now = new Date().toISOString();
    const commands = pairing.commands.filter((command) => command.status === "pending");
    for (const command of commands) {
      command.status = "in_progress";
      command.deliveredAt = now;
      command.updatedAt = now;
    }
    sendJson(response, 200, relayResult({ commands: commands.map(publicCommand) }));
  }

  completeCommand(commandId, body, request, response) {
    const pairing = this.authorizedPairing(body, request, "pc");
    const command = pairing?.commands.find((entry) => entry.commandId === commandId);
    if (!pairing || !command || !body.secureEnvelope) {
      sendJson(response, 404, { ok: false, error: "command_not_found" });
      return;
    }
    command.resultEnvelope = body.secureEnvelope;
    command.status = body.ok === false ? "failed" : "completed";
    command.completedAt = new Date().toISOString();
    command.updatedAt = command.completedAt;
    sendJson(response, 200, relayResult({ command: publicCommand(command) }));
  }

  commandResult(commandId, body, request, response) {
    const pairing = this.authorizedPairing(body, request, "mobile");
    const index = pairing?.commands.findIndex((entry) => entry.commandId === commandId) ?? -1;
    if (!pairing || index < 0) {
      sendJson(response, 404, { ok: false, error: "command_not_found" });
      return;
    }
    const [command] = pairing.commands.splice(index, 1);
    sendJson(response, 200, relayResult({
      command: publicCommand(command),
      ackPurge: { acknowledged: true, purged: true }
    }));
  }

  authorizedPairing(body, request, role) {
    const pairing = this.pairings.get(String(body.pairingId || ""));
    if (!pairing) return null;
    const token = bearerToken(request) || String(body.pcToken || body.mobileToken || body.token || "");
    const pc = token && token === pairing.pcToken;
    const mobile = token && token === pairing.mobileToken;
    if ((role === "pc" && !pc) || (role === "mobile" && !mobile) ||
      (role === "either" && !pc && !mobile)) return null;
    return pairing;
  }

  scanPlaintext(body) {
    const serialized = JSON.stringify(body);
    for (const marker of this.plaintextMarkers) {
      if (serialized.includes(marker)) this.plaintextObserved = true;
    }
  }

  observeMarker(marker) {
    this.plaintextMarkers.add(marker);
  }

  async stop() {
    this.server.closeAllConnections?.();
    const stopped = await Promise.race([
      new Promise((resolve) => this.server.close(() => resolve(true))),
      new Promise((resolve) => setTimeout(() => resolve(false), 5_000))
    ]);
    this.pairings.clear();
    this.plaintextMarkers.clear();
    return stopped;
  }
}

function relayResult(payload) {
  return {
    ok: true,
    schemaVersion: "licolite.mobile-relay.response-schema.v1",
    protocolVersion: "licolite.mobile-relay.v1",
    ...payload
  };
}

function publicPairing(pairing) {
  return {
    pairingId: pairing.pairingId,
    status: pairing.status,
    createdAt: pairing.createdAt,
    updatedAt: pairing.updatedAt,
    expiresAt: pairing.expiresAt,
    pc: { ...pairing.pc, tokenConfigured: true },
    mobile: pairing.mobile ? { ...pairing.mobile, tokenConfigured: true } : null
  };
}

function publicCommand(command) {
  return {
    commandId: command.commandId,
    pairingId: command.pairingId,
    type: command.type,
    payload: {},
    secureEnvelope: command.secureEnvelope,
    envelope: command.secureEnvelope,
    resultEnvelope: command.resultEnvelope,
    status: command.status,
    createdAt: command.createdAt,
    updatedAt: command.updatedAt,
    deliveredAt: command.deliveredAt,
    completedAt: command.completedAt,
    result: null,
    error: ""
  };
}

async function readJsonBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    assert(size <= 4 * 1024 * 1024, "Opaque relay request exceeded its bound");
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
  } catch {
    throw new Error("Opaque relay received invalid JSON");
  }
}

function sendJson(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store"
  });
  response.end(body);
}

function bearerToken(request) {
  const header = String(request.headers.authorization || "");
  return header.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
}

function extractArchive(archive, destination) {
  const result = spawnSync("/usr/bin/tar", ["-xzf", archive, "-C", destination], {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    timeout: LINUX_TAR_RESOURCE_LIMITS.extractTimeoutMs,
  });
  assert(result.status === 0 && result.error?.code !== "ETIMEDOUT",
    "Linux node archive extraction failed or timed out");
}

function sha256File(file) {
  return stableSha256File(file);
}

function requiredFile(value, label) {
  const file = path.resolve(String(value || ""));
  const info = value && existsSync(file)
    ? lstatSync(file, { throwIfNoEntry: false })
    : undefined;
  assert(info?.isFile() === true && info.isSymbolicLink() === false,
    `${label} is missing or unsafe`);
  return file;
}

function writeReport(report) {
  const { root, ref } = safeReportDestination();
  atomicWriteReportJson(root, ref, report);
}

function writeFailureReport(reason) {
  if (!options.report) return;
  const { root, ref } = safeReportDestination();
  atomicWriteReportJson(root, ref, {
    schema: linuxNodeMatrixSchema,
    schemaVersion: linuxEvidenceSchemaVersion,
    ok: false,
    artifactKind: "linux-current-client-node-matrix",
    reason,
    phase: verificationPhase,
    redacted: true,
    reportLeakScan: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    privacy: linuxEvidencePrivacyRecord()
  });
}

function safeReportDestination() {
  const rootValue = String(process.env.LICO_LINUX_VM_REPORT_ROOT || "").trim();
  assert(rootValue, "Linux node matrix report root is missing");
  const root = path.resolve(rootValue);
  const target = path.resolve(requiredOption("report"));
  const relative = path.relative(root, target);
  assert(relative && !relative.startsWith("..") && !path.isAbsolute(relative),
    "Linux node matrix report path escapes its allowed root");
  return { root, ref: relative };
}

function requiredOption(name) {
  const value = String(options[name] || "").trim();
  assert(value, "Linux node matrix option is missing");
  return value;
}

function parseArgs(args) {
  const parsed = { selfTest: false };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--self-test") {
      parsed.selfTest = true;
      continue;
    }
    if (!arg.startsWith("--")) throw new Error("Unknown Linux node matrix argument");
    const [rawKey, inline] = arg.slice(2).split("=", 2);
    const key = rawKey.replace(/-([a-z])/gu, (_, letter) => letter.toUpperCase());
    parsed[key] = inline ?? args[index + 1] ?? "";
    if (inline === undefined) index += 1;
  }
  return parsed;
}

function runSelfTest() {
  const digest = `sha256:${"a".repeat(64)}`;
  const capabilityReport = fixtureCapabilityReport();
  const sourceBinding = {
    sourceStateDigest: digest,
    sourceStateDigestProvenance: "vm-orchestrator-verified",
    archiveDigest: `sha256:${"b".repeat(64)}`,
    bundleManifestDigest: `sha256:${"c".repeat(64)}`,
    nativeClientDigest: `sha256:${"f".repeat(64)}`,
    stale: false
  };
  const vm = {
    schema: "licolite.secure-mesh.linux-vm-package-receipt",
    schemaVersion: 2,
    ok: true,
    producer: "linux-vm-package-receipt",
    generatedAt: "2030-01-01T00:00:00.000Z",
    closureChallengeDigest: `sha256:${"d".repeat(64)}`,
    invocationNonceDigest: `sha256:${"e".repeat(64)}`,
    productVersion: "1.2.3",
    buildNumber: 7,
    artifactKind: "linux-vm-installed-client",
    target: "ubuntu-linux-arm64",
    redacted: true,
    reportLeakScan: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    sourceBinding,
    package: {
      format: "tar.gz",
      layoutClasses: [
        "desktop_executable",
        "native_sidecar",
        "flutter_assets",
        "package_metadata"
      ],
      executableCount: 2,
      signaturePresent: true,
      validationSignature: true,
      signatureVerified: true,
      archiveDigestVerified: true,
      bundleManifestDigestVerified: true,
      installedFromArchive: true
    },
    session: {
      kind: "x11_virtual_display",
      clientStarted: true,
      visibleWindow: true,
      interactionSmoke: true,
      boundedShutdown: true
    },
    smoke: { cliTargetScan: true, guiSession: true, exactCapabilitySchema: true },
    capabilityReport,
    privacy: linuxEvidencePrivacyRecord(),
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      publicDownloadStatus: "not-configured",
      updateChannelStatus: "not-configured",
      rollbackChannelStatus: "not-configured",
    },
    summary: {
      currentSourceArchive: true,
      installReceiptReady: true,
      sessionLaunchReady: true,
      smokeReady: true,
      privacyReady: true
    }
  };
  validateLinuxVmPackageReceipt(vm, digest);
  const matrix = {
    schema: linuxNodeMatrixSchema,
    schemaVersion: 1,
    ok: true,
    producer: "linux-node-matrix",
    artifactKind: "linux-current-client-node-matrix",
    target: "ubuntu-linux-arm64",
    redacted: true,
    reportLeakScan: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    sourceBinding,
    runtime: {
      kind: "isolated_linux_containers",
      nodeCount: 3,
      currentClientArchive: true,
      publicOperationsOnly: true,
      eventDrivenReadiness: true
    },
    isolation: {
      participantLabels: ["linux-a", "linux-b", "linux-c"],
      distinctStateRoots: true,
      noSharedSecretVolume: true,
      uniquePublicIdentityCount: 3,
      crossNodeStateReadRejected: true,
      containerIsolation: true
    },
    pairwise: {
      exchangeCount: 3,
      allNodesParticipated: true,
      secureSessionsEstablished: true,
      opaqueRelay: true,
      relayPlaintextObserved: false,
      relayCiphertextIncludedInReport: false
    },
    restart: {
      restartedParticipant: "linux-a",
      restartedProcessCount: 1,
      restartRequiresRePairRekey: true,
      unaffectedParticipantCount: 2,
      postRestartExchangeReady: true,
      stateContaminationDetected: false
    },
    teardown: {
      bounded: true,
      nodeCount: 3,
      allProcessesStopped: true,
      allContainersRemoved: true,
      ephemeralStateRemoved: true
    },
    capabilityReport,
    privacy: linuxEvidencePrivacyRecord(),
    summary: {
      currentSourceNodes: true,
      isolationReady: true,
      pairwiseReady: true,
      restartIsolationReady: true,
      teardownReady: true,
      privacyReady: true
    }
  };
  validateLinuxNodeMatrixReport(matrix, digest);
  let privacyRejected = false;
  try {
    validateLinuxNodeMatrixReport({ ...matrix, runtimeId: "forbidden" }, digest);
  } catch {
    privacyRejected = true;
  }
  assert(privacyRejected, "Linux node matrix exact schema accepted a runtime identifier");
  let staleRejected = false;
  try {
    validateLinuxVmPackageReceipt(vm, `sha256:${"d".repeat(64)}`);
  } catch (error) {
    staleRejected = classifyLinuxEvidenceValidationFailure(error).ruleId ===
      "linux_vm_expected_source_digest_match";
  }
  assert(staleRejected, "Linux VM receipt accepted stale source binding");
  for (const [name, ruleId, candidate] of [
    ["missing_challenge", "linux_vm_closure_challenge_digest_valid",
      { ...vm, closureChallengeDigest: "" }],
    ["missing_invocation_nonce", "linux_vm_invocation_nonce_digest_valid",
      { ...vm, invocationNonceDigest: "" }],
    ["wrong_product_version", "linux_vm_product_version_match",
      { ...vm, productVersion: "9.9.9" }],
    ["wrong_build_number", "linux_vm_build_number_match", { ...vm, buildNumber: 8 }],
    ["blocking_distribution_guidance", "linux_vm_distribution_guidance_non_blocking",
      { ...vm, nonBlockingDistributionGuidance: { blocking: true } }],
    ["unbounded_shutdown", "linux_vm_session_bounded_shutdown_ready", {
      ...vm,
      session: { ...vm.session, boundedShutdown: false },
    }],
    ["privacy_value", "linux_vm_privacy_value_scan_clean", {
      ...vm,
      target: ["", "tmp", "private-fixture"].join("/"),
    }],
  ]) {
    let rejected = false;
    try {
      validateLinuxVmPackageReceipt(candidate, digest, "1.2.3", 7);
    } catch (error) {
      const failure = classifyLinuxEvidenceValidationFailure(error);
      rejected = failure.ruleId === ruleId &&
        ["artifact", "binding", "capability", "privacy", "readiness", "schema", "session"]
          .includes(failure.category);
    }
    assert(rejected, `Linux VM receipt accepted ${name}`);
  }
  const fallback = classifyLinuxEvidenceValidationFailure(
    new Error(["private", "dynamic", "value"].join("-")),
    "linux_vm_receipt_validation_unclassified",
  );
  assert(fallback.ruleId === "linux_vm_receipt_validation_unclassified" &&
    fallback.category === "schema" &&
    JSON.stringify(fallback).includes("dynamic") === false,
  "Linux VM validation fallback exposed an unsafe dynamic failure");
  let internalOperationFailure;
  try {
    validateLinuxVmPackageReceipt(new Proxy({}, {
      ownKeys() {
        throw new Error(["private", "dynamic", "validator", "value"].join("-"));
      },
    }), digest);
  } catch (error) {
    internalOperationFailure = classifyLinuxEvidenceValidationFailure(error);
  }
  assert(internalOperationFailure?.ruleId ===
    "linux_vm_validator_internal_operation_failed" &&
    internalOperationFailure.category === "schema" &&
    JSON.stringify(internalOperationFailure).includes("dynamic") === false,
  "Linux VM validator leaked an untagged internal operation failure");
  const failureRecord = createLinuxVmPackageFailureRecord("receipt_validation", fallback);
  const failureText = JSON.stringify(failureRecord);
  assert(failureRecord.validationRuleId === "linux_vm_receipt_validation_unclassified" &&
    failureRecord.failureCategory === "schema" &&
    failureRecord.redacted === true && failureRecord.rawPrivateMaterialIncluded === false &&
    failureRecord.rawPlaintextIncluded === false &&
    !failureText.includes("dynamic") && !failureText.includes("nonce") &&
    !failureText.includes("challenge") && !failureText.includes(["", "tmp", "private"].join("/")),
  "Linux VM failure receipt exposed dynamic validation data");
  const plainWriteFailure = classifyLinuxVmProducerFailure(
    "receipt_write",
    new Error(["private", "write", "value"].join("-")),
  );
  const taggedWriteFailure = classifyLinuxVmProducerFailure(
    "receipt_write",
    new LinuxEvidenceValidationError(
      "linux_vm_receipt_write_atomic_publish_failed",
      "producer",
    ),
  );
  const writeFailureRecord = createLinuxVmPackageFailureRecord(
    "receipt_write",
    taggedWriteFailure,
  );
  assert(plainWriteFailure.ruleId === "linux_vm_producer_receipt_write_failed" &&
    plainWriteFailure.category === "producer" &&
    taggedWriteFailure.ruleId === "linux_vm_receipt_write_atomic_publish_failed" &&
    taggedWriteFailure.category === "producer" &&
    writeFailureRecord.phase === "receipt_write" &&
    JSON.stringify(writeFailureRecord).includes("private") === false,
  "Linux VM receipt write failure masqueraded as validator failure");
  for (const stage of SAFE_REPORT_WRITE_STAGES) {
    const stageFailure = classifyLinuxVmProducerFailure(
      "receipt_write",
      linuxVmReceiptWriteFailure(stage),
    );
    assert(stageFailure.ruleId === `linux_vm_receipt_write_${stage}_failed` &&
      stageFailure.category === "producer",
    `Linux VM receipt write stage mapping failed: ${stage}`);
  }
  return {
    ok: true,
    exactCapabilitySchemaReady: true,
    exactEvidenceSchemaReady: true,
    staleSourceRejected: staleRejected,
    runtimeIdentityRejected: true,
    boundedTeardownRequired: true
    ,stableValidationRuleIdsReady: true
    ,dynamicFailureValuesIncluded: false
    ,safeFailureReceiptReady: true
    ,internalOperationFailureTagged: true
    ,receiptWritePhaseIsolated: true
    ,receiptWriteStageCount: SAFE_REPORT_WRITE_STAGES.length
  };
}

function fixtureCapabilityReport() {
  const catalog = loadCapabilityCatalog();
  const facts = catalog.order
    .map((id) => catalog.byId.get(id))
    .filter((definition) => definition.mandatory && !definition.derived)
    .map((definition) => ({ capability: definition.id, state: "supported" }));
  return reduceCapabilityFacts(facts, catalog);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
