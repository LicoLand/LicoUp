#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import { createPlanAssertions } from "./shared/assert.mjs";
import { createPlanContext } from "./shared/context.mjs";
import { createPlanFileReader } from "./shared/fs.mjs";
import { sanitizePlanDiagnostic } from "./shared/sanitize.mjs";

export const DYNAMIC_SELF_TEST_IDS = Object.freeze([
  "contract-binding",
  "scope-authority",
  "authority-proof",
]);

function requestedSelfTests(argv) {
  if (argv.length === 0 || argv.includes("--all")) {
    return new Set(DYNAMIC_SELF_TEST_IDS);
  }
  const selected = new Set();
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== "--check" || !argv[index + 1]) {
      throw new Error("usage: dynamic-self-tests.mjs [--all | --check <id> ...]");
    }
    for (const id of argv[index + 1].split(",")) {
      selected.add(id.trim());
    }
    index += 1;
  }
  for (const id of selected) {
    if (!DYNAMIC_SELF_TEST_IDS.includes(id)) {
      throw new Error(`unknown dynamic self-test: ${id}`);
    }
  }
  return selected;
}

export async function runDynamicSelfTests(selected) {
  const context = await createPlanContext();
  const { repoRoot, secureClientContract } = context;
  const { readJson } = createPlanFileReader(repoRoot);
  const { assert, getFailures } = createPlanAssertions();

  if (selected.has("contract-binding")) {
const bindingCheck = spawnSync(process.execPath, [
  "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs",
  "--contract-binding-check"
], {
  cwd: repoRoot,
  env: process.env,
  encoding: "utf8",
  shell: false
});
assert(bindingCheck.status === 0,
  `secure mesh evidence bundle generator contract-binding check failed: ${sanitizePlanDiagnostic(bindingCheck.stderr || bindingCheck.stdout)}`);
let bindingCheckReport = {};
try {
  bindingCheckReport = JSON.parse(bindingCheck.stdout || "{}");
} catch (error) {
  assert(false, `secure mesh contract-binding check did not emit JSON: ${sanitizePlanDiagnostic(error)}`);
}
assert(bindingCheckReport.ok === true, "secure mesh contract-binding check must return ok=true");
assert(typeof bindingCheckReport.sourceOfTruth === "string" && bindingCheckReport.sourceOfTruth.length > 0,
  "secure mesh contract-binding check must identify a source of truth");
assert(typeof bindingCheckReport.evidenceRefReportSchemaVersion === "string" &&
  bindingCheckReport.evidenceRefReportSchemaVersion.length > 0,
  "secure mesh contract-binding check must identify the evidence ref report schema");
assert(typeof bindingCheckReport.authorityProofTemplateRef === "string" &&
  bindingCheckReport.authorityProofTemplateRef.length > 0,
  "secure mesh contract-binding check must identify the configured authority-proof template ref");
assert(Number(bindingCheckReport.evidenceRouteMissingCount || 0) === 0,
  "secure mesh evidence route plan must cover every contract blocker");
  }
  if (selected.has("scope-authority")) {
const scopeSelfTestModule = await import(pathToFileURL(
  path.join(repoRoot, "tools/scripts/lib/secure-client-mesh-e2ee-ref-report.mjs")
).href);
assert(typeof scopeSelfTestModule.verifySecureClientMeshE2eeRefReportScopeSelfTest === "function",
  "secure mesh scope helper must expose a per-claim authority self-test");
const scopeSelfTestReport = await scopeSelfTestModule.verifySecureClientMeshE2eeRefReportScopeSelfTest({
  contract: secureClientContract
});
assert(scopeSelfTestReport.ok === true &&
  scopeSelfTestReport.perClaimAuthoritiesAccepted === true &&
  scopeSelfTestReport.completeRequiredClaimSetEnforced === true &&
  scopeSelfTestReport.scopeEvidenceFreshUntilEmitted === true &&
  scopeSelfTestReport.independentAuditClaimRejectsExternalClient === true &&
  scopeSelfTestReport.injectedScopeConfigSchemaGuarded === true,
  "secure mesh scope helper must accept per-claim authorities, enforce complete required claim sets, emit scope freshUntil, reject external-client authority for independent audit claims, and schema-check injected configs");
  }
  if (selected.has("authority-proof")) {
const authorityProofSelfTest = spawnSync(process.execPath, [
  "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs",
  "--authority-proof-self-test"
], {
  cwd: repoRoot,
  env: process.env,
  encoding: "utf8",
  shell: false
});
assert(authorityProofSelfTest.status === 0,
  `secure mesh evidence bundle authority-proof self-test failed: ${sanitizePlanDiagnostic(authorityProofSelfTest.stderr || authorityProofSelfTest.stdout)}`);
let authorityProofSelfTestReport = {};
try {
  authorityProofSelfTestReport = JSON.parse(authorityProofSelfTest.stdout || "{}");
} catch (error) {
  assert(false, `secure mesh authority-proof self-test did not emit JSON: ${sanitizePlanDiagnostic(error)}`);
}
assert(authorityProofSelfTestReport.ok === true &&
  authorityProofSelfTestReport.validSignedFixtureAccepted === true &&
  authorityProofSelfTestReport.tamperedSignedFixtureRejected === true &&
  authorityProofSelfTestReport.privateKeyTrustRootRejected === true &&
  authorityProofSelfTestReport.inTreeTrustRootRejected === true,
  "secure mesh authority-proof self-test must accept valid signatures and reject tampered reports, private-key trust roots, and in-tree trust roots");
const authorityProofTemplateRef = "build/tmp/secure-mesh-authority-proof-template-plan-self-test.json";
const authorityProofTemplate = spawnSync(process.execPath, [
  "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs",
  "--generate-authority-proof-template",
  "--authority-proof-template",
  authorityProofTemplateRef
], {
  cwd: repoRoot,
  env: process.env,
  encoding: "utf8",
  shell: false
});
assert(authorityProofTemplate.status === 0,
  `secure mesh evidence bundle authority-proof template generation failed: ${sanitizePlanDiagnostic(authorityProofTemplate.stderr || authorityProofTemplate.stdout)}`);
let authorityProofTemplateReport = {};
try {
  authorityProofTemplateReport = JSON.parse(authorityProofTemplate.stdout || "{}");
} catch (error) {
  assert(false, `secure mesh authority-proof template generator did not emit JSON: ${sanitizePlanDiagnostic(error)}`);
}
const authorityProofTemplatePayload = await readJson(authorityProofTemplateRef);
assert(authorityProofTemplateReport.ok === true &&
  authorityProofTemplateReport.authorityProofTemplateWritten === true &&
  authorityProofTemplateReport.report === authorityProofTemplateRef &&
  authorityProofTemplateReport.productionReadyClaimed === false &&
  authorityProofTemplatePayload.schemaVersion === "licolite.secure-mesh.e2ee-authority-proof-template.v1" &&
  authorityProofTemplatePayload.redacted === true &&
  authorityProofTemplatePayload.productionReadyClaimed === false &&
  authorityProofTemplatePayload.rawPrivateMaterialIncluded === false &&
  authorityProofTemplatePayload.rawPlaintextIncluded === false &&
  authorityProofTemplatePayload.rawPublicWireBytesIncluded === false &&
  authorityProofTemplatePayload.authorityTrustRoot?.privateKeyIncluded === false &&
  Array.isArray(authorityProofTemplatePayload.evidenceRefs) &&
  authorityProofTemplatePayload.evidenceRefs.every((entry) =>
    entry.exists !== true || /^sha256:[a-f0-9]{64}$/u.test(String(entry.evidenceRefDigest || ""))
  ) &&
  authorityProofTemplatePayload.evidenceRefs.every((entry) =>
    entry.readyForSigning !== true ||
      (entry.hasAuthorityProof === false &&
        /^sha256:[a-f0-9]{64}$/u.test(String(entry.authorityProofPayloadDigest || "")) &&
        entry.authorityProofTemplate?.privateKeyIncluded !== true)
  ) &&
  authorityProofTemplatePayload.evidenceRefs.some((entry) =>
    entry.readyForSigning === false && entry.authorityProofTemplate === null
  ),
  "secure mesh authority-proof template generator must write a redacted non-ready template with digest-bound external evidence refs, no private key material, and no ready-for-signing flag on incomplete reports");

  }

  const failures = getFailures().map(sanitizePlanDiagnostic);
  return Object.freeze({
    ok: failures.length === 0,
    selected: [...selected],
    failures,
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const report = await runDynamicSelfTests(requestedSelfTests(process.argv.slice(2)));
    if (!report.ok) {
      console.error(JSON.stringify(report, null, 2));
      process.exit(1);
    }
    console.log(JSON.stringify(report, null, 2));
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      failures: [sanitizePlanDiagnostic(error)],
    }, null, 2));
    process.exit(1);
  }
}
