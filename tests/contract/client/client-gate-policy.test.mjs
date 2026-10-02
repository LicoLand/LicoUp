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
  combineLocalRegressionResults,
  createTargetEvidenceReceipt,
  runLocalClientDelivery,
  runLane,
  runClientGateStep,
  targetReceiptResults,
  targetResultsCoverSelection,
  reusableLinuxResults,
  validateClientGateTopology,
  verifyClientGate,
  withExecutionPrerequisites,
} from "../../../tools/scripts/client-gate.mjs";
import { CLIENT_MODULE_CATALOG } from "../../../tools/regression/client-module-catalog.mjs";

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
      "target_darwin",
      "target_linux",
      "target_win32",
    ]);
    assert.equal(entries.some((entry) => entry.includes("/")), false);
    assert.match(entries.find((entry) => entry.startsWith("change_digest=")),
      /^change_digest=[a-f0-9]{64}$/u);
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
    assert.equal(changedPaths({ base: "HEAD", head: "HEAD", target: "delivery" }).includes(relative), true);
    assert.equal(changedPaths({ base: "HEAD", head: "HEAD", target: "pr" }).includes(relative), false);
  } finally {
    unlinkSync(absolute);
  }
});

test("complete verification rejects blocked, unverified, failed, or incomplete evidence", async () => {
  const statuses = ["blocked", "unverified", "failed"];
  for (const status of statuses) {
    const code = await verifyClientGate([
      "--base", "HEAD", "--target", "commit", "--execution", "direct", "--host", process.platform,
    ], {
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
    const code = await verifyClientGate([
      "--base", "HEAD", "--target", "commit", "--execution", "direct", "--host", process.platform,
    ], {
      output: { write() {} },
      reportPath: null,
      executor: async () => ({ exitCode: 0, report }),
    });
    assert.equal(code, 1);
  }
});

test("complete verification passes only complete settled engineering evidence", async () => {
  let output = "";
  const code = await verifyClientGate([
    "--base", "HEAD", "--target", "commit", "--execution", "direct", "--host", process.platform,
  ], {
    output: { write(value) { output += value; } },
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
  const receipt = JSON.parse(output.trim());
  assert.equal(receipt.scope, "host-engineering-profile");
  assert.equal(receipt.mergeReady, false);
});

test("local delivery builds, installs, and launches only after each prior stage passes", () => {
  const releaseCatalog = { targets: [{
    id: "macos-direct-arm64",
    platform: "macos",
    buildHost: "darwin-arm64",
    packageBuildSupported: true,
    releaseSupported: true,
  }] };
  const releaseTargets = { "macos-direct-arm64": { localOnly: true } };
  const calls = [];
  let output = "";
  const code = runLocalClientDelivery({
    host: "darwin",
    architecture: "arm64",
    releaseCatalog,
    releaseTargets,
    output: { write(value) { output += value; } },
    spawnImpl(command, args) {
      calls.push([command, ...args]);
      return { status: 0, error: null };
    },
  });
  assert.equal(code, 0);
  assert.deepEqual(calls, [
    ["npm", "run", "client:build", "--", "--platform", "macos"],
    ["npm", "run", "client:install:macos", "--", "--launch-installed"],
  ]);
  assert.deepEqual(JSON.parse(output), {
    ok: true,
    schemaVersion: "licomesh.client-gate-policy.v1",
    target: "delivery",
    deliveryTargetId: "macos-direct-arm64",
    platform: "macos",
    built: true,
    installed: true,
    launchRequested: true,
    uiInspected: false,
    published: false,
  });

  calls.length = 0;
  const failed = runLocalClientDelivery({
    host: "darwin",
    architecture: "arm64",
    releaseCatalog,
    releaseTargets,
    output: { write() {} },
    spawnImpl(command, args) {
      calls.push([command, ...args]);
      return { status: 7, error: null };
    },
  });
  assert.equal(failed, 1);
  assert.equal(calls.length, 1);
});

test("local aggregation replaces only the exact delegated hygiene result", () => {
  const linux = [
    { id: "hygiene", status: "passed", members: ["regression.repository-local-info-hygiene"] },
    { id: "batch", status: "failed", members: ["module.a", "module.b"] },
  ];
  const host = [
    { id: "host-hygiene", status: "passed", members: ["regression.repository-local-info-hygiene"] },
    { id: "host-target", status: "passed", members: ["module.a"] },
  ];
  assert.deepEqual(combineLocalRegressionResults(linux, host, "darwin"), [
    { ...linux[1], id: "host.linux.batch" },
    { ...host[0], id: "host.darwin.host-hygiene" },
    { ...host[1], id: "host.darwin.host-target" },
  ]);
});

test("reuse keeps only passed unchanged Linux members and preserves their evidence head", () => {
  const previousHead = "a".repeat(40);
  const currentHead = "b".repeat(40);
  const changedModule = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "release.model-pricing");
  const unchangedModule = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "regression.documentation-governance");
  assert.ok(changedModule);
  assert.ok(unchangedModule);
  const results = reusableLinuxResults({
    schemaVersion: "licoup.client-regression-report.v1",
    complete: true,
    candidateHead: previousHead,
    sourceStateDigest: `sha256:${"c".repeat(64)}`,
    results: [{
      id: "host.linux.batch",
      status: "passed",
      members: [changedModule.id, unchangedModule.id],
      evidenceHead: previousHead,
    }, {
      id: "host.linux.failed",
      status: "failed",
      members: ["regression.contracts-client"],
      evidenceHead: previousHead,
    }, {
      id: "host.win32.target",
      status: "passed",
      members: [unchangedModule.id],
      evidenceHead: previousHead,
    }, {
      id: "host.linux.stale",
      status: "passed",
      members: ["regression.contracts-client"],
      evidenceHead: "d".repeat(40),
    }],
  }, {
    currentHead,
    changedPaths: [changedModule.inputs[0]],
    catalog: CLIENT_MODULE_CATALOG,
  });
  assert.deepEqual(results.map((result) => result.members), [[unchangedModule.id]]);
  assert.equal(results[0].evidenceHead, previousHead);
  assert.deepEqual(reusableLinuxResults({ complete: true, results: [] }, {
    currentHead,
    changedPaths: [],
    catalog: CLIENT_MODULE_CATALOG,
  }), []);
});

test("target evidence requires one passed result for every selected module", () => {
  const selected = [{ id: "module.a" }, { id: "module.b" }];
  assert.equal(targetResultsCoverSelection(selected, [
    { status: "passed", members: ["module.a", "module.b"] },
  ]), true);
  assert.equal(targetResultsCoverSelection(selected, []), false);
  assert.equal(targetResultsCoverSelection(selected, [
    { status: "passed", members: ["module.a"] },
  ]), false);
  assert.equal(targetResultsCoverSelection(selected, [
    { status: "passed", members: ["module.a", "module.b"] },
    { status: "failed", members: ["module.c"] },
  ]), false);
});

test("target evidence receipt preserves the existing per-batch report", () => {
  const selected = [{ id: "module.a" }, { id: "module.b" }];
  const report = {
    complete: false,
    status: "failed",
    results: [{
      id: "batch.one",
      status: "failed",
      reason: "command_failed",
      members: ["module.a", "module.b"],
    }],
    compatibility: [],
  };
  const receipt = createTargetEvidenceReceipt({
    revisions: { target: "pr", execution: "target", host: "win32", head: "a".repeat(40) },
    selected,
    result: { exitCode: 1, report },
  });
  assert.equal(receipt.ok, false);
  assert.equal(receipt.report, report);
  assert.deepEqual(receipt.report.results[0], report.results[0]);
});

test("local target aggregation uses real batch results and blocks missing receipts", () => {
  const head = "a".repeat(40);
  const modules = [
    { id: "module.a", regression: { stage: "foundation", lane: "foundation", toolchain: "rust" } },
    { id: "module.b", regression: { stage: "foundation", lane: "foundation", toolchain: "rust" } },
  ];
  const reportResult = {
    id: "rust-target-1",
    stage: "foundation",
    lane: "foundation",
    toolchain: "rust",
    status: "failed",
    reason: "command_failed",
    members: ["module.a"],
  };
  const partial = targetReceiptResults({
    ok: false,
    schemaVersion: "licomesh.client-gate-policy.v1",
    execution: "target",
    host: "win32",
    head,
    stepIds: ["module.a", "module.b"],
    report: { results: [reportResult] },
  }, modules, "win32", { head, processStatus: 1 });
  assert.deepEqual(partial[0], { ...reportResult, id: "host.win32.rust-target-1" });
  assert.equal(partial[1].members[0], "module.b");
  assert.equal(partial[1].reason, "target_result_missing");

  assert.deepEqual(targetReceiptResults(null, modules.slice(0, 1), "win32", {
    head,
    processStatus: null,
  }).map((result) => ({
    status: result.status,
    reason: result.reason,
    members: result.members,
  })), [{ status: "blocked", reason: "target_host_unavailable", members: ["module.a"] }]);
  assert.equal(targetReceiptResults({
    schemaVersion: "licomesh.client-gate-policy.v1",
    execution: "target",
    host: "win32",
    head,
    stepIds: ["module.a"],
    status: "failed",
  }, modules.slice(0, 1), "win32", { head, processStatus: 1 })[0].reason, "target_result_missing");

  const stale = targetReceiptResults({
    ok: true,
    schemaVersion: "licomesh.client-gate-policy.v1",
    execution: "target",
    host: "win32",
    head: "b".repeat(40),
    stepIds: ["module.a"],
    report: { results: [{ ...reportResult, status: "passed" }] },
  }, modules.slice(0, 1), "win32", { head, processStatus: 0 });
  assert.equal(stale[0].reason, "target_receipt_binding_invalid");

  const exitConflict = targetReceiptResults({
    ok: true,
    schemaVersion: "licomesh.client-gate-policy.v1",
    execution: "target",
    host: "win32",
    head,
    stepIds: ["module.a"],
    report: { results: [{ ...reportResult, status: "passed" }] },
  }, modules.slice(0, 1), "win32", { head, processStatus: 1 });
  assert.equal(exitConflict.at(-1).reason, "target_runner_failed");
});

test("focused Flutter target execution prepends the registered dependency prerequisite", () => {
  const prerequisite = { id: "regression.flutter-dependencies", regression: { toolchain: "flutter" } };
  const flutterTarget = { id: "bridge.macos", regression: { toolchain: "flutter" } };
  const rustTarget = { id: "rust.target", regression: { toolchain: "rust" } };
  assert.deepEqual(
    withExecutionPrerequisites([flutterTarget], [prerequisite, flutterTarget]),
    [prerequisite, flutterTarget],
  );
  assert.deepEqual(
    withExecutionPrerequisites([prerequisite, flutterTarget], [prerequisite, flutterTarget]),
    [prerequisite, flutterTarget],
  );
  assert.deepEqual(
    withExecutionPrerequisites([rustTarget], [prerequisite, rustTarget]),
    [rustTarget],
  );
});

test("target evidence rejects a revision that is not the clean checked-out head", async () => {
  const parent = spawnSync("git", ["rev-parse", "HEAD^"], {
    cwd: process.cwd(),
    encoding: "utf8",
    shell: false,
  }).stdout.trim();
  await assert.rejects(
    verifyClientGate([
      "--base", parent,
      "--head", parent,
      "--target", "pr",
      "--execution", "target",
      "--host", process.platform,
    ], { output: { write() {} }, reportPath: null }),
    /candidate does not match the clean checked-out head/u,
  );
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
