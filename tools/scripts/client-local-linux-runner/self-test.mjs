import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseArgs } from "./cli.mjs";
import { inspectLocalDocker, runnerDockerArgs } from "./docker.mjs";
import { materializeCandidate } from "./snapshot.mjs";

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
  } finally {
    rmSync(fixture, { recursive: true, force: true });
    rmSync(output, { recursive: true, force: true });
  }
}

export function runSelfTest() {
  assert.deepEqual(parseArgs(["run", "--lane", "rust"]), {
    command: "run",
    lane: "rust",
    profile: null,
  });
  assert.deepEqual(parseArgs(["run", "--profile", "engineering"]), {
    command: "run",
    lane: null,
    profile: "engineering",
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
  const androidArgs = runnerDockerArgs({
    image: { tag: "synthetic:image" },
    lane: "android",
    profile: null,
    candidateRoot: "/synthetic/candidate",
    cacheRoot: mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-android-cache-")),
    outputRoot: "/synthetic/output",
    cargoAuditVersion: "0.22.2",
    androidPackages: ["platforms;android-33", "ndk;27.0.12077973", "ndk;30.0.14904198"],
  });
  try {
    assert.equal(androidArgs.some((arg) => arg.includes("sdkmanager --sdk_root=/cache/android-sdk")), true);
    assert.equal(androidArgs.some((arg) => arg.includes("npm run client:gate:android")), true);
  } finally {
    const cacheArgument = androidArgs.find((arg) => arg.includes("/licoup-linux-ci-android-cache-"));
    if (cacheArgument) {
      const root = cacheArgument.split(",dst=")[0].replace(/^type=bind,src=/u, "");
      rmSync(path.dirname(root), { recursive: true, force: true });
    }
  }
  testSnapshot();
  return Object.freeze({
    ok: true,
    schemaVersion: "licoup.client-local-linux-ci.self-test.v1",
    localDockerFailClosed: true,
    workingTreeSnapshotReady: true,
    ignoredDataExcluded: true,
    deletedPathExcluded: true,
    linuxAmd64Required: true,
    dockerSocketMounted: false,
    rawLogsIncluded: false,
    androidBootstrapReady: true,
  });
}
