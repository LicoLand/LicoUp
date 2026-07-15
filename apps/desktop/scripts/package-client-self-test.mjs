#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  assertReleaseSourceDigestStable,
  diffReleaseSourceManifests,
  packageSourceStateBinding,
  validatePackagingConfig,
  validateReleaseBuildPolicy,
} from "./package-client.mjs";
import { readFileSync } from "node:fs";
import { sha256File } from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const packageScript = "apps/desktop/scripts/package-client.mjs";
const digest = `sha256:${"a".repeat(64)}`;

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

function expectRejected(operation, code) {
  let rejected = false;
  try {
    operation();
  } catch {
    rejected = true;
  }
  requireValue(rejected, code);
}

function invoke(args) {
  return spawnSync(process.execPath, [packageScript, ...args], {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    stdio: "pipe",
    timeout: 30_000,
    maxBuffer: 4 * 1024 * 1024,
  });
}

function outputIsReferenceOnly(value) {
  const output = String(value || "");
  const home = String(process.env.HOME || "");
  return !/(?:^|[\s"':])\/(?:[^/\s"']|$)/mu.test(output) &&
    !/[A-Za-z]:\\/u.test(output) &&
    !output.includes(repoRoot) &&
    (!home || !output.includes(home));
}

assertReleaseSourceDigestStable(digest, digest);
expectRejected(
  () => assertReleaseSourceDigestStable(digest, `sha256:${"b".repeat(64)}`),
  "source_change_during_build_was_accepted",
);
const manifestDiff = diffReleaseSourceManifests(
  { entries: [{ path: "apps/desktop/source-a", digest, mode: 0o644, size: 1 }] },
  { entries: [{ path: "apps/desktop/source-b", digest, mode: 0o644, size: 1 }] },
);
requireValue(
  manifestDiff.changedSourceCount === 2 &&
    manifestDiff.changedSourceRefs.join(",") ===
      "apps/desktop/source-a,apps/desktop/source-b" &&
    manifestDiff.truncated === false,
  "source_manifest_diff_is_not_exact",
);
let ordinaryDigestCalls = 0;
const ordinaryBinding = packageSourceStateBinding(
  { platform: "macos", releaseSourceStateDigest: "" },
  {
    environment: {},
    sourceDigest: () => {
      ordinaryDigestCalls += 1;
      return digest;
    },
  },
);
requireValue(ordinaryBinding.digest === digest &&
  ordinaryBinding.provenance === "git-worktree" && ordinaryDigestCalls === 1,
"ordinary_release_source_binding_bypassed_git");
let attestedDigestCalls = 0;
const attestedBinding = packageSourceStateBinding(
  { platform: "linux", releaseSourceStateDigest: "" },
  {
    environment: {
      LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST: digest,
    },
    sourceDigest: () => {
      attestedDigestCalls += 1;
      throw new Error("git digest must not run in the non-git VM workspace");
    },
    verifySourceManifest: (expectedDigest) => ({
      ok: true,
      sourceStateDigest: expectedDigest,
      manifestDigest: `sha256:${"b".repeat(64)}`,
    }),
  },
);
requireValue(attestedBinding.digest === digest &&
  attestedBinding.provenance === "vm-orchestrator-verified" &&
  attestedDigestCalls === 0,
"valid_vm_source_attestation_called_git");
for (const fixture of [
  {
    platform: "macos",
    environment: {
      LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST: digest,
    },
  },
  {
    platform: "linux",
    environment: {
      LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST: digest,
    },
  },
  {
    platform: "linux",
    environment: {
      LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST: "sha256:invalid",
    },
  },
]) {
  expectRejected(
    () => packageSourceStateBinding(
      { platform: fixture.platform, releaseSourceStateDigest: "" },
      { environment: fixture.environment, sourceDigest: () => digest },
    ),
    "invalid_vm_source_attestation_was_accepted",
  );
}
const sourceFixtureRoot = mkdtempSync(path.join(os.tmpdir(), "lico-package-source-"));
try {
  const sourceFixture = path.join(sourceFixtureRoot, "source.txt");
  writeFileSync(sourceFixture, "before", { mode: 0o600 });
  const sourceBeforeBuild = sha256File(sourceFixture);
  writeFileSync(sourceFixture, "changed-during-build", { mode: 0o600 });
  expectRejected(
    () => assertReleaseSourceDigestStable(
      sourceBeforeBuild,
      sha256File(sourceFixture),
    ),
    "source_file_change_during_build_was_accepted",
  );
} finally {
  rmSync(sourceFixtureRoot, { recursive: true, force: true });
}
for (const field of ["skipFlutterBuild", "skipNativeBuild"]) {
  expectRejected(() => validateReleaseBuildPolicy({
    mode: "release",
    dryRun: false,
    skipFlutterBuild: field === "skipFlutterBuild",
    skipNativeBuild: field === "skipNativeBuild",
  }), `release_${field}_was_accepted`);
}
for (const invalid of [
  { configPath: path.join(repoRoot, "external-packaging.json") },
  { configPath: path.join(repoRoot, "apps/desktop/packaging.modules.json"), enabledOverrides: ["native-sidecar"] },
  { configPath: path.join(repoRoot, "apps/desktop/packaging.modules.json"), disabledOverrides: ["native-sidecar"] },
  { configPath: path.join(repoRoot, "apps/desktop/packaging.modules.json"), profile: "lico-client" },
]) {
  expectRejected(() => validateReleaseBuildPolicy({
    mode: "release",
    dryRun: true,
    skipFlutterBuild: true,
    skipNativeBuild: true,
    enabledOverrides: [],
    disabledOverrides: [],
    profile: null,
    ...invalid,
  }), "release_packaging_policy_override_was_accepted");
}
const canonicalConfig = JSON.parse(readFileSync(
  path.join(repoRoot, "apps/desktop/packaging.modules.json"),
  "utf8",
));
validatePackagingConfig(canonicalConfig);
for (const mutate of [
  (value) => { value.unknown = true; },
  (value) => { value.modules["../escape"] = value.modules["native-sidecar"]; },
  (value) => { value.modules["mail-import-runtime"].swiftSource = "../outside.swift"; },
  (value) => { value.modules["mail-import-runtime"].artifactName = "../outside"; },
  (value) => { value.modules["native-sidecar"].includePaths = ["../outside"]; },
]) {
  const fixture = structuredClone(canonicalConfig);
  mutate(fixture);
  expectRejected(() => validatePackagingConfig(fixture),
    "unsafe_packaging_schema_fixture_was_accepted");
}

const dryRun = invoke(["--platform", "macos", "--mode", "release", "--dry-run"]);
requireValue(dryRun.status === 0, "package_dry_run_failed");
requireValue(outputIsReferenceOnly(`${dryRun.stdout}\n${dryRun.stderr}`),
  "package_dry_run_disclosed_absolute_path");
const windowsX64DryRun = invoke([
  "--platform", "windows", "--target", "windows-x64", "--mode", "release", "--dry-run",
]);
requireValue(windowsX64DryRun.status === 0,
  "windows_x64_package_dry_run_failed");
const windowsArm64DryRun = invoke([
  "--platform", "windows", "--target", "windows-arm64", "--mode", "release", "--dry-run",
]);
requireValue(windowsArm64DryRun.status !== 0 &&
  outputIsReferenceOnly(`${windowsArm64DryRun.stdout}\n${windowsArm64DryRun.stderr}`),
"windows_arm64_upstream_boundary_not_fail_closed");

const privateArgument = ["", "sensitive-root", "fixture", "private-value"].join("/");
const rejected = invoke(["--unknown-option", privateArgument]);
requireValue(rejected.status !== 0, "unknown_package_option_was_accepted");
requireValue(outputIsReferenceOnly(`${rejected.stdout}\n${rejected.stderr}`) &&
  !`${rejected.stdout}\n${rejected.stderr}`.includes(privateArgument),
"package_failure_disclosed_private_argument");

console.log(JSON.stringify({
  ok: true,
  caseCount: 25,
  canonicalReleaseConfigRequired: true,
  releaseOverridesRejected: true,
  packagingSchemaClosed: true,
  packagingPathsContained: true,
  buildExecuted: false,
  privatePathsIncluded: false,
}));
