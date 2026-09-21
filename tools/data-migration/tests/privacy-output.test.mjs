import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { initJournal } from "../lib/journal.mjs";
import { plan } from "../lib/plan.mjs";
import { writeJsonAtomicSync } from "../lib/fs-atomic.mjs";

/**
 * The public output boundary, checked with synthetic canaries.
 *
 * Every canary below is written by this test into a temporary root: the root's
 * own directory name, a value inside stored documents, and a credential-shaped
 * string. Nothing real is read or written. The commands under test are the ones
 * whose output an operator or an agent reports: `inspect`, `plan`, `convert`
 * (preview, refusal and exception) and `resume`, in both JSON and human form.
 *
 * The other half of the contract is that redaction must not cost the tool its
 * identity: the reports still name domains, versions, step ids and symbolic
 * codes, and the conversion still runs against the real root and leaves the
 * real artifacts behind.
 */

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const cli = path.join(repoRoot, "tools/data-migration/bin/cli.mjs");
const CANARY_DIR = "licoup-privacy-CANARYPATH";
const CANARY_VALUE = "CANARYDOCVALUE";
const CANARY_CREDENTIAL = ["sk", "live", "CANARYCREDENTIAL1234567890"].join("-");

function temporaryRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), `${CANARY_DIR}-`));
}

function runCli(args, { cwd = repoRoot } = {}) {
  const proc = spawnSync(process.execPath, [cli, ...args], {
    encoding: "utf8",
    cwd,
    timeout: 60_000,
  });
  return {
    status: proc.status,
    stdout: proc.stdout || "",
    stderr: proc.stderr || "",
    combined: `${proc.stdout || ""}${proc.stderr || ""}`,
  };
}

