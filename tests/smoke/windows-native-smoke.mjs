#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { sanitizeError } from "../../../tools/scripts/lib/sanitize-error.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const progressPath = path.join(repoRoot, "build", "test-reports", "windows-native-smoke-progress.jsonl");

async function recordProgress(step, status, detail = {}) {
  await fs.mkdir(path.dirname(progressPath), { recursive: true });
  const entry = { time: new Date().toISOString(), step, status, ...detail };
  appendFileSync(progressPath, `${JSON.stringify(entry)}\n`);
  console.log(`[windows-smoke] ${step}: ${status}`);
}

function killProcessTree(pid) {
  if (!pid) return;
  if (process.platform === "win32") {
    spawnSync("taskkill.exe", ["/PID", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
  } else {
    try {
      process.kill(-pid, "SIGTERM");
    } catch {
      try {
        process.kill(pid, "SIGTERM");
      } catch {}
    }
  }
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd || repoRoot,
      env: { ...process.env, ...(options.env || {}) },
      stdio: options.inherit ? "inherit" : ["ignore", "pipe", "pipe"],
      windowsHide: true
    });
    const stdout = [];
    const stderr = [];
    if (!options.inherit) {
      child.stdout.on("data", (chunk) => stdout.push(Buffer.from(chunk)));
      child.stderr.on("data", (chunk) => stderr.push(Buffer.from(chunk)));
    }
    const timer = options.timeoutMs
      ? setTimeout(() => {
          killProcessTree(child.pid);
          setTimeout(() => finish(1, "timeout"), 5000).unref?.();
        }, options.timeoutMs)
      : null;
    timer?.unref?.();
    let settled = false;
    const finish = (code, signal) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve({
        code,
        signal,
        stdout: Buffer.concat(stdout).toString("utf8").trim(),
        stderr: Buffer.concat(stderr).toString("utf8").trim()
      });
    };
    child.once("error", reject);
    if (options.resolveOnExit) {
      child.once("exit", (code, signal) => setTimeout(() => finish(code, signal), 50));
    } else {
      child.once("close", finish);
    }
  });
}

async function runChecked(command, args, options = {}) {
  const result = await run(command, args, options);
  assert.equal(
    result.code,
    0,
    `${command} ${args.join(" ")} failed: ${result.stderr || result.stdout || result.signal || result.code}`
  );
  return result;
}

async function runJson(command, args, options = {}) {
  const result = await runChecked(command, args, options);
  try {
    return JSON.parse(result.stdout || "{}");
  } catch (error) {
    throw new Error(`${command} ${args.join(" ")} did not return JSON: ${error.message}\n${result.stdout}`);
  }
}

