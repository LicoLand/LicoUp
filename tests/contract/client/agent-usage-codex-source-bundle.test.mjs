import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const sourceRoot =
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex";
const integrationRoot = "crates/lico-client-native/tests/agent_usage_cache_cases";

const productionLeaves = Object.freeze([
  "aggregation.rs",
  "append_guard.rs",
  "cache.rs",
  "cache_batch.rs",
  "constants.rs",
  "event_hash.rs",
  "file_collection.rs",
  "lineage.rs",
  "models.rs",
  "parser.rs",
  "scan.rs",
  "scan_params.rs",
  "utils.rs",
]);

const lineLimits = Object.freeze({
  "aggregation.rs": 250,
  "append_guard.rs": 80,
  "cache.rs": 190,
  "cache_batch.rs": 220,
  "constants.rs": 15,
  "event_hash.rs": 100,
  "file_collection.rs": 90,
  "lineage.rs": 100,
  "models.rs": 150,
  "parser.rs": 300,
  "scan.rs": 190,
  "scan_params.rs": 100,
  "utils.rs": 70,
});

const integrationLeaves = Object.freeze({
  "append_refresh.rs": 190,
  "cache_runtime.rs": 130,
  "dedup_lineage.rs": 170,
  "estimates.rs": 75,
  "generic_usage.rs": 145,
  "reconciliation.rs": 40,
  "retained_reports.rs": 80,
  "support.rs": 115,
  "windows.rs": 80,
});

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all(productionLeaves.map(async (leaf) => [
    leaf,
    await read(`${sourceRoot}/${leaf}`),
  ])));
}

test("Codex usage facade is thin and owns every production leaf", async () => {
  const facade = await read(`${sourceRoot}.rs`);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 35);
  assert.deepEqual(
    [...facade.matchAll(/^mod ([a-z_]+);$/gmu)]
      .map((match) => match[1])
      .filter((moduleName) => moduleName !== "tests")
      .map((moduleName) => `${moduleName}.rs`)
      .sort(),
    [...productionLeaves].sort(),
  );
  for (const implementationToken of [
    "struct TokenTotals",
    "Connection::open",
    "fs::read_dir",
    "BufReader::new",
    "include!(",
    "#[path",
  ]) {
    assert.equal(facade.includes(implementationToken), false);
  }
});

test("Codex usage leaves retain bounded single responsibilities", async () => {
  const source = await sources();
  for (const [leaf, body] of Object.entries(source)) {
    assert.ok(
      body.trimEnd().split(/\r?\n/u).length <= lineLimits[leaf],
      `${leaf} exceeds its responsibility limit`,
    );
    assert.equal(body.includes("include!("), false);
    assert.equal(body.includes("#[path"), false);
    assert.equal(/^mod [a-z_]+;$/mu.test(body), false);
  }
});

test("Codex usage discovery and parsing stay local, read-only, and bounded", async () => {
  const source = await sources();
  const collection = source["file_collection.rs"];
  const parser = source["parser.rs"];
  for (const token of [
    "HashSet::<PathBuf>::new()",
    "BTreeSet::<PathBuf>::new()",
    "file_type().is_symlink()",
  ])
    assert.ok(collection.includes(token), `missing bounded discovery token: ${token}`);
  assert.ok(collection.includes("fs::read_dir"));
  assert.ok(parser.includes("fs::File::open(path)"));
  assert.ok(parser.includes("BufReader::new(file)"));
  assert.ok(parser.includes("return Ok(line_start)"));
  for (const mutationToken of ["OpenOptions", ".write_all(", ".set_len(", "fs::remove_file"])
    assert.equal(parser.includes(mutationToken), false);
});

test("Codex usage cache keeps incremental guards, prepared batches, and indexed queries", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  for (const token of [
    'pragma_update(None, "journal_mode", "WAL")',
    "TransactionBehavior::Immediate",
    "CREATE INDEX usage_rows_window",
    "CREATE INDEX usage_rows_identity",
    "CREATE INDEX usage_estimates_window",
    "CREATE INDEX usage_estimates_identity",
    "struct CacheBatch",
    "struct ParserBatch",
    "Statement<'connection>",
    "append_guard_matches",
    "extend_content_guard",
  ]) {
    assert.ok(joined.includes(token), `missing incremental cache boundary: ${token}`);
  }
});

test("Codex usage projection exposes aggregates without local paths or content", async () => {
  const source = await sources();
  const aggregation = source["aggregation.rs"];
  const schema = source["cache.rs"];
  const scan = source["scan.rs"];
  assert.ok(aggregation.includes('source: Some("codex-local-token-events")'));
  assert.ok(aggregation.includes('"codex-local-usage-store".to_string()'));
  assert.equal(aggregation.includes("to_string_lossy"), false);
  assert.equal(aggregation.includes("PathBuf"), false);
  for (const forbiddenColumn of ["source_path TEXT", "raw_content", "message_content"])
    assert.equal(schema.includes(forbiddenColumn), false);
  assert.ok(scan.includes('"code": "codex_local_token_event_scan_failed"'));
  assert.equal(scan.includes('"error":'), false);
  assert.equal(scan.includes("error.to_string()"), false);
});

test("Codex usage canonical identity and lineage remain deterministic", async () => {
  const source = await sources();
  assert.ok(source["event_hash.rs"].includes("hash_canonical_json"));
  assert.ok(source["event_hash.rs"].includes("keys.sort()"));
  assert.ok(source["lineage.rs"].includes("HashMap<String, String>"));
  assert.ok(source["lineage.rs"].includes("BTreeSet::<String>::new()"));
  assert.ok(source["aggregation.rs"].includes("event_identity=r.event_identity"));
  assert.ok(source["aggregation.rs"].includes("prior_file.lineage_scope=f.lineage_scope"));
});

test("Codex usage integration target is a thin composition of precise scenario leaves", async () => {
  const crateRoot = await read(
    "crates/lico-client-native/tests/agent_usage_incremental_cache.rs",
  );
  const composition = await read(`${integrationRoot}/mod.rs`);
  assert.equal(crateRoot.trim(), "mod agent_usage_cache_cases;");
  assert.deepEqual(
    [...composition.matchAll(/^mod ([a-z_]+);$/gmu)]
      .map((match) => `${match[1]}.rs`)
      .filter((leaf) => leaf !== "support.rs")
      .sort(),
    Object.keys(integrationLeaves)
      .filter((leaf) => leaf !== "support.rs")
      .sort(),
  );
  assert.ok(composition.includes("mod support;"));
  for (const [leaf, maxLines] of Object.entries(integrationLeaves)) {
    const body = await read(`${integrationRoot}/${leaf}`);
    assert.ok(
      body.trimEnd().split(/\r?\n/u).length <= maxLines,
      `${leaf} exceeds its integration scenario limit`,
    );
    assert.equal(body.includes("include!("), false);
    assert.equal(body.includes("#[path"), false);
  }
});
