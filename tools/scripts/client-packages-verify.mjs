#!/usr/bin/env node

// Verifies the Dart and Flutter packages that a revision actually touches.
//
// The Flutter lane runs the desktop app's get/format/analyze/test. This step
// covers the package surface explicitly: a package present in the change set
// is formatted, analyzed, and tested here, a package the revision does not
// touch is reported not-applicable, and a changed package path without a
// pubspec on disk fails instead of passing silently.
//
// Commands run through the existing client toolchain runner, so the pub cache
// and toolchain checks match the rest of the lane. Pass --plan to resolve the
// per-package commands without running them.

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { flutterEnv } from "./client-toolchain-runner/flutter.mjs";

const REPO_ROOT = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const SCHEMA_VERSION = "licomesh.client-packages-verify.v1";

function parseArgs(argv) {
  const options = { plan: false, changed: [], base: null, head: null };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--plan") {
      options.plan = true;
    } else if (arg === "--changed" && argv[index + 1]) {
      options.changed.push(...argv[index + 1].split(",").filter(Boolean));
      index += 1;
    } else if (arg === "--base" && argv[index + 1]) {
      options.base = argv[index + 1];
      index += 1;
    } else if (arg === "--head" && argv[index + 1]) {
      options.head = argv[index + 1];
      index += 1;
    } else {
      throw new Error(`unknown option: ${arg}`);
    }
  }
  return options;
}

function gitDiffNames(from, to) {
  const args = to
    ? ["diff", "--name-only", from, to, "--"]
    : ["diff", "--name-only", from, "--"];
  const result = spawnSync("git", args, { cwd: REPO_ROOT, encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(result.stderr.trim() || "unable to read the changed paths");
  }
  return result.stdout.split("\n").filter(Boolean);
}

function changedPaths(options) {
  if (options.changed.length > 0) {
    return [...new Set(options.changed)].sort();
  }
  if (options.base && options.head) {
    return gitDiffNames(options.base, options.head);
  }
  const eventPath = process.env.GITHUB_EVENT_PATH;
  if (eventPath && existsSync(eventPath)) {
    const event = JSON.parse(readFileSync(eventPath, "utf8"));
    const pullRequest = event.pull_request;
    if (pullRequest?.base?.sha && pullRequest?.head?.sha) {
      return gitDiffNames(pullRequest.base.sha, pullRequest.head.sha);
    }
  }
  return gitDiffNames("HEAD");
}

function packageDirectories() {
  const root = path.join(REPO_ROOT, "packages");
  if (!existsSync(root)) {
    return [];
  }
  return readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => `packages/${entry.name}`)
    .filter((directory) => existsSync(path.join(REPO_ROOT, directory, "pubspec.yaml")))
    .sort();
}

function isFlutterPackage(directory) {
  const pubspec = readFileSync(path.join(REPO_ROOT, directory, "pubspec.yaml"), "utf8");
  return /^\s+sdk:\s*flutter\s*$/mu.test(pubspec);
}

function packageCommands(directory) {
  const runner = isFlutterPackage(directory) ? "flutter" : "dart";
  const commands = [
    [runner, "pub", "get"],
    ["dart", "format", "--output=none", "--set-exit-if-changed", "."],
    [runner, "analyze"],
  ];
  if (existsSync(path.join(REPO_ROOT, directory, "test"))) {
    commands.push([runner, "test"]);
  }
  return commands;
}

function runThroughToolchain(directory, command) {
  const result = spawnSync(
    process.execPath,
    [
      "tools/scripts/client-toolchain-runner.mjs",
      "--check",
      "flutter",
      "--cwd",
      directory,
      "--",
      ...command,
    ],
    { cwd: REPO_ROOT, stdio: "inherit", env: flutterEnv(directory) },
  );
  return result.status === 0;
}

function main(argv) {
  const options = parseArgs(argv);
  const changed = changedPaths(options);
  const directories = packageDirectories();
  const touched = new Set(
    changed
      .map((file) => /^packages\/([^/]+)\//u.exec(file))
      .filter(Boolean)
      .map((match) => `packages/${match[1]}`),
  );
  const results = [];
  let ok = true;

  for (const directory of [...touched].sort()) {
    if (!directories.includes(directory)) {
      results.push({ directory, applicable: true, result: "missing", commands: [] });
      ok = false;
    }
  }

  for (const directory of directories) {
    const applicable = changed.some(
      (file) => file === directory || file.startsWith(`${directory}/`),
    );
    if (!applicable) {
      results.push({ directory, applicable: false, result: "not-applicable", commands: [] });
      continue;
    }
    const commands = packageCommands(directory);
    if (options.plan) {
      results.push({ directory, applicable: true, result: "planned", commands });
      continue;
    }
    let passed = true;
    for (const command of commands) {
      console.log(`[client-packages-verify] ${directory}$ ${command.join(" ")}`);
      if (!runThroughToolchain(directory, command)) {
        passed = false;
        break;
      }
    }
    results.push({
      directory,
      applicable: true,
      result: passed ? "passed" : "failed",
      commands,
    });
    if (!passed) {
      ok = false;
    }
  }

  process.stdout.write(
    `${JSON.stringify({ ok, schemaVersion: SCHEMA_VERSION, packages: results })}\n`,
  );
  if (!ok) {
    process.exitCode = 1;
  }
}

try {
  main(process.argv.slice(2));
} catch (error) {
  console.error(`[client-packages-verify] ${error.message}`);
  process.exitCode = 1;
}
