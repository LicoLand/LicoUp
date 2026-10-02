import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import {
  CLIENT_GATE_LANES,
  CLIENT_RELEASE_TARGETS,
  classifyClientGatePaths,
} from "../../../tools/scripts/client-gate-policy.mjs";
import {
  changedPaths,
  clientGateTaskEvent,
  runLane,
  runClientGateStep,
  validateClientGateTopology,
  verifyClientGate,
} from "../../../tools/scripts/client-gate.mjs";

function selectedOptionalLanes(paths) {
  const plan = classifyClientGatePaths(paths);
  return Object.entries(plan.lanes)
    .filter(([lane, selected]) => lane !== "source" && selected)
    .map(([lane]) => lane);
}

test("source policy is mandatory without selecting platform toolchains", () => {
  assert.deepEqual(classifyClientGatePaths([]).lanes, {
    source: true,
    flutter: false,
    rust: false,
    android: false,
    dependencies: false,
    "release-policy": false,
  });
  assert.deepEqual(selectedOptionalLanes(["docs/RUNBOOK.md"]), []);
  for (const forbidden of [
    "client:get",
    "client:native:fmt:check",
    "client:test:android:native",
    "client:deps:audit",
    "client:verify:release-artifact-io:self-test",
  ]) {
    assert.equal(CLIENT_GATE_LANES.source.includes(forbidden), false);
  }
});

test("changed paths select only their independent technology lanes", () => {
  assert.deepEqual(
    selectedOptionalLanes(["apps/desktop/lib/client_controller.dart"]),
    ["flutter"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["apps/desktop/shaders/glass_lens.frag"]),
    ["flutter"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["crates/licoup-native/src/lib.rs"]),
    ["rust"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["apps/desktop/android/app/build.gradle.kts"]),
    ["android"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["Cargo.lock"]),
    ["rust", "dependencies"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["tools/apple-release/macos-direct-arm64.json"]),
    ["release-policy"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["tools/scripts/client-device-demo.mjs"]),
    [],
  );
  assert.deepEqual(
    selectedOptionalLanes(["package.json"]),
    ["dependencies"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["tools/scripts/client-gate-policy.mjs"]),
    [],
  );
  assert.deepEqual(
    selectedOptionalLanes([".github/workflows/client-release-ready.yml"]),
    ["release-policy"],
  );
});

test("gate policy rejects paths that escape the repository", () => {
  assert.throws(
    () => classifyClientGatePaths(["../outside"]),
    /stay inside the repository/u,
  );
  assert.throws(
    () => classifyClientGatePaths(["/absolute"]),
    /stay inside the repository/u,
  );
});

test("CI and release workflows implement the declared topology", () => {
  const result = validateClientGateTopology();
  assert.equal(result.ok, true);
  assert.equal(result.laneCount, Object.keys(CLIENT_GATE_LANES).length);
  assert.equal(result.releaseTargetCount, Object.keys(CLIENT_RELEASE_TARGETS).length);
});

test("ordinary regression lanes never run real-device demonstrations", () => {
  for (const scripts of Object.values(CLIENT_GATE_LANES)) {
    assert.equal(
      scripts.some((script) =>
        script.startsWith("client:demo:device:") &&
        script !== "client:demo:device:self-test"),
      false,
    );
  }
  assert.equal(
    CLIENT_GATE_LANES["release-policy"].filter((script) =>
      script === "client:demo:device:self-test").length,
    1,
  );
});

