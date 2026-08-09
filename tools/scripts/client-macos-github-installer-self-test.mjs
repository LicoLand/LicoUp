#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const installer = path.join(repoRoot, "tools/install-macos.sh");
const source = readFileSync(installer, "utf8");

function requireFact(value, code) {
  if (!value) throw new Error(code);
}

function run(args) {
  return spawnSync("/bin/bash", args, {
    cwd: repoRoot,
    encoding: "utf8",
    shell: false,
    stdio: "pipe",
  });
}

requireFact(run(["-n", installer]).status === 0, "installer_shell_syntax_invalid");
const selfTest = run([installer, "--self-test"]);
requireFact(
  selfTest.status === 0 && selfTest.stdout === "macos_github_installer=self_test_passed\n",
  "installer_self_test_failed",
);
for (const token of [
  "https://github.com/${repository}/releases/latest",
  "https://github.com/${repository}/releases/download/${release_tag}",
  "LicoUp-macos-arm64.zip.sha256",
  "/usr/bin/shasum -a 256 -c",
  "/usr/bin/codesign --verify --deep --strict",
  'readonly applications_root="${system_root}Applications"',
  'readonly destination="${applications_root}/LicoUp.app"',
  'case "/$entry" in',
  'previous_moved="true"',
]) {
  requireFact(source.includes(token), `installer_contract_missing:${token}`);
}
for (const forbidden of ["xattr -d", "spctl --master-disable", "eval ", "curl |", "curl|"]) {
  requireFact(!source.includes(forbidden), `installer_unsafe_behavior_present:${forbidden}`);
}

console.log(JSON.stringify({
  ok: true,
  githubLatestResolvedOnce: true,
  checksumRequired: true,
  archivePathsBounded: true,
  codeSignatureVerified: true,
  rollbackReady: true,
}));
