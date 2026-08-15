#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
export const readmeFastManifestPath = "tools/scripts/config/readme-fast-files.json";

function safeRevision(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 256 &&
    !value.startsWith("-") && !/[\0-\x20\x7f]/u.test(value);
}

function normalizedManifest(document) {
  if (!Array.isArray(document) || document.length === 0) return null;
  const files = [];
  for (const value of document) {
    if (
      typeof value !== "string" || value.length === 0 || value.startsWith("/") ||
      value.startsWith("../") || value.includes("/../") || value.includes("\\") ||
      /[\0\r\n]/u.test(value) || path.posix.normalize(value) !== value
    ) {
      return null;
    }
    files.push(value);
  }
  return Object.freeze([...new Set(files)]);
}

function git(root, args) {
  const result = spawnSync("git", args, {
    cwd: root,
    encoding: "buffer",
    shell: false,
    stdio: ["ignore", "pipe", "ignore"],
    maxBuffer: 4 * 1024 * 1024,
  });
  return result.error || result.status !== 0 ? null : result.stdout;
}

function manifestAt(root, revision) {
  const source = git(root, ["show", `${revision}:${readmeFastManifestPath}`]);
  if (!source) return null;
  try {
    return normalizedManifest(JSON.parse(source.toString("utf8")));
  } catch {
    return null;
  }
}

function changedEntries(root, base, head) {
  const output = git(root, ["diff", "--name-status", "--no-renames", "-z", base, head, "--"]);
  if (!output) return null;
  const tokens = output.toString("utf8").split("\0").filter(Boolean);
  if (tokens.length % 2 !== 0) return null;
  const entries = [];
  for (let index = 0; index < tokens.length; index += 2) {
    const status = tokens[index];
    const relativePath = tokens[index + 1];
    if (!/^[AMD]$/u.test(status) || relativePath.length === 0) return null;
    entries.push(Object.freeze({ status, path: relativePath }));
  }
  return Object.freeze(entries);
}

export function classifyReadmeFastPath({ base, head = "HEAD", root = repoRoot }) {
  if (!safeRevision(base) || !safeRevision(head)) {
    return Object.freeze({ eligible: false, changedCount: 0, entries: Object.freeze([]) });
  }
  const before = manifestAt(root, base);
  const after = manifestAt(root, head);
  const entries = changedEntries(root, base, head);
  if (!before || !after || !entries || entries.length === 0) {
    return Object.freeze({
      eligible: false,
      changedCount: entries?.length || 0,
      entries: entries || Object.freeze([]),
    });
  }
  const allowed = new Set([...before, ...after, readmeFastManifestPath]);
  return Object.freeze({
    eligible: entries.every((entry) => allowed.has(entry.path)),
    changedCount: entries.length,
    entries,
  });
}

function writeOutput(result) {
  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(process.env.GITHUB_OUTPUT,
      `readme_fast=${result.eligible === true}\nchanged_count=${result.changedCount}\n`,
      { encoding: "utf8", mode: 0o600 });
  }
  process.stdout.write(`${JSON.stringify({
    ok: result.ok === true,
    eligible: result.eligible === true,
    readmeFast: result.readmeFast === true,
    changedCount: result.changedCount,
    privateDataIncluded: false,
  })}\n`);
}

function argumentsFor(args) {
  const values = {};
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if ((flag !== "--base" && flag !== "--head") || value === undefined) return null;
    values[flag.slice(2)] = value;
  }
  return values.base && values.head && Object.keys(values).length === 2 ? values : null;
}

export function main(args = process.argv.slice(2)) {
  const [command, ...rest] = args;
  const values = argumentsFor(rest);
  if (!values) throw new Error("arguments_invalid");
  if (command === "classify") {
    writeOutput(classifyReadmeFastPath(values));
    return;
  }
  throw new Error("command_invalid");
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    main();
  } catch {
    if (process.argv[2] === "classify") {
      writeOutput({ eligible: false, changedCount: 0, entries: Object.freeze([]) });
    } else {
      process.stderr.write(`${JSON.stringify({ ok: false, privateDataIncluded: false })}\n`);
      process.exitCode = 1;
    }
  }
}
