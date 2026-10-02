#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  chmodSync,
  createWriteStream,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  linuxProductNodeVersion as nodeVersion,
  linuxProductRustVersion as rustVersion,
  linuxProductRustupVersion as rustupVersion,
} from "./client-cli-vm/constants.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const schemaVersion = "licoup.client-gate.v1";
const shaPattern = /^[a-f0-9]{40}$/u;
const modulePattern = /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/u;
const targetPattern = /^[a-z0-9][a-z0-9._-]{0,127}$/u;
const nodeArchiveSha256 = "6e50ce5498c0cebc20fd39ab3ff5df836ed2f8a31aa093cecad8497cff126d70";
const rustupSha256 = "88d8258dcf6ae4f7a80c7d1088e1f36fa7025a1cfd1343731b4ee6f385121fc0";
const sshOptions = Object.freeze([
  "-oBatchMode=yes",
  "-oStrictHostKeyChecking=yes",
  "-oClearAllForwardings=yes",
]);

function fail(reason) {
  throw new Error(reason);
}

function runGit(args, options = {}) {
  const result = spawnSync("git", args, {
    cwd: options.cwd || repoRoot,
    encoding: options.encoding || "utf8",
    input: options.input,
    maxBuffer: 64 * 1024 * 1024,
    stdio: options.stdio,
  });
  if (result.status !== 0) fail(options.reason || "windows_target_git_failed");
  return result.stdout;
}

export function parseArgs(argv) {
  if (argv.length === 1 && argv[0] === "self-test") return Object.freeze({ command: "self-test" });
  if (argv[0] !== "run") fail("windows_target_usage_invalid");
  const values = { command: "run", base: "", head: "", target: "", modules: [], config: "" };
  for (let index = 1; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!value || !["--base", "--head", "--target", "--module", "--config"].includes(flag)) {
      fail("windows_target_usage_invalid");
    }
    if (flag === "--module") values.modules.push(value);
    else values[flag.slice(2)] = value;
  }
  values.base = values.base.toLowerCase();
  values.head = values.head.toLowerCase();
  if (!shaPattern.test(values.base) || !shaPattern.test(values.head)) {
    fail("windows_target_revision_invalid");
  }
  if (!values.modules.length || values.modules.some((id) => !modulePattern.test(id)) ||
      new Set(values.modules).size !== values.modules.length) {
    fail("windows_target_modules_invalid");
  }
  if (!['pr', 'release'].includes(values.target)) fail("windows_target_kind_invalid");
  return Object.freeze({ ...values, modules: Object.freeze([...values.modules].sort()) });
}

