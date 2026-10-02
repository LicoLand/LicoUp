import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { sanitizeError } from "../lib/sanitize-error.mjs";
import {
  dockerfilePath,
  repoRoot,
  runnerArchitecture,
  runnerPlatform,
} from "./constants.mjs";

function command(command, args, options = {}) {
  return spawnSync(command, args, {
    cwd: options.cwd || repoRoot,
    encoding: "utf8",
    stdio: options.stdio || ["ignore", "pipe", "pipe"],
    env: options.env,
  });
}

function output(result) {
  return String(result.stdout || "").trim();
}

function commandFailure(code, result) {
  const detail = sanitizeError(result?.stderr || result?.stdout || code);
  const error = new Error(`${code}:${detail}`);
  error.code = code;
  throw error;
}

export function inspectLocalDocker(run = command) {
  const context = run("docker", ["context", "inspect", "--format", "{{json .Endpoints.docker.Host}}"]);
  if (context.status !== 0) commandFailure("docker_context_unavailable", context);
  let endpoint;
  try {
    endpoint = JSON.parse(output(context));
  } catch {
    const error = new Error("docker_context_invalid");
    error.code = "docker_context_invalid";
    throw error;
  }
  if (typeof endpoint !== "string" || !endpoint.startsWith("unix://")) {
    const error = new Error("docker_context_not_local_unix");
    error.code = "docker_context_not_local_unix";
    throw error;
  }
  const info = run("docker", ["info", "--format", "{{json .OSType}}"]);
  if (info.status !== 0) commandFailure("docker_engine_unavailable", info);
  let osType;
  try {
    osType = JSON.parse(output(info));
  } catch {
    const error = new Error("docker_engine_response_invalid");
    error.code = "docker_engine_response_invalid";
    throw error;
  }
  if (osType !== "linux") {
    const error = new Error("docker_engine_not_linux");
    error.code = "docker_engine_not_linux";
    throw error;
  }
  return Object.freeze({ localUnix: true, linuxEngine: true });
}

function imageIdentity() {
  const digest = createHash("sha256").update(readFileSync(dockerfilePath)).digest("hex");
  return Object.freeze({ digest, tag: `licoup-local-linux-ci:${digest.slice(0, 20)}` });
}

export async function ensureRunnerImage(runStreaming) {
  const image = imageIdentity();
  const inspect = command("docker", ["image", "inspect", image.tag]);
  if (inspect.status === 0) return image;
  const context = mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-image-"));
  try {
    copyFileSync(dockerfilePath, path.join(context, "Dockerfile"));
    const status = await runStreaming("docker", [
      "build",
      "--platform",
      runnerPlatform,
      "--file",
      path.join(context, "Dockerfile"),
      "--tag",
      image.tag,
      context,
    ]);
    if (status !== 0) {
      const error = new Error("docker_image_build_failed");
      error.code = "docker_image_build_failed";
      throw error;
    }
  } finally {
    rmSync(context, { recursive: true, force: true });
  }
  return image;
}

export function verifyRunnerArchitecture(image) {
  const result = command("docker", [
    "run",
    "--rm",
    "--platform",
    runnerPlatform,
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--cpus=3",
    image.tag,
    "uname",
    "-m",
  ]);
  if (result.status !== 0) commandFailure("docker_amd64_runtime_unavailable", result);
  if (output(result) !== runnerArchitecture) {
    const error = new Error("docker_amd64_runtime_architecture_mismatch");
    error.code = "docker_amd64_runtime_architecture_mismatch";
    throw error;
  }
  return true;
}

function mount(source, target, readOnly = false) {
  return `type=bind,src=${source},dst=${target}${readOnly ? ",readonly" : ""}`;
}

