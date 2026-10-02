import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {inspectDeveloperToolSites} from "../../../apps/desktop/scripts/client-architecture/ratchet/developer-tools.mjs";
import {sourceDigest} from "../../../apps/desktop/scripts/client-architecture/ratchet/runtime-review.mjs";
import {compareRatchetPayloads} from "../../../apps/desktop/scripts/client-architecture/ratchet/baseline.mjs";

const file = "crates/demo/src/runner.rs";
const source = "use std::process::Command;\npub fn run(program: &str) { Command::new(program).spawn(); }\n";

async function fixture(files, run) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "licoup-runtime-review-"));
  try {
    for (const [relative, content] of Object.entries(files)) {
      const target = path.join(root, relative);
      await fs.mkdir(path.dirname(target), {recursive: true});
      await fs.writeFile(target, content);
    }
    await run(root);
  } finally { await fs.rm(root, {recursive: true, force: true}); }
}

const inspect = (root, runtimeReviews = [], readFile = fs.readFile) =>
  inspectDeveloperToolSites({repoRoot: root, readdir: fs.readdir, readFile, allowlist: [], runtimeReviews});

function reviewFor(site, files, selection = {kind: "parameter", file, evidence: "program: &str"}) {
  return {id: site.id, purpose: "Synthetic interface fixture accepts the caller's executable for one explicitly reviewed process boundary.", selection,
    provenance: Object.entries(files).map(([file, content]) => ({file, digest: sourceDigest(content), role: "synthetic-interface-provenance"}))};
}

test("an exact runtime review is counted and compared, not converted into zero", async () => {
  await fixture({[file]: source}, async (root) => {
    const missing = await inspect(root);
    assert.equal(missing.unreviewedRuntimeInterfaces.length, 1);
    assert.equal(missing.analysisFailures.length, 0);
    const review = reviewFor(missing.unresolved[0], {[file]: source});
    const accepted = await inspect(root, [review]);
    assert.deepEqual(accepted.problems, []);
    assert.equal(accepted.runtimeInterfaces.length, 1);
    assert.equal(accepted.executionSites.length, 0);
    assert.equal(accepted.runtimeSiteIds.length, 1);
    const changed = await inspect(root, [{...review, purpose: "A different reviewed purpose changes the tracked interface contract, even when its source location is unchanged."}]);
    assert.notDeepEqual(accepted.runtimeSiteIds, changed.runtimeSiteIds);
    const result = compareRatchetPayloads(
      {developer_tool_sites: {runtime_interface_ids: accepted.runtimeSiteIds}},
      {developer_tool_sites: {runtime_interface_ids: changed.runtimeSiteIds}},
    );
    assert.ok(result.regressions.length > 0);
  });
});

test("source drift and a second same-file site cannot inherit a reviewed interface", async () => {
  await fixture({[file]: source}, async (root) => {
    const missing = await inspect(root);
    const review = reviewFor(missing.unresolved[0], {[file]: source});
    const changed = source.replace("Command::new(program).spawn();", "Command::new(program).spawn(); Command::new(program).spawn();");
    await fs.writeFile(path.join(root, file), changed);
    assert.match((await inspect(root, [review])).problems.join("\n"), /source changed/u);
    const reconfirmedOldSite = {...review, provenance: [{...review.provenance[0], digest: sourceDigest(changed)}]};
    const measured = await inspect(root, [reconfirmedOldSite]);
    assert.equal(measured.runtimeInterfaces.length, 1);
    assert.equal(measured.unreviewedRuntimeInterfaces.length, 1);
    assert.match(measured.problems.join("\n"), /unreviewed runtime-selected interface/u);
  });
});

test("API identity, malformed input and finite unsupported macros remain analysis failures", async () => {
  for (const text of [
    source.replace("std::process::Command", "unresolved::Command"),
    "use std::process::Command;\npub fn run(program: &str) { Command::new(missing_symbol).spawn(); }\n",
    "use std::process::Command;\nmacro_rules! discover { () => { \"node\" }; }\nfn discover() -> String { std::env::var(\"FIXTURE_RUNTIME\").unwrap_or_default() }\npub fn run(program: &str) { Command::new(discover!()).spawn(); }\n",
  ]) {
    await fixture({[file]: text}, async (root) => {
      const failed = await inspect(root);
      assert.ok(failed.analysisFailures.length > 0);
      const review = reviewFor(failed.unresolved[0], {[file]: text}, text.includes("discover!")
        ? {kind: "discovery", file, symbol: "discover", evidence: "fn discover() -> String"}
        : {kind: "parameter", file, evidence: "program: &str"});
      const stillFailed = await inspect(root, [review]);
      assert.ok(stillFailed.analysisFailures.length > 0);
      assert.equal(stillFailed.runtimeInterfaces.length, 0);
    });
  }
});

