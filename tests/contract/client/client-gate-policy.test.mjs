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
  createTargetEvidenceReceipt,
  runLane,
  runClientGateStep,
  selectDirectModules,
  selectLocalHostModules,
  selectTargetModules,
  targetResultsCoverSelection,
  validateClientGateTopology,
  verifyClientGate,
  withExecutionPrerequisites,
} from "../../../tools/scripts/client-gate.mjs";
import { runLocalClientDelivery } from "../../../tools/scripts/client-macos-deliver.mjs";
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

test("local host selection keeps generic modules and only the host's own target owners", () => {
  for (const host of ["darwin", "linux", "win32"]) {
    const selected = selectLocalHostModules({ host, catalog: CLIENT_MODULE_CATALOG });
    const ids = new Set(selected.map((module) => module.id));
    for (const module of CLIENT_MODULE_CATALOG) {
      const runnable = module.regression.runnableHosts.includes(host);
      const targets = module.regression.targetEvidenceHosts;
      const expected = runnable && (targets.length === 0 || targets.includes(host));
      assert.equal(ids.has(module.id), expected, `${host}:${module.id}`);
    }
  }
});

test("local host selection excludes every foreign target owner", () => {
  const foreign = CLIENT_MODULE_CATALOG.filter((module) =>
    module.regression.targetEvidenceHosts.length > 0 &&
    !module.regression.targetEvidenceHosts.includes("linux"));
  assert.equal(foreign.length > 0, true);
  const linuxIds = new Set(selectLocalHostModules({
    host: "linux",
    catalog: CLIENT_MODULE_CATALOG,
  }).map((module) => module.id));
  for (const module of foreign) assert.equal(linuxIds.has(module.id), false, module.id);
  const hostTargets = CLIENT_MODULE_CATALOG.filter((module) =>
    module.regression.targetEvidenceHosts.includes("linux"));
  assert.equal(hostTargets.length > 0, true);
  for (const module of hostTargets) assert.equal(linuxIds.has(module.id), true, module.id);
});

test("direct selection without a module id keeps only generic host-runnable modules", () => {
  for (const host of ["darwin", "linux", "win32"]) {
    const selected = selectDirectModules({ host, catalog: CLIENT_MODULE_CATALOG });
    for (const module of selected) {
      assert.equal(module.regression.targetEvidenceHosts.length, 0, module.id);
      assert.equal(module.regression.runnableHosts.includes(host), true, module.id);
    }
    for (const module of CLIENT_MODULE_CATALOG) {
      if (module.regression.targetEvidenceHosts.length !== 0) {
        assert.equal(selected.includes(module), false, `${host}:${module.id}`);
      }
    }
  }
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

test("focused target execution uses only requested target owners and validates the host", () => {
  assert.deepEqual(selectTargetModules({
    moduleIds: ["rust.platform.file-security.windows-acl"],
    paths: ["unrelated/source.rs"],
    host: "win32",
    catalog: CLIENT_MODULE_CATALOG,
  }).map((module) => module.id), ["rust.platform.file-security.windows-acl"]);
  assert.throws(() => selectTargetModules({
    moduleIds: ["rust.platform.file-security.unix-hardening"],
    host: "win32",
    catalog: CLIENT_MODULE_CATALOG,
  }), /does not require evidence from this host/u);
  assert.throws(() => selectTargetModules({
    moduleIds: ["regression.documentation-governance"],
    host: "win32",
    catalog: CLIENT_MODULE_CATALOG,
  }), /does not require evidence from this host/u);
});

test("focused direct execution preserves an explicitly requested unsupported-host owner", async () => {
  const selectedId = "regression.documentation-governance";
  const unsupportedHost = process.platform === "win32" ? "linux" : "win32";
  const catalog = CLIENT_MODULE_CATALOG.map((module) => module.id === selectedId
    ? Object.freeze({
      ...module,
      regression: Object.freeze({
        ...module.regression,
        runnableHosts: Object.freeze([unsupportedHost]),
      }),
    })
    : module);
  assert.deepEqual(selectDirectModules({
    moduleIds: [selectedId],
    host: process.platform,
    catalog,
  }).map((module) => module.id), [selectedId]);
  let executed = [];
  const code = await verifyClientGate([
    "--base", "HEAD", "--target", "commit", "--execution", "direct",
    "--host", process.platform, "--module", selectedId,
  ], {
    catalog,
    output: { write() {} },
    reportPath: null,
    executor: async (modules) => {
      executed = modules.map((module) => module.id);
      return {
        exitCode: 1,
        report: {
          complete: true,
          status: "blocked",
          results: [{ status: "blocked", reason: "unsupported_host", members: [selectedId] }],
          compatibility: [],
        },
      };
    },
  });
  assert.deepEqual(executed, [selectedId]);
  assert.equal(code, 1);
});

test("target evidence rejects a revision that is not the clean checked-out head", async () => {
  const tree = spawnSync("git", ["rev-parse", "HEAD^{tree}"], {
    cwd: process.cwd(),
    encoding: "utf8",
    shell: false,
  }).stdout.trim();
  const differentHead = spawnSync("git", ["commit-tree", tree, "-p", "HEAD"], {
    cwd: process.cwd(),
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "Synthetic Client Gate",
      GIT_AUTHOR_EMAIL: "client-gate@example.invalid",
      GIT_AUTHOR_DATE: "2000-01-01T00:00:00Z",
      GIT_COMMITTER_NAME: "Synthetic Client Gate",
      GIT_COMMITTER_EMAIL: "client-gate@example.invalid",
      GIT_COMMITTER_DATE: "2000-01-01T00:00:00Z",
    },
    input: "synthetic different candidate\n",
    shell: false,
  }).stdout.trim();
  assert.match(differentHead, /^[a-f0-9]{40}$/u);
  await assert.rejects(
    verifyClientGate([
      "--base", differentHead,
      "--head", differentHead,
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
