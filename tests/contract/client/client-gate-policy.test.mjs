import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
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
  clientGateTaskEvent,
  validateClientGateTopology,
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
    selectedOptionalLanes([
      "packages/presentation_runtime/lib/src/presentation_runtime.dart",
    ]),
    ["flutter"],
  );
  assert.deepEqual(
    selectedOptionalLanes([
      "packages/presentation_contract/test/prepared_contract_test.dart",
    ]),
    ["flutter"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["packages/presentation_flutter/pubspec.yaml"]),
    ["flutter", "dependencies"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["packages/presentation_flutter/pubspec.lock"]),
    ["flutter", "dependencies"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["tools/apple-release/macos-direct-arm64.json"]),
    [],
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
});

test("presentation packages select a package-aware verification step", () => {
  assert.equal(CLIENT_GATE_LANES.flutter.includes("client:packages:verify"), true);
  const planned = spawnSync(
    process.execPath,
    [
      "tools/scripts/client-packages-verify.mjs",
      "--plan",
      "--changed",
      "packages/presentation_runtime/lib/src/presentation_runtime.dart",
    ],
    { cwd: process.cwd(), encoding: "utf8" },
  );
  assert.equal(planned.status, 0, planned.stderr);
  const plan = JSON.parse(planned.stdout);
  const runtime = plan.packages.find(
    (entry) => entry.directory === "packages/presentation_runtime",
  );
  assert.equal(runtime.applicable, true);
  assert.deepEqual(runtime.commands[0], ["dart", "pub", "get"]);
  assert.equal(runtime.commands.some((command) => command.join(" ") === "dart test"), true);
  for (const directory of [
    "packages/presentation_contract",
    "packages/presentation_flutter",
  ]) {
    const entry = plan.packages.find((candidate) => candidate.directory === directory);
    assert.equal(entry.applicable, false);
    assert.equal(entry.result, "not-applicable");
  }

  const flutterPlanned = spawnSync(
    process.execPath,
    [
      "tools/scripts/client-packages-verify.mjs",
      "--plan",
      "--changed",
      "packages/presentation_flutter/lib/src/collection_view.dart",
    ],
    { cwd: process.cwd(), encoding: "utf8" },
  );
  assert.equal(flutterPlanned.status, 0, flutterPlanned.stderr);
  const flutterPlan = JSON.parse(flutterPlanned.stdout);
  const widgets = flutterPlan.packages.find(
    (entry) => entry.directory === "packages/presentation_flutter",
  );
  assert.deepEqual(widgets.commands[0], ["flutter", "pub", "get"]);
  assert.equal(widgets.commands.some((command) => command.join(" ") === "flutter test"), true);
});

test("a changed package path without a real package fails instead of passing", () => {
  const planned = spawnSync(
    process.execPath,
    [
      "tools/scripts/client-packages-verify.mjs",
      "--plan",
      "--changed",
      "packages/presentation_ghost/lib/ghost.dart",
    ],
    { cwd: process.cwd(), encoding: "utf8" },
  );
  assert.equal(planned.status, 1);
  const plan = JSON.parse(planned.stdout);
  assert.equal(plan.ok, false);
  const ghost = plan.packages.find(
    (entry) => entry.directory === "packages/presentation_ghost",
  );
  assert.equal(ghost.result, "missing");
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
      "changed_count",
      "change_digest",
    ]);
    assert.equal(entries.some((entry) => entry.includes("/")), false);
    assert.match(entries.at(-1), /^change_digest=[a-f0-9]{64}$/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
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
