#!/usr/bin/env node
import process from "node:process";
import {
  CLIENT_GATE_LANES,
  CLIENT_GATE_SCHEMA_VERSION,
} from "../../../tools/scripts/client-gate-policy.mjs";
import { createPlanAssertions } from "./verify-client-plan/shared/assert.mjs";
import { createPlanContext } from "./verify-client-plan/shared/context.mjs";
import { createPlanFileReader } from "./verify-client-plan/shared/fs.mjs";
import { sanitizePlanDiagnostic } from "./verify-client-plan/shared/sanitize.mjs";
import { checkPackageAndRunner } from "./verify-client-plan/checks/package-and-runner.mjs";
import { checkClientBoundary } from "./verify-client-plan/checks/client-boundary.mjs";
import { checkDocsReadiness } from "./verify-client-plan/checks/docs-readiness.mjs";

const STATIC_PLAN_CHECKS = Object.freeze([
  ["package-and-runner", checkPackageAndRunner],
  ["client-boundary", checkClientBoundary],
  ["docs-readiness", checkDocsReadiness],
]);

const context = await createPlanContext();
const files = createPlanFileReader(context.repoRoot);
const { assert, getFailures } = createPlanAssertions();
let docsReadiness = Object.freeze({ targets: [], adapterCount: 0 });

for (const [checkId, check] of STATIC_PLAN_CHECKS) {
  try {
    const result = await check({ assert, files, context });
    if (checkId === "docs-readiness" && result) {
      docsReadiness = result;
    }
  } catch (error) {
    assert(false, `${checkId} check failed: ${sanitizePlanDiagnostic(error)}`);
  }
}

const failures = getFailures().map(sanitizePlanDiagnostic);
if (failures.length > 0) {
  console.error(JSON.stringify({ ok: false, failures }, null, 2));
  process.exit(1);
}

console.log(JSON.stringify({
  ok: true,
  gatePolicy: {
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    lanes: Object.keys(CLIENT_GATE_LANES),
  },
  targets: docsReadiness.targets,
  modules: context.shellModules,
  adapterCount: docsReadiness.adapterCount,
}, null, 2));
