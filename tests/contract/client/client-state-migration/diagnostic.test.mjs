// The operator-facing contract of the client-state migration diagnostic: what
// `status`, `doctor` and `repair` report against a synthetic data root, which
// exit code each verdict carries, and what the tool must never print or write.
// The mirrored Rust constants are asserted by the sibling admission-mirror
// leaf; this leaf only observes behavior.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { loadEmbeddedFrontier, planSteps } from "../../../../tools/scripts/client-state-migration/frontier.mjs";
import { evaluateMigrationState } from "../../../../tools/scripts/client-state-migration/report.mjs";
import { repairDomain } from "../../../../tools/scripts/client-state-migration/repair.mjs";
import { writePrivateJsonAtomic } from "../../../../tools/scripts/client-state-migration/util.mjs";
import {
  removeRoot,
  runCli,
  runJson,
  seedAdmittedRoot,
  seedLedger,
  snapshot,
  tempRoot,
  writeJson,
  writePrivateJson,
} from "./support.mjs";

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