export function runnerDockerArgs({
  image,
  lane,
  profile,
  candidateRoot,
  cacheRoot,
  outputRoot,
  cargoAuditVersion,
  androidPackages,
}) {
  const containerRoot = path.posix.join("/", "root");
  const androidSdkManager = path.posix.join(
    "/", "opt", "android-command-line-tools", "latest", "bin", "sdkmanager",
  );
  const npmCache = path.join(cacheRoot, "npm");
  const cargoRegistry = path.join(cacheRoot, "cargo-registry");
  const cargoGit = path.join(cacheRoot, "cargo-git");
  const cargoTarget = path.join(cacheRoot, "cargo-target");
  const cargoAuditRoot = path.join(cacheRoot, "cargo-audit");
  const cargoAuditTarget = path.join(cacheRoot, "cargo-audit-target");
  const pubCache = path.join(cacheRoot, "pub-cache");
  const gradleCache = path.join(cacheRoot, "gradle");
  const androidSdkCache = path.join(cacheRoot, "android-sdk");
  for (const directory of [
    npmCache,
    cargoRegistry,
    cargoGit,
    cargoTarget,
    cargoAuditRoot,
    cargoAuditTarget,
    pubCache,
    gradleCache,
    androidSdkCache,
  ]) mkdirSync(directory, { recursive: true, mode: 0o700 });

  const sourceDelegation = lane === "source" || profile === "engineering"
    ? [
      "--env", "LICO_AUDITOR_GATE_DELEGATED=1",
      "--env", "GITHUB_ACTIONS=true",
      "--env", "GITHUB_WORKFLOW=Client CI",
      "--env", "GITHUB_JOB=source",
    ]
    : [];
  const dependencyBootstrap = lane === "dependencies" || profile === "engineering"
    ? `if ! /cache/cargo-audit/bin/cargo-audit --version 2>/dev/null | ` +
      `grep -Fq \"cargo-audit ${cargoAuditVersion}\"; then ` +
      `CARGO_TARGET_DIR=/cache/cargo-audit-target cargo install --root /cache/cargo-audit ` +
      `cargo-audit --version ${cargoAuditVersion} --locked; fi && `
    : "";
  const flutterBootstrap = profile === "engineering"
    ? "npm run client:get && "
    : "";
  const androidBootstrap = lane === "android" || profile === "engineering"
    ? `set +o pipefail; yes | ${androidSdkManager} ` +
      "--sdk_root=/cache/android-sdk --licenses >/dev/null; license_status=$?; " +
      "set -o pipefail; [ \"$license_status\" -eq 0 ]; " +
      `${androidSdkManager} --sdk_root=/cache/android-sdk ${androidPackages.join(" ")} < /dev/null && `
    : "";
  const invocation = profile === "engineering"
    ? "npm run client:gate:verify -- --base HEAD --head HEAD --target pr --execution direct --host linux"
    : `npm run client:gate:${lane}`;
  const setup = [
    "set -euo pipefail",
    `[ \"$(uname -m)\" = \"${runnerArchitecture}\" ]`,
    "mkdir -p /workspace",
    "cp -a /candidate/. /workspace/",
    "cd /workspace",
    "git init -q",
    "git config user.name local-linux-ci",
    "git config user.email local-linux-ci@invalid.example",
    "git add --all",
    "git commit -q --no-gpg-sign -m candidate",
    "npm ci",
    "export PATH=/cache/cargo-audit/bin:$PATH",
  ].join("; ");
  const copyReport = profile === "engineering"
    ? "if [ -f build/reports/client-module-regression.json ]; then " +
      "install -m 0600 build/reports/client-module-regression.json " +
      "/output/client-module-regression.json; fi"
    : ":";
  const script = `${setup} && status=0; ${dependencyBootstrap}${androidBootstrap}${flutterBootstrap}${invocation} || status=$?; ` +
    `${copyReport}; exit "$status"`;
  return [
    "run",
    "--rm",
    "--platform",
    runnerPlatform,
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--env", "CI=true",
    "--env", "HOME=/root",
    "--env", "npm_config_cache=/cache/npm",
    "--env", `CARGO_HOME=${containerRoot}/.cargo`,
    "--env", "CARGO_BUILD_JOBS=3",
    "--env", "RUST_TEST_THREADS=3",
    "--env", "CARGO_TARGET_DIR=/workspace/build/crates/licoup-native/target",
    "--env", "PUB_CACHE=/cache/pub",
    "--env", "GRADLE_USER_HOME=/cache/gradle",
    "--env", "ANDROID_HOME=/cache/android-sdk",
    "--env", "ANDROID_SDK_ROOT=/cache/android-sdk",
    "--env", "LICO_CLIENT_GATE_ISOLATED_LINUX=1",
    ...sourceDelegation,
    "--mount", mount(candidateRoot, "/candidate", true),
    "--mount", mount(npmCache, "/cache/npm"),
    "--mount", mount(cargoRegistry, `${containerRoot}/.cargo/registry`),
    "--mount", mount(cargoGit, `${containerRoot}/.cargo/git`),
    "--mount", mount(cargoTarget, "/workspace/build/crates/licoup-native/target"),
    "--mount", mount(cargoAuditRoot, "/cache/cargo-audit"),
    "--mount", mount(cargoAuditTarget, "/cache/cargo-audit-target"),
    "--mount", mount(pubCache, "/cache/pub"),
    "--mount", mount(gradleCache, "/cache/gradle"),
    "--mount", mount(androidSdkCache, "/cache/android-sdk"),
    "--mount", mount(outputRoot, "/output"),
    "--workdir", "/",
    image.tag,
    "bash",
    "-lc",
    script,
  ];
}

export function runnerCacheRoot() {
  const commonDirectory = command("git", [
    "rev-parse",
    "--path-format=absolute",
    "--git-common-dir",
  ]);
  if (commonDirectory.status !== 0) {
    commandFailure("git_common_directory_unavailable", commonDirectory);
  }
  const gitCommonDirectory = path.resolve(output(commonDirectory));
  if (path.basename(gitCommonDirectory) !== ".git") {
    const error = new Error("git_common_directory_invalid");
    error.code = "git_common_directory_invalid";
    throw error;
  }
  const root = path.join(gitCommonDirectory, "licoup-local-linux-ci-cache");
  if (!existsSync(root)) mkdirSync(root, { recursive: true, mode: 0o700 });
  return root;
}
