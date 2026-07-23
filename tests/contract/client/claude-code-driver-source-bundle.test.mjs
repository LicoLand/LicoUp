import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const driverRoot = "crates/lico-client-native/src/platform/claude_code_driver";

const productionLeaves = Object.freeze([
  "command.rs",
  "control.rs",
  "errors.rs",
  "events.rs",
  "execution.rs",
  "io.rs",
  "model.rs",
  "params.rs",
  "probe.rs",
  "protocol.rs",
  "supervision.rs",
  "transport.rs",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all(productionLeaves.map(async (leaf) => [
    leaf,
    await read(`${driverRoot}/${leaf}`),
  ])));
}

test("Claude Code driver facade is thin and owns every production leaf", async () => {
  const facade = await read(`${driverRoot}.rs`);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 30);
  assert.deepEqual(
    [...facade.matchAll(/^mod ([a-z_]+);$/gmu)]
      .map((match) => match[1])
      .filter((moduleName) => moduleName !== "tests")
      .map((moduleName) => `${moduleName}.rs`)
      .sort(),
    [...productionLeaves].sort(),
  );
  for (const implementationToken of ["include!(", "#[path"]) {
    assert.equal(facade.includes(implementationToken), false);
  }
});

test("Claude Code keeps the fixed streaming-input lane without argv resume or shell fallback", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.ok(source["model.rs"].includes(
    'RUNTIME_PROTOCOL: &str = "claude-code-cli-stream-json"',
  ));
  for (const token of [
    '"--input-format"',
    '"stream-json"',
    '"--output-format"',
    '"--include-partial-messages"',
    '"--no-session-persistence"',
  ]) {
    assert.ok(source["command.rs"].includes(token), `missing fixed command token: ${token}`);
  }
  assert.ok(source["params.rs"].includes("stdin_message"));
  for (const forbidden of [
    '"--resume"',
    '"--continue"',
    'Command::new("sh")',
    'Command::new("bash")',
    'Command::new("cmd")',
    'Command::new("powershell")',
  ]) {
    assert.equal(joined.includes(forbidden), false);
  }
});

test("Claude Code public lifecycle contract is bounded and exact-session scoped", async () => {
  const manifest = JSON.parse(await read(
    "packages/contracts/client/fixtures/agent-conversation-adapter/manifests/claude-code.json",
  ));
  assert.equal(manifest.transport.sessionScope, "process");
  assert.equal(manifest.transport.continuityChannel, "protected-mapping");
  assert.ok(Number.isSafeInteger(manifest.lifecycle.maxConcurrentTransports));
  assert.ok(manifest.lifecycle.maxConcurrentTransports > 0);
  assert.ok(manifest.lifecycle.maxConcurrentTransports <= 64);
  assert.ok(Number.isSafeInteger(manifest.lifecycle.maxTrackedSessions));
  assert.ok(manifest.lifecycle.maxTrackedSessions >= manifest.lifecycle.maxConcurrentTransports);
  assert.ok(manifest.lifecycle.maxTrackedSessions <= 4096);
  assert.equal(manifest.lifecycle.cleanupScope, "process-session");
  assert.equal(manifest.operations.exactResume.status, "supported");
  assert.equal(manifest.operations.cleanup.status, "supported");
  assert.equal(manifest.operations.history.status, "supported");
  assert.equal(manifest.privacy.safeCleanup, true);
  assert.equal(manifest.privacy.continuityIdInArguments, false);
});

test("Claude Code IO, events, controls, probe, and failures stay bounded and redacted", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  for (const token of [
    "MAX_PROTOCOL_LINE_BYTES",
    "LineLimitExceeded",
    "BoundedStdinWriter",
    "max_stdout",
    "max_stderr",
    "CONTROL_QUEUE_CAPACITY",
    "IO_THREAD_EXIT_GRACE",
    "claude_code_timeout",
    "PROCESS_POLL_INTERVAL",
  ]) {
    assert.ok(joined.includes(token), `missing bounded lifecycle token: ${token}`);
  }
  assert.ok(source["events.rs"].includes("project_event"));
  assert.ok(source["errors.rs"].includes("message: &'static str"));
  for (const rawProjection of [
    "stderr: String",
    "stderr: Vec",
    "String::from_utf8_lossy(&stderr",
    '"tool_input": message',
    '"message": message',
    '"session_id": message',
  ]) {
    assert.equal(joined.includes(rawProjection), false);
  }
});

test("Claude Code split contains no production unsafe or hidden compatibility include", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.equal(joined.includes("unsafe {"), false);
  assert.equal(joined.includes("include!("), false);
  assert.equal(joined.includes("#[path"), false);
});

