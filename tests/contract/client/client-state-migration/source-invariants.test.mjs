// Source and layout invariants of the migration diagnostic: the facade stays
// thin, each module leaf keeps one authority, startup migration stays
// exclusively the Rust admission, and the CLI never guesses a data root. These
// assertions read source and repository structure rather than exercising the
// CLI, which the sibling diagnostic leaf does.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

import { FRONTIER_REF } from "../../../../tools/scripts/client-state-migration/frontier.mjs";
import {
  MIGRATION_MODULE,
  facadeRef,
  moduleRoot,
  repoRoot,
  runCli,
} from "./support.mjs";

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