function sanitizeDiagnosticText(value) {
  return String(value || "")
    .replace(/\b[A-Za-z]:[\\/][^\r\n"'`]*/g, "<path>")
    .replace(/(^|[\s"'=:(])\/(?:Users|home|root|private|var|tmp|opt|usr|Volumes)\/[^\s"',)\]}]*/g, "$1<path>")
    .replace(/\bworkspace_[A-Za-z0-9_]+\b/g, "<workspace-id>");
}

async function localRuntimeFailureDiagnostics(licoClientExe, env) {
  const logs = await run(licoClientExe, ["local-runtime", "logs", "--tail", "30"], { env, timeoutMs: 30000 }).catch((error) => ({
    code: 1,
    stdout: "",
    stderr: error instanceof Error ? error.message : String(error)
  }));
  const output = sanitizeDiagnosticText([logs.stderr, logs.stdout].filter(Boolean).join("\n")).trim();
  if (!output) {
    return "local-runtime diagnostics were empty";
  }
  return output.split(/\r?\n/).slice(-30).join("\n");
}

function windowsExcludedTcpPortRanges() {
  if (process.platform !== "win32") {
    return [];
  }
  const result = spawnSync("netsh.exe", ["interface", "ipv4", "show", "excludedportrange", "protocol=tcp"], {
    encoding: "utf8",
    windowsHide: true
  });
  if (result.status !== 0) {
    return [];
  }
  return String(result.stdout || "")
    .split(/\r?\n/)
    .map((line) => line.match(/^\s*(\d+)\s+(\d+)/))
    .filter(Boolean)
    .map((match) => [Number(match[1]), Number(match[2])])
    .filter(([start, end]) => Number.isInteger(start) && Number.isInteger(end));
}

function portWindowExcluded(port, ranges, width = 10) {
  const end = port + width;
  return ranges.some(([rangeStart, rangeEnd]) => port <= rangeEnd && end >= rangeStart);
}

function probePort(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.listen(port, "127.0.0.1", () => {
      server.close(() => resolve(true));
    });
  });
}

async function freePort() {
  if (process.platform === "win32") {
    const excludedRanges = windowsExcludedTcpPortRanges();
    for (let attempt = 0; attempt < 240; attempt += 1) {
      const port = 42000 + ((attempt * 113) % 6000);
      if (portWindowExcluded(port, excludedRanges)) {
        continue;
      }
      if (await probePort(port)) {
        return port;
      }
    }
  }
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

async function fileExists(filePath) {
  try {
    const stat = await fs.stat(filePath);
    return stat.isFile();
  } catch {
    return false;
  }
}

async function fileSize(filePath) {
  try {
    const stat = await fs.stat(filePath);
    return stat.isFile() ? stat.size : 0;
  } catch {
    return 0;
  }
}

function assertNoPosixOnlyPackageScripts() {
  const pkg = JSON.parse(readFileSync(path.join(repoRoot, "package.json"), "utf8"));
  const critical = [
    "client:native:test",
    "client:native:test:coverage",
    ...Object.keys(pkg.scripts).filter((key) => key.startsWith("client:verify:"))
  ];
  for (const key of critical) {
    const script = String(pkg.scripts[key] || "");
    assert.equal(/^bash\b/.test(script), false, `${key} must not require bash`);
    assert.equal(/\bCARGO_TARGET_DIR=/.test(script), false, `${key} must not use POSIX env assignment`);
    assert.equal(/\bmkdir -p\b/.test(script), false, `${key} must not use POSIX mkdir -p`);
  }
}

async function assertExistingWindowsBundleIfPresent() {
  const runnableRoot = path.join(repoRoot, "build", "apps", "desktop", "runnable", "windows", "release");
  const bundleRoot = path.join(repoRoot, "build", "apps", "desktop", "bundles", "windows", "release", "bundle");
  if (!(await fileExists(path.join(runnableRoot, "flutter_client.exe")))) {
    console.log("windows bundle artifact check skipped; run npm run client:build:windows first");
    return;
  }
  for (const root of [runnableRoot, bundleRoot]) {
    assert.ok((await fileSize(path.join(root, "flutter_client.exe"))) > 0, `${root} missing non-empty flutter_client.exe`);
    assert.ok((await fileSize(path.join(root, "lico-client.exe"))) > 0, `${root} missing non-empty lico-client.exe`);
    assert.equal(
      await fileExists(path.join(root, "package-metadata", "windows", "client-manifest.json")),
      true,
      `${root} missing Windows client manifest`
    );
  }
}

async function main() {
  await fs.rm(progressPath, { force: true }).catch(() => {});
  await recordProgress("static-scripts", "start");
  assertNoPosixOnlyPackageScripts();
  await recordProgress("static-scripts", "ok");
  await recordProgress("windows-file-security", "start");
  await runChecked(process.execPath, ["tests/verify-windows-file-security-boundary.mjs"], { timeoutMs: 30000 });
  await recordProgress("windows-file-security", "ok");
  await recordProgress("windows-runtime-setup", "start");
  await runChecked(process.execPath, ["tests/verify-windows-local-runtime-setup.mjs"], { timeoutMs: 30000 });
  await recordProgress("windows-runtime-setup", "ok");
  if (process.platform !== "win32") {
    console.log("windows native smoke static checks passed; full Windows smoke skipped on non-Windows");
    return;
  }

  await recordProgress("lico-client-build", "start");
  await runChecked(process.execPath, ["tools/scripts/cargo-client.mjs", "build", "--manifest-path", "crates/lico-client-native/Cargo.toml", "--bin", "lico-client"], { timeoutMs: 240000 });
  await recordProgress("lico-client-build", "ok");

  const licoClientExe = path.join(repoRoot, "build", "crates", "lico-client-native", "target", "debug", "lico-client.exe");
  assert.equal(await fileExists(licoClientExe), true, `lico-client.exe missing: ${licoClientExe}`);

  const portableDir = await fs.mkdtemp(path.join(os.tmpdir(), "lico-windows-native-smoke-"));
  await recordProgress("portable-dir", "created");
  const env = { LICO_PORTABLE_DIR: portableDir };
  try {
    await recordProgress("targets-scan", "start");
    const targets = await runJson(licoClientExe, ["targets", "scan"], { env, timeoutMs: 30000 });
    assert.equal(targets.ok, true);
    for (const candidate of targets.candidates || []) {
      assert.equal(
        String(candidate.configPath || "").includes("Library/Application Support"),
        false,
        `${candidate.target} returned a macOS-only path on Windows`
      );
    }
    await recordProgress("targets-scan", "ok", { candidates: (targets.candidates || []).length });

    await recordProgress("local-runtime-build", "start");
    await runChecked(licoClientExe, [
      "local-runtime",
      "build"
    ], { env, timeoutMs: 240000 });
    await recordProgress("local-runtime-build", "ok");

    const port = await freePort();
    await recordProgress("local-runtime-start", "start", { port });
    let start;
    try {
      start = await runJson(licoClientExe, [
        "local-runtime",
        "start",
        "--port", String(port),
        "--health-timeout-ms", "180000"
      ], { env, timeoutMs: 240000, resolveOnExit: true });
    } catch (error) {
      const diagnostics = await localRuntimeFailureDiagnostics(licoClientExe, env);
      throw new Error(`${error instanceof Error ? error.message : String(error)}\n${diagnostics}`);
    }
    assert.equal(start.status, "running");
    assert.match(start.serverUrl, new RegExp(`:${port}$`));
    await recordProgress("local-runtime-start", "ok");

    await recordProgress("local-runtime-status", "start");
    const status = await runJson(licoClientExe, ["local-runtime", "status"], { env, timeoutMs: 30000 });
    assert.equal(status.status, "running");
    await recordProgress("local-runtime-status", "ok");

    await recordProgress("local-runtime-logs", "start");
    const logs = await runJson(licoClientExe, ["local-runtime", "logs", "--tail", "20"], { env, timeoutMs: 30000 });
    assert.equal(Array.isArray(logs.lines), true);
    await recordProgress("local-runtime-logs", "ok", { lines: logs.lines.length });

    await recordProgress("local-runtime-stop", "start");
    const stop = await runJson(licoClientExe, ["local-runtime", "stop"], { env, timeoutMs: 60000 });
    assert.equal(stop.status, "stopped");
    await recordProgress("local-runtime-stop", "ok");

    await recordProgress("windows-secret-store", "start");
    const secretStore = await runJson(licoClientExe, [
      "mobile", "relay", "e2ee", "secret-store-self-test",
    ], { env, timeoutMs: 120000 });
    assert.equal(secretStore.ok, true);
    assert.equal(secretStore.selfTestPassed, true);
    assert.equal(secretStore.backend, "windows-credential-manager");
    assert.equal(secretStore.sharedSecretClassRoundTripPassed, true);
    assert.equal(secretStore.sharedSecretClassPersistenceReady, true);
    assert.equal(secretStore.portableConfigPrivateMaterialRedacted, true);
    assert.equal(secretStore.rawPrivateMaterialIncluded, false);
    assert.equal(secretStore.rawPlaintextIncluded, false);
    assert.equal(secretStore.ordinaryFileSecretArtifactCount, 0);
    await recordProgress("windows-secret-store", "ok");
  } finally {
    await recordProgress("cleanup", "start");
    await run(licoClientExe, ["local-runtime", "stop"], { env, timeoutMs: 60000 }).catch(() => {});
    await fs.rm(portableDir, { recursive: true, force: true });
    await recordProgress("cleanup", "ok");
  }

  await recordProgress("windows-bundle-artifacts", "start");
  await assertExistingWindowsBundleIfPresent();
  await recordProgress("windows-bundle-artifacts", "ok");
  console.log("windows native smoke passed");
}

main().catch((error) => {
  console.error(sanitizeError(error));
  process.exitCode = 1;
});