function assertNoPrivateMaterial(output, root, { cwd = repoRoot } = {}) {
  for (const needle of [
    root,
    CANARY_DIR,
    CANARY_VALUE,
    CANARY_CREDENTIAL,
    "sk-live",
    os.tmpdir(),
    cwd,
  ]) {
    assert.ok(
      !output.includes(needle),
      `public output leaked ${JSON.stringify(needle)}:\n${output}`,
    );
  }
  assert.doesNotMatch(output, /\n\s+at\s/u, "no stack frame may be published");
  assert.doesNotMatch(output, /\/var\/folders\//u, "no machine temp path may be published");
  assert.doesNotMatch(output, /\/Users\//u, "no home path may be published");
  assert.doesNotMatch(output, /Error:\s*$/mu, "an error without a message is not a report");
}

/** A strategy store in the version-2 published shape, for the refusal path. */
function writeVersionTwoStore(root) {
  const databasePath = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
  fs.mkdirSync(path.dirname(databasePath), { recursive: true });
  const database = new DatabaseSync(databasePath);
  database.exec(`
    CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    INSERT INTO strategy_meta(key,value) VALUES ('version','2');
    CREATE TABLE strategy_bindings(
      revision_digest TEXT NOT NULL, slot_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
      value_id TEXT NOT NULL, model TEXT NOT NULL DEFAULT '',
      reasoning_effort TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL,
      PRIMARY KEY(revision_digest, slot_id, ordinal)
    );
  `);
  database.close();
}

test("a corrupt document never echoes its bytes, paths or credential-shaped text", () => {
  const root = temporaryRoot();
  try {
    // The parser would normally quote the offending bytes back at the caller.
    fs.writeFileSync(
      path.join(root, ".licoup-workspace.json"),
      `{"secret": ${CANARY_VALUE} ${CANARY_CREDENTIAL},`,
      "utf8",
    );
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), [CANARY_VALUE]);

    const commands = [
      ["inspect", "--data-root", root, "--format", "json"],
      ["inspect", "--data-root", root],
      ["plan", "--data-root", root, "--target", "0.0.1-alpha", "--format", "json"],
      ["plan", "--data-root", root, "--target", "0.0.1-alpha"],
      ["convert", "--data-root", root, "--target", "0.0.1-alpha", "--dry-run", "--format", "json"],
      ["convert", "--data-root", root, "--target", "0.0.1-alpha", "--dry-run"],
      ["convert", "--data-root", root, "--target", "0.0.1-alpha", "--writers-stopped"],
      ["resume", "--data-root", root, "--format", "json"],
      ["resume", "--data-root", root],
    ];
    for (const command of commands) {
      const result = runCli(command);
      assertNoPrivateMaterial(result.combined, root);
    }

    // Stable identity survives: the report names the root symbolically, the
    // domain, and the shape problem as a symbolic code.
    const inspectJson = runCli(["inspect", "--data-root", root, "--format", "json"]);
    assert.equal(inspectJson.status, 0);
    assert.match(inspectJson.stdout, /"dataRoot": "<data-root>"/u);
    assert.match(inspectJson.stdout, /"error": "invalid JSON document"|invalid JSON document/u);
    assert.match(inspectJson.stdout, /workspace-manifest/u);

    const inspectText = runCli(["inspect", "--data-root", root]);
    assert.match(inspectText.stdout, /Data Root: <data-root>/u);
    assert.match(inspectText.stdout, /workspace-manifest/u);

    const planJson = runCli(["plan", "--data-root", root, "--target", "0.0.1-alpha", "--format", "json"]);
    assert.equal(planJson.status, 1);
    assert.match(planJson.combined, /"code": "unsupported_state_shape"/u);
    assert.match(planJson.combined, /workspace-manifest/u);
    assert.doesNotMatch(planJson.combined, /"stack"/u);

    // A refused conversion must not have started: no journal, no ledger.
    assert.equal(
      fs.existsSync(path.join(root, "client-state/migrations/data-migration-journal.json")),
      false,
    );
    assert.equal(fs.existsSync(path.join(root, "client-state/migrations/ledger.json")), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a refusal reports a symbolic code and writes nothing, with canaries present", () => {
  const root = temporaryRoot();
  try {
    writeVersionTwoStore(root);
    writeJsonAtomicWriteTrap(root);

    for (const command of [
      ["plan", "--data-root", root, "--target", "v0.1.0", "--format", "json"],
      ["plan", "--data-root", root, "--target", "v0.1.0"],
      ["convert", "--data-root", root, "--target", "v0.1.0", "--writers-stopped", "--format", "json"],
      ["convert", "--data-root", root, "--target", "v0.1.0", "--writers-stopped"],
    ]) {
      const result = runCli(command);
      assertNoPrivateMaterial(result.combined, root);
      assert.equal(result.status, 1);
      assert.match(result.combined, /migration_unsupported_downgrade/u);
      assert.match(result.combined, /adaptive-flywheel/u);
    }
    assert.equal(
      fs.existsSync(path.join(root, "client-state/migrations/data-migration-journal.json")),
      false,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a successful conversion keeps its report clean and its real artifacts intact", () => {
  const root = temporaryRoot();
  try {
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), [
      CANARY_VALUE,
      "agent-one",
    ]);

    const convertResult = runCli([
      "convert",
      "--data-root",
      root,
      "--target",
      "v0.3.0",
      "--writers-stopped",
      "--format",
      "json",
    ]);
    assert.equal(convertResult.status, 0);
    assertNoPrivateMaterial(convertResult.combined, root);
    const converted = JSON.parse(convertResult.stdout);
    assert.equal(converted.status, "success");
    assert.ok(converted.pendingNativeAdmissionDomains.includes("canonical-conversation"));

    // Redaction is at the boundary only: the conversion ran against the real
    // root, so the stored document is what it was, now in the current shape.
    assert.deepEqual(
      JSON.parse(fs.readFileSync(path.join(root, "client-state/agent-tab-order.json"), "utf8")),
      { schemaVersion: 1, order: [CANARY_VALUE, "agent-one"] },
    );
    assert.ok(fs.existsSync(path.join(root, "client-state/migrations/ledger.json")));
    const ledgerText = fs.readFileSync(
      path.join(root, "client-state/migrations/ledger.json"),
      "utf8",
    );
    assert.ok(!ledgerText.includes(CANARY_VALUE), "the tool's own ledger must not store document values");

    const inspectText = runCli(["inspect", "--data-root", root]);
    assertNoPrivateMaterial(inspectText.combined, root);
    assert.match(inspectText.stdout, /agent-tab-order\s+: store=v1/u);
    assert.match(inspectText.stdout, /Data Root: <data-root>/u);

    const convertText = runCli([
      "convert",
      "--data-root",
      root,
      "--target",
      "v0.3.0",
      "--writers-stopped",
    ]);
    assertNoPrivateMaterial(convertText.combined, root);
    assert.match(convertText.stdout, /Status: SUCCESS/u);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("resume reports progress without values and needs its confirmation first", () => {
  const root = temporaryRoot();
  try {
    writeJsonAtomicSync(path.join(root, "client-state/agent-tool-allowlist.json"), {
      schemaVersion: 1,
      tools: [CANARY_VALUE],
    });
    initJournal(root, plan(root, "v0.3.0"), {
      maintenanceConfirmedAt: new Date().toISOString(),
    });

    // The pending journal reaches the report; it must carry steps and codes,
    // not values or paths.
    const inspectWithJournal = runCli(["inspect", "--data-root", root, "--format", "json"]);
    assert.equal(inspectWithJournal.status, 0);
    assertNoPrivateMaterial(inspectWithJournal.combined, root);
    assert.match(inspectWithJournal.stdout, /"hasPendingJournal": true/u);
    assert.match(inspectWithJournal.stdout, /agent-tool-allowlist/u);

    const unconfirmed = runCli(["resume", "--data-root", root, "--format", "json"]);
    assert.equal(unconfirmed.status, 1);
    assertNoPrivateMaterial(unconfirmed.combined, root);
    assert.match(unconfirmed.combined, /maintenance_confirmation_required/u);

    const confirmed = runCli([
      "resume",
      "--data-root",
      root,
      "--writers-stopped",
      "--format",
      "json",
    ]);
    assert.equal(confirmed.status, 0);
    assertNoPrivateMaterial(confirmed.combined, root);
    const resumed = JSON.parse(confirmed.stdout);
    assert.equal(resumed.status, "success");
    assert.ok(resumed.resumedSteps.some((step) => step.domainId === "agent-tool-allowlist"));

    const confirmedText = runCli(["resume", "--data-root", root, "--writers-stopped"]);
    assertNoPrivateMaterial(confirmedText.combined, root);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

/** A valid document holding the canary, so only the output could leak it. */
function writeJsonAtomicWriteTrap(root) {
  writeJsonAtomicSync(path.join(root, "client-state/agent-tool-allowlist.json"), {
    schemaVersion: 1,
    tools: [CANARY_VALUE, CANARY_CREDENTIAL],
  });
}
