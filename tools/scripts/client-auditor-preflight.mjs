#!/usr/bin/env node

import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promotionRequiredStatusContexts } from "./repository-rulesets.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const expectedChecks = Object.freeze([
  [".github/workflows/branch-flow.yml", "Branch flow", "Branch flow"],
  [".github/workflows/commit-identity.yml", "Commit identity", "Commit identity"],
  [".github/workflows/client-ci.yml", null, "Client required"],
  [".github/workflows/client-stable.yml", "Stable client", "Stable client"],
  [".github/workflows/client-release-ready.yml", "Release ready", "Release ready"],
  [".github/workflows/lico-auditor-gate.yml", "Auditor", "Auditor"],
]);

function requireValue(value, code) { if (!value) throw new Error(code); }

function workflowName(source) {
  return /^name:\s*([^\r\n]+)$/mu.exec(source)?.[1]?.trim() || "";
}

function hasExactJobName(source, jobName) {
  return new RegExp(`^\\s{4}name:\\s*["']?${jobName.replace(/[.*+?^${}()|[\]\\]/gu,
    "\\$&")}["']?\\s*$`, "mu").test(source);
}

export function validateGovernanceDeclarations(files) {
  for (const [file, expectedWorkflow, expectedJob] of expectedChecks) {
    const source = files[file];
    requireValue(typeof source === "string", "audit_workflow_binding_invalid");
    if (expectedWorkflow) {
      requireValue(workflowName(source) === expectedWorkflow,
        "audit_required_checks_mismatch");
    }
    requireValue(hasExactJobName(source, expectedJob),
      expectedJob === "Auditor"
        ? "audit_required_check_auditor_missing" : "audit_required_checks_mismatch");
  }
  requireValue(JSON.stringify(promotionRequiredStatusContexts) === JSON.stringify({
    nightly: ["Branch flow", "Commit identity", "Client required", "Auditor"],
    stable: ["Branch flow", "Commit identity", "Stable client", "Auditor"],
    release: ["Branch flow", "Commit identity", "Release ready", "Auditor"],
  }),
  "audit_required_checks_mismatch");
  const config = JSON.parse(
    files["tools/apple-release/macos-direct-arm64.json"] || "null",
  );
  const candidate = config?.candidate;
  const updateManifestArtifact = Array.isArray(config?.artifacts)
    ? config.artifacts.filter((entry) => entry?.role === "update-manifest")
    : [];
  requireValue(
    config?.schema === "apple-release.config.v1" &&
      config?.source?.branch === "release" &&
      candidate?.branch === "macos-release-candidate" &&
      Array.isArray(candidate?.requiredChecks) && candidate.requiredChecks.length > 0 &&
      config?.github?.repository === "LicoLand/LicoUp" &&
      config?.apple?.target === "macos-direct-arm64" &&
      Array.isArray(config?.update?.command) && config.update.command.length > 0 &&
      updateManifestArtifact.length === 1 &&
      updateManifestArtifact[0]?.publicName === "LicoUp-update-manifest.json",
    "audit_release_service_contract_invalid",
  );
  return true;
}

function main() {
  requireValue(process.argv.length === 2, "audit_argument_invalid");
  const paths = [
    ...expectedChecks.map(([file]) => file),
    "tools/apple-release/macos-direct-arm64.json",
  ];
  validateGovernanceDeclarations(Object.fromEntries(paths.map((file) => [
    file, readFileSync(path.join(repoRoot, file), "utf8"),
  ])));
  process.stdout.write(`${JSON.stringify({ ok: true, workflowBindingReady: true,
    statusBindingReady: true, requiredChecksReady: true,
    delegatedApplePublicationReady: true, remoteMutationExecuted: false,
    privateDataIncluded: false })}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(); } catch (error) {
    const code = /^audit_[a-z0-9_]+$/u.test(String(error?.message || ""))
      ? error.message : "audit_auditor_failed";
    process.stderr.write(`${JSON.stringify({ ok: false, code,
      remoteMutationExecuted: false, privateDataIncluded: false })}\n`);
    process.exitCode = 1;
  }
}
