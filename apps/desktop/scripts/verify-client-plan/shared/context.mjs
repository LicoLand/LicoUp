import path from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = path.resolve(
  fileURLToPath(new URL("../../../../..", import.meta.url)),
);

export const releaseBoundarySelfTestScripts = [
  "client:verify:release-artifact-io:self-test",
  "client:verify:source-state-digest:self-test",
  "client:verify:linux-tar-resource-bounds:self-test",
  "client:verify:review-signoff:self-test",
];
export const requiredClientScripts = [
  "repo:client-boundary",
  "repo:local-info-hygiene",
  "repo:local-info-hygiene:self-test",
  "repo:workspace-cache-boundary",
  "client:gate:topology",
  "client:gate:self-test",
  "client:gate:plan",
  "client:gate:source",
  "client:gate:flutter",
  "client:gate:dependencies",
  "client:gate:release-policy",
  "client:version:check",
  "client:version:sync",
  "client:support-matrix:check",
  "client:support-matrix:sync",
  "client:verify:architecture",
  ...releaseBoundarySelfTestScripts,
  "client:verify:plan",
  "client:contracts:test",
  "client:verify:update-release",
  "client:cli:vm:list",
  "client:cli:vm:prepare",
  "client:cli:vm:linux-product-bootstrap",
  "client:cli:vm:linux-product",
  "client:verify:macos-bundle"
];
export const shellModules = ["Agents", "Token Usage", "Skill Hub", "Devices", "Settings"];

export function formatAdapterReadinessSummary(adapterReadiness) {
  const summary = adapterReadiness?.summary || {};
  return `${summary.ready} ready / ${summary.failed} failed / ${summary.blocked} blocked / ${summary.unverified} unverified`;
}

export async function createPlanContext() {
  return Object.freeze({
    repoRoot,
    releaseBoundarySelfTestScripts,
    requiredClientScripts,
    shellModules,
    formatAdapterReadinessSummary,
  });
}
