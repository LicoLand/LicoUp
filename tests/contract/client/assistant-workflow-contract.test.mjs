import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const read = (relative) => readFileSync(path.join(root, relative), "utf8");

const domain = read("crates/licoup-native/src/domain/client_conversation/mod.rs");
const conversationDomain = read("crates/licoup-conversation/src/client_conversation/mod.rs");
const store = [
  "crates/licoup-conversation/src/store/mod.rs",
  "crates/licoup-conversation/src/store/schema.rs",
].map(read).join("\n");
const profile = read("crates/licoup-native/src/domain/client_conversation/profile_snapshot.rs");
const profileAdmission = read("crates/licoup-native/src/domain/client_conversation/profile_admission.rs");
const assistant = read("crates/licoup-native/src/domain/workflow_runtime/assistant.rs");
const flywheelService = read("crates/licoup-native/src/domain/workflow_runtime/service.rs");
const usage = read("crates/licoup-native/src/domain/agent_usage/workflow_ledger.rs");
const policy = read("crates/licoup-client-state/src/policy.rs");
const subagents = read("crates/licoup-native/src/domain/subagents/mod.rs");
const conversationContract = JSON.parse(read("schemas/client_bridge/conversation.json"));
const strategyContract = JSON.parse(read("schemas/client_bridge/strategy.json"));
const bundledSkill = read("crates/licoup-mcp/resources/licoup-guide/SKILL.md");
const guideSkillIdentity = read("crates/licoup-mcp/src/guide_skill.rs");

const FORBIDDEN_PRIVATE = [
  /prompt body/u,
  /secret_token/u,
  /authorization: Bearer/u,
  /<user-home>\/private-workspace-sentinel/u,
  /<windows-user-home>\\private-workspace-sentinel/u,
  /machine-id/u,
  /endpoint-token/u,
];

