import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const read = (relative) => readFileSync(path.join(root, relative), "utf8");
const exists = (relative) => existsSync(path.join(root, relative));

const decision0003 = read("docs/adrs/0003-group-conversation-agent-profile.md");
const decision0004 = read("docs/adrs/0004-assistant-authored-flexible-workflows.md");
const decision0005 = read("docs/adrs/0005-assistant-auto-adaptation-and-deepseek-harness.md");
const domain = read("crates/licoup-native/src/domain/client_conversation/mod.rs");
const store = read("crates/licoup-native/src/domain/client_conversation/store.rs");
const profile = read("crates/licoup-native/src/domain/client_conversation/profile_snapshot.rs");
const assistant = read("crates/licoup-native/src/domain/adaptive_flywheel/assistant.rs");
const flywheelService = read("crates/licoup-native/src/domain/adaptive_flywheel/service.rs");
const strategyStore = read("crates/licoup-native/src/domain/adaptive_flywheel/store.rs");
const usage = read("crates/licoup-native/src/domain/agent_usage/workflow_ledger.rs");
const policy = read("crates/licoup-native/src/platform/client_state/policy.rs");
const subagentMcp = read("crates/licoup-native/src/bin/lico-subagent-mcp.rs");
const conversationContract = JSON.parse(read("schemas/client_bridge/conversation.json"));
const strategyContract = JSON.parse(read("schemas/client_bridge/strategy.json"));
const bundledSkill = exists("crates/licoup-native/resources/assistant-workflow-authoring/SKILL.md")
  ? read("crates/licoup-native/resources/assistant-workflow-authoring/SKILL.md")
  : "";

const FORBIDDEN_PRIVATE = [
  /prompt body/u,
  /secret_token/u,
  /authorization: Bearer/u,
  /<user-home>\/private-workspace-sentinel/u,
  /<windows-user-home>\\private-workspace-sentinel/u,
  /machine-id/u,
  /endpoint-token/u,
];

