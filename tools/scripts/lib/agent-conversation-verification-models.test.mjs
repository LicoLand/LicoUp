import assert from "node:assert/strict";
import test from "node:test";
import {
  VERIFICATION_MODELS_SCHEMA,
  loadVerificationModels,
  parseVerificationModelsToml,
  verificationModelForAgent,
  verificationModelsMap,
} from "./agent-conversation-verification-models.mjs";

test("parseVerificationModelsToml accepts the maintained config shape", () => {
  const parsed = parseVerificationModelsToml(`
schema_version = "${VERIFICATION_MODELS_SCHEMA}"

[models]
cursor = "composer-2.5"
"claude-code" = "haiku"
`);
  assert.equal(parsed.schemaVersion, VERIFICATION_MODELS_SCHEMA);
  assert.deepEqual(parsed.models, {
    cursor: "composer-2.5",
    "claude-code": "haiku",
  });
});

test("loadVerificationModels loads the repo config once", () => {
  const first = loadVerificationModels({ reload: true });
  const second = loadVerificationModels();
  assert.equal(first, second);
  assert.equal(first.schemaVersion, VERIFICATION_MODELS_SCHEMA);
  assert.equal(verificationModelForAgent("codex"), "gpt-5.3-codex-spark");
  assert.equal(verificationModelForAgent("cursor"), "composer-2.5");
  assert.equal(
    verificationModelForAgent("antigravity"),
    "gemini-3.7-flash-medium",
  );
  assert.equal(verificationModelForAgent("missing-agent"), "");
  assert.equal(typeof verificationModelsMap().cursor, "string");
});
