import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import Ajv2020 from "ajv/dist/2020.js";

const schemaUrl = new URL(
  "../../../packages/contracts/client/agent-orchestration-policy.schema.json",
  import.meta.url,
);

const clone = (value) => structuredClone(value);
const long = (length) => "x".repeat(length);

function validPolicy() {
  return {
    schemaVersion: 3,
    id: "synthetic-policy",
    label: "Synthetic policy",
    commander: {
      agentId: "synthetic-agent-0",
      modelId: "synthetic-model-0",
      reasoningLevel: "max",
    },
    modelLibrary: [
      {
        agentId: "synthetic-agent-1",
        modelId: "synthetic-model-1",
        reasoningLevel: "low",
      },
    ],
    agents: [
      {
        id: "synthetic-agent-1",
        roles: ["synthetic-role"],
        capabilities: ["synthetic-capability"],
      },
    ],
    workflow: {
      steps: [
        {
          id: "prepare",
          predecessorId: null,
          purpose: "action",
          roleId: "synthetic-role-a",
          agentId: "synthetic-agent-1",
          modelId: "synthetic-model-1",
          reasoningLevel: "max",
          contextStepIds: [],
          maxContextBytes: 262144,
          outputMode: "json",
          timeoutMs: 86400000,
          maxAttempts: 16,
          failureAction: "stop",
          approval: { required: true },
          condition: null,
          validation: null,
        },
        {
          id: "verify",
          predecessorId: "prepare",
          purpose: "validation",
          roleId: "synthetic-role-b",
          agentId: "synthetic-agent-1",
          modelId: "synthetic-model-1",
          reasoningLevel: "low",
          contextStepIds: ["prepare"],
          maxContextBytes: 1,
          outputMode: "text",
          timeoutMs: 1,
          maxAttempts: 1,
          failureAction: "continue",
          approval: { required: false },
          condition: {
            sourceStepId: "prepare",
            pointer: "/result/enabled",
            operator: "equals",
            value: true,
          },
          validation: {
            mode: "requiredPass",
            evidenceKinds: ["tests", "review"],
          },
        },
      ],
    },
  };
}

function compile(schema) {
  return new Ajv2020({
    allErrors: true,
    strict: true,
    strictRequired: true,
    validateFormats: true,
  }).compile(schema);
}

function assertInvalid(validate, sample, label) {
  assert.equal(validate(sample), false, `${label} unexpectedly passed schema validation`);
  assert.ok(validate.errors?.length, `${label} did not produce a structured Ajv error`);
}

test("agent orchestration policy schema compiles strictly and accepts only the closed canonical shape", async () => {
  const schema = JSON.parse(await readFile(schemaUrl, "utf8"));
  assert.equal(schema.$schema, "https://json-schema.org/draft/2020-12/schema");
  const validate = compile(schema);
  assert.equal(validate(validPolicy()), true, JSON.stringify(validate.errors));

  const empty = validPolicy();
  empty.commander = null;
  empty.modelLibrary = [];
  empty.agents = [];
  empty.workflow.steps = [];
  assert.equal(validate(empty), true, JSON.stringify(validate.errors));

  const unknownCases = [
    [[], "unknownTop"],
    [["commander"], "unknownCommander"],
    [["modelLibrary", 0], "unknownModel"],
    [["agents", 0], "unknownAgent"],
    [["workflow"], "unknownWorkflow"],
    [["workflow", "steps", 0], "unknownStep"],
    [["workflow", "steps", 0, "approval"], "unknownApproval"],
    [["workflow", "steps", 1, "condition"], "unknownCondition"],
    [["workflow", "steps", 1, "validation"], "unknownValidation"],
  ];
  for (const [path, field] of unknownCases) {
    const sample = validPolicy();
    let target = sample;
    for (const segment of path) target = target[segment];
    target[field] = true;
    assertInvalid(validate, sample, `unknown field ${field}`);
  }

  const requiredObjects = [
    [[], ["schemaVersion", "id", "label", "commander", "modelLibrary", "agents", "workflow"]],
    [["commander"], ["agentId", "modelId", "reasoningLevel"]],
    [["modelLibrary", 0], ["agentId", "modelId", "reasoningLevel"]],
    [["agents", 0], ["id", "roles", "capabilities"]],
    [["workflow"], ["steps"]],
    [["workflow", "steps", 0], [
      "id", "predecessorId", "purpose", "roleId", "agentId", "modelId", "reasoningLevel",
      "contextStepIds", "maxContextBytes", "outputMode", "timeoutMs", "maxAttempts",
      "failureAction", "approval", "condition", "validation",
    ]],
    [["workflow", "steps", 0, "approval"], ["required"]],
    [["workflow", "steps", 1, "condition"], ["sourceStepId", "pointer", "operator", "value"]],
    [["workflow", "steps", 1, "validation"], ["mode", "evidenceKinds"]],
  ];
  for (const [path, required] of requiredObjects) {
    for (const field of required) {
      const sample = validPolicy();
      let target = sample;
      for (const segment of path) target = target[segment];
      delete target[field];
      assertInvalid(validate, sample, `missing ${path.join(".") || "root"}.${field}`);
    }
  }
  const wrongNestedTypes = [
    ["commander", (p) => { p.commander = []; }],
    ["model library entry", (p) => { p.modelLibrary[0] = true; }],
    ["agent entry", (p) => { p.agents[0] = "agent"; }],
    ["workflow", (p) => { p.workflow = []; }],
    ["workflow step", (p) => { p.workflow.steps[0] = "step"; }],
    ["approval", (p) => { p.workflow.steps[0].approval = false; }],
    ["condition", (p) => { p.workflow.steps[1].condition = "condition"; }],
    ["validation", (p) => { p.workflow.steps[1].validation = []; }],
  ];
  for (const [label, mutate] of wrongNestedTypes) {
    const sample = validPolicy();
    mutate(sample);
    assertInvalid(validate, sample, `wrong nested type ${label}`);
  }
});