test("Claude Code process-local lifecycle and transcript have one bounded supervisor authority", async () => {
  const source = await sources();
  for (const token of [
    "TransportLifecycle",
    "Live",
    "Closing",
    "Closed",
    "BoundedTranscript",
    "VecDeque",
  ]) {
    assert.ok(
      source["model.rs"].includes(token),
      `missing process-local model token: ${token}`,
    );
  }
  for (const symbol of ["cleanup_session", "shutdown_all"]) {
    assert.ok(
      source["supervision.rs"].includes(symbol),
      `missing frozen lifecycle symbol: ${symbol}`,
    );
  }
  assert.ok(source["protocol.rs"].includes("claude_code_authentication_required"));
});

test("Claude Code product controls and parity use one persistent stdio RPC owner", async () => {
  const [
    request,
    server,
    processIo,
    rpcClient,
    processLocalRound,
    results,
    evidence,
  ] = await Promise.all([
    read("crates/lico-client-native/src/bin/lico-client/stdio_rpc/request.rs"),
    read("crates/lico-client-native/src/bin/lico-client/stdio_rpc/server.rs"),
    read("apps/desktop/lib/src/platform/native_client/agent_service_process_io.dart"),
    read("tools/scripts/client-acp-conversation-parity/clients/stdio-rpc-client.mjs"),
    read("tools/scripts/client-acp-conversation-parity/process-local-round.mjs"),
    read("tools/scripts/client-acp-conversation-parity/results.mjs"),
    read("tools/scripts/client-acp-conversation-parity/evidence.mjs"),
  ]);
  for (const operation of ["open", "send", "history", "cleanup", "capabilities", "cancel"]) {
    assert.ok(request.includes(`agent.conversation.${operation}`));
  }
  assert.ok(server.includes("shutdown_all"));
  assert.ok(processIo.includes("executeStructured"));
  assert.ok(rpcClient.includes('["rpc", "stdio"]'));
  assert.ok(processLocalRound.includes('continuityScope: "process-local"'));
  assert.equal(processLocalRound.includes("nativeTurn("), false);
  assert.equal(processLocalRound.includes("AcpClient"), false);
  assert.equal(processLocalRound.includes("runSidecar("), false);
  assert.equal(processLocalRound.includes("runBoundedProcess("), false);
  assert.equal(processLocalRound.includes(["cleanup", "DurationMs"].join("")), false);
  assert.ok(processLocalRound.includes("strictHistoryProjection"));
  assert.ok(processLocalRound.includes("eventTranscriptMatches"));
  assert.ok(rpcClient.includes("stdio_rpc_frame_after_terminal"));
  assert.ok(rpcClient.includes("stdio_rpc_turn_id_reused"));
  assert.ok(rpcClient.includes("stdio_rpc_chunk_output_mismatch"));
  assert.ok(results.includes("processLocalFactsEvidenceComplete"));
  assert.ok(results.includes("processLocalFactsPassed"));
  assert.ok(evidence.includes("process_local_facts_unproven"));
});

test("Claude Code capabilities do not advertise queue-blocked concurrent cancel", async () => {
  const [manifestText, inventoryText] = await Promise.all([
    read("packages/contracts/client/fixtures/agent-conversation-adapter/manifests/claude-code.json"),
    read("crates/lico-client-native/resources/agent-conversation-drivers.json"),
  ]);
  const manifest = JSON.parse(manifestText);
  const inventory = JSON.parse(inventoryText);
  const driver = inventory.drivers.find((row) => row.agentId === "claude-code");
  assert.equal(manifest.transport.sessionScope, "process");
  assert.equal(manifest.operations.history.status, "supported");
  assert.equal(manifest.operations.cancel.status, "unsupported");
  assert.equal(manifest.acceptance.continuityScope, "process-local");
  assert.equal(manifest.acceptance.nativeToArcRequired, false);
  assert.equal(manifest.acceptance.arcToNativeRequired, false);
  assert.equal(driver.capabilityMatrix.processLocalContinuation, true);
  assert.equal(driver.capabilityMatrix.cancel, false);
});

test("Claude Code routing remains model-data driven and process argv stays ephemeral", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n").toLowerCase();
  for (const forbidden of [
    "deepseek",
    "kimi k3",
    "gpt-5.6",
    '"--resume"',
    '"--continue"',
  ]) {
    assert.equal(joined.includes(forbidden), false);
  }
  assert.ok(source["command.rs"].includes('"--model"'));
  assert.ok(source["command.rs"].includes('"--no-session-persistence"'));
});