test("change planner emits only bounded booleans, counts, and a digest", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "lico-gate-plan-"));
  try {
    const output = path.join(root, "github-output");
    writeFileSync(output, "", { mode: 0o600 });
    const result = spawnSync(process.execPath, [
      "tools/scripts/client-gate.mjs",
      "plan",
      "--base",
      "HEAD",
      "--head",
      "HEAD",
    ], {
      cwd: process.cwd(),
      env: { ...process.env, GITHUB_OUTPUT: output },
      encoding: "utf8",
      shell: false,
    });
    assert.equal(result.status, 0);
    const entries = readFileSync(output, "utf8").trim().split("\n");
    assert.deepEqual(entries.map((entry) => entry.split("=")[0]), [
      "source",
      "flutter",
      "rust",
      "android",
      "dependencies",
      "release_policy",
      "changed_count",
      "change_digest",
    ]);
    assert.equal(entries.some((entry) => entry.includes("/")), false);
    assert.match(entries.at(-1), /^change_digest=[a-f0-9]{64}$/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("local planning includes working tree and untracked paths while PR planning stays immutable", () => {
  const relative = "tools/apple-release/.gate-local-selection.tmp";
  const absolute = path.join(process.cwd(), relative);
  writeFileSync(absolute, "synthetic\n", { mode: 0o600 });
  try {
    assert.equal(changedPaths({ base: "HEAD", head: "HEAD", target: "commit" }).includes(relative), true);
    assert.equal(changedPaths({ base: "HEAD", head: "HEAD", target: "pr" }).includes(relative), false);
  } finally {
    unlinkSync(absolute);
  }
});

test("complete verification rejects blocked, unverified, failed, or incomplete evidence", async () => {
  const statuses = ["blocked", "unverified", "failed"];
  for (const status of statuses) {
    const code = await verifyClientGate(["--base", "HEAD", "--target", "commit"], {
      output: { write() {} },
      reportPath: null,
      executor: async () => ({
        exitCode: 0,
        report: { complete: true, status: "passed", results: [{ status }], compatibility: [] },
      }),
    });
    assert.equal(code, 1, status);
  }
  for (const report of [
    { complete: false, status: "passed", results: [], compatibility: [] },
    { complete: true, status: "passed", results: [], compatibility: [{ status: "unverified" }] },
  ]) {
    const code = await verifyClientGate(["--base", "HEAD", "--target", "commit"], {
      output: { write() {} },
      reportPath: null,
      executor: async () => ({ exitCode: 0, report }),
    });
    assert.equal(code, 1);
  }
});

test("complete verification passes only complete settled engineering evidence", async () => {
  const code = await verifyClientGate(["--base", "HEAD", "--target", "commit"], {
    output: { write() {} },
    reportPath: null,
    executor: async () => ({
      exitCode: 0,
      report: {
        complete: true,
        status: "passed",
        results: [{ status: "passed" }],
        compatibility: [],
      },
    }),
  });
  assert.equal(code, 0);
});

test("lane execution settles every independent step and returns all failures", () => {
  const invoked = [];
  const events = [];
  let output = "";
  const code = runLane("source", {
    output: { write(value) { output += value; } },
    eventEmitter(event) { events.push(event); },
    spawnImpl(command, args) {
      invoked.push([command, ...args]);
      return { status: 7, error: null };
    },
  });
  assert.equal(code, 1);
  assert.equal(invoked.length, CLIENT_GATE_LANES.source.length);
  assert.equal(events.filter((event) => event.type === "step-failure").length,
    CLIENT_GATE_LANES.source.length);
  const receipt = JSON.parse(output.trim().split("\n").at(-1));
  assert.equal(receipt.ok, false);
  assert.equal(receipt.results.every((result) => result.status === "failed"), true);
});

test("single registered step stays focused and cannot claim merge readiness", async () => {
  let output = "";
  const code = await runClientGateStep("regression.public-client-docs", {
    output: { write(value) { output += value; } },
    executor: async () => ({
      exitCode: 0,
      report: { results: [{ status: "passed" }] },
    }),
  });
  assert.equal(code, 0);
  assert.deepEqual(JSON.parse(output.trim()), {
    ok: true,
    schemaVersion: "licomesh.client-gate-policy.v1",
    scope: "focused-step",
    stepId: "regression.public-client-docs",
    complete: false,
    mergeReady: false,
  });
});

test("client gate emits bounded typed failure events without raw diagnostics", () => {
  const line = clientGateTaskEvent({
    type: "step-failure",
    stage: "client:test",
    code: "command-exit-nonzero",
    exitCode: 1,
    retryable: false,
    recovery: "inspect-failed-step",
  });
  assert.equal(line.startsWith("::lico-dev-task-event::"), true);
  const event = JSON.parse(line.slice("::lico-dev-task-event::".length));
  assert.deepEqual(event, {
    schemaVersion: "v0.0.1:lico-dev:task-event-1",
    type: "step-failure",
    stage: "client:test",
    component: "client-gate",
    code: "command-exit-nonzero",
    exitCode: 1,
    retryable: false,
    recovery: "inspect-failed-step",
  });
  assert.throws(
    () => clientGateTaskEvent({ type: "step-start", stage: "private path" }),
    /task event is invalid/u,
  );
});