test("agent orchestration policy schema enforces every enum and scalar bound", async () => {
  const validate = compile(JSON.parse(await readFile(schemaUrl, "utf8")));
  for (const [path, values] of [
    [["commander", "reasoningLevel"], [null, "low", "medium", "high", "max"]],
    [["workflow", "steps", 0, "reasoningLevel"], [null, "low", "medium", "high", "max"]],
    [["workflow", "steps", 0, "purpose"], ["action", "validation"]],
    [["workflow", "steps", 0, "outputMode"], ["text", "json"]],
    [["workflow", "steps", 0, "failureAction"], ["stop", "continue"]],
    [["workflow", "steps", 1, "condition", "operator"], ["exists", "equals", "contains"]],
  ]) {
    for (const value of values) {
      const sample = validPolicy();
      let target = sample;
      for (const segment of path.slice(0, -1)) target = target[segment];
      target[path.at(-1)] = value;
      if (path.at(-1) === "purpose") {
        sample.workflow.steps[0].validation = value === "validation"
          ? { mode: "requiredPass", evidenceKinds: ["tests"] }
          : null;
      }
      assert.equal(validate(sample), true, `${path.join(".")}=${value}: ${JSON.stringify(validate.errors)}`);
    }
  }
  const mutations = [
    ["schema version", (p) => { p.schemaVersion = 4; }],
    ["empty policy id", (p) => { p.id = ""; }],
    ["policy id maximum", (p) => { p.id = long(129); }],
    ["label maximum", (p) => { p.label = long(257); }],
    ["empty commander agent", (p) => { p.commander.agentId = ""; }],
    ["empty commander model", (p) => { p.commander.modelId = ""; }],
    ["commander agent maximum", (p) => { p.commander.agentId = long(257); }],
    ["commander model maximum", (p) => { p.commander.modelId = long(257); }],
    ["reasoning enum", (p) => { p.commander.reasoningLevel = "arbitrary"; }],
    ["agent id maximum", (p) => { p.agents[0].id = long(257); }],
    ["empty agent id", (p) => { p.agents[0].id = ""; }],
    ["agent role maximum", (p) => { p.agents[0].roles[0] = long(129); }],
    ["empty agent role", (p) => { p.agents[0].roles[0] = ""; }],
    ["capability maximum", (p) => { p.agents[0].capabilities[0] = long(129); }],
    ["empty capability", (p) => { p.agents[0].capabilities[0] = ""; }],
    ["step id maximum", (p) => { p.workflow.steps[0].id = long(129); }],
    ["empty step id", (p) => { p.workflow.steps[0].id = ""; }],
    ["predecessor maximum", (p) => { p.workflow.steps[1].predecessorId = long(129); }],
    ["empty predecessor", (p) => { p.workflow.steps[1].predecessorId = ""; }],
    ["step role maximum", (p) => { p.workflow.steps[0].roleId = long(129); }],
    ["empty step role", (p) => { p.workflow.steps[0].roleId = ""; }],
    ["step agent maximum", (p) => { p.workflow.steps[0].agentId = long(257); }],
    ["empty step agent", (p) => { p.workflow.steps[0].agentId = ""; }],
    ["step model maximum", (p) => { p.workflow.steps[0].modelId = long(257); }],
    ["empty step model", (p) => { p.workflow.steps[0].modelId = ""; }],
    ["step reasoning enum", (p) => { p.workflow.steps[0].reasoningLevel = "arbitrary"; }],
    ["purpose enum", (p) => { p.workflow.steps[0].purpose = "parallel"; }],
    ["output enum", (p) => { p.workflow.steps[0].outputMode = "binary"; }],
    ["failure enum", (p) => { p.workflow.steps[0].failureAction = "fallback"; }],
    ["condition operator enum", (p) => { p.workflow.steps[1].condition.operator = "execute"; }],
    ["condition pointer maximum", (p) => { p.workflow.steps[1].condition.pointer = `/${long(2048)}`; }],
    ["condition pointer syntax", (p) => { p.workflow.steps[1].condition.pointer = "not-a-pointer"; }],
    ["condition source maximum", (p) => { p.workflow.steps[1].condition.sourceStepId = long(129); }],
    ["empty condition source", (p) => { p.workflow.steps[1].condition.sourceStepId = ""; }],
    ["condition pointer segments", (p) => { p.workflow.steps[1].condition.pointer = `/${Array.from({ length: 65 }, () => "x").join("/")}`; }],
    ["empty context reference", (p) => { p.workflow.steps[1].contextStepIds[0] = ""; }],
    ["context lower bound", (p) => { p.workflow.steps[0].maxContextBytes = 0; }],
    ["context upper bound", (p) => { p.workflow.steps[0].maxContextBytes = 262145; }],
    ["timeout lower bound", (p) => { p.workflow.steps[0].timeoutMs = 0; }],
    ["timeout upper bound", (p) => { p.workflow.steps[0].timeoutMs = 86400001; }],
    ["attempt lower bound", (p) => { p.workflow.steps[0].maxAttempts = 0; }],
    ["attempt upper bound", (p) => { p.workflow.steps[0].maxAttempts = 17; }],
    ["validation mode enum", (p) => { p.workflow.steps[1].validation.mode = "replyPresent"; }],
    ["evidence kind maximum", (p) => { p.workflow.steps[1].validation.evidenceKinds[0] = long(65); }],
    ["empty evidence kind", (p) => { p.workflow.steps[1].validation.evidenceKinds[0] = ""; }],
  ];
  for (const [label, mutate] of mutations) {
    const sample = validPolicy();
    mutate(sample);
    assertInvalid(validate, sample, label);
  }
});

