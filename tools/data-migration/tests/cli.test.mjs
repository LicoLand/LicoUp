import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const cliPath = path.resolve(fileURLToPath(new URL("../bin/cli.mjs", import.meta.url)));

function runCli(args) {
  const result = spawnSync("node", [cliPath, ...args], {
    encoding: "utf8",
    timeout: 30_000,
  });
  return result;
}

function createTempRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "licoup-cli-test-"));
}

test("cli --version prints version string", () => {
  const res = runCli(["--version"]);
  assert.equal(res.status, 0);
  assert.match(res.stdout, /licoup-data-migration v/);
});

test("cli inspect --format json returns valid JSON report", () => {
  const root = createTempRoot();
  try {
    const res = runCli(["inspect", "--data-root", root, "--format", "json"]);
    assert.equal(res.status, 0);
    const parsed = JSON.parse(res.stdout);
    assert.equal(parsed.ledger.present, false);
    assert.ok(parsed.domains["agent-tab-order"]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("cli plan and convert execute migration via command line", () => {
  const root = createTempRoot();
  try {
    const planRes = runCli(["plan", "--data-root", root, "--target", "v0.3.0", "--format", "json"]);
    assert.equal(planRes.status, 0);
    const planParsed = JSON.parse(planRes.stdout);
    assert.equal(planParsed.targetVersion, "0.3.0");
    assert.equal(planParsed.direction, "upgrade");

    // A real conversion is gated on the operator's statement that every writer
    // stopped: the tool's own lock cannot constrain a program that never heard
    // of it, and the plan forbids claiming offline safety from a lock file.
    const refused = runCli(["convert", "--data-root", root, "--target", "v0.3.0"]);
    assert.equal(refused.status, 1);
    assert.match(refused.stderr, /maintenance_confirmation_required/);
    assert.equal(
      fs.existsSync(path.join(root, "client-state", "migrations", "data-migration-journal.json")),
      false,
      "a refused conversion must not have started writing",
    );

    // --dry-run is the preview path and needs no confirmation.
    const preview = runCli(["convert", "--data-root", root, "--target", "v0.3.0", "--dry-run", "--format", "json"]);
    assert.equal(preview.status, 0);
    assert.equal(JSON.parse(preview.stdout).status, "dry_run");

    const convertRes = runCli([
      "convert", "--data-root", root, "--target", "v0.3.0", "--writers-stopped", "--format", "json",
    ]);
    assert.equal(convertRes.status, 0);
    const convertParsed = JSON.parse(convertRes.stdout);
    assert.equal(convertParsed.status, "success");
    assert.ok(convertParsed.pendingAuthorizationDomains.includes("gateway-credential-custody"));
    assert.ok(
      convertParsed.pendingNativeAdmissionDomains.includes("canonical-conversation"),
      "the Conversation store's owner still owes its step",
    );

    const inspectRes = runCli(["inspect", "--data-root", root]);
    assert.equal(inspectRes.status, 0);
    assert.match(inspectRes.stdout, /Admitted product version: 0.3.0/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
