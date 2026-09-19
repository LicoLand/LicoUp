import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  FRONTIER_REF,
  loadEmbeddedFrontier,
  planSteps,
} from "../../../tools/scripts/client-state-migration/frontier.mjs";
import { DURABLE_SHAPES } from "../../../tools/scripts/client-state-migration/probe.mjs";
import { evaluateMigrationState } from "../../../tools/scripts/client-state-migration/report.mjs";
import { repairDomain } from "../../../tools/scripts/client-state-migration/repair.mjs";
import { writePrivateJsonAtomic } from "../../../tools/scripts/client-state-migration/util.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const facadeRef = "tools/scripts/client-state-migration.mjs";
const moduleRoot = "tools/scripts/client-state-migration";
const MIGRATION_MODULE = "crates/licoup-native/src/domain/client_state_migration.rs";
const CLIENT_STATE_POLICY = "crates/licoup-native/src/platform/client_state/policy.rs";
const CLIENT_STATE_MIGRATION =
  "crates/licoup-native/src/platform/client_state/migration.rs";
const CONVERSATION_STORE = "crates/licoup-conversation/src/store/mod.rs";
const BACKSLASH = String.fromCharCode(92);

function tempRoot(label) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `licoup-migration-${label}-`));
}

function removeRoot(root) {
  fs.rmSync(root, { recursive: true, force: true });
}

function runCli(args) {
  return spawnSync(process.execPath, [path.join(repoRoot, facadeRef), ...args], {
    cwd: repoRoot,
    encoding: "utf8",
  });
}

