#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  rmSync,
  statSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const canonicalAuditorRemote = "https://github.com/LicoLand/Lico-Auditor.git";
const commitPattern = /^[a-f0-9]{40}$/u;
const maximumOutputBytes = 16 * 1024 * 1024;

class AuditorPreflightError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function reject(code) {
  throw new AuditorPreflightError(code);
}

function run(command, args, {
  cwd = repoRoot,
  timeout = 120_000,
  code = "auditor_preflight_command_failed",
} = {}) {
  const result = spawnSync(command, args, {
    cwd,
    env: {
      PATH: process.env.PATH || "/usr/bin:/bin:/usr/sbin:/sbin",
      LANG: "C.UTF-8",
      LC_ALL: "C.UTF-8",
    },
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout,
    maxBuffer: maximumOutputBytes,
  });
  if (result.error || result.status !== 0) reject(code);
}

export function buildAuditorGateArguments({
  repositoryPath,
  baseSha = "",
  headSha = "",
  workingTree = false,
}) {
  if (!path.isAbsolute(repositoryPath)) reject("auditor_preflight_repository_invalid");
  if (workingTree) {
    if (baseSha || headSha) reject("auditor_preflight_range_invalid");
    return ["gate", "--repo", repositoryPath, "--profile", "licoup", "--format", "text"];
  }
  if (!commitPattern.test(baseSha) || !commitPattern.test(headSha)) {
    reject("auditor_preflight_range_invalid");
  }
  return [
    "gate",
    "--repo",
    repositoryPath,
    "--profile",
    "licoup",
    "--history",
    "--ref",
    `${baseSha}..${headSha}`,
    "--format",
    "text",
  ];
}

function parseArgs(argv) {
  const options = { baseSha: "", headSha: "", workingTree: false };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--working-tree") {
      options.workingTree = true;
    } else if (value === "--base-sha" || value === "--head-sha") {
      if (index + 1 >= argv.length) reject("auditor_preflight_argument_missing");
      options[value === "--base-sha" ? "baseSha" : "headSha"] = argv[index + 1];
      index += 1;
    } else {
      reject("auditor_preflight_argument_invalid");
    }
  }
  if (options.workingTree) {
    if (options.baseSha || options.headSha) reject("auditor_preflight_range_invalid");
  } else if (!commitPattern.test(options.baseSha) || !commitPattern.test(options.headSha)) {
    reject("auditor_preflight_range_invalid");
  }
  return options;
}

function explicitAuditorRoot() {
  const configured = String(process.env.LICO_AUDITOR_ROOT || "").trim();
  if (!configured) return "";
  if (!path.isAbsolute(configured) || !existsSync(configured) ||
    !statSync(configured).isDirectory() ||
    !existsSync(path.join(configured, "bin/lico-auditor"))) {
    reject("auditor_preflight_root_invalid");
  }
  return path.resolve(configured);
}

function verifySourceOfTruth(auditorRoot) {
  run(path.join(auditorRoot, "bin/lico-auditor"), [
    "source-of-truth",
    "--repo",
    auditorRoot,
    "--remote",
    "origin",
    "--branch",
    "only",
    "--require-current-head",
    "--enforce-remote-heads",
  ], {
    cwd: auditorRoot,
    timeout: 180_000,
    code: "auditor_source_of_truth_failed",
  });
}

export function runAuditorPreflight(options) {
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "licoup-auditor-preflight-"));
  try {
    let auditorRoot = explicitAuditorRoot();
    if (!auditorRoot) {
      auditorRoot = path.join(temporaryRoot, "auditor");
      run("git", [
        "clone",
        "--quiet",
        "--single-branch",
        "--branch",
        "only",
        "--",
        canonicalAuditorRemote,
        auditorRoot,
      ], {
        timeout: 180_000,
        code: "auditor_clone_failed",
      });
    }
    verifySourceOfTruth(auditorRoot);
    run(
      path.join(auditorRoot, "bin/lico-auditor"),
      buildAuditorGateArguments({
        repositoryPath: repoRoot,
        baseSha: options.baseSha,
        headSha: options.headSha,
        workingTree: options.workingTree,
      }),
      {
        cwd: auditorRoot,
        timeout: 30 * 60 * 1000,
        code: "auditor_profile_rejected_candidate",
      },
    );
    process.stdout.write(
      `client_auditor_preflight=passed mode=${options.workingTree ? "working-tree" : "committed"}\n`,
    );
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

function main() {
  runAuditorPreflight(parseArgs(process.argv.slice(2)));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    const code = error instanceof AuditorPreflightError
      ? error.code
      : "auditor_preflight_failed";
    process.stderr.write(`LicoUp Auditor preflight: ${code}\n`);
    process.exitCode = 1;
  }
}
