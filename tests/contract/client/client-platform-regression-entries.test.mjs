import assert from "node:assert/strict";
import test from "node:test";
import {
  PLATFORM_REGRESSION_ENTRIES,
  validateClientRegressionEntries,
} from "../../../tools/regression/client-regression-entries/index.mjs";
import { runClientCompatibilityFrontier } from "../../../tools/regression/client-regression-compatibility.mjs";

test("every supported platform owns a dedicated parallel compatibility entry", async () => {
  assert.equal(validateClientRegressionEntries(), true);
  assert.deepEqual(PLATFORM_REGRESSION_ENTRIES.map((entry) => entry.id), [
    "macos", "android", "windows", "linux", "ios",
  ]);
  for (const entry of PLATFORM_REGRESSION_ENTRIES) {
    assert.equal(entry.stage, "compatibility");
    assert.equal(entry.resources.includes(`platform-runtime:${entry.id}`), true);
    const probe = await entry.probe();
    assert.equal(typeof probe.eligible, "boolean");
    assert.equal(probe.reason === null || /^[a-z0-9_-]+$/u.test(probe.reason), true);
  }
});

test("eligible platform branches probe and execute concurrently", async () => {
  let activeProbes = 0;
  let peakProbes = 0;
  let activeCommands = 0;
  let peakCommands = 0;
  const entries = ["alpha", "beta"].map((id) => ({
    id,
    kind: "platform",
    stage: "compatibility",
    lane: `platform:${id}`,
    resources: [`platform-runtime:${id}`],
    liveCommand: { program: "node", args: ["--version"], cwd: ".", timeoutMs: 1000 },
    async probe() {
      activeProbes += 1;
      peakProbes = Math.max(peakProbes, activeProbes);
      await new Promise((resolve) => setImmediate(resolve));
      activeProbes -= 1;
      return { eligible: true, reason: null };
    },
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
      activeCommands += 1;
      peakCommands = Math.max(peakCommands, activeCommands);
      await new Promise((resolve) => setImmediate(resolve));
      activeCommands -= 1;
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
  assert.equal(peakProbes, 2);
  assert.equal(peakCommands, 2);
  assert.deepEqual(execution.rows.map((row) => row.status), ["passed", "passed"]);
});

test("missing platform capability is explicit unverified evidence, not a core failure", async () => {
  const windows = PLATFORM_REGRESSION_ENTRIES.find((entry) => entry.id === "windows");
  const probe = await windows.probe();
  if (process.platform !== "win32") {
    assert.deepEqual(probe, {
      eligible: false,
      reason: "platform_host_unavailable",
    });
  } else {
    assert.equal(probe.eligible, false);
    assert.equal([
      "platform_toolchain_unavailable",
      "platform_live_verifier_unavailable",
    ].includes(probe.reason), true);
  }
});

test("a failed platform probe is isolated while eligible siblings still run", async () => {
  const entries = [
    {
      id: "broken",
      kind: "platform",
      stage: "compatibility",
      lane: "platform:broken",
      resources: ["platform-runtime:broken"],
      liveCommand: { program: "node", args: ["--version"], cwd: ".", timeoutMs: 1000 },
      async probe() { throw new Error("private probe details"); },
    },
    {
      id: "healthy",
      kind: "platform",
      stage: "compatibility",
      lane: "platform:healthy",
      resources: ["platform-runtime:healthy"],
      liveCommand: { program: "node", args: ["--version"], cwd: ".", timeoutMs: 1000 },
      async probe() { return { eligible: true, reason: null }; },
    },
  ];
  const execution = await runClientCompatibilityFrontier({
    repoRoot: ".",
    entries,
    capacities: { global: 2, pools: { compatibility: 2 }, resources: {} },
    async commandRunner(batch) {
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
  assert.deepEqual(execution.rows.map((row) => [row.id, row.status, row.reason]), [
    ["broken", "failed", "compatibility_probe_failed"],
    ["healthy", "passed", null],
  ]);
});
