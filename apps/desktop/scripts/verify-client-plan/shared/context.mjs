import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadSecureClientContract } from "../../../../../tools/scripts/lib/secure-client-contract.mjs";

export const repoRoot = path.resolve(
  fileURLToPath(new URL("../../../../..", import.meta.url)),
);

export const releaseBoundarySelfTestScripts = [
  "client:verify:release-artifact-io:self-test",
  "client:verify:source-state-digest:self-test",
  "client:verify:linux-tar-resource-bounds:self-test",
  "client:verify:android-apk-zip-facts:self-test",
  "client:verify:android-release-toolchain:self-test",
  "client:verify:review-signoff:self-test",
  "client:verify:release-target-evidence:self-test",
];
export const requiredVerifierScripts = [
  "repo:client-boundary",
  "repo:local-info-hygiene",
  "repo:local-info-hygiene:self-test",
  "repo:workspace-cache-boundary",
  "client:verify",
  "client:verify:source",
  "client:version:check",
  "client:version:sync",
  "client:support-matrix:check",
  "client:support-matrix:sync",
  "client:verify:architecture",
  "client:verify:local-data-egress-boundary",
  ...releaseBoundarySelfTestScripts,
  "client:verify:agent-conversation-parity",
  "client:verify:plan",
  "client:contracts:test",
  "client:native:smoke",
  "client:verify:update-release",
  "client:verify:windows-file-security",
  "client:cli:vm:list",
  "client:cli:vm:prepare",
  "client:cli:vm:verify",
  "client:cli:vm:linux-product-bootstrap",
  "client:cli:vm:linux-product",
  "client:verify:agent-usage",
  "client:verify:android-physical-install-launch",
  "client:test:android:native",
  "client:verify:secure-client-relay-mock-e2e",
  "client:verify:secure-mesh-pairwise-content-audit",
  "client:verify:secure-mesh-platform-secret-store-matrix",
  "client:verify:secure-mesh-physical-device-matrix",
  "client:verify:secure-mesh-encrypted-file-handoff",
  "client:verify:secure-mesh-acp-relay-governed-baseline",
  "client:verify:secure-mesh-acp-archive-release-proof",
  "client:verify:secure-mesh-trust-ux:self-test",
  "client:verify:secure-mesh-trust-ux",
  "client:verify:secure-mesh-report-redaction",
  "client:verify:secure-mesh-report-redaction:self-test",
  "client:verify:secure-mesh-release-proof-bundle",
  "client:verify:secure-mesh-e2ee-evidence:contract-binding",
  "client:verify:secure-mesh-e2ee-evidence:authority-proof-self-test",
  "client:verify:secure-mesh-e2ee-evidence:readiness-self-test",
  "client:verify:secure-mesh-e2ee-evidence:leak-scan-self-test",
  "client:verify:secure-mesh-e2ee-evidence",
  "client:verify:macos-bundle"
];
export const shellModules = ["Agents", "Token Usage", "Skill Hub", "Mobile Relay", "Settings"];

export function formatAdapterReadinessSummary(adapterReadiness) {
  const summary = adapterReadiness?.summary || {};
  return `${summary.ready} ready / ${summary.failed} failed / ${summary.blocked} blocked / ${summary.unverified} unverified`;
}

export async function createPlanContext() {
  const secureClientContract = await loadSecureClientContract();
  return Object.freeze({
    repoRoot,
    releaseBoundarySelfTestScripts,
    requiredVerifierScripts,
    shellModules,
    secureClientContract,
    formatAdapterReadinessSummary,
  });
}
