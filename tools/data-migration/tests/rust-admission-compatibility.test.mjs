import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { convert } from "../lib/convert.mjs";
import { writeJsonAtomicSync } from "../lib/fs-atomic.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const nativeCli = path.join(
  repoRoot,
  "build",
  "crates",
  "licoup-native",
  "target",
  "debug",
  "licoup-cli"
);

function createTempRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "licoup-rust-compat-"));
}

test("Rust native client admits state upgraded by independent migration tool", (t) => {
  if (!fs.existsSync(nativeCli)) {
    t.skip(`Native binary not compiled at ${nativeCli}`);
    return;
  }

  const root = createTempRoot();
  try {
    const stateDir = path.join(root, "client-state");
    fs.mkdirSync(stateDir, { recursive: true });

    // Seed legacy state
    writeJsonAtomicSync(path.join(stateDir, "agent-conversation-projections.json"), {
      schemaVersion: 1,
      sessionsByAgent: {
        "test-agent": [
          {
            id: "sess-compat-1",
            title: "Compat Test",
            messages: [{ role: "user", content: "hello rust admission" }],
          },
        ],
      },
    });
    writeJsonAtomicSync(path.join(stateDir, "agent-tab-order.json"), ["test-agent"]);

    // 1. Upgrade state with independent tool
    const result = convert(root, "0.0.1-alpha");
    assert.equal(result.status, "success");
    assert.ok(result.pendingAuthorizationDomains.includes("gateway-credential-custody"));

    // 2. Invoke native Rust CLI: licoup-cli state admit <data-root>
    const proc = spawnSync(nativeCli, ["state", "admit", root], {
      encoding: "utf8",
      timeout: 30_000,
    });

    assert.equal(proc.status, 0, `licoup-cli failed: ${proc.stderr}`);
    const admission = JSON.parse(proc.stdout.trim());
    assert.equal(admission.status, "ready");
    assert.equal(admission.frontierId, "licoup-state-0.2.2");

    // 3. Second run should skip already admitted domains
    const proc2 = spawnSync(nativeCli, ["state", "admit", root], {
      encoding: "utf8",
      timeout: 30_000,
    });
    assert.equal(proc2.status, 0);
    const admission2 = JSON.parse(proc2.stdout.trim());
    assert.equal(admission2.status, "ready");
    assert.deepEqual(admission2.appliedDomainIds, []);
    assert.ok(admission2.skippedDomainIds.length > 0);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
