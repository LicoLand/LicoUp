import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const generatorPath = "tools/scripts/generate-client-bridge-contracts.mjs";

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

test("frozen schema and generated Dart binding stay closed", () => {
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

  const dart = fs.readFileSync(
    path.join(repoRoot, "apps/desktop/lib/src/contracts/generated/conversation.g.dart"),
    "utf8",
  );
  for (const typeName of Object.values(TYPE_PARSERS)) {
    assert.match(dart, new RegExp(`class ${typeName}|enum ${typeName}`));
  }
  assert.match(dart, /String _continuityString\(/);
  assert.match(dart, /bool _continuityBool\(/);
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
    "schemas/client_bridge/strategy.json",
    "schemas/client_bridge/package.json",
    generatorPath,
    "tools/templates/client_bridge",
    "package.json",
    "apps/desktop/lib/src/contracts/generated/conversation.g.dart",
    "apps/desktop/lib/src/contracts/generated/client_error.g.dart",
    "apps/desktop/lib/src/contracts/generated/client_state.g.dart",
    "apps/desktop/lib/src/contracts/generated/strategy.g.dart",
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
  const dartBefore = fs.readFileSync(
    path.join(scratch, "apps/desktop/lib/src/contracts/generated/conversation.g.dart"),
    "utf8",
  );
  const second = spawnSync(process.execPath, [generatorPath], {
    cwd: scratch,
    encoding: "utf8",
  });
  assert.equal(second.status, 0, second.stderr || second.stdout);
  assert.equal(
    fs.readFileSync(
      path.join(scratch, "apps/desktop/lib/src/contracts/generated/conversation.g.dart"),
      "utf8",
    ),
    dartBefore,
  );
  fs.rmSync(scratch, { recursive: true, force: true });
});