test("ADR 0003 is historical and ADR 0004 freezes the Assistant boundary", () => {
  assert.match(decision0003, /# ADR 0003/u);
  // Decision 0003 deliberately defers the concrete fields, format, and
  // default usage to a follow-up decision.
  assert.match(decision0003, /intentionally unspecified|follow-up decision|left open/u);
  assert.match(decision0004, /assistant-temporary/u);
  assert.match(decision0004, /assistant-workflow-authoring/u);
  assert.match(decision0005, /Automatic adaptation/u);
  assert.match(decision0005, /DeepSeek Harness/u);
});

test("conversation migration v8 cuts over to intent-only Assistant Profiles idempotently", () => {
  assert.equal(domain.includes('ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID: &str = "assistant-workflow-authoring"'), true);
  assert.match(domain, /include_str!\([\s\S]*assistant-workflow-authoring\/SKILL\.md/u);
  assert.match(store, /CREATE TABLE IF NOT EXISTS membership_profiles/u);
  assert.match(store, /CREATE INDEX IF NOT EXISTS membership_profiles_membership_idx/u);
  assert.match(store, /assistant_membership_id TEXT REFERENCES memberships\(id\)/u);
  assert.match(store, /INSERT INTO schema_meta\(key, value\) VALUES \('version', '8'\)/u);
  assert.match(store, /pub fn set_conversation_assistant/u);
  assert.match(store, /pub fn set_membership_profile/u);
  assert.match(store, /pub fn membership_profiles/u);
  // Migration is applied before any store read and repeated opens replay it
  // without reinterpretation; the retired ordinal generation has no table.
  assert.match(store, /normalize_reserved_default_group_after_legacy_import/u);
  assert.match(store, /DROP TABLE IF EXISTS flywheels/u);
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
  assert.match(profile, /ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID/u);
  const prompt = bundledSkill.split("\n---\n").at(-1).trim();
  assert.ok(Buffer.byteLength(prompt, "utf8") <= 256);
  assert.match(prompt, /Understand and complete the user's request/u);
  assert.match(prompt, /use tools freely/u);
  assert.match(prompt, /existing workflow/u);
  assert.match(prompt, /write one/u);
  assert.match(prompt, /Keep going until it is done/u);
  assert.doesNotMatch(prompt, /\b(?:must not|never|do not|only)\b/iu);
  assert.match(usage, /graph-usage-ledger-v2\.sqlite3/u);
  assert.match(usage, /licoup\.graph-usage-report\.v2/u);
  assert.doesNotMatch(policy, /assistant-workflow-usage/u);
});

test("candidate ranking is deterministic and keeps unknown optional facts visible", () => {
  assert.match(profile, /pub fn rank_candidates/u);
  assert.match(profile, /optional_desc\(left\.intelligence_score, right\.intelligence_score\)/u);
  assert.match(profile, /optional_price\(left\)\.cmp\(&optional_price\(right\)\)/u);
  assert.match(profile, /optional_asc\(left\.latency_class, right\.latency_class\)/u);
  assert.match(profile, /left\.membership_id\.cmp\(&right\.membership_id\)/u);
  assert.match(profile, /profile_candidate_rejected/u);
  assert.match(profile, /Hard constraints/u);
});

test("preflight returns every hard failure before any actor/script effect", () => {
  assert.match(assistant, /precedes durable admission or an effect permit/u);
  assert.match(assistant, /graph_preflight_rejected/u);
  assert.match(assistant, /graph_identity_rejected/u);
  assert.match(assistant, /graph_membership_rejected/u);
  assert.match(assistant, /graph_binding_incomplete/u);
  assert.match(assistant, /graph_model_rejected/u);
  assert.match(assistant, /graph_readiness_rejected/u);
  assert.match(assistant, /graph_environment_unavailable/u);
  assert.match(assistant, /assistant-temporary/u);
  assert.match(assistant, /pub struct PreflightDiagnostic/u);
  assert.match(assistant, /pub diagnostics: Vec<PreflightDiagnostic>/u);
  assert.deepEqual(strategyContract.diagnosticStages, [
    "workflow/parse",
    "workflow/compile",
    "package/validate",
    "assistant-workflow/preflight",
    "assistant-workflow/revalidate",
  ]);
  assert.match(flywheelService, /assistant_graph_preflight_rejects_before_any_actor_effect/u);
  assert.match(flywheelService, /assistant_graph_start_preflights_and_replays_without_duplicate_effects/u);
  assert.match(flywheelService, /assistant_route_revision_change_rejects_before_admission_or_effect/u);
  // Admission revalidates the exact bindings immediately before durable
  // register/bind/grant, so stale or ineligible facts cannot become permission.
  assert.match(flywheelService, /revalidate_assistant_admission/u);
  assert.match(flywheelService, /run_id_by_idempotency_key/u);
  assert.match(strategyStore, /fn run_id_by_idempotency_key/u);
  assert.match(strategyStore, /assistant-temporary%/u);
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

test("subagent MCP surface is closed and exposes the Assistant workflow facade only", () => {
  const assistantTools = [
    "lico_assistant_profiles",
    "lico_assistant_workflow_execute",
    "lico_assistant_workflow_inspect",
    "lico_assistant_workflow_cancel",
  ];
  for (const name of assistantTools) {
    assert.match(subagentMcp, new RegExp(`"${name}"`, "u"), name);
  }
  const catalog = subagentMcp.slice(
    subagentMcp.indexOf("fn tool_catalog()"),
    subagentMcp.indexOf("fn closed_object("),
  );
  assert.deepEqual(
    [...catalog.matchAll(/"name": "(lico_assistant_[^"]+)"/gu)].map((match) => match[1]),
    assistantTools,
  );
  // Every tool schema is built by the closed-object helper; the helper is the
  // single authority that forbids extra keys.
  assert.match(catalog, /closed_object\(/u);
  assert.match(
    subagentMcp.slice(
      subagentMcp.indexOf("fn closed_object("),
      subagentMcp.indexOf("fn bounded_string("),
    ),
    /additionalProperties": false/u,
  );
  assert.doesNotMatch(catalog, /conversationPath/u);
  assert.doesNotMatch(catalog, /sessionMode/u);
  for (const pattern of FORBIDDEN_PRIVATE) {
    assert.doesNotMatch(catalog, pattern, pattern);
  }
});
