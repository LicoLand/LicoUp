import assert from "node:assert/strict";
import test from "node:test";
import {
  AGENT_REGRESSION_ENTRIES,
  validateClientRegressionEntries,
} from "../../../tools/regression/client-regression-entries/index.mjs";
import { runClientCompatibilityFrontier } from "../../../tools/regression/client-regression-compatibility.mjs";

const expectedAgents = [
  "openclaw",
  "claude-code",
  "codex",
  "antigravity",
  "opencode",
  "copilot",
  "kilo-code",
  "cursor",
  "hermes",
  "kimi-code",
  "pi",
  "deepseek-harness",
  "lico-agent",
];

test("every Agent adapter owns one independently schedulable compatibility entry", async () => {
  assert.equal(validateClientRegressionEntries(), true);
  assert.deepEqual(AGENT_REGRESSION_ENTRIES.map((entry) => entry.id), expectedAgents);
  for (const entry of AGENT_REGRESSION_ENTRIES) {
    assert.deepEqual(entry.resources, [`agent-runtime:${entry.id}`]);
    const probe = await entry.probe();
    assert.equal(typeof probe.eligible, "boolean");
    assert.equal(probe.reason === null || /^[a-z0-9_-]+$/u.test(probe.reason), true);
    if (entry.liveCommand) {
      assert.equal(entry.liveCommand.program, "node");
      assert.equal(entry.liveCommand.args.includes(entry.id), true);
    }
  }
});

test("eligible Agent adaptation targets execute as one parallel frontier", async () => {
  let active = 0;
  let peak = 0;
  const entries = ["alpha", "beta"].map((id) => ({
    id,
    kind: "agent",
    stage: "compatibility",
    lane: `agent:${id}`,
    resources: [`agent-runtime:${id}`],
    liveCommand: { program: "node", args: ["--version", id], cwd: ".", timeoutMs: 1000 },
    async probe() { return { eligible: true, reason: null }; },
  }));
  const execution = await runClientCompatibilityFrontier({
    repoRoot: ".",
    entries,
    capacities: {
      global: 2,
      pools: { compatibility: 2 },
      resources: {},
    },
    async commandRunner(batch) {
      active += 1;
      peak = Math.max(peak, active);
      await new Promise((resolve) => setImmediate(resolve));
      active -= 1;
      return {
        id: batch.id,
        stage: batch.stage,
        lane: batch.lane,
        toolchain: batch.toolchain,
        status: "passed",
        reason: null,
        durationMs: 1,
        members: batch.members,
        metrics: {},
      };
    },
  });
  assert.equal(peak, 2);
  assert.deepEqual(execution.rows.map((row) => row.status), ["passed", "passed"]);
});

test("one Agent static failure blocks only its own live branch", async () => {
  const entries = ["alpha", "beta"].map((id) => ({
    id,
    kind: "agent",
    stage: "compatibility",
    lane: `agent:${id}`,
    resources: [`agent-runtime:${id}`],
    liveCommand: { program: "node", args: ["--version", id], cwd: ".", timeoutMs: 1000 },
    async probe() { return { eligible: true, reason: null }; },
  }));
  const started = [];
  const execution = await runClientCompatibilityFrontier({
    repoRoot: ".",
    entries,
    capacities: { global: 2, pools: { compatibility: 2 }, resources: {} },
    async commandRunner(batch) {
      started.push(batch.id);
      const failed = batch.id === "agent-static-alpha";
      return {
        id: batch.id,
        stage: batch.stage,
        lane: batch.lane,
        toolchain: batch.toolchain,
        status: failed ? "failed" : "passed",
        reason: failed ? "agent_contract_failed" : null,
        durationMs: 1,
        members: batch.members,
        metrics: {},
      };
    },
  });
  assert.deepEqual(execution.rows.map((row) => [row.id, row.status, row.reason]), [
    ["alpha", "failed", "agent_contract_failed"],
    ["beta", "passed", null],
  ]);
  assert.equal(started.includes("agent-alpha"), false);
  assert.equal(started.includes("agent-beta"), true);
});

test("DeepSeek Harness remains represented without manufacturing live readiness", async () => {
  const deepseek = AGENT_REGRESSION_ENTRIES.find((entry) =>
    entry.id === "deepseek-harness");
  assert.deepEqual(await deepseek.probe(), {
    eligible: false,
    reason: "deepseek_harness_jsonrpc_carrier_unverified",
  });
  assert.equal(deepseek.liveCommand, null);
});
