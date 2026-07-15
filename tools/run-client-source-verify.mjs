#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import process from "node:process";

const steps = [
  "repo:client-boundary",
  "repo:local-info-hygiene:self-test",
  "repo:local-info-hygiene",
  "repo:workspace-cache-boundary",
  "client:version:check",
  "client:verify:plan",
  "client:verify:architecture",
  "client:verify:release-artifact-io:self-test",
  "client:verify:source-state-digest:self-test",
  "client:verify:android-apk-zip-facts:self-test",
  "client:verify:android-release-toolchain:self-test",
  "client:verify:consumer-verification-manifest:self-test",
  "client:verify:remote-release-assets:self-test",
  "client:verify:client-release-acceptance:self-test",
  "client:contracts:test",
  "client:verify:update-release",
  "client:format:check",
  "client:native:fmt:check",
  "client:native:clippy",
  "client:deps:audit",
  "client:analyze",
  "client:test",
  "client:native:test",
  "client:native:smoke",
];

for (const script of steps) {
  console.log(`\n[client-source-verify] npm run ${script}`);
  const result = spawnSync("npm", ["run", script], {
    cwd: process.cwd(),
    env: process.env,
    shell: process.platform === "win32",
    stdio: "inherit",
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

console.log(JSON.stringify({
  ok: true,
  scope: "source-development-and-artifact-policy",
  physicalEvidenceConsumed: false,
  externalSecurityAuthorityConsumed: false,
}));
