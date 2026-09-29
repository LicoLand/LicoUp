import assert from "node:assert/strict";
import test from "node:test";
import {
  VERIFICATION_MODELS_SCHEMA,
  loadVerificationModels,
  parseVerificationModelsToml,
  verificationEffortForAgent,
  verificationModelForAgent,
  verificationProviderForAgent,
  verificationModelsMap,
} from "./agent-conversation-verification-models.mjs";
import {
  parityEffortForAgent,
  parityModelForAgent,
} from "../../../tests/product-e2e/cli/agent-conversations/support/parity/agent-ids.mjs";

test("parseVerificationModelsToml accepts the maintained config shape", () => {
  const parsed = parseVerificationModelsToml(`
schema_version = "${VERIFICATION_MODELS_SCHEMA}"

[models]
cursor = "composer-2.5"
"claude-code" = "haiku"
codex = "gpt-6-luna"
"deepseek-harness" = "deepseek-flash"

[providers]
"deepseek-harness" = "deepseek-official"

[reasoning_efforts]
codex = "low"
"deepseek-harness" = "low"
`);
  assert.equal(parsed.schemaVersion, VERIFICATION_MODELS_SCHEMA);
  assert.deepEqual(parsed, {
    schemaVersion: VERIFICATION_MODELS_SCHEMA,
    models: {
      cursor: "composer-2.5",
      "claude-code": "haiku",
      codex: "gpt-6-luna",
      "deepseek-harness": "deepseek-flash",
    },
    providers: { "deepseek-harness": "deepseek-official" },
    reasoningEfforts: {
      codex: "low",
      "deepseek-harness": "low",
    },
  });
  assert.throws(
    () => parseVerificationModelsToml(`
schema_version = "${VERIFICATION_MODELS_SCHEMA}"
[providers]
deepseek-harness = "deepseek-official"
[models]
cursor = "composer-2.5"
`),
    /verification_models_selector_unconfigured:deepseek-harness/u,
  );
});

test("loadVerificationModels loads the repo config once", () => {
  const first = loadVerificationModels({ reload: true });
  const second = loadVerificationModels();
  assert.equal(first, second);
  assert.equal(first.schemaVersion, VERIFICATION_MODELS_SCHEMA);
  assert.equal(verificationModelForAgent("codex"), "gpt-6-luna");
  assert.equal(verificationModelForAgent("cursor"), "composer-2.5");
  assert.equal(
    verificationModelForAgent("antigravity"),
    "gemini-3.8-flash-low",
  );
  assert.equal(verificationModelForAgent("deepseek-harness"), "deepseek-flash");
  assert.equal(verificationProviderForAgent("deepseek-harness"), "deepseek-official");
  assert.equal(verificationProviderForAgent("codex"), "");
  assert.equal(verificationModelForAgent("missing-agent"), "");
  assert.deepEqual(verificationModelsMap(), {
    "claude-code": "haiku",
    antigravity: "gemini-3.8-flash-low",
    codex: "gpt-6-luna",
    cursor: "composer-2.5",
    "deepseek-harness": "deepseek-flash",
    "kimi-code": "kimi-code/kimi-for-coding",
    "kilo-code": "Kilo Auto Free",
  });
});

test("verification effort is paired with the recorded verification model", () => {
  assert.equal(verificationEffortForAgent("codex", "gpt-6-luna"), "low");
  assert.equal(verificationEffortForAgent("codex", "gpt-5.3-codex-spark"), "");
  assert.equal(verificationEffortForAgent("codex", ""), "");
  assert.equal(verificationEffortForAgent("cursor", "composer-2.5"), "");
  assert.equal(verificationEffortForAgent("antigravity", "gemini-3.8-flash-low"), "");
  assert.equal(verificationEffortForAgent("deepseek-harness", "deepseek-flash"), "low");
  assert.equal(verificationEffortForAgent("deepseek-harness", "other-model"), "");
  assert.equal(verificationEffortForAgent("", "gpt-6-luna"), "");
});

test("inherited model and effort overrides cannot raise live verification cost", () => {
  const keys = ["LICO_CODEX_PARITY_MODEL", "LICO_CODEX_PARITY_REASONING_EFFORT"];
  const previous = keys.map((key) => process.env[key]);
  try {
    process.env[keys[0]] = "synthetic-expensive-model";
    process.env[keys[1]] = "max";
    const model = parityModelForAgent("codex");
    assert.equal(model, verificationModelForAgent("codex"));
    assert.equal(parityEffortForAgent("codex", model), "low");
    assert.throws(() => parityModelForAgent("missing-agent"), /verification_model_unconfigured/u);
  } finally {
    keys.forEach((key, index) => {
      if (previous[index] === undefined) delete process.env[key];
      else process.env[key] = previous[index];
    });
  }
});
