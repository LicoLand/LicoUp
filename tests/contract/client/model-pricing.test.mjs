import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import test from "node:test";

import {
  PRICING_FACT_PATHS,
  PricingFactsError,
  loadCatalog,
  runSelfTest,
  validateCatalog,
  validateReleaseFreshness,
} from "../../../tools/scripts/model-pricing-facts.mjs";
import {
  CLIENT_GATE_LANES,
  classifyClientGatePaths,
} from "../../../tools/scripts/client-gate-policy.mjs";

const source = readFileSync(
  path.join(PRICING_FACT_PATHS.repoRoot, "tools/scripts/model-pricing-facts.mjs"),
  "utf8",
);
const rust = readFileSync(
  path.join(
    PRICING_FACT_PATHS.repoRoot,
    "crates/licoup-native/src/domain/provider_model_pricing.rs",
  ),
  "utf8",
);
const packageJson = JSON.parse(readFileSync(
  path.join(PRICING_FACT_PATHS.repoRoot, "package.json"),
  "utf8",
));

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function rejects(operation, code) {
  assert.throws(operation, (error) =>
    error instanceof PricingFactsError && error.code === code);
}

function route(catalog, tableId, modelId) {
  return [...catalog.providers, ...catalog.agents]
    .find((table) => table.id === tableId)?.routes
    .find((candidate) => candidate.model_id === modelId);
}

test("one current catalog owns all rich provider and Agent pricing facts", () => {
  const catalog = loadCatalog();
  const checked = validateCatalog(catalog);
  assert.deepEqual(Object.keys(catalog).sort(), ["agents", "last_updated", "providers"]);
  assert.equal(catalog.last_updated, "2026-08-14");
  assert.equal(checked.tableCount, 10);
  assert.equal(checked.routeCount, 91);
  assert.deepEqual(
    [...catalog.providers, ...catalog.agents].map((table) => table.id),
    [
      "deepseek",
      "kimi",
      "google",
      "openai",
      "anthropic",
      "xai",
      "cursor",
      "openai-chatgpt",
      "kilo",
      "opencode-zen",
    ],
  );
  assert.deepEqual(
    readdirSync(path.dirname(PRICING_FACT_PATHS.catalog)).sort(),
    ["pricing_catalog.json"],
  );
});

test("cache-write retention and context tiers remain lossless", () => {
  const catalog = loadCatalog();
  const routes = [...catalog.providers, ...catalog.agents].flatMap((table) => table.routes);
  assert.equal(
    routes.filter((candidate) =>
      candidate.tiers.some((tier) => tier.cache_write !== null)).length,
    30,
  );
  assert.equal(routes.filter((candidate) => candidate.tiers.length > 1).length, 15);
  const anthropic = route(catalog, "anthropic", "claude-fable-5");
  assert.deepEqual(
    anthropic.tiers[0].cache_write.map(({ ttl_seconds: ttl }) => ttl),
    [300, 3600],
  );
  const openAiSol = route(catalog, "openai", "gpt-5.6-sol");
  assert.deepEqual(
    openAiSol.tiers.map(({ context_min, context_max }) => [context_min, context_max]),
    [[null, 272000], [272001, null]],
  );
  const free = route(catalog, "opencode-zen", "big-pickle");
  assert.equal(free.included_by_harness, true);
  assert.equal(free.tiers[0].input, 0);
});

test("catalog validation rejects malformed or incomplete facts", () => {
  const base = loadCatalog();
  const missingSource = clone(base);
  missingSource.providers[0].routes[0].source_urls = [];
  rejects(() => validateCatalog(missingSource), "pricing_sources_missing");

  const duplicateRaw = clone(base);
  duplicateRaw.providers[1].routes[0].model_id =
    duplicateRaw.providers[0].routes[0].model_id;
  rejects(() => validateCatalog(duplicateRaw), "pricing_raw_provider_duplicate");

  const ended = clone(base);
  ended.providers[0].routes[0].lifecycle.service_end = ended.last_updated;
  rejects(() => validateCatalog(ended), "pricing_service_end_elapsed");

  const unknownKey = clone(base);
  unknownKey.providers[0].unknown = true;
  rejects(() => validateCatalog(unknownKey), "pricing_table_shape_invalid");

  const ambiguous = clone(base);
  ambiguous.providers[3].routes[0].tiers.push(
    clone(ambiguous.providers[3].routes[0].tiers[0]),
  );
  rejects(() => validateCatalog(ambiguous), "pricing_default_tier_ambiguous");
});

test("release freshness is inclusive for seven days", () => {
  const current = loadCatalog();
  assert.equal(validateReleaseFreshness(current, "2026-08-14"), true);

  const sevenDays = clone(current);
  sevenDays.providers[0].routes[0].verified_on = "2026-08-07";
  assert.equal(validateReleaseFreshness(validateCatalog(sevenDays), "2026-08-14"), true);

  const stale = clone(current);
  stale.providers[0].routes[0].verified_on = "2026-08-06";
  rejects(
    () => validateReleaseFreshness(validateCatalog(stale), "2026-08-14"),
    "pricing_verification_stale",
  );
});

test("Rust and release commands consume only the canonical catalog", () => {
  assert.match(rust, /pricing_catalog\.json/u);
  assert.match(rust, /last_updated: guard\.last_updated/u);
  assert.doesNotMatch(source, /writeFileSync|mkdirSync|rmSync/u);
  assert.equal(packageJson.scripts[["client", "pricing", "generate"].join(":")], undefined);
  assert.ok(CLIENT_GATE_LANES["release-policy"].includes("client:pricing:release-check"));
  const selection = classifyClientGatePaths([
    "crates/licoup-native/src/domain/provider_model_pricing/pricing_catalog.json",
    "tools/scripts/model-pricing-facts.mjs",
  ]);
  assert.equal(selection.lanes["release-policy"], undefined);
});

test("read-only validator self-test is deterministic", () => {
  const result = runSelfTest();
  assert.equal(result.ok, true);
  assert.equal(result.tableCount, 10);
  assert.equal(result.routeCount, 91);
  assert.equal(result.deterministic, true);
});
