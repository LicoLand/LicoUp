#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, createReadStream, lstatSync, readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  SensitiveContentScanner,
  classifyPath,
} from "./lib/repository-sensitive-file-policy.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const manifestPath = "tools/scripts/config/docs-fast-promotion-manifest.json";
const manifestSchemaVersion = 1;
const regularBlobModes = new Set(["100644", "100755"]);

export class DocsFastPromotionError extends Error {
  constructor(code) {
    super(code);
    this.name = "DocsFastPromotionError";
    this.code = code;
  }
}

function reject(code) {
  throw new DocsFastPromotionError(code);
}

function normalizePath(value) {
  if (typeof value !== "string" || value.length === 0) reject("manifest_path_invalid");
  if (
    value !== value.replaceAll("\\", "/") ||
    value.startsWith("/") ||
    value.startsWith("./") ||
    value.startsWith("../") ||
    value.includes("/../") ||
    value.includes("//") ||
    /[\0\r\n]/u.test(value) ||
    /^[A-Za-z]:\//u.test(value) ||
    path.posix.normalize(value) !== value
  ) {
    reject("manifest_path_invalid");
  }
  return value;
}

export function validateDocsFastManifest(document) {
  if (
    document === null ||
    typeof document !== "object" ||
    Array.isArray(document) ||
    JSON.stringify(Object.keys(document).sort()) !== JSON.stringify(["files", "schemaVersion"]) ||
    document.schemaVersion !== manifestSchemaVersion ||
    !Array.isArray(document.files) ||
    document.files.length === 0
  ) {
    reject("manifest_schema_invalid");
  }
  const files = document.files.map(normalizePath);
  if (new Set(files).size !== files.length) reject("manifest_duplicate_path");
  if (JSON.stringify([...files].sort()) !== JSON.stringify(files)) {
    reject("manifest_paths_unsorted");
  }
  if (files.includes(manifestPath)) reject("manifest_self_exemption_forbidden");
  return Object.freeze([...files]);
}

export function readDocsFastManifest(root = repoRoot) {
  let document;
  try {
    document = JSON.parse(readFileSync(path.join(root, manifestPath), "utf8"));
  } catch {
    reject("manifest_unreadable");
  }
  return validateDocsFastManifest(document);
}

function validateRevision(value) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > 256 ||
    value.startsWith("-") ||
    /[\0-\x20\x7f]/u.test(value)
  ) {
    reject("revision_invalid");
  }
  return value;
}