function runJson(args) {
  const result = runCli([...args, "--json"]);
  const envelope = JSON.parse(result.stdout);
  return { ...result, envelope };
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value)}\n`);
}

/**
 * Migration metadata is private state: the admission reads it through the
 * 0700/0600-enforcing path, so a fixture that is going to be certified healthy
 * has to carry those modes.
 */
function writePrivateJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  fs.writeFileSync(filePath, `${JSON.stringify(value)}\n`, { mode: 0o600 });
}

/** Every path and byte under `root`, so a read-only command can be proven inert. */
function snapshot(root) {
  const entries = [];
  const visit = (directory, prefix) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort()) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        entries.push(`${relative}/`);
        visit(absolute, relative);
      } else {
        entries.push(`${relative}:${fs.readFileSync(absolute).toString("base64")}`);
      }
    }
  };
  visit(root, "");
  return entries.join("\n");
}

function seedLedger(root, frontier, domains) {
  writePrivateJson(path.join(root, "client-state/migrations/ledger.json"), {
    schemaVersion: "v0.0.1:client-state-migration-ledger-1",
    highestAdmittedProductVersion: "0.3.0",
    frontierId: frontier.frontierId,
    domains,
  });
}

/** The state a completed admission leaves behind, for the healthy verdict. */
function seedAdmittedRoot(root, frontier) {
  const expectedSteps = (domain) =>
    domain.steps.filter((step) => step.toSchemaVersion <= domain.targetSchemaVersion)
      .map((step) => step.stepId);
  const domains = {};
  for (const domain of frontier.domains) {
    domains[domain.domainId] = {
      schemaVersion: domain.targetSchemaVersion,
      completedStepIds: expectedSteps(domain),
    };
  }
  seedLedger(root, frontier, domains);
  for (const domain of frontier.domains) {
    writePrivateJson(path.join(root, `client-state/migrations/domain-state/${domain.domainId}.json`), {
      schemaVersion: "v0.0.1:client-state-domain-marker-1",
      domainId: domain.domainId,
      authoritativeSchemaVersion: domain.targetSchemaVersion,
    });
  }
  writeJson(path.join(root, ".licoup-workspace.json"), { schemaVersion: 1 });
  writeJson(path.join(root, "client-state/appearance-preferences.json"), {
    schemaVersion: 1,
    appearancePresetId: "synthetic",
  });
  writeJson(path.join(root, "client-state/agent-tool-allowlists.json"), { schemaVersion: 1 });
  writeJson(path.join(root, "client-state/current-client-view.json"), { schemaVersion: 1 });
  writeJson(path.join(root, "client-state/skill-hub-preferences.json"), { schemaVersion: 1 });
  writeJson(path.join(root, "client-state/mobile-home-layout.json"), { schemaVersion: 2 });
  writeJson(path.join(root, "client-state/agent-tab-order.json"), {
    schemaVersion: 1,
    order: [],
  });
  writeJson(path.join(root, "client-state/mobile-relay/config.json"), { schemaVersion: 2 });
  writeJson(path.join(root, "client-state/settings.json"), {
    schemaVersion: "v0.0.1:schema:definition-1",
    collection: "settings",
    items: [],
  });
  const conversations = path.join(root, "client-state/conversations");
  fs.mkdirSync(conversations, { recursive: true });
  const database = new DatabaseSync(path.join(conversations, "conversations.sqlite3"));
  database.exec(
    "CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);" +
      "INSERT INTO schema_meta(key,value) VALUES ('version','15');",
  );
  database.close();
  fs.writeFileSync(
    path.join(conversations, "migration-v5.complete"),
    ["schema=v5", "status=complete", ""].join("\n"),
  );
  const flywheel = path.join(root, "client-state/adaptive-flywheel");
  fs.mkdirSync(flywheel, { recursive: true });
  const strategies = new DatabaseSync(path.join(flywheel, "strategies.sqlite3"));
  strategies.exec(
    "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);" +
      "INSERT INTO strategy_meta(key,value) VALUES ('version','3');",
  );
  strategies.close();
}

test("status reports every domain from the ledger and the durable stores, and changes nothing", () => {
  const root = tempRoot("status");
  try {
    const before = snapshot(root);
    const frontier = loadEmbeddedFrontier();
    const { envelope, status } = runJson(["status", "--root", root]);
    assert.equal(status, 2);
    assert.equal(envelope.command, "status");
    assert.equal(envelope.verdict, "behind");
    assert.equal(envelope.domains.length, frontier.domains.length);
    assert.deepEqual(
      envelope.domains.map((domain) => domain.domainId),
      frontier.domains.map((domain) => domain.domainId),
    );
    const appearance = envelope.domains.find(
      (domain) => domain.domainId === "appearance-presentation",
    );
    assert.equal(appearance.targetSchemaVersion, 1);
    assert.equal(appearance.observedSchemaVersion, 0);
    assert.equal(appearance.ledgerSchemaVersion, null);
    assert.deepEqual(appearance.completedStepIds, []);
    assert.deepEqual(appearance.missingStepIds, ["appearance-presentation.absent-to-1"]);
    assert.equal(snapshot(root), before, "status must not touch the data root");
  } finally {
    removeRoot(root);
  }

  const admitted = tempRoot("status-admitted");
  try {
    const frontier = loadEmbeddedFrontier();
    seedAdmittedRoot(admitted, frontier);
    const before = snapshot(admitted);
    const { envelope } = runJson(["status", "--root", admitted]);
    assert.equal(envelope.verdict, "healthy");
    assert.deepEqual(envelope.codes, []);
    assert.equal(
      envelope.domains.every(
        (domain) =>
          domain.observedSchemaVersion === domain.targetSchemaVersion &&
          domain.missingStepIds.length === 0,
      ),
      true,
    );
    assert.equal(snapshot(admitted), before, "status must not rewrite admitted state");
  } finally {
    removeRoot(admitted);
  }
});

test("doctor certifies an admitted root and fails closed on every deviation", () => {
  const frontier = loadEmbeddedFrontier();
  const healthy = tempRoot("doctor-healthy");
  try {
    seedAdmittedRoot(healthy, frontier);
    const { envelope, status } = runJson(["doctor", "--root", healthy]);
    assert.equal(status, 0);
    assert.equal(envelope.verdict, "healthy");
    assert.deepEqual(envelope.codes, []);
    assert.equal(envelope.ledger.readable, true);
  } finally {
    removeRoot(healthy);
  }

  const cases = [
    {
      label: "ledger is not the admission's contract",
      seed: (root) => writePrivateJson(path.join(root, "client-state/migrations/ledger.json"), {
        schemaVersion: "v0.0.1:client-state-migration-ledger-1",
        highestAdmittedProductVersion: "0.3.0",
        frontierId: frontier.frontierId,
        domains: { "appearance-presentation": { schemaVersion: 1, completedStepIds: [] } },
      }),
      code: "migration_ledger_invalid",
      exitCode: 4,
      verdict: "invalid",
    },
    {
      label: "ledger claims a domain the frontier does not define",
      seed: (root) => seedLedger(root, frontier, {
        "not-a-frontier-domain": { schemaVersion: 1, completedStepIds: [] },
      }),
      code: "migration_ledger_invalid",
      exitCode: 4,
      verdict: "invalid",
    },
    {
      label: "state was admitted by a newer binary",
      seed: (root) => seedLedger(root, frontier, {
        "appearance-presentation": {
          schemaVersion: 1,
          completedStepIds: ["appearance-presentation.absent-to-1"],
        },
      }) ||
        writePrivateJson(path.join(root, "client-state/migrations/ledger.json"), {
          schemaVersion: "v0.0.1:client-state-migration-ledger-1",
          highestAdmittedProductVersion: "99.0.0",
          frontierId: frontier.frontierId,
          domains: {},
        }),
      code: "state_newer_than_binary",
      exitCode: 3,
      verdict: "ahead",
    },
    {
      label: "a durable store is newer than the binary",
      seed: (root) => writeJson(path.join(root, "client-state/appearance-preferences.json"), {
        schemaVersion: 9,
      }),
      code: "state_newer_than_binary",
      exitCode: 3,
      verdict: "ahead",
    },
    {
      label: "a durable store is an unknown shape",
      seed: (root) => writeJson(path.join(root, "client-state/current-client-view.json"), {
        schemaVersion: 1.5,
      }),
      code: "unsupported_state_shape",
      exitCode: 4,
      verdict: "invalid",
    },
    {
      label: "migration metadata is not private state",
      seed: (root) => {
        writePrivateJson(path.join(root, "client-state/migrations/ledger.json"), {
          schemaVersion: "v0.0.1:client-state-migration-ledger-1",
          highestAdmittedProductVersion: "0.3.0",
          frontierId: frontier.frontierId,
          domains: {},
        });
        fs.chmodSync(path.join(root, "client-state/migrations/ledger.json"), 0o644);
      },
      code: "migration_ledger_invalid",
      exitCode: 4,
      verdict: "invalid",
    },
    {
      label: "an update handoff is waiting for the next startup",
      seed: (root) => writePrivateJson(
        path.join(root, "client-state/migrations/update-handoff.json"),
        {
          schemaVersion: "v0.0.1:client-update-handoff-1",
          state: "pending",
          version: "0.0.1-alpha",
          targetReleaseTrack: "nightly",
          migrationFrontier: { frontierId: "licoup-state-0.2.1", domains: [] },
          receiptId: `sha256:${"a".repeat(64)}`,
          targetPath: "/synthetic/target",
          backupPath: "/synthetic/backup",
        },
      ),
      code: "update_handoff_pending",
      exitCode: 4,
      verdict: "invalid",
    },
    {
      label: "a durable store is not a regular file",
      seed: (root) => {
        fs.mkdirSync(path.join(root, "client-state"), { recursive: true });
        fs.symlinkSync(
          path.join(root, "missing-target"),
          path.join(root, "client-state/appearance-preferences.json"),
        );
      },
      code: "unsupported_state_shape",
      exitCode: 4,
      verdict: "invalid",
    },
  ];
  for (const scenario of cases) {
    const root = tempRoot("doctor");
    try {
      scenario.seed(root);
      const { envelope, status } = runJson(["doctor", "--root", root]);
      assert.equal(status, scenario.exitCode, scenario.label);
      assert.equal(envelope.verdict, scenario.verdict, scenario.label);
      assert.equal(
        envelope.codes.some((entry) => entry.code === scenario.code),
        true,
        `${scenario.label}: ${JSON.stringify(envelope.codes)}`,
      );
    } finally {
      removeRoot(root);
    }
  }
});

test("a gap and an ambiguous plan each report their own stable code", () => {
  const root = tempRoot("plan");
  try {
    const frontier = loadEmbeddedFrontier();
    const base = frontier.domains[0];
    const gap = {
      ...frontier,
      domains: [{ ...base, targetSchemaVersion: 3, steps: [base.steps[0], {
        stepId: `${base.domainId}.jump-to-3`,
        fromSchemaVersion: 2,
        toSchemaVersion: 3,
      }] }],
    };
    assert.deepEqual(planSteps(gap.domains[0], 1), { steps: [], code: "migration_plan_gap" });

    // The store is behind its target and the frontier defines no step from
    // where it stands.
    const leadingGap = {
      ...frontier,
      domains: [{ ...base, targetSchemaVersion: 2, steps: [{
        stepId: `${base.domainId}.synthetic-to-2`,
        fromSchemaVersion: 1,
        toSchemaVersion: 2,
      }] }],
    };
    const leadingReport = evaluateMigrationState({
      root,
      frontier: leadingGap,
      binaryProductVersion: "0.3.0",
    });
    assert.equal(leadingReport.verdict, "invalid");
    assert.equal(leadingReport.codes[0].code, "migration_plan_gap");
    const gapReport = evaluateMigrationState({
      root,
      frontier: gap,
      binaryProductVersion: "0.3.0",
    });
    assert.equal(gapReport.verdict, "invalid");
    assert.equal(gapReport.codes[0].code, "migration_plan_gap");

    const ambiguous = {
      ...frontier,
      domains: [{ ...base, steps: [base.steps[0], {
        stepId: `${base.domainId}.competing-to-1`,
        fromSchemaVersion: 0,
        toSchemaVersion: 1,
      }] }],
    };
    assert.deepEqual(planSteps(ambiguous.domains[0], 0), {
      steps: [],
      code: "migration_plan_ambiguous",
    });
    const ambiguousReport = evaluateMigrationState({
      root,
      frontier: ambiguous,
      binaryProductVersion: "0.3.0",
    });
    assert.equal(ambiguousReport.verdict, "invalid");
    assert.equal(ambiguousReport.codes[0].code, "migration_plan_ambiguous");
  } finally {
    removeRoot(root);
  }
});

test("repair applies exactly one step, is idempotent, and keeps the ledger consistent", () => {
  const root = tempRoot("repair");
  try {
    const frontier = loadEmbeddedFrontier();
    const first = repairDomain({
      root,
      frontier,
      domainId: "appearance-presentation",
      binaryProductVersion: "0.3.0",
    });
    assert.deepEqual(first.mutations, [{
      domainId: "appearance-presentation",
      stepId: "appearance-presentation.absent-to-1",
      toSchemaVersion: 1,
      storeWritten: false,
      ledgerUpdated: true,
      applied: true,
    }]);
    const ledger = JSON.parse(
      fs.readFileSync(path.join(root, "client-state/migrations/ledger.json"), "utf8"),
    );
    assert.deepEqual(ledger.domains, {
      "appearance-presentation": {
        schemaVersion: 1,
        completedStepIds: ["appearance-presentation.absent-to-1"],
      },
    });
    assert.equal(ledger.highestAdmittedProductVersion, "0.0.0");
    assert.deepEqual(
      JSON.parse(
        fs.readFileSync(
          path.join(root, "client-state/migrations/domain-state/appearance-presentation.json"),
          "utf8",
        ),
      ),
      {
        schemaVersion: "v0.0.1:client-state-domain-marker-1",
        domainId: "appearance-presentation",
        authoritativeSchemaVersion: 1,
      },
    );

    const second = repairDomain({
      root,
      frontier,
      domainId: "appearance-presentation",
      binaryProductVersion: "0.3.0",
    });
    assert.deepEqual(second.mutations, [{
      domainId: "appearance-presentation",
      stepId: null,
      toSchemaVersion: 1,
      storeWritten: false,
      ledgerUpdated: false,
      applied: false,
    }]);
    assert.equal(second.report.verdict, "behind");
    // The admission's own reconciliation rules accept what the repair wrote.
    assert.deepEqual(
      second.report.codes.filter((entry) => entry.code === "migration_ledger_invalid"),
      [],
    );
    assert.equal(
      second.report.domains.find((domain) => domain.domainId === "appearance-presentation")
        .verdict,
      "healthy",
    );
  } finally {
    removeRoot(root);
  }
});

test("repair rewrites only the store the step owns, and never invents a missing definition", () => {
  const legacy = tempRoot("repair-legacy");
  try {
    const frontier = loadEmbeddedFrontier();
    writeJson(path.join(legacy, "client-state/appearance-preferences.json"), {
      appearancePresetId: "canary-preset",
      localePreference: "canary-locale",
    });
    writeJson(path.join(legacy, "client-state/agent-tab-order.json"), [{ agent: "canary" }]);
    const appearance = repairDomain({
      root: legacy,
      frontier,
      domainId: "appearance-presentation",
      binaryProductVersion: "0.3.0",
    });
    assert.equal(appearance.mutations[0].storeWritten, true);
    assert.deepEqual(
      JSON.parse(fs.readFileSync(path.join(legacy, "client-state/appearance-preferences.json"), "utf8")),
      { appearancePresetId: "canary-preset", localePreference: "canary-locale", schemaVersion: 1 },
    );
    const tabOrder = repairDomain({
      root: legacy,
      frontier,
      domainId: "agent-tab-order",
      binaryProductVersion: "0.3.0",
    });
    assert.equal(tabOrder.mutations[0].storeWritten, true);
    assert.deepEqual(
      JSON.parse(fs.readFileSync(path.join(legacy, "client-state/agent-tab-order.json"), "utf8")),
      { schemaVersion: 1, order: [{ agent: "canary" }] },
    );
    // A collection marker that is a string is the admission's marker; a numeric
    // one is a legacy document, not an unknown shape.
    writeJson(path.join(legacy, "client-state/settings.json"), {
      collection: "settings",
      items: [],
    });
    writeJson(path.join(legacy, "client-state/pins.json"), { schemaVersion: 3, items: [] });
    const collections = evaluateMigrationState({
      root: legacy,
      frontier,
      binaryProductVersion: "0.3.0",
    });
    assert.equal(
      collections.domains.find((domain) => domain.domainId === "client-state").verdict,
      "behind",
    );
  } finally {
    removeRoot(legacy);
  }

  const untypedMarker = tempRoot("repair-untyped-marker");
  try {
    const frontier = loadEmbeddedFrontier();
    // A marker that is not a version leaves the document legacy, so the tool
    // must both report it as behind *and* be able to stamp it: reporting a
    // repair it would then refuse would be worse than refusing up front.
    writeJson(path.join(untypedMarker, "client-state/appearance-preferences.json"), {
      schemaVersion: "not-a-version",
      appearancePresetId: "canary-preset",
    });
    const reported = evaluateMigrationState({
      root: untypedMarker,
      frontier,
      binaryProductVersion: "0.3.0",
    }).domains.find((domain) => domain.domainId === "appearance-presentation");
    assert.equal(reported.verdict, "behind");
    assert.equal(reported.repairable, true);
    assert.deepEqual(reported.codes, []);
    const repaired = repairDomain({
      root: untypedMarker,
      frontier,
      domainId: "appearance-presentation",
      binaryProductVersion: "0.3.0",
    });
    assert.equal(repaired.mutations[0].storeWritten, true);
    assert.deepEqual(
      JSON.parse(
        fs.readFileSync(
          path.join(untypedMarker, "client-state/appearance-preferences.json"),
          "utf8",
        ),
      ),
      { schemaVersion: 1, appearancePresetId: "canary-preset" },
    );
  } finally {
    removeRoot(untypedMarker);
  }

  const refused = tempRoot("repair-refused");
  try {
    const frontier = loadEmbeddedFrontier();
    // Each of these steps is defined by the admission, not by the frontier, so
    // the frontier alone cannot authorize the write.
    for (const domainId of [
      "adaptive-flywheel",
      "canonical-conversation",
      "client-state",
      "mobile-home-layout",
      "mobile-relay",
    ]) {
      assert.throws(
        () => repairDomain({ root: refused, frontier, domainId, binaryProductVersion: "0.3.0" }),
        { code: "repair_requires_native_admission" },
        domainId,
      );
    }
    assert.throws(
      () => repairDomain({
        root: refused,
        frontier,
        domainId: "gateway-credential-custody",
        binaryProductVersion: "0.3.0",
      }),
      { code: "migration_authorization_required" },
    );
    assert.throws(
      () => repairDomain({
        root: refused,
        frontier,
        domainId: "unknown-domain",
        binaryProductVersion: "0.3.0",
      }),
      { code: "repair_domain_unknown" },
    );
    assert.equal(snapshot(refused), "", "a refused repair must change nothing");
  } finally {
    removeRoot(refused);
  }

  const newerBinary = tempRoot("repair-newer-binary");
  try {
    const frontier = loadEmbeddedFrontier();
    seedLedger(newerBinary, frontier, {});
    writePrivateJson(path.join(newerBinary, "client-state/migrations/ledger.json"), {
      schemaVersion: "v0.0.1:client-state-migration-ledger-1",
      highestAdmittedProductVersion: "99.0.0",
      frontierId: frontier.frontierId,
      domains: {},
    });
    const before = snapshot(newerBinary);
    // `reject_older_binary` is a precondition of the whole admission: in this
    // state the binary may not write anything, including one domain step.
    assert.throws(
      () => repairDomain({
        root: newerBinary,
        frontier,
        domainId: "appearance-presentation",
        binaryProductVersion: "0.3.0",
      }),
      { code: "state_newer_than_binary" },
    );
    assert.equal(snapshot(newerBinary), before);
  } finally {
    removeRoot(newerBinary);
  }

  const resumable = tempRoot("repair-resumable");
  try {
    const frontier = loadEmbeddedFrontier();
    const extended = {
      ...frontier,
      domains: frontier.domains.map((domain) =>
        domain.domainId === "appearance-presentation"
          ? {
              ...domain,
              targetSchemaVersion: 2,
              steps: [...domain.steps, {
                stepId: "appearance-presentation.synthetic-to-2",
                fromSchemaVersion: 1,
                toSchemaVersion: 2,
              }],
            }
          : domain),
    };
    const first = repairDomain({
      root: resumable,
      frontier: extended,
      domainId: "appearance-presentation",
      binaryProductVersion: "0.3.0",
    });
    assert.equal(first.mutations[0].stepId, "appearance-presentation.absent-to-1");
    assert.deepEqual(
      first.report.domains.find((domain) => domain.domainId === "appearance-presentation")
        .missingStepIds,
      ["appearance-presentation.synthetic-to-2"],
    );
    // The frontier states nothing about this document's version 2 marker, so
    // the second step is refused rather than guessed.
    assert.throws(
      () => repairDomain({
        root: resumable,
        frontier: extended,
        domainId: "appearance-presentation",
        binaryProductVersion: "0.3.0",
      }),
      { code: "repair_requires_native_admission" },
    );
  } finally {
    removeRoot(resumable);
  }
});

test("the private write refuses to clobber a document that changed after the read", () => {
  const root = tempRoot("cas");
  try {
    const target = path.join(root, "client-state/appearance-preferences.json");
    writeJson(target, { appearancePresetId: "first" });
    const stale = fs.readFileSync(target, "utf8");
    writeJson(target, { appearancePresetId: "second" });
    assert.throws(
      () => writePrivateJsonAtomic(target, { schemaVersion: 1 }, { expectedBytes: stale }),
      { code: "repair_conflict" },
    );
    assert.equal(
      fs.readFileSync(target, "utf8"),
      `${JSON.stringify({ appearancePresetId: "second" })}\n`,
      "a refused compare-and-swap must leave the document alone",
    );
    writePrivateJsonAtomic(target, { schemaVersion: 1 }, {
      expectedBytes: fs.readFileSync(target, "utf8"),
    });
    assert.deepEqual(JSON.parse(fs.readFileSync(target, "utf8")), { schemaVersion: 1 });
    assert.equal(fs.readdirSync(path.dirname(target)).length, 1, "no temporary file is left behind");
  } finally {
    removeRoot(root);
  }
});

test("a root reached through a user-owned symlink is not certified", () => {
  const real = tempRoot("symlink-real");
  const link = `${real}-link`;
  try {
    seedAdmittedRoot(real, loadEmbeddedFrontier());
    fs.symlinkSync(real, link);
    const { envelope, status } = runJson(["doctor", "--root", link]);
    assert.equal(status, 4);
    assert.equal(
      envelope.codes.some((entry) => entry.code === "migration_ledger_invalid"),
      true,
      JSON.stringify(envelope.codes),
    );
  } finally {
    fs.rmSync(link, { force: true });
    removeRoot(real);
  }
});

test("no output carries a local path, a stored value or credential material", () => {
  const root = tempRoot("privacy-canary");
  const canaries = [
    "canary-stored-value-7f3a",
    "pcToken",
    "pairingCode",
    os.homedir(),
    root,
    os.tmpdir(),
  ];
  try {
    writeJson(path.join(root, "client-state/appearance-preferences.json"), {
      appearancePresetId: canaries[0],
      localePreference: canaries[0],
    });
    writeJson(path.join(root, "client-state/mobile-relay/config.json"), {
      schemaVersion: 1,
      pcToken: canaries[0],
      pairingCode: canaries[0],
      mobileRelayE2ee: { protocolVersion: "incompatible-protocol" },
    });
    const outputs = [
      runCli(["status", "--root", root]),
      runCli(["doctor", "--root", root]),
      runCli(["repair", "--domain", "appearance-presentation", "--root", root]),
      runCli(["repair", "--domain", "mobile-relay", "--root", root]),
      runCli(["status", "--root", root, "--json"]),
      runCli(["repair", "--domain", "gateway-credential-custody", "--root", root, "--json"]),
    ];
    for (const result of outputs) {
      for (const stream of [result.stdout, result.stderr]) {
        for (const canary of canaries) {
          assert.equal(
            stream.includes(canary),
            false,
            `output leaked ${canary}: ${stream.slice(0, 200)}`,
          );
        }
      }
    }
    assert.equal(outputs[0].stdout.includes("appearance-presentation"), true);
  } finally {
    removeRoot(root);
  }
});

test("the client never invokes the migration CLI and the tool never guesses a data root", async () => {
  const offenders = [];
  const visit = async (relative) => {
    const absolute = path.join(repoRoot, relative);
    if (!fs.existsSync(absolute)) return;
    for (const entry of await fs.promises.readdir(absolute, { withFileTypes: true })) {
      const child = path.join(relative, entry.name);
      if (entry.isDirectory()) {
        await visit(child);
      } else if (/\.(rs|dart)$/u.test(entry.name)) {
        const source = await fs.promises.readFile(path.join(repoRoot, child), "utf8");
        if (source.includes(`client-state-migration${".mjs"}`)) offenders.push(child);
      }
    }
  };
  await visit("crates");
  await visit("apps/desktop/lib");
  assert.deepEqual(offenders, [], "startup migration stays exclusively the Rust admission");

  const admission = await fs.promises.readFile(path.join(repoRoot, MIGRATION_MODULE), "utf8");
  assert.doesNotMatch(admission, /Command::new|std::process::Command/u);
  const bridge = JSON.parse(
    await fs.promises.readFile(path.join(repoRoot, "schemas/client_bridge/state.json"), "utf8"),
  );
  assert.deepEqual(bridge.operations, ["get", "set", "admit"]);

  // The CLI has no default data root: an operator always names the root, so a
  // self-test cannot read a real installation.
  const missingRoot = runCli(["status"]);
  assert.equal(missingRoot.status, 64);
  assert.match(missingRoot.stderr, /usage: client-state-migration/u);
  for (const source of await Promise.all(
    fs.readdirSync(path.join(repoRoot, moduleRoot))
      .map((leaf) => fs.promises.readFile(path.join(repoRoot, moduleRoot, leaf), "utf8")),
  )) {
    assert.doesNotMatch(source, /homedir\(\)|Application Support|APPDATA/u);
  }
});

test("exit codes stay distinct for healthy, behind, ahead, invalid, and usage", () => {
  const frontier = loadEmbeddedFrontier();
  const healthy = tempRoot("exit-healthy");
  const ahead = tempRoot("exit-ahead");
  try {
    seedAdmittedRoot(healthy, frontier);
    assert.equal(runCli(["doctor", "--root", healthy]).status, 0);
    assert.equal(runCli(["doctor", "--root", tempRoot("exit-behind")]).status, 2);
    writeJson(path.join(ahead, "client-state/appearance-preferences.json"), { schemaVersion: 9 });
    assert.equal(runCli(["doctor", "--root", ahead]).status, 3);
    fs.writeFileSync(path.join(ahead, "client-state/appearance-preferences.json"), "not json");
    assert.equal(runCli(["doctor", "--root", ahead]).status, 4);
    assert.equal(runCli(["status", "--root", "relative/path"]).status, 64);
    assert.equal(runCli(["unknown-command", "--root", healthy]).status, 64);
    assert.equal(runCli(["repair", "--root", healthy]).status, 64);
  } finally {
    removeRoot(healthy);
    removeRoot(ahead);
  }
});

test("every mirrored durable shape and constant still matches the Rust admission", async () => {
  const [migration, policy, migrationPlatform, conversationStore] = await Promise.all([
    fs.promises.readFile(path.join(repoRoot, MIGRATION_MODULE), "utf8"),
    fs.promises.readFile(path.join(repoRoot, CLIENT_STATE_POLICY), "utf8"),
    fs.promises.readFile(path.join(repoRoot, CLIENT_STATE_MIGRATION), "utf8"),
    fs.promises.readFile(path.join(repoRoot, CONVERSATION_STORE), "utf8"),
  ]);
  // Whitespace is stripped so the binding survives any rustfmt layout.
  const compact = migration.replace(/\s+/gu, "");

  const jsonDocuments = new Map();
  const pattern =
    /"([a-z0-9-]+)"=>probe_json_schema\(&root\.join\("([^"]+)"\),(\d+),JsonSchemaPolicy::(\w+),\)/gu;
  for (const match of compact.matchAll(pattern)) {
    jsonDocuments.set(match[1], {
      document: match[2],
      schemaVersion: Number(match[3]),
      policy: match[4] === "MissingIsLegacy" ? "missing-is-legacy" : "current-only",
    });
  }
  const mirrored = Object.fromEntries(
    Object.entries(DURABLE_SHAPES)
      .filter(([, shape]) => shape.kind === "json-document")
      .map(([domainId, shape]) => [domainId, {
        document: shape.document,
        schemaVersion: shape.schemaVersion,
        policy: shape.policy,
      }]),
  );
  assert.deepEqual(Object.fromEntries(jsonDocuments), mirrored);
  for (const [domainId, shape] of Object.entries(mirrored)) {
    assert.ok(
      compact.includes(`"${domainId}"=>probe_json_schema`),
      `${domainId} must route through probe_json_schema`,
    );
    assert.ok(shape.document.length > 0);
  }

  const probeRoute = (name, document) =>
    `${name}(&root.join("${document}"))`;
  assert.ok(
    compact.includes(probeRoute("probe_agent_tab_order", DURABLE_SHAPES["agent-tab-order"].document)),
  );
  assert.ok(
    compact.includes(probeRoute("probe_mobile_relay", DURABLE_SHAPES["mobile-relay"].document)),
  );
  assert.ok(compact.includes('root.join("client-state/adaptive-flywheel/strategies.sqlite3")'));
  assert.ok(compact.includes('Some("3")=>Ok(AuthoritativeProbe{version:2,present:true,})'));
  assert.ok(compact.includes('Some("2")=>Ok(AuthoritativeProbe{version:1,present:true,})'));
  assert.ok(compact.includes('root.join("client-state/conversations/conversations.sqlite3")'));
  assert.ok(compact.includes('root.join("client-state/conversations/migration-v5.complete")'));
  const completionSource =
    `value=="schema=v5${BACKSLASH}nstatus=complete${BACKSLASH}n"`;
  assert.ok(
    compact.includes(completionSource),
    "the completion marker contract moved in the admission",
  );
  const currentSchema = conversationStore.match(
    /pub const CURRENT_SCHEMA_VERSION: &str = "(\d+)";/u,
  );
  assert.ok(currentSchema, "the conversation store schema version moved");
  const probe = await fs.promises.readFile(
    path.join(repoRoot, "tools/scripts/client-state-migration/probe.mjs"),
    "utf8",
  );
  assert.ok(probe.includes(`const CONVERSATION_SCHEMA_VERSION = "${currentSchema[1]}";`));

  const collections = policy
    .slice(
      policy.indexOf("pub(super) const COLLECTIONS"),
      policy.indexOf("];", policy.indexOf("pub(super) const COLLECTIONS")),
    )
    .match(/"([a-z0-9-]+)"/gu)
    .map((quoted) => quoted.slice(1, -1));
  assert.deepEqual(collections, [
    "settings",
    "targets",
    "target-discovery-cache",
    "pairings",
    "skills",
    "pins",
    "identities",
    "conversation-archive-profiles",
    "agent-usage-reports",
    "provider-quota-snapshots",
    "skill-usage",
    "collaboration-plugins",
    "local-server-assemblies",
    "local-server-assembly-cleanup",
    "local-server-assembly-transaction",
    "mcp-install-transactions",
  ]);
  const stateSchema = policy.match(
    /pub\(super\) const STATE_SCHEMA_VERSION: &str = "([^"]+)";/u,
  );
  assert.ok(stateSchema, "the client-state schema marker moved");
  assert.ok(probe.includes(`const CLIENT_STATE_SCHEMA_VERSION = "${stateSchema[1]}";`));
  assert.match(migrationPlatform, /"client state collection owner mismatch"/u);
});

test("the diagnostic module keeps its facade, its leaf set, and one authority per leaf", async () => {
  const leaves = fs.readdirSync(path.join(repoRoot, moduleRoot)).sort();
  assert.deepEqual(leaves, [
    "cli.mjs",
    "errors.mjs",
    "frontier.mjs",
    "ledger.mjs",
    "probe.mjs",
    "repair.mjs",
    "report.mjs",
    "util.mjs",
  ]);
  const facade = await fs.promises.readFile(path.join(repoRoot, facadeRef), "utf8");
  assert.match(facade, /runClientStateMigrationCli\(\);/u);
  assert.equal(facade.includes("readFileSync"), false);
  const sources = Object.fromEntries(await Promise.all(leaves.map(async (leaf) => [
    leaf,
    await fs.promises.readFile(path.join(repoRoot, moduleRoot, leaf), "utf8"),
  ])));
  for (const [leaf, source] of Object.entries(sources)) {
    assert.equal(
      source.includes(`../client-state-migration${".mjs"}`),
      false,
      `${leaf} must not import the facade`,
    );
  }
  const owners = (declaration) =>
    leaves.filter((leaf) => new RegExp(`export (?:async )?function ${declaration}\\(`, "u")
      .test(sources[leaf]));
  assert.deepEqual(owners("parseArgs"), ["cli.mjs"]);
  assert.deepEqual(owners("evaluateMigrationState"), ["report.mjs"]);
  assert.deepEqual(owners("repairDomain"), ["repair.mjs"]);
  assert.deepEqual(owners("loadEmbeddedFrontier"), ["frontier.mjs"]);
  assert.deepEqual(owners("loadLedger"), ["ledger.mjs"]);
  assert.deepEqual(owners("probeDomain"), ["probe.mjs"]);
  assert.deepEqual(owners("writePrivateJsonAtomic"), ["util.mjs"]);
  assert.equal(fs.existsSync(path.join(repoRoot, FRONTIER_REF)), true);
});
