import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const fixtureRoot = path.join(
  repoRoot,
  "tests/fixtures/continuous-assistant/contracts",
);
const generatorPath = "tools/scripts/generate-client-bridge-contracts.mjs";
const mcpSchemaPath = "schemas/subagent_mcp/subagent_mcp.schema.json";

const TYPE_PARSERS = {
  SourceRef: "ContinuitySourceRef",
  Matter: "ContinuityMatter",
  Agreement: "ContinuityAgreement",
  GoalContract: "ContinuityGoalContract",
  GoalProgress: "ContinuityGoalProgress",
  InterpretationProposal: "ContinuityInterpretationProposal",
  AssistantTurnResponse: "ContinuityAssistantTurnResponse",
  ContextManifest: "ContinuityContextManifest",
  WorkContext: "ContinuityWorkContext",
  Wake: "ContinuityWake",
  QualificationRecord: "ContinuityQualificationRecord",
  ParentCardAnchor: "ContinuityParentCardAnchor",
  GoalCompletionTransition: "ContinuityGoalCompletionTransition",
  ParentContextGrant: "ContinuityParentContextGrant",
  TaskChildAdmission: "ContinuityTaskChildAdmission",
  TaskConversationRelation: "ContinuityTaskConversationRelation",
  ParentGrantBasis: "ContinuityParentGrantBasis",
  ContextCompositionRequest: "ContinuityContextCompositionRequest",
};

function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(repoRoot, relativePath), "utf8"));
}

function listFixtures(kind) {
  return fs
    .readdirSync(path.join(fixtureRoot, kind))
    .filter((name) => name.endsWith(".json"))
    .sort();
}