test("conversation store converges intent-only Assistant Profiles and writes its own format", () => {
  assert.equal(conversationDomain.includes('LICOUP_GUIDE_SKILL_ID: &str = "licoup-guide"'), true);
  // The bundled Skill's identity is owned by the crate that owns the MCP
  // registration delivering it, and the host reads it downward instead of
  // holding a second copy: the source is embedded where the identity is, and the
  // conversation domain no longer embeds it.
  assert.match(guideSkillIdentity, /LICOUP_GUIDE_SKILL_ID: &str = "licoup-guide"/u);
  assert.match(guideSkillIdentity, /include_str!\([\s\S]*licoup-guide\/SKILL\.md/u);
  assert.doesNotMatch(domain, /include_str!\([\s\S]*licoup-guide\/SKILL\.md/u);
  assert.match(domain, /licoup-mcp::guide_skill/u);
  assert.match(store, /CREATE TABLE IF NOT EXISTS membership_profiles/u);
  assert.match(store, /CREATE INDEX IF NOT EXISTS membership_profiles_membership_idx/u);
  assert.match(store, /assistant_membership_id TEXT REFERENCES memberships\(id\)/u);
  // The published membership shape converges duplicate rows once, and every
  // accepted input then writes this binary's own format through the single
  // parameterized version writer.
  assert.match(store, /INSERT INTO schema_meta\(key, value\) VALUES \('version', '12'\)/u);
  assert.match(store, /INSERT INTO schema_meta\(key, value\) VALUES \('version', \?1\)/u);
  assert.match(store, /pub fn set_conversation_assistant/u);
  assert.match(store, /pub fn set_membership_profile/u);
  assert.match(store, /pub fn membership_profiles/u);
  // Migration is applied before any store read and repeated opens replay it
  // without reinterpretation; the retired ordinal generation has no table, and
  // a shape no release wrote is refused instead of being upgraded.
  assert.match(store, /normalize_reserved_default_group_after_legacy_import/u);
  assert.doesNotMatch(
    store,
    /CREATE TABLE IF NOT EXISTS (conversation_roles|role_candidates|flywheels|flywheel_stages|runs|turns)\b/u,
  );
  assert.match(store, /conversation_schema_unsupported_version/u);
});

test("Profile snapshots derive only from named existing authorities", () => {
  assert.match(profile, /trait ProfileSnapshotAuthority/u);
  assert.match(profile, /fn target_facts/u);
  assert.match(profile, /fn model_price_usd_per_million_tokens/u);
  assert.match(profile, /fn coding_score/u);
  assert.match(profile, /agent_model_max_intelligence/u);
  assert.match(profile, /fn skill_names/u);
  assert.match(profile, /RequestScopedAuthority/u);
  assert.match(profile, /reads each owner at most once/u);
  assert.match(profile, /targets::inspect_target_read_only/u);
  assert.match(profile, /provider_model_pricing::model_price/u);
  assert.match(
    profile,
    /agent_intelligence_catalog::agent_model_max_intelligence/u,
  );
  assert.match(profile, /skill_hub::skill_list/u);
  // The Assistant Profile references one concise, product-owned coordinator Skill.
  assert.match(profile, /LICOUP_GUIDE_SKILL_ID/u);
  const prompt = bundledSkill.split("\n---\n").at(-1).trim();
  assert.ok(prompt.length > 0);
  assert.match(bundledSkill, /^name: licoup-guide$/mu);
  const documentedTools = [...prompt.matchAll(/`(lico_[a-z_]+)`/gu)].map((match) => match[1]);
  assert.ok(documentedTools.length > 0);
  for (const tool of documentedTools) {
    assert.ok(subagents.includes(`"${tool}"`), `guide tool is available: ${tool}`);
  }
  assert.match(usage, /graph-usage-ledger-v2\.sqlite3/u);
  assert.match(usage, /licoup\.graph-usage-report\.v2/u);
  assert.doesNotMatch(policy, /assistant-workflow-usage/u);
});

test("candidate ranking is deterministic and keeps unknown optional facts visible", () => {
  // Ranking and admission moved to profile_admission.rs; the markers follow the code
  // that owns them, and the new admission value is pinned in the same place.
  assert.match(profileAdmission, /pub fn rank_candidates/u);
  assert.match(profileAdmission, /optional_desc\(left\.intelligence_score, right\.intelligence_score\)/u);
  assert.match(profileAdmission, /optional_price\(left\)\.cmp\(&optional_price\(right\)\)/u);
  assert.match(profileAdmission, /optional_asc\(left\.latency_class, right\.latency_class\)/u);
  assert.match(profileAdmission, /left\.membership_id\.cmp\(&right\.membership_id\)/u);
  assert.match(profileAdmission, /profile_candidate_rejected/u);
  assert.match(profileAdmission, /Hard constraints/u);
  assert.match(profileAdmission, /pub fn admit_profile_candidates/u);
  assert.match(profileAdmission, /ProfileAdmissionRefusal/u);
});

test("preflight diagnostic stages match the public bridge contract", () => {
  // Admission, stale-route rejection and effect idempotency are exercised by
  // the native service tests; Rust declarations are not their behavior oracle.
  assert.deepEqual(strategyContract.diagnosticStages, [
    "workflow/parse",
    "workflow/compile",
    "package/validate",
    "assistant-workflow/preflight",
    "assistant-workflow/revalidate",
  ]);
});

test("receipts freeze exact bindings and allowlisted sources without private data", () => {
  assert.match(assistant, /pub struct PreflightReceipt/u);
  for (const field of [
    "conversation_id",
    "assistant_membership_id",
    "workflow_digest",
    "membership_ids",
    "route_receipt",
  ]) {
    assert.match(assistant, new RegExp(`pub ${field}:`, "u"), field);
  }
  assert.doesNotMatch(assistant, /pub checks:/u);
  assert.match(assistant, /route_receipt/u);
  for (const owner of [
    "targets",
    "providerModelPricing",
    "agentIntelligenceCatalog",
    "skillHub",
    "assistantWorkflowAuthoringBundle",
  ]) {
    assert.match(flywheelService + read("crates/licoup-native/src/domain/client_conversation/service.rs"), new RegExp(`"${owner}"`, "u"));
  }
  for (const pattern of FORBIDDEN_PRIVATE) {
    assert.doesNotMatch(assistant, pattern, pattern);
  }
});

test("bridge contracts expose Assistant/Profile actions and typed failures", () => {
  for (const action of [
    "conversation.assistant.set",
    "conversation.profile.update",
    "conversation.profile.get",
    "conversation.profile.candidates",
    "conversation.subagent.edge",
  ]) {
    assert.equal(conversationContract.actions.includes(action), true, action);
  }
  for (const action of [
    "strategy.assistant.workflow.execute",
    "strategy.assistant.workflow.inspect",
    "strategy.assistant.workflow.cancel",
  ]) {
    assert.equal(strategyContract.actions.includes(action), true, action);
  }
  for (const code of [
    "profile_intent_invalid",
    "profile_revision_stale",
    "profile_candidate_rejected",
    "graph_invalid",
    "graph_preflight_rejected",
    "graph_identity_rejected",
    "strategy_idempotency_conflict",
  ]) {
    assert.equal(
      [...conversationContract.failureCodes, ...strategyContract.failureCodes].includes(code),
      true,
      code,
    );
  }
});

test("local native Subagent catalog exposes the Assistant workflow facade", () => {
  const assistantTools = [
    "lico_assistant_profiles",
    "lico_assistant_workflow_execute",
    "lico_assistant_workflow_inspect",
    "lico_assistant_workflow_cancel",
  ];
  for (const name of assistantTools) {
    assert.match(subagents, new RegExp(`"${name}"`, "u"), name);
  }
  const catalog = subagents.slice(
    subagents.indexOf("pub const TOOL_NAMES"),
    subagents.indexOf("pub fn tool_catalog"),
  );
  assert.deepEqual(
    [...catalog.matchAll(/"(lico_assistant_[^"]+)"/gu)].map((match) => match[1]),
    assistantTools,
  );
  assert.match(subagents, /"additionalProperties": false/u);
  assert.doesNotMatch(catalog, /conversationPath/u);
  assert.doesNotMatch(catalog, /sessionMode/u);
  for (const pattern of FORBIDDEN_PRIVATE) {
    assert.doesNotMatch(catalog, pattern, pattern);
  }
});
