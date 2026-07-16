#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import process from "node:process";

const offline = process.env.LICO_CLIENT_VERIFY_OFFLINE === "1";

const steps = [
  ["npm", ["run", "repo:client-boundary"]],
  ["npm", ["run", "repo:local-info-hygiene:self-test"]],
  ["npm", ["run", "repo:local-info-hygiene"]],
  ["npm", ["run", "repo:workspace-cache-boundary"]],
  ["npm", ["run", "client:artifacts:self-test"]],
  ["npm", ["run", "client:version:check"]],
  ["npm", ["run", "client:get", ...(offline ? ["--", "--offline"] : [])]],
  ["npm", ["run", "client:verify:plan"]],
  ["npm", ["run", "client:verify:architecture"]],
  ["npm", ["run", "client:verify:local-data-egress-boundary"]],
  ["npm", ["run", "client:verify:release-artifact-io:self-test"]],
  ["npm", ["run", "client:verify:release-dependency-receipts:self-test"]],
  ["npm", ["run", "client:verify:source-state-digest:self-test"]],
  ["npm", ["run", "client:verify:linux-tar-resource-bounds:self-test"]],
  ["npm", ["run", "client:verify:bounded-child-process:self-test"]],
  ["npm", ["run", "client:verify:android-apk-zip-facts:self-test"]],
  ["npm", ["run", "client:verify:android-release-toolchain:self-test"]],
  ["npm", ["run", "client:verify:consumer-verification-manifest:self-test"]],
  ["npm", ["run", "client:verify:macos-distribution:self-test"]],
  ["npm", ["run", "client:verify:review-signoff:self-test"]],
  ["npm", ["run", "client:verify:release-target-evidence:self-test"]],
  ["npm", ["run", "client:verify:release-report-schema:self-test"]],
  ["npm", ["run", "client:verify:macos-nested-code-bounds:self-test"]],
  ["npm", ["run", "client:verify:package-client:self-test"]],
  ["npm", ["run", "client:native:smoke:policy:self-test"]],
  ["npm", ["run", "client:verify:closure-producer-writer:self-test"]],
  ["npm", ["run", "client:verify:android-physical-install-launch:self-test"]],
  ["npm", ["run", "client:verify:secure-mesh-macos-capabilities:self-test"]],
  ["npm", ["run", "client:install:macos:identity:self-test"]],
  ["npm", ["run", "client:verify:secure-mesh-linux-node-matrix:self-test"]],
  ["npm", ["run", "client:cli:vm:self-test"]],
  ["npm", ["run", "client:verify:artifact-verification-receipts:self-test"]],
  ["npm", ["run", "client:verify:agent-conversation-parity"]],
  ["npm", ["run", "client:verify:agent-adapter-standard"]],
  ["npm", ["run", "client:verify:agent-conversations:product-e2e:self-test"]],
  ["npm", ["run", "client:verify:agent-usage"]],
  ["npm", ["run", "client:contracts:test"]],
  ["npm", ["run", "client:verify:update-release"]],
  ["npm", ["run", "client:verify:windows-file-security"]],
  ["npm", ["run", "client:verify:secure-mesh-windows-implementation"]],
  ["npm", ["run", "client:verify:secure-client-relay-mock-e2e"]],
  ["npm", ["run", "client:verify:secure-mesh-pairwise-content-audit"]],
  ["npm", ["run", "client:verify:secure-mesh-capability-model:self-test"]],
  ["npm", ["run", "client:verify:secure-mesh-capability-model"]],
  ["npm", ["run", "client:verify:secure-mesh-capability-native"]],
  ["npm", ["run", "client:verify:secure-mesh-platform-secret-store-matrix"]],
  ["npm", ["run", "client:test:android:native"]],
  ["npm", ["run", "client:verify:secure-mesh-encrypted-file-handoff"]],
  ["npm", ["run", "client:verify:secure-mesh-acp-relay-governed-baseline"]],
  ["npm", ["run", "client:verify:secure-mesh-acp-archive-release-proof"]],
  ["npm", ["run", "client:verify:secure-mesh-trust-ux:self-test"]],
  ["npm", ["run", "client:verify:secure-mesh-trust-ux"]],
  ["npm", ["run", "client:verify:secure-mesh-physical-device-matrix"]],
  ["npm", ["run", "client:verify:secure-mesh-physical-evidence-manifest"]],
  ["npm", ["run", "client:verify:secure-mesh-report-redaction:self-test"]],
  ["npm", ["run", "client:verify:secure-mesh-report-redaction"]],
  ["npm", ["run", "client:verify:secure-mesh-release-proof-bundle"]],
  ["npm", ["run", "client:verify:secure-mesh-e2ee-evidence:contract-binding"]],
  ["npm", ["run", "client:verify:secure-mesh-e2ee-evidence:authority-proof-self-test"]],
  ["npm", ["run", "client:verify:secure-mesh-e2ee-evidence:readiness-self-test"]],
  ["npm", ["run", "client:verify:secure-mesh-e2ee-evidence:leak-scan-self-test"]],
  // A10 remains a cross-product certification diagnostic. Ordinary Lico Arc
  // publication is reduced only from selected, client-owned platform evidence.
  ["npm", ["run", "client:verify:secure-mesh-e2ee-evidence:diagnostic"]],
  ["npm", ["run", "client:support-matrix:check"]],
  ["npm", ["run", "client:verify:client-release-acceptance:self-test"]],
  ["npm", ["run", "client:format:check"]],
  ["npm", ["run", "client:native:fmt:check"]],
  ["npm", ["run", "client:native:clippy"]],
  ["npm", ["run", offline ? "client:deps:audit:offline" : "client:deps:audit"]],
  ["npm", ["run", "client:analyze"]],
  ["npm", ["run", "client:test"]],
  ["npm", ["run", "client:native:test"]],
  ["npm", ["run", "client:native:smoke"]]
];

for (const [command, args] of steps) {
  const label = `${command} ${args.join(" ")}`;
  console.log(`\n[client-verify] ${label}`);
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    env: process.env,
    shell: process.platform === "win32",
    stdio: "inherit"
  });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

console.log("\n[client-verify] ok");