function git(root, args, { allowFailure = false } = {}) {
  const result = spawnSync("git", args, {
    cwd: root,
    encoding: "buffer",
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    if (allowFailure) return null;
    reject("git_inspection_failed");
  }
  return result.stdout;
}

export function parseChangedEntries(buffer) {
  const tokens = buffer.toString("utf8").split("\0").filter(Boolean);
  if (tokens.length % 2 !== 0) reject("git_delta_invalid");
  const entries = [];
  for (let index = 0; index < tokens.length; index += 2) {
    const status = tokens[index];
    if (!/^[A-Z]$/u.test(status)) reject("git_delta_invalid");
    entries.push(Object.freeze({ status, path: normalizePath(tokens[index + 1]) }));
  }
  return Object.freeze(entries);
}

export function classifyDocsFastEntries(entries, manifestFiles) {
  if (!Array.isArray(entries) || !Array.isArray(manifestFiles)) {
    reject("classification_input_invalid");
  }
  const allowed = new Set(manifestFiles);
  const changed = new Set();
  let eligible = entries.length > 0;
  for (const entry of entries) {
    if (entry === null || typeof entry !== "object") reject("classification_input_invalid");
    const relativePath = normalizePath(entry.path);
    changed.add(relativePath);
    if (!allowed.has(relativePath) || (entry.status !== "A" && entry.status !== "M")) {
      eligible = false;
    }
  }
  return Object.freeze({ eligible, changedCount: changed.size });
}

export function inspectDocsFastDelta({ base, head = "HEAD", root = repoRoot }) {
  const safeBase = validateRevision(base);
  const safeHead = validateRevision(head);
  const output = git(root, [
    "diff", "--name-status", "--no-renames", "-z", safeBase, safeHead, "--",
  ]);
  const manifestFiles = readDocsFastManifest(root);
  const classification = classifyDocsFastEntries(parseChangedEntries(output), manifestFiles);
  return Object.freeze({ ...classification, manifestFiles });
}

async function scanStream(stream) {
  const scanner = new SensitiveContentScanner();
  for await (const chunk of stream) {
    if (scanner.feed(chunk).verdict === "reject") reject("sensitive_content");
  }
  if (scanner.finish().verdict === "reject") reject("sensitive_content");
}

export async function scanRegularWorktreeFile(root, relativePath) {
  const safePath = normalizePath(relativePath);
  if (classifyPath(safePath).verdict === "reject") reject("sensitive_extension");
  const absolutePath = path.join(root, safePath);
  const metadata = lstatSync(absolutePath, { throwIfNoEntry: false });
  if (!metadata || !metadata.isFile() || metadata.isSymbolicLink()) {
    reject("manifest_file_not_regular");
  }
  await scanStream(createReadStream(absolutePath, { highWaterMark: 64 * 1024 }));
}

async function scanGitBlob(root, head, relativePath) {
  const safePath = normalizePath(relativePath);
  if (classifyPath(safePath).verdict === "reject") reject("sensitive_extension");
  const tree = git(root, ["ls-tree", "-z", head, "--", safePath]);
  const match = /^(\d{6}) blob ([a-f0-9]{40,64})\t/u.exec(tree.toString("utf8"));
  if (!match || !regularBlobModes.has(match[1])) reject("manifest_file_not_regular");
  const child = spawn("git", ["cat-file", "blob", `${head}:${safePath}`], {
    cwd: root,
    env: process.env,
    shell: false,
    stdio: ["ignore", "pipe", "ignore"],
  });
  await scanStream(child.stdout);
  const status = await new Promise((resolve, rejectPromise) => {
    child.once("error", rejectPromise);
    child.once("close", resolve);
  }).catch(() => reject("git_blob_unreadable"));
  if (status !== 0) reject("git_blob_unreadable");
}

export async function verifyDocsFastCandidate({ base, head = "HEAD", root = repoRoot }) {
  const result = inspectDocsFastDelta({ base, head, root });
  if (!result.eligible) reject("candidate_not_eligible");
  for (const relativePath of result.manifestFiles) {
    await scanGitBlob(root, validateRevision(head), relativePath);
  }
  return Object.freeze({
    ok: true,
    eligible: true,
    changedCount: result.changedCount,
    manifestCount: result.manifestFiles.length,
    sensitive: false,
    privateDataIncluded: false,
  });
}

function writeOutput(receipt) {
  const outputPath = process.env.GITHUB_OUTPUT;
  if (outputPath) {
    const lines = [
      `docs_fast=${receipt.eligible}`,
      `changed_count=${receipt.changedCount}`,
    ];
    appendFileSync(outputPath, `${lines.join("\n")}\n`, { encoding: "utf8", mode: 0o600 });
  }
  process.stdout.write(`${JSON.stringify({ ...receipt, privateDataIncluded: false })}\n`);
}

function parseArgs(args) {
  const values = {};
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (!flag?.startsWith("--") || value === undefined || values[flag.slice(2)] !== undefined) {
      reject("arguments_invalid");
    }
    values[flag.slice(2)] = value;
  }
  return values;
}

export async function main(args = process.argv.slice(2)) {
  const [command = "plan", ...rest] = args;
  const values = parseArgs(rest);
  if (command === "plan") {
    if (!values.base || !values.head || Object.keys(values).length !== 2) reject("arguments_invalid");
    const result = inspectDocsFastDelta({ base: values.base, head: values.head });
    writeOutput({ ok: true, eligible: result.eligible, changedCount: result.changedCount });
    return;
  }
  if (command === "verify") {
    if (!values.base || !values.head || Object.keys(values).length !== 2) reject("arguments_invalid");
    writeOutput(await verifyDocsFastCandidate({ base: values.base, head: values.head }));
    return;
  }
  if (command === "prevalidate") {
    if (!values.base || Object.keys(values).length !== 1) reject("arguments_invalid");
    writeOutput(await verifyDocsFastCandidate({ base: values.base, head: "HEAD" }));
    return;
  }
  reject("command_invalid");
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => {
    const code = error instanceof DocsFastPromotionError ? error.code : "docs_fast_promotion_failed";
    process.stderr.write(`${JSON.stringify({ ok: false, code, privateDataIncluded: false })}\n`);
    process.exitCode = 1;
  });
}