test("review provenance cannot point outside enumerated source or clear an I/O failure", async () => {
  const producer = "crates/demo/src/producer.rs";
  const files = {[file]: source, [producer]: "pub fn configured() -> String { String::new() }\n"};
  await fixture(files, async (root) => {
    const site = (await inspect(root)).unresolved[0];
    const review = reviewFor(site, files);
    const denied = async (target, encoding) => {
      if (String(target).endsWith("/producer.rs")) throw Object.assign(new Error("synthetic source denied"), {code: "EACCES"});
      return fs.readFile(target, encoding);
    };
    const failed = await inspect(root, [review], denied);
    assert.match(failed.problems.join("\n"), /cannot be read|unavailable/u);
    const escaped = {...review, provenance: [...review.provenance, {file: "../private.rs", digest: "a".repeat(64), role: "not-owned-provenance"}]};
    assert.match((await inspect(root, [escaped])).problems.join("\n"), /invalid source provenance/u);
  });
});

test("a source selector summary cannot be borrowed from an unrelated same-named function", async () => {
  const producer = "crates/demo/src/producer.rs";
  const other = "crates/demo/src/other.rs";
  const text = "use std::process::Command;\nuse crate::other::discover;\npub fn run(){ Command::new(discover()).spawn(); }\n";
  const files = {[file]: text,
    [producer]: "pub fn discover() -> String { std::env::var(\"FIXTURE_PROGRAM\").unwrap_or_default() }\n",
    [other]: "pub fn discover() -> String { match true { true => \"node\", false => \"git\" }.to_string() }\n"};
  await fixture(files, async (root) => {
    const failed = await inspect(root);
    const review = reviewFor(failed.unresolved[0], files, {kind: "discovery", file: producer, symbol: "discover", evidence: "pub fn discover() -> String"});
    const measured = await inspect(root, [review]);
    assert.equal(measured.runtimeInterfaces.length, 0);
    assert.ok(measured.analysisFailures.length > 0);
  });
});

test("wildcards duplicate reviews and comment-only selector evidence are refused", async () => {
  const content = "// reviewer_evidence_only_in_comment\n" + source;
  await fixture({[file]: content}, async (root) => {
    const site = (await inspect(root)).unresolved[0];
    const review = reviewFor(site, {[file]: content});
    assert.match((await inspect(root, [{...review, id: `${file}::*`}])).problems.join("\n"), /invalid/u);
    assert.match((await inspect(root, [review, review])).problems.join("\n"), /duplicate/u);
    const comment = {...review, selection: {...review.selection, evidence: "reviewer_evidence_only_in_comment"}};
    assert.match((await inspect(root, [comment])).problems.join("\n"), /lacks its exact/u);
  });
});

test("known process receivers do not borrow an unrelated Command field's identity", async () => {
  await fixture({[file]: "use std::process::Command;\nstruct Unrelated { command: Command }\nstruct Worker; impl Worker { fn spawn(&self) {} }\npub fn run(){ let command = Worker; command.spawn(); }\n"}, async (root) => {
    const measured = await inspect(root);
    assert.equal(measured.runtimeInterfaces.length, 0);
    assert.equal(measured.unreviewedRuntimeInterfaces.length, 0);
    assert.equal(measured.executionSites.length, 0);
  });
});

test("unsupported value-changing pipelines and escaping constructor references never become reviewed runtime input", async () => {
  for (const text of [
    'use std::process::Command; pub fn run(program: Option<&str>) { Command::new(program.map(opaque("node")).unwrap()).spawn(); }',
    'use std::process::Command; pub fn run(program: Option<&str>) { Command::new(program.filter(|_| false).unwrap_or("node")).spawn(); }',
    'use std::process::Command; pub fn run() { Command::new(std::env::var("FIXTURE_PROGRAM").ok().filter(|_| false).unwrap_or("node".to_string())).spawn(); }',
    'use std::process::Command; pub const FACTORY: fn(&str) -> Command = Command::new;',
    'use std::process::Command; pub fn run() { let factory = Command::new; opaque(factory); }',
  ]) {
    await fixture({[file]: text}, async (root) => {
      const result = await inspect(root);
      assert.ok(result.analysisFailures.length > 0, text);
      assert.equal(result.runtimeInterfaces.length, 0);
    });
  }
});
