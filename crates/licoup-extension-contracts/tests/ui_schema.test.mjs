import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import Ajv2020 from "ajv/dist/2020.js";

const schema = JSON.parse(fs.readFileSync(
  new URL("../../../schemas/extensions/ui.schema.json", import.meta.url),
  "utf8",
));

function validator() {
  return new Ajv2020({ strict: true, allErrors: true }).compile(schema);
}

const base = {
  schema: "licoup.ui-contribution.v1",
  id: "example.ui.panel",
  title: "Synthetic panel",
};

test("the published UI schema compiles in strict mode", () => {
  assert.equal(typeof validator(), "function");
});

test("existing primitives and versioned resource views remain declarable", () => {
  const validate = validator();
  for (const contribution of [
    { ...base, kind: "settings", fields: [{ id: "auth", label: "Credential", type: "secret-ref" }] },
    { ...base, kind: "command", actionRef: "example.action.run" },
    { ...base, kind: "navigation" },
    { ...base, kind: "metric-panel", series: [{ metric: "example.metric.latency", label: "Latency", unit: "ms" }] },
    { ...base, kind: "resource-view", resourceRef: "example.resource.graph", resourceFormat: "licoup.ui.graph-resource.v1" },
    // Unknown formats remain data; actual host capability decides mounting.
    { ...base, kind: "resource-view", resourceFormat: "example.future-format.v2" },
  ]) assert.equal(validate(contribution), true, JSON.stringify(validate.errors));
});

test("only resource views may request a resource format", () => {
  const validate = validator();
  for (const kind of ["settings", "command", "navigation", "metric-panel"]) {
    const contribution = {
      ...base, kind, resourceFormat: "licoup.ui.graph-resource.v1",
      ...(kind === "metric-panel" ? {
        series: [{ metric: "example.metric.latency", label: "Latency", unit: "ms" }],
      } : {}),
    };
    assert.equal(validate(contribution), false, `${kind} accepted a resource format`);
  }
  assert.equal(validate({ ...base, kind: "resource-view", resourceFormat: "unnamespaced" }), false);
});

test("secret values, executable fields and invalid metric shapes are refused", () => {
  const validate = validator();
  for (const contribution of [
    { ...base, kind: "settings", fields: [{ id: "auth", label: "Credential", type: "secret-ref", value: "synthetic-value" }] },
    { ...base, kind: "resource-view", handler: "synthetic-handler" },
    { ...base, kind: "metric-panel" },
    { ...base, kind: "metric-panel", series: [] },
    { ...base, kind: "metric-panel", series: {} },
    { ...base, kind: "command", series: [{ metric: "example.metric.latency", label: "Latency", unit: "ms" }] },
  ]) assert.equal(validate(contribution), false, JSON.stringify(contribution));
});
