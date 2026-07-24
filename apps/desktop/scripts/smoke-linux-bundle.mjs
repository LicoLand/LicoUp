import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import process from "node:process";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const bundleRoot = path.join(workspaceRoot, "build", "apps", "desktop", "bundles", "linux");

function findLinuxBundle() {
  const candidates = [];
  for (const mode of existsSync(bundleRoot) ? readdirSync(bundleRoot) : []) {
    const bundleDir = path.join(bundleRoot, mode, "bundle");
    if (existsSync(path.join(bundleDir, "licoup"))) {
      candidates.push(bundleDir);
    }
  }
  if (candidates.length === 0) {
    throw new Error("No Linux bundle found. Run npm run client:build:linux first.");
  }
  candidates.sort((left, right) => statSync(right).mtimeMs - statSync(left).mtimeMs);
  return candidates[0];
}

function runJson(command, args, env) {
  const result = spawnSync(command, args, {
    cwd: path.dirname(command),
    env,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(
      `${path.basename(command)} ${args.join(" ")} failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`Command did not return JSON: ${result.stdout}\n${error.message}`);
  }
}

function assertTargetScan(scan) {
  if (scan.ok !== true || !Array.isArray(scan.candidates)) {
    throw new Error(`Unexpected target scan result: ${JSON.stringify(scan)}`);
  }

  const targets = new Set();
  for (const candidate of scan.candidates) {
    if (!candidate || typeof candidate.target !== "string" || candidate.target.length === 0) {
      throw new Error(`Target scan returned an invalid candidate: ${JSON.stringify(candidate)}`);
    }
    if (typeof candidate.status !== "string" || candidate.status.length === 0) {
      throw new Error(`Target scan candidate is missing status: ${JSON.stringify(candidate)}`);
    }
    if (!candidate.adapterCapabilities || typeof candidate.adapterCapabilities !== "object") {
      throw new Error(`Target scan candidate is missing adapter capabilities: ${JSON.stringify(candidate)}`);
    }
    targets.add(candidate.target);
  }

  for (const target of ["openclaw", "codex", "opencode"]) {
    if (!targets.has(target)) {
      throw new Error(`Target scan result is missing required target: ${target}`);
    }
  }
}

async function main() {
  if (process.platform !== "linux") {
    throw new Error("Linux bundle smoke tests must run inside Linux.");
  }

  const bundleDir = findLinuxBundle();
  const flutterBinary = path.join(bundleDir, "licoup");
  const cli = path.join(bundleDir, "licoup");
  const packagingManifest = path.join(
    bundleDir,
    "package-metadata",
    "licoup",
    "packaging-modules.json"
  );
  for (const file of [flutterBinary, cli]) {
    if (!existsSync(file)) {
      throw new Error(`Bundle binary is missing: ${file}`);
    }
  }
  if (!existsSync(packagingManifest)) {
    throw new Error(`Packaging manifest is missing: ${packagingManifest}`);
  }
  const manifest = JSON.parse(readFileSync(packagingManifest, "utf8"));
  const enabledModuleIds = new Set(
    manifest.modules?.map((item) => item.id) || []
  );
  for (const moduleId of [
    "desktop-app",
    "native-sidecar",
    "portable-data",
    "target-adapters",
    "local-task-queue",
    "protocol-adapters",
  ]) {
    if (!enabledModuleIds.has(moduleId)) {
      throw new Error(`Packaging manifest does not include required module: ${moduleId}`);
    }
  }
  const dataDir = path.join(os.tmpdir(), `lico-ubuntu-smoke-${process.pid}-${Date.now()}`);
  mkdirSync(dataDir, { recursive: true });
  const env = { ...process.env, LICOUP_PORTABLE_DIR: dataDir };
  try {
    const scan = runJson(cli, ["targets", "scan"], env);
    assertTargetScan(scan);

    console.log(JSON.stringify({
      ok: true,
      bundleDir,
      checks: [
        "bundle binaries exist",
        "packaging manifest includes required modules",
        "CLI target scan works with shared portable workspace",
      ],
    }, null, 2));
  } finally {
    rmSync(dataDir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
