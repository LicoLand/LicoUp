import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  runAndroidSdkBootstrapSelfTest,
} from "../client-android-sdk-bootstrap.mjs";
import { parseArgs } from "./cli.mjs";
import {
  inspectLocalDocker,
  resolveRunnerCacheRoot,
  runnerDockerArgs,
} from "./docker.mjs";
import { materializeCandidate } from "./snapshot.mjs";
import {
  importEngineeringReport,
  prepareEngineeringDependencies,
  selectedFlutterPackageRoots,
} from "./run.mjs";

function git(root, args) {
  return execFileSync("git", args, {
    cwd: root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function testSnapshot() {
  const fixture = mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-fixture-"));
  const output = mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-snapshot-"));
  const repeatedOutput = mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-snapshot-"));
  const changedOutput = mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-snapshot-"));
  try {
    git(fixture, ["init", "-q"]);
    git(fixture, ["config", "user.name", "fixture"]);
    git(fixture, ["config", "user.email", "fixture@invalid.example"]);
    writeFileSync(path.join(fixture, ".gitignore"), "ignored.txt\n", "utf8");
    writeFileSync(path.join(fixture, "tracked.txt"), "before\n", "utf8");
    writeFileSync(path.join(fixture, "deleted.txt"), "deleted\n", "utf8");
    git(fixture, ["add", "--all"]);
    git(fixture, ["commit", "-qm", "fixture"]);
    writeFileSync(path.join(fixture, "tracked.txt"), "after\n", "utf8");
    utimesSync(path.join(fixture, "tracked.txt"), new Date(1_700_000_000_000),
      new Date(1_700_000_000_000));
    writeFileSync(path.join(fixture, "untracked.txt"), "candidate\n", "utf8");
    writeFileSync(path.join(fixture, "ignored.txt"), "private\n", "utf8");
    rmSync(path.join(fixture, "deleted.txt"));
    const result = materializeCandidate(fixture, output);
    assert.equal(readFileSync(path.join(output, "tracked.txt"), "utf8"), "after\n");
    assert.equal(readFileSync(path.join(output, "untracked.txt"), "utf8"), "candidate\n");
    assert.equal(readFileSync(path.join(output, ".gitignore"), "utf8"), "ignored.txt\n");
    assert.equal(result.fileCount, 3);
    assert.match(result.sourceStateDigest, /^sha256:[a-f0-9]{64}$/u);
    assert.throws(() => readFileSync(path.join(output, "ignored.txt")));
    assert.throws(() => readFileSync(path.join(output, "deleted.txt")));
    materializeCandidate(fixture, repeatedOutput);
    const initialSourceMtime = statSync(path.join(fixture, "tracked.txt")).mtimeMs;
    assert.ok(statSync(path.join(output, "tracked.txt")).mtimeMs > initialSourceMtime);
    assert.ok(statSync(path.join(repeatedOutput, "tracked.txt")).mtimeMs > initialSourceMtime);
    writeFileSync(path.join(fixture, "tracked.txt"), "changed again\n", "utf8");
    utimesSync(path.join(fixture, "tracked.txt"), new Date(1_700_000_100_000),
      new Date(1_700_000_100_000));
    materializeCandidate(fixture, changedOutput);
    assert.ok(statSync(path.join(changedOutput, "tracked.txt")).mtimeMs >
      statSync(path.join(fixture, "tracked.txt")).mtimeMs);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
    rmSync(output, { recursive: true, force: true });
    rmSync(repeatedOutput, { recursive: true, force: true });
    rmSync(changedOutput, { recursive: true, force: true });
  }
}

function testDiagnosticImport() {
  const output = mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-output-"));
  const destination = mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-import-"));
  try {
    mkdirSync(path.join(output, "private", "client-regression"), { recursive: true, mode: 0o700 });
    writeFileSync(path.join(output, "private", "client-regression", "owner.failed.log"),
      "private assertion\n", { mode: 0o600 });
    writeFileSync(path.join(output, "client-module-regression.json"), JSON.stringify({
      results: [{
        id: "owner.failed",
        status: "failed",
        diagnosticLog: "build/private/client-regression/owner.failed.log",
      }],
    }), { mode: 0o600 });
    const imported = importEngineeringReport(output, destination);
    assert.deepEqual(imported, { reportImported: true, diagnosticCount: 1 });
    assert.equal(readFileSync(path.join(destination, "private/client-regression/owner.failed.log"), "utf8"),
      "private assertion\n");
    assert.equal(statSync(path.join(destination, "private/client-regression/owner.failed.log")).mode & 0o077, 0);
    writeFileSync(path.join(output, "client-module-regression.json"), JSON.stringify({
      results: [{ status: "failed", diagnosticLog: "build/private/client-regression/../private.log" }],
    }), { mode: 0o600 });
    assert.throws(() => importEngineeringReport(output, destination), /diagnostic_reference_unsafe/u);
  } finally {
    rmSync(output, { recursive: true, force: true });
    rmSync(destination, { recursive: true, force: true });
  }
}

function testSharedProjectCache() {
  const fixture = mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-cache-fixture-"));
  const primary = path.join(fixture, "primary");
  const sibling = path.join(fixture, "sibling");
  const independent = path.join(fixture, "independent");
  try {
    mkdirSync(primary);
    git(primary, ["init", "-q"]);
    git(primary, ["config", "user.name", "fixture"]);
    git(primary, ["config", "user.email", "fixture@invalid.example"]);
    writeFileSync(path.join(primary, "tracked.txt"), "fixture\n", "utf8");
    git(primary, ["add", "tracked.txt"]);
    git(primary, ["commit", "-qm", "fixture"]);
    git(primary, ["worktree", "add", "-qb", "fixture-sibling", sibling]);
    mkdirSync(independent);
    git(independent, ["init", "-q"]);
    const primaryCache = resolveRunnerCacheRoot(primary);
    const siblingCache = resolveRunnerCacheRoot(sibling);
    const independentCache = resolveRunnerCacheRoot(independent);
    assert.equal(primaryCache, siblingCache);
    assert.notEqual(primaryCache, independentCache);
    assert.equal(path.basename(primaryCache), "licoup-local-linux-ci-cache");
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
}

export async function runSelfTest() {
  assert.deepEqual(parseArgs(["run", "--lane", "rust"]), {
    command: "run",
    lane: "rust",
    profile: null,
    moduleIds: [],
  });
  assert.deepEqual(parseArgs(["run", "--profile", "engineering"]), {
    command: "run",
    lane: null,
    profile: "engineering",
    moduleIds: [],
  });
  assert.deepEqual(parseArgs(["prepare", "--module", "flutter.package.presentation-contract"]), {
    command: "prepare",
    lane: null,
    profile: null,
    moduleIds: ["flutter.package.presentation-contract"],
  });
  assert.deepEqual(parseArgs([
    "run", "--profile", "engineering", "--module", "release.model-pricing",
  ]), {
    command: "run",
    lane: null,
    profile: "engineering",
    moduleIds: ["release.model-pricing"],
  });
  assert.throws(() => parseArgs(["run", "--lane", "unknown"]));
  assert.deepEqual(inspectLocalDocker((command, args) => {
    assert.equal(command, "docker");
    return args[0] === "context"
      ? { status: 0, stdout: '"unix:///local/docker.sock"\n', stderr: "" }
      : { status: 0, stdout: '"linux"\n', stderr: "" };
  }), { localUnix: true, linuxEngine: true });
  assert.throws(() => inspectLocalDocker((command, args) => args[0] === "context"
    ? { status: 0, stdout: '"tcp://remote.example:2376"\n', stderr: "" }
    : { status: 0, stdout: '"linux"\n', stderr: "" }));
  const args = runnerDockerArgs({
    image: { tag: "synthetic:image" },
    lane: "source",
    profile: null,
    candidateRoot: "/synthetic/candidate",
    cacheRoot: mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-cache-")),
    outputRoot: "/synthetic/output",
    cargoAuditVersion: "0.22.2",
    javaMajorVersion: "17",
    androidPackages: [
      "platforms;android-33",
      "ndk;27.0.12077973",
      "ndk;30.0.14904198",
    ],
  });
  try {
    assert.ok(args.includes("linux/amd64"));
    assert.ok(args.includes("type=bind,src=/synthetic/candidate,dst=/candidate,readonly"));
    assert.equal(args.some((arg) => arg.includes("docker.sock")), false);
    assert.equal(args.some((arg) => arg.includes("/Users/")), false);
    assert.equal(args.some((arg) => arg.includes("npm run client:gate:source")), true);
    assert.equal(args.includes("LICO_CLIENT_GATE_ISOLATED_LINUX=1"), true);
  } finally {
    const cacheArgument = args.find((arg) => arg.includes("/licoup-linux-ci-cache-"));
    if (cacheArgument) {
      const root = cacheArgument.split(",dst=")[0].replace(/^type=bind,src=/u, "");
      rmSync(path.dirname(root), { recursive: true, force: true });
    }
  }
  const focusedArgs = runnerDockerArgs({
    image: { tag: "synthetic:image" },
    lane: null,
    profile: "engineering",
    moduleIds: ["release.model-pricing"],
    candidateRoot: "/synthetic/candidate",
    cacheRoot: mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-cache-")),
    outputRoot: "/synthetic/output",
    cargoAuditVersion: "0.22.2",
    javaMajorVersion: "17",
  });
  assert.match(focusedArgs.at(-1), /--host linux --module release\.model-pricing/u);
  assert.match(focusedArgs.at(-1), /client-local-linux-runner\.mjs prepare --module release\.model-pricing/u);
  assert.match(focusedArgs.at(-1), /output\/private\/client-regression/u);
  assert.match(focusedArgs.at(-1), /export JAVA_HOME=\$java_home/u);
  assert.match(focusedArgs.at(-1), /openjdk version "17/u);
  const androidArgs = runnerDockerArgs({
    image: { tag: "synthetic:image" },
    lane: "android",
    profile: null,
    candidateRoot: "/synthetic/candidate",
    cacheRoot: mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-android-cache-")),
    outputRoot: "/synthetic/output",
    cargoAuditVersion: "0.22.2",
    javaMajorVersion: "17",
  });
  try {
    assert.equal(androidArgs.some((arg) => arg.includes(
      "node tools/scripts/client-android-sdk-bootstrap.mjs",
    )), true);
    assert.equal(androidArgs.some((arg) => arg.includes("npm run client:gate:android")), true);
  } finally {
    const cacheArgument = androidArgs.find((arg) => arg.includes("/licoup-linux-ci-android-cache-"));
    if (cacheArgument) {
      const root = cacheArgument.split(",dst=")[0].replace(/^type=bind,src=/u, "");
      rmSync(path.dirname(root), { recursive: true, force: true });
    }
  }
  testSnapshot();
  assert.deepEqual(selectedFlutterPackageRoots([
    "flutter.package.presentation-contract",
    "flutter.package.presentation-runtime",
    "flutter.package.presentation-flutter",
  ]), [
    "packages/presentation_contract",
    "packages/presentation_flutter",
    "packages/presentation_runtime",
  ]);
  const prepared = [];
  assert.equal(await prepareEngineeringDependencies([
    "flutter.package.presentation-contract",
    "flutter.package.presentation-runtime",
    "flutter.package.presentation-flutter",
  ], async (command, commandArgs, cwd) => {
    prepared.push([command, commandArgs, path.relative(process.cwd(), cwd)]);
    return 0;
  }), 0);
  assert.deepEqual(prepared.map(([command, , cwd]) => [command, cwd]), [
    ["flutter", "packages/presentation_contract"],
    ["flutter", "packages/presentation_flutter"],
    ["flutter", "packages/presentation_runtime"],
  ]);
  assert.equal(prepared.every(([, commandArgs]) =>
    commandArgs.join(" ") === "pub get --enforce-lockfile"), true);
  const completePreparation = [];
  assert.equal(await prepareEngineeringDependencies([], async (command, commandArgs, cwd) => {
    completePreparation.push([command, commandArgs, path.relative(process.cwd(), cwd)]);
    return 0;
  }), 0);
  assert.deepEqual(completePreparation.filter(([command]) => command === "cargo")
    .map(([, commandArgs]) => commandArgs.at(-1)), [
    "Cargo.toml",
    "components/analytics/Cargo.toml",
    "sdk/usage-source/Cargo.toml",
  ]);
  assert.deepEqual(completePreparation.filter(([command]) => command === "flutter")
    .map(([, , cwd]) => cwd), [
    "packages/presentation_contract",
    "packages/presentation_flutter",
    "packages/presentation_runtime",
  ]);
  testDiagnosticImport();
  testSharedProjectCache();
  assert.equal((await runAndroidSdkBootstrapSelfTest()).status, "passed");
  return Object.freeze({
    ok: true,
    schemaVersion: "licoup.client-local-linux-ci.self-test.v1",
    localDockerFailClosed: true,
    workingTreeSnapshotReady: true,
    ignoredDataExcluded: true,
    deletedPathExcluded: true,
    linuxAmd64Required: true,
    dockerSocketMounted: false,
    sharedProjectToolCache: true,
    rawLogsIncluded: false,
    privateDiagnosticsImported: true,
    androidBootstrapReady: true,
  });
}