test("frozen schema, generated bindings, and MCP catalog stay closed", () => {
  const conversation = readJson("schemas/client_bridge/conversation.json");
  const continuity = conversation.continuousAssistant;
  assert.equal(continuity.schemaId, "lico.continuous-assistant.v1");
  assert.equal(continuity.spanEncoding, "utf8-byte-range");
  assert.deepEqual(continuity.ports, [
    "continuity-read",
    "interpretation",
    "continuity-commit",
    "context-composition",
    "native-work-context",
    "goal-evaluation",
    "follow-up",
    "qualification",
    "discovered-knowledge",
  ]);
  assert.equal(continuity.m1Leaves.length, 5);
  assert.equal(continuity.commands.includes("apply-interpretation"), true);
  assert.equal(continuity.commands.includes("pause-goal"), true);
  assert.equal(continuity.commands.includes("resume-goal"), true);
  assert.equal(continuity.commands.includes("admit-task-child"), true);
  assert.equal(continuity.failureCodes.includes("identity_conflict"), true);
  assert.equal(continuity.failureCodes.includes("premature_closure"), true);
  assert.equal(conversation.actions.includes("conversation.assistant.set"), true);
  assert.equal(
    conversation.actions.some((action) => action.startsWith("conversation.continuity")),
    false,
  );

  const rust = fs.readFileSync(
    path.join(repoRoot, "crates/licoup-native/src/ffi/generated/conversation.rs"),
    "utf8",
  );
  const dart = fs.readFileSync(
    path.join(repoRoot, "apps/desktop/lib/src/contracts/generated/conversation.g.dart"),
    "utf8",
  );
  const domain = fs.readFileSync(
    path.join(repoRoot, "crates/licoup-conversation/src/continuity/generated.rs"),
    "utf8",
  );
  const runtime = fs.readFileSync(
    path.join(repoRoot, "crates/licoup-agent-runtime/src/work_context/generated.rs"),
    "utf8",
  );
  for (const typeName of Object.values(TYPE_PARSERS)) {
    assert.match(rust, new RegExp(`struct ${typeName}|enum ${typeName}`));
    assert.match(domain, new RegExp(`struct ${typeName}|enum ${typeName}`));
    assert.match(dart, new RegExp(`class ${typeName}|enum ${typeName}`));
  }
  assert.match(runtime, /enum ContinuityFailureCode/);
  assert.match(runtime, /struct ContinuityNativeCapabilitySnapshot/);
  assert.match(runtime, /struct ContinuityFailure/);
  assert.match(dart, /String _continuityString\(/);
  assert.match(dart, /bool _continuityBool\(/);

  const mcp = readJson(mcpSchemaPath);
  assert.equal(mcp.properties.tools.minItems, 10);
  assert.equal(mcp.properties.tools.maxItems, 10);
  assert.deepEqual(mcp.properties.tools.prefixItems, [
    { const: "lico_assistant_profiles" },
    { const: "lico_assistant_workflow_execute" },
    { const: "lico_assistant_workflow_inspect" },
    { const: "lico_assistant_workflow_cancel" },
    { const: "lico_subagents_list" },
    { const: "lico_subagent_probe" },
    { const: "lico_subagent_delegate" },
    { const: "lico_subagent_continue" },
    { const: "lico_subagent_cancel" },
    { const: "lico_assistant_workflow_policy" },
  ]);
});

test("legal and illegal fixtures have closed expected outcomes", () => {
  const legal = listFixtures("legal");
  const illegal = listFixtures("illegal");
  assert.ok(legal.includes("matter.json"));
  assert.ok(legal.includes("interpretation-proposal.json"));
  assert.ok(legal.includes("task-conversation-relation.json"));
  assert.ok(legal.includes("parent-card-anchor.json"));
  assert.ok(legal.includes("goal-completion-transition.json"));
  assert.ok(legal.includes("parent-context-grant.json"));
  assert.ok(legal.includes("parent-grant-contained-span.json"));
  assert.ok(legal.includes("context-composition-request.json"));
  assert.ok(legal.includes("sibling-card-order.json"));
  assert.ok(illegal.includes("unknown-field.json"));
  assert.ok(illegal.includes("invalid-span.json"));
  assert.ok(illegal.includes("idempotency-conflict.json"));
  assert.ok(illegal.includes("simple-chat-child.json"));
  assert.ok(illegal.includes("identity-conflict.json"));
  assert.ok(illegal.includes("premature-closure.json"));
  assert.ok(illegal.includes("ungranted-parent-ref.json"));
  assert.ok(illegal.includes("card-moved.json"));
  assert.ok(illegal.includes("card-part-moved.json"));
  assert.ok(illegal.includes("grant-other-member.json"));
  assert.ok(illegal.includes("grant-stale-generation.json"));
  assert.ok(illegal.includes("grant-changed-revision.json"));
  assert.ok(illegal.includes("grant-changed-digest.json"));
  assert.ok(illegal.includes("grant-widened-span.json"));
  assert.ok(illegal.includes("sibling-sequence-collision.json"));
  for (const name of illegal) {
    const fixture = JSON.parse(
      fs.readFileSync(path.join(fixtureRoot, "illegal", name), "utf8"),
    );
    assert.equal(fixture.expect.status, "reject");
    assert.equal(typeof fixture.expect.reason, "string");
  }
});

test("generator --check is byte-stable across a second generate", () => {
  const check = spawnSync(process.execPath, [generatorPath, "--check"], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  assert.equal(check.status, 0, check.stderr || check.stdout);

  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "lico-continuity-gen-"));
  const copied = [
    "schemas/client_bridge/manifest.json",
    "schemas/client_bridge/conversation.json",
    "schemas/client_bridge/client_error.schema.json",
    "schemas/client_bridge/state.json",
    "schemas/client_bridge/secure_mesh.json",
    "schemas/client_bridge/strategy.json",
    generatorPath,
    "tools/templates/client_bridge",
    "package.json",
    "crates/licoup-native/src/ffi/generated/conversation.rs",
    "crates/licoup-native/src/ffi/generated/client_error.rs",
    "crates/licoup-native/src/ffi/generated/client_state.rs",
    "crates/licoup-native/src/ffi/generated/secure_mesh.rs",
    "crates/licoup-native/src/ffi/generated/strategy.rs",
    "apps/desktop/lib/src/contracts/generated/conversation.g.dart",
    "apps/desktop/lib/src/contracts/generated/client_error.g.dart",
    "apps/desktop/lib/src/contracts/generated/client_state.g.dart",
    "apps/desktop/lib/src/contracts/generated/secure_mesh.g.dart",
    "apps/desktop/lib/src/contracts/generated/strategy.g.dart",
    "crates/licoup-conversation/src/continuity/generated.rs",
    "crates/licoup-agent-runtime/src/work_context/generated.rs",
  ];
  for (const relative of copied) {
    const source = path.join(repoRoot, relative);
    if (!fs.existsSync(source)) continue;
    const target = path.join(scratch, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.cpSync(source, target, {
      force: true,
      recursive: true,
      preserveTimestamps: false,
    });
  }
  const first = spawnSync(process.execPath, [generatorPath], {
    cwd: scratch,
    encoding: "utf8",
  });
  assert.equal(first.status, 0, first.stderr || first.stdout);
  const rustBefore = fs.readFileSync(
    path.join(scratch, "crates/licoup-native/src/ffi/generated/conversation.rs"),
    "utf8",
  );
  const dartBefore = fs.readFileSync(
    path.join(scratch, "apps/desktop/lib/src/contracts/generated/conversation.g.dart"),
    "utf8",
  );
  const domainBefore = fs.readFileSync(
    path.join(scratch, "crates/licoup-conversation/src/continuity/generated.rs"),
    "utf8",
  );
  const runtimeBefore = fs.readFileSync(
    path.join(scratch, "crates/licoup-agent-runtime/src/work_context/generated.rs"),
    "utf8",
  );
  const second = spawnSync(process.execPath, [generatorPath], {
    cwd: scratch,
    encoding: "utf8",
  });
  assert.equal(second.status, 0, second.stderr || second.stdout);
  assert.equal(
    fs.readFileSync(
      path.join(scratch, "crates/licoup-native/src/ffi/generated/conversation.rs"),
      "utf8",
    ),
    rustBefore,
  );
  assert.equal(
    fs.readFileSync(
      path.join(scratch, "apps/desktop/lib/src/contracts/generated/conversation.g.dart"),
      "utf8",
    ),
    dartBefore,
  );
  assert.equal(
    fs.readFileSync(
      path.join(scratch, "crates/licoup-conversation/src/continuity/generated.rs"),
      "utf8",
    ),
    domainBefore,
  );
  assert.equal(
    fs.readFileSync(
      path.join(scratch, "crates/licoup-agent-runtime/src/work_context/generated.rs"),
      "utf8",
    ),
    runtimeBefore,
  );
  fs.rmSync(scratch, { recursive: true, force: true });
});

test("production rust parser and admission cover the fixture matrix", () => {
  const result = spawnSync(
    process.execPath,
    [
      "tools/scripts/cargo-client.mjs",
      "test",
      "-p",
      "licoup-conversation",
      "--test",
      "continuity_contract",
      "--",
      "--nocapture",
    ],
    {
      cwd: repoRoot,
      encoding: "utf8",
    },
  );
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout || "", /legal_fixtures_parse_on_generated_types/);
});
