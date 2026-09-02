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
import { validateClientGateTopology } from "../../../tools/scripts/client-gate.mjs";

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
