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

    // 1. Upgrade state with independent tool. The canonical Conversation store
    // is the client owner's: the tool plans the step, reports it as pending
    // native admission, and leaves the legacy projection for the owner's import
    // instead of fabricating a database.
    const result = convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.equal(result.status, "success");
    assert.ok(result.pendingAuthorizationDomains.includes("gateway-credential-custody"));
    assert.ok(
      result.pendingNativeAdmissionDomains.includes("canonical-conversation"),
      "the Conversation store's transition belongs to the native owner",
    );
    assert.ok(
      fs.existsSync(path.join(stateDir, "agent-conversation-projections.json")),
      "the legacy source must survive for the owner's import",
    );
    assert.equal(
      fs.existsSync(path.join(stateDir, "conversations", "conversations.sqlite3")),
      false,
      "the tool must not fabricate the owner's store",
    );

    // 2. Invoke native Rust CLI: licoup-cli state admit <data-root>
    const proc = spawnSync(nativeCli, ["state", "admit", root], {
      encoding: "utf8",
      timeout: 30_000,
    });

    assert.equal(proc.status, 0, `licoup-cli failed: ${proc.stderr}`);
    const admission = JSON.parse(proc.stdout.trim());
    assert.equal(admission.status, "ready");
    assert.equal(admission.frontierId, "licoup-state-0.2.2");
    assert.ok(
      admission.appliedDomainIds.includes("canonical-conversation"),
      "the native admission must perform the deferred import",
    );
    assert.ok(
      fs.existsSync(path.join(stateDir, "conversations", "conversations.sqlite3")),
      "the owner's store now exists",
    );
    assert.ok(
      fs.existsSync(path.join(stateDir, "conversations", "migration-v5.complete")),
      "the owner's completion marker now exists",
    );

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
