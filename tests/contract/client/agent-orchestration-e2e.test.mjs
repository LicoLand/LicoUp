import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const scriptPath = path.join(
  repoRoot,
  "tools/scripts/client-agent-orchestration-e2e.mjs",
);
const readinessPath = path.join(
  repoRoot,
  "crates/licoup-native/resources/agent-conversation-readiness.json",
);

test("agent orchestration e2e self-test emits redacted blocked receipt when sendEnabled is zero", () => {
  assert.equal(existsSync(scriptPath), true);
  const result = spawnSync("node", [scriptPath, "--self-test"], {
    cwd: repoRoot,
    encoding: "utf8",
    env: process.env,
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const lines = `${result.stdout}`
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  const receipt = JSON.parse(lines.at(-1));
  assert.equal(receipt.schemaVersion, 1);
  assert.equal(receipt.receiptKind, "agent-orchestration-e2e");
  assert.equal(receipt.synthetic.cutoverHarness, true);
  assert.equal(receipt.synthetic.packagedPluginSurface, true);
  assert.deepEqual(receipt.surfaces, ["desktop", "cli", "codex-mcp"]);
  const catalog = JSON.parse(readFileSync(readinessPath, "utf8"));
  const sendEnabledTargets = (catalog.adapters || []).filter(
    (adapter) => adapter?.sendEnabled === true,
  ).length;
  if ((catalog.summary?.sendEnabled ?? sendEnabledTargets) === 0) {
    assert.equal(receipt.status, "blocked");
    assert.equal(receipt.reasonCode, "target_unready_send_enabled_zero");
    assert.equal(receipt.readiness.sendEnabledTargets, 0);
    assert.equal(receipt.readiness.catalogSendEnabledTotal, 0);
    assert.equal(receipt.live.blocked, true);
  }
  const encoded = JSON.stringify(receipt).toLowerCase();
  for (const canary of [
    "sensitive_prompt_canary",
    "sensitive_reasoning_canary",
    "credential-canary",
    "private-path-canary",
    "raw-output-canary",
    "native-session-canary",
  ]) {
    assert.equal(encoded.includes(canary), false, canary);
  }
});