function quotePowerShell(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function encodedPowerShell(source) {
  return Buffer.from(source, "utf16le").toString("base64");
}

function privateConfigPath(explicit) {
  const supplied = explicit || process.env.LICO_WINDOWS_TARGET_CONFIG;
  if (supplied) return path.resolve(supplied);
  const local = path.join(repoRoot, "build", "private", "windows-target.json");
  if (existsSync(local)) return local;
  const commonGitDirectory = path.resolve(repoRoot,
    runGit(["rev-parse", "--git-common-dir"]).trim());
  return path.join(path.dirname(commonGitDirectory), "build", "private", "windows-target.json");
}

export function readPrivateTargetConfig(explicit) {
  const configPath = privateConfigPath(explicit);
  const metadata = statSync(configPath);
  if (!metadata.isFile() || (metadata.mode & 0o077) !== 0) fail("windows_target_config_not_private");
  const config = JSON.parse(readFileSync(configPath, "utf8"));
  if (!targetPattern.test(config.sshTarget || "")) fail("windows_target_config_invalid");
  return Object.freeze({ sshTarget: config.sshTarget });
}

function treeObjectIds(revision, cwd = repoRoot) {
  const commit = runGit(["rev-parse", `${revision}^{commit}`], { cwd }).trim();
  const tree = runGit(["rev-parse", `${revision}^{tree}`], { cwd }).trim();
  const entries = runGit(["ls-tree", "-r", "-t", "--full-tree", revision], { cwd })
    .split("\n")
    .filter(Boolean)
    .map((line) => line.split(/[ \t]/u)[2]);
  return [commit, tree, ...entries];
}

export async function writeCandidatePack({ base, head, destination, cwd = repoRoot }) {
  const ids = [...new Set([...treeObjectIds(base, cwd), ...treeObjectIds(head, cwd)])].sort();
  await new Promise((resolve, reject) => {
    const output = createWriteStream(destination, { mode: 0o600 });
    const child = spawn("git", ["pack-objects", "--stdout"], {
      cwd,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    let childClosed = false;
    let outputClosed = false;
    const completed = () => {
      if (childClosed && outputClosed) resolve();
    };
    output.once("close", () => { outputClosed = true; completed(); });
    output.once("error", () => reject(new Error("windows_target_pack_failed")));
    child.stdout.pipe(output);
    child.stdin.end(`${ids.join("\n")}\n`);
    child.once("error", () => reject(new Error("windows_target_pack_failed")));
    child.once("close", (code) => {
      output.end();
      if (code !== 0) reject(new Error(stderr ? "windows_target_pack_failed" : "windows_target_pack_failed"));
      else {
        childClosed = true;
        completed();
      }
    });
  });
  chmodSync(destination, 0o600);
}

function remoteRoot(config, nonce) {
  const source = `$ErrorActionPreference='Stop';$root=Join-Path $env:TEMP ${quotePowerShell(`LicoUpEngineering-${nonce}`)};New-Item -ItemType Directory -Path $root -Force|Out-Null;[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($root))`;
  const result = spawnSync("ssh", [...sshOptions, config.sshTarget,
    `powershell -NoProfile -NonInteractive -EncodedCommand ${encodedPowerShell(source)}`], {
    encoding: "utf8",
  });
  if (result.status !== 0) fail("windows_target_transport_failed");
  try {
    const encoded = result.stdout.trim().split(/\r?\n/u).at(-1);
    const value = Buffer.from(encoded, "base64").toString("utf8");
    if (!value.endsWith(`LicoUpEngineering-${nonce}`)) fail("windows_target_remote_root_invalid");
    return value.replaceAll("\\", "/");
  } catch {
    fail("windows_target_remote_root_invalid");
  }
}

function emitStage(stage, fields = {}) {
  process.stderr.write(`[windows-target] ${JSON.stringify({ stage, ...fields })}\n`);
}

async function executeRemote(config, source) {
  return await new Promise((resolve) => {
    const child = spawn("ssh", [...sshOptions, config.sshTarget,
      `powershell -NoProfile -NonInteractive -EncodedCommand ${encodedPowerShell(source)}`], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let pending = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      pending += chunk;
      const lines = pending.split(/\r?\n/u);
      pending = lines.pop() || "";
      for (const line of lines) {
        try {
          const event = JSON.parse(line);
          if (["bootstrap-complete", "check-start", "check-complete"].includes(event.event)) {
            emitStage(event.event);
          }
        } catch {}
      }
    });
    child.stderr.on("data", () => {});
    child.once("error", () => resolve({ status: null, stdout }));
    child.once("close", (status) => resolve({ status, stdout }));
  });
}

export function executionScript({ nonce, base, head, target, modules }) {
  const expected = Buffer.from(JSON.stringify(modules), "utf8").toString("base64");
  return String.raw`$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ${quotePowerShell(`LicoUpEngineering-${nonce}`)}
$cache=Join-Path $env:TEMP 'LicoUpEngineeringCache'
$repo=Join-Path $root 'candidate'
$pack=Join-Path $root 'candidate.pack'
$log=Join-Path $root 'gate.log'
$preserve=$false
try {
  New-Item -ItemType Directory -Path $cache,$repo -Force | Out-Null
  git init -q $repo
  $info=New-Object Diagnostics.ProcessStartInfo
  $info.FileName='git.exe'
  $info.Arguments='-C "'+$repo+'" index-pack --stdin --fix-thin --keep'
  $info.UseShellExecute=$false
  $info.RedirectStandardInput=$true
  $info.RedirectStandardOutput=$true
  $info.RedirectStandardError=$true
  $process=New-Object Diagnostics.Process
  $process.StartInfo=$info
  [void]$process.Start()
  $stream=[IO.File]::OpenRead($pack)
  try{$stream.CopyTo($process.StandardInput.BaseStream)}finally{$stream.Dispose();$process.StandardInput.Close()}
  $process.WaitForExit()
  if($process.ExitCode -ne 0){throw 'candidate_pack_rejected'}
  git -C $repo update-ref refs/heads/base ${quotePowerShell(base)}
  git -C $repo update-ref refs/heads/candidate ${quotePowerShell(head)}
  git -C $repo checkout -q -f candidate
  if((git -C $repo rev-parse HEAD).Trim().ToLowerInvariant() -ne ${quotePowerShell(head)}){throw 'candidate_head_mismatch'}
  if([bool](git -C $repo status --porcelain=v1 --untracked-files=all)){throw 'candidate_not_clean'}

  $nodeRoot=Join-Path $cache ${quotePowerShell(`node-v${nodeVersion}-win-x64`)}
  $nodeExe=Join-Path $nodeRoot 'node.exe'
  if(!(Test-Path -LiteralPath $nodeExe -PathType Leaf)){
    $zip=Join-Path $root 'node.zip'
    Invoke-WebRequest -UseBasicParsing -Uri ${quotePowerShell(`https://nodejs.org/dist/v${nodeVersion}/node-v${nodeVersion}-win-x64.zip`)} -OutFile $zip
    if((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant() -ne ${quotePowerShell(nodeArchiveSha256)}){throw 'node_archive_digest_mismatch'}
    Expand-Archive -LiteralPath $zip -DestinationPath $cache -Force
  }
  if((& $nodeExe --version).Trim() -ne ${quotePowerShell(`v${nodeVersion}`)}){throw 'node_version_mismatch'}

  $env:CARGO_HOME=Join-Path $cache 'cargo'
  $env:RUSTUP_HOME=Join-Path $cache 'rustup'
  $rustup=Join-Path $env:CARGO_HOME 'bin\rustup.exe'
  if(!(Test-Path -LiteralPath $rustup -PathType Leaf)){
    $rustupInit=Join-Path $root 'rustup-init.exe'
    Invoke-WebRequest -UseBasicParsing -Uri ${quotePowerShell(`https://static.rust-lang.org/rustup/archive/${rustupVersion}/x86_64-pc-windows-msvc/rustup-init.exe`)} -OutFile $rustupInit
    if((Get-FileHash -Algorithm SHA256 -LiteralPath $rustupInit).Hash.ToLowerInvariant() -ne ${quotePowerShell(rustupSha256)}){throw 'rustup_archive_digest_mismatch'}
    & $rustupInit -y --profile minimal --default-toolchain none --no-modify-path | Out-Null
    if($LASTEXITCODE -ne 0){throw 'rustup_install_failed'}
  }
  & $rustup toolchain install ${quotePowerShell(rustVersion)} --profile minimal | Out-Null
  if($LASTEXITCODE -ne 0){throw 'rust_toolchain_install_failed'}

  $vswhere=Join-Path ${"$"}{env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if(!(Test-Path -LiteralPath $vswhere -PathType Leaf)){throw 'visual_cpp_locator_missing'}
  $vsRoot=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
  $vsDev=Join-Path $vsRoot 'Common7\Tools\VsDevCmd.bat'
  if(!$vsRoot -or !(Test-Path -LiteralPath $vsDev -PathType Leaf)){throw 'visual_cpp_environment_missing'}
  Write-Output '{"event":"bootstrap-complete"}'
  $npm=Join-Path $nodeRoot 'npm.cmd'
  $command='call "'+$vsDev+'" -arch=x64 -host_arch=x64 >nul && set "PATH='+$nodeRoot+';'+$env:CARGO_HOME+'\bin;%PATH%" && set "CARGO_HOME='+$env:CARGO_HOME+'" && set "RUSTUP_HOME='+$env:RUSTUP_HOME+'" && cd /d "'+$repo+'" && "'+$npm+'" run client:gate:verify -- --base ${base} --head ${head} --target ${target} --execution target --host win32 > "'+$log+'" 2>&1'
  Write-Output '{"event":"check-start"}'
  cmd.exe /d /s /c $command
  $gateExit=$LASTEXITCODE
  Write-Output '{"event":"check-complete"}'
  $summary=$null
  foreach($line in (Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)){
    try{$candidate=$line|ConvertFrom-Json -ErrorAction Stop;if($candidate.schemaVersion -eq ${quotePowerShell(schemaVersion)} -and $candidate.execution -eq 'target'){$summary=$candidate}}catch{}
  }
  if($null -eq $summary){throw 'target_summary_missing'}
  $expected=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(${quotePowerShell(expected)}))|ConvertFrom-Json
  $actual=@($summary.stepIds|Sort-Object)
  $wanted=@($expected|Sort-Object)
  if((ConvertTo-Json -Compress $actual) -ne (ConvertTo-Json -Compress $wanted)){throw 'target_module_selection_mismatch'}
  if($summary.head -ne ${quotePowerShell(head)} -or $summary.host -ne 'win32'){throw 'target_summary_binding_mismatch'}
  $preserve=($gateExit -ne 0 -or !$summary.ok)
  [ordered]@{status=if($gateExit -eq 0 -and $summary.ok){'passed'}else{'failed'};exitCode=$gateExit;summary=$summary;abi='msvc';architecture='x64'}|ConvertTo-Json -Compress -Depth 8
} catch {
  $preserve=$true
  [ordered]@{status='blocked';reason=if($_.Exception.Message -match '^[a-z0-9_]+$'){$_.Exception.Message}else{'windows_target_execution_failed'};abi='msvc';architecture='x64'}|ConvertTo-Json -Compress
} finally {
  if(!$preserve){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
`;
}

function blockedReceipt(args, reason) {
  return Object.freeze({
    ok: false,
    schemaVersion,
    target: args.target,
    execution: "target",
    host: "win32",
    head: args.head,
    stepIds: args.modules,
    selectedStepCount: args.modules.length,
    complete: false,
    mergeReady: false,
    status: "blocked",
    reason,
  });
}

function parseRemoteEnvelope(stdout) {
  for (const line of stdout.trim().split(/\r?\n/u).reverse()) {
    try {
      const value = JSON.parse(line);
      if (["passed", "failed", "blocked"].includes(value.status)) return value;
    } catch {}
  }
  return null;
}

function collectFailureLog(config, nonce, head) {
  const source = String.raw`$root=Join-Path $env:TEMP ${quotePowerShell(`LicoUpEngineering-${nonce}`)}
$log=Join-Path $root 'gate.log'
try{if(Test-Path -LiteralPath $log -PathType Leaf){[Convert]::ToBase64String([IO.File]::ReadAllBytes($log))}}finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}`;
  const result = spawnSync("ssh", [...sshOptions, config.sshTarget,
    `powershell -NoProfile -NonInteractive -EncodedCommand ${encodedPowerShell(source)}`], {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0 || !result.stdout.trim()) return false;
  let bytes;
  try {
    bytes = Buffer.from(result.stdout.trim().split(/\r?\n/u).at(-1), "base64");
  } catch {
    return false;
  }
  if (bytes.length === 0 || bytes.length > 8 * 1024 * 1024) return false;
  const directory = path.join(repoRoot, "build", "private", "windows-target");
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const destination = path.join(directory, `${head}.log`);
  const temporary = `${destination}.tmp`;
  writeFileSync(temporary, bytes, { mode: 0o600 });
  chmodSync(temporary, 0o600);
  renameSync(temporary, destination);
  return true;
}

export async function runWindowsTarget(args) {
  const config = readPrivateTargetConfig(args.config);
  const actualHead = runGit(["rev-parse", "HEAD"]).trim().toLowerCase();
  const state = runGit(["status", "--porcelain=v1", "--untracked-files=all"]);
  if (actualHead !== args.head || state.length !== 0) fail("windows_target_source_not_clean_candidate");
  runGit(["cat-file", "-e", `${args.base}^{commit}`]);
  const temporary = mkdtempSync(path.join(os.tmpdir(), "licoup-windows-target-"));
  const pack = path.join(temporary, "candidate.pack");
  const nonce = randomBytes(12).toString("hex");
  try {
    await writeCandidatePack({ base: args.base, head: args.head, destination: pack });
    emitStage("pack-complete", { bytes: statSync(pack).size });
    const targetRoot = remoteRoot(config, nonce);
    const upload = spawnSync("scp", [...sshOptions, pack,
      `${config.sshTarget}:${targetRoot}/candidate.pack`], {
      stdio: ["ignore", "pipe", "pipe"],
      encoding: "utf8",
    });
    if (upload.status !== 0) {
      collectFailureLog(config, nonce, args.head);
      return blockedReceipt(args, "windows_target_transport_failed");
    }
    emitStage("upload-complete", { bytes: statSync(pack).size });
    const execution = await executeRemote(config, executionScript({ ...args, nonce }));
    if (execution.status !== 0) {
      return Object.freeze({
        ...blockedReceipt(args, "windows_target_transport_failed"),
        failureLogStored: collectFailureLog(config, nonce, args.head),
      });
    }
    const envelope = parseRemoteEnvelope(execution.stdout);
    if (!envelope || envelope.status === "blocked") {
      return Object.freeze({
        ...blockedReceipt(args, envelope?.reason || "windows_target_receipt_missing"),
        failureLogStored: collectFailureLog(config, nonce, args.head),
      });
    }
    const failureLogStored = envelope.status === "failed"
      ? collectFailureLog(config, nonce, args.head)
      : false;
    return Object.freeze({
      ...envelope.summary,
      status: envelope.status,
      abi: "msvc",
      architecture: "x64",
      failureLogStored,
    });
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

async function selfTest() {
  const fixture = mkdtempSync(path.join(os.tmpdir(), "licoup-windows-target-fixture-"));
  const pack = path.join(fixture, "candidate.pack");
  const reconstructed = path.join(fixture, "reconstructed");
  try {
    runGit(["init", "-q"], { cwd: fixture });
    runGit(["config", "user.name", "fixture"], { cwd: fixture });
    runGit(["config", "user.email", "fixture@invalid.example"], { cwd: fixture });
    writeFileSync(path.join(fixture, "source.txt"), "base\n", "utf8");
    runGit(["add", "source.txt"], { cwd: fixture });
    runGit(["commit", "-qm", "base"], { cwd: fixture });
    const base = runGit(["rev-parse", "HEAD"], { cwd: fixture }).trim();
    writeFileSync(path.join(fixture, "source.txt"), "head\n", "utf8");
    runGit(["commit", "-qam", "head"], { cwd: fixture });
    const head = runGit(["rev-parse", "HEAD"], { cwd: fixture }).trim();
    await writeCandidatePack({ base, head, destination: pack, cwd: fixture });
    assert.equal(statSync(pack).mode & 0o077, 0);
    runGit(["init", "-q", reconstructed], { cwd: fixture });
    runGit(["-C", reconstructed, "index-pack", "--stdin", "--fix-thin", "--keep"], {
      cwd: fixture,
      input: readFileSync(pack),
      encoding: "buffer",
    });
    runGit(["-C", reconstructed, "update-ref", "refs/heads/base", base], { cwd: fixture });
    runGit(["-C", reconstructed, "update-ref", "refs/heads/candidate", head], { cwd: fixture });
    runGit(["-C", reconstructed, "checkout", "-q", "-f", "candidate"], { cwd: fixture });
    assert.equal(runGit(["-C", reconstructed, "rev-parse", "HEAD"], { cwd: fixture }).trim(), head);
    assert.equal(runGit(["-C", reconstructed, "status", "--porcelain=v1", "--untracked-files=all"], { cwd: fixture }), "");
    const script = executionScript({ nonce: "0".repeat(24), base, head, target: "pr", modules: ["rust.synthetic"] });
    assert.match(script, /vswhere\.exe/u);
    assert.match(script, /VsDevCmd\.bat/u);
    assert.match(script, /candidate_not_clean/u);
    assert.doesNotMatch(script, /sshTarget|windows-target\.json/u);
    assert.deepEqual(parseArgs(["run", "--base", base, "--head", head, "--target", "pr", "--module", "rust.synthetic"]).modules, ["rust.synthetic"]);
    assert.throws(() => parseArgs(["run", "--base", base, "--head", head, "--target", "commit", "--module", "rust.synthetic"]));
    return { ok: true, schemaVersion: "licoup.client-windows-target-runner.self-test.v1", exactCandidatePack: true, privateTransportConfig: true, msvcOwnerDiscovery: true };
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
    const result = args.command === "self-test" ? await selfTest() : await runWindowsTarget(args);
    process.stdout.write(`${JSON.stringify(result)}\n`);
    if (result.ok === false || ["failed", "blocked"].includes(result.status)) process.exitCode = 1;
  } catch (error) {
    const safe = /^[a-z0-9_]+$/u.test(error?.message || "") ? error.message : "windows_target_runner_failed";
    process.stderr.write(`${JSON.stringify({ status: "blocked", reason: safe })}\n`);
    process.exitCode = 1;
  }
}

await main();
