import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const modulePath = path.join(repoRoot, "crates/licoup-native/src/domain/delivery_plan/mod.rs");
const domainPath = path.join(repoRoot, "crates/licoup-native/src/domain/mod.rs");

async function source() {
  return fs.readFile(modulePath, "utf8");
}

test("native delivery Plan owns the current semantic/checkpoint generations", async () => {
  const text = await source();
  for (const required of [
    'PLAN_SCHEMA: &str = "better-plan.plan/v3"',
    'CHECKPOINT_SCHEMA: &str = "better-plan.checkpoints/v3"',
    "MAX_TASKS: usize = 256",
    "MAX_SEMANTIC_BYTES: usize = 2 * 1024 * 1024",
    "serde(deny_unknown_fields)",
    "pub struct Plan",
    "pub struct Checkpoints",
    "pub struct DeliveryPlanEngine",
    "pub fn resolve_dossier",
    "pub fn open_designer",
    "pub fn authorize",
    "pub fn continue_unstarted",
    "pub fn next_action",
    "pub fn bind_dispatch",
    "pub fn accept_task",
    "pub fn open_reviewer",
    "pub fn cancel",
  ]) {
    assert.ok(text.includes(required), "missing native delivery-plan contract: " + required);
  }
});

test("native delivery Plan keeps semantic digest separate from runtime checkpoint data", async () => {
  const text = await source();
  assert.match(text, /fn\s+canonical_json\s*\(/);
  assert.match(text, /fn\s+sha256_hex\s*\(/);
  assert.match(text, /semantic_digest/);
  assert.match(text, /conversation_location/);
  assert.match(text, /atomic_private_write/);
  assert.match(text, /GraphIndex/);
  assert.match(text, /reachable/);
  assert.match(text, /unsafe_parallel_write_overlap/);
  assert.match(text, /"cancelled" => \(PlanPhase::Blocked, true\)/);
  assert.match(text, /persist_checkpoint_at/);
  assert.match(text, /cancelled delivery state is terminal/);
});

test("delivery-plan is registered as one focused regression module", async () => {
  const [domain, catalog] = await Promise.all([
    fs.readFile(domainPath, "utf8"),
    fs.readFile(path.join(repoRoot, "tools/regression/client-module-catalog/groups/regression.mjs"), "utf8"),
  ]);
  assert.match(domain, /pub\s+mod\s+delivery_plan;/);
  assert.match(catalog, /regression\.delivery-plan-contract/);
  assert.match(catalog, /tests\/contract\/client\/lico-delivery-plan\.test\.mjs/);
});

test("delivery-plan does not introduce an external Better Plan runtime or context layer", async () => {
  const text = await source();
  assert.doesNotMatch(text, /better_plan_python|context_capsule|prompt_cache|prime_agent/i);
});