test("agent orchestration policy schema enforces every array and nested-value bound", async () => {
  const validate = compile(JSON.parse(await readFile(schemaUrl, "utf8")));
  const cases = [
    ["model library", (p) => { p.modelLibrary = Array.from({ length: 257 }, () => clone(p.modelLibrary[0])); }],
    ["agents", (p) => { p.agents = Array.from({ length: 257 }, () => clone(p.agents[0])); }],
    ["roles", (p) => { p.agents[0].roles = Array.from({ length: 257 }, (_, i) => `role-${i}`); }],
    ["capabilities", (p) => { p.agents[0].capabilities = Array.from({ length: 257 }, (_, i) => `cap-${i}`); }],
    ["steps", (p) => { p.workflow.steps = Array.from({ length: 4097 }, (_, i) => ({ ...clone(p.workflow.steps[0]), id: `step-${i}` })); }],
    ["context refs", (p) => { p.workflow.steps[1].contextStepIds = Array.from({ length: 257 }, (_, i) => `step-${i}`); }],
    ["duplicate context refs", (p) => { p.workflow.steps[1].contextStepIds = ["prepare", "prepare"]; }],
    ["evidence kinds", (p) => { p.workflow.steps[1].validation.evidenceKinds = Array.from({ length: 65 }, (_, i) => `kind-${i}`); }],
    ["empty evidence kinds", (p) => { p.workflow.steps[1].validation.evidenceKinds = []; }],
    ["duplicate evidence kinds", (p) => { p.workflow.steps[1].validation.evidenceKinds = ["tests", "tests"]; }],
    ["condition value bytes", (p) => { p.workflow.steps[1].condition.value = long(4097); }],
  ];
  for (const [label, mutate] of cases) {
    const sample = validPolicy();
    mutate(sample);
    assertInvalid(validate, sample, label);
  }
});
