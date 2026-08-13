import { spawnSync } from "node:child_process";
import path from "node:path";
import { CLIENT_MODULE_CATALOG } from "./client-module-catalog.mjs";

const compiledCatalogs = new WeakMap();
const allowedPrograms = new Set(["cargo", "node"]);

export function normalizeRepoPath(value) {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error("repository path must be a non-empty string");
  }
  const portable = value.replaceAll("\\", "/").replace(/^\.\//u, "");
  if (portable.startsWith("/") || /^[A-Za-z]:\//u.test(portable)) {
    throw new Error("repository path must be relative");
  }
  const normalized = path.posix.normalize(portable);
  if (normalized === "." || normalized === ".." || normalized.startsWith("../")) {
    throw new Error("repository path must stay inside the repository");
  }
  return normalized;
}

function compileInput(input) {
  if (typeof input !== "string" || input.length === 0) {
    throw new Error("module input must be a non-empty string");
  }
  if (input.endsWith("/**")) {
    const prefix = normalizeRepoPath(input.slice(0, -3));
    return (candidate) => candidate === prefix || candidate.startsWith(`${prefix}/`);
  }
  if (/[*?\[\]]/u.test(input)) {
    throw new Error("module inputs only support an exact path or a terminal /**");
  }
  const exact = normalizeRepoPath(input);
  return (candidate) => candidate === exact;
}

export function validateClientModuleCatalog(catalog = CLIENT_MODULE_CATALOG) {
  if (!Array.isArray(catalog) || catalog.length === 0) {
    throw new Error("client module catalog must not be empty");
  }
  const ids = new Set();
  for (const module of catalog) {
    if (!module || typeof module !== "object") {
      throw new Error("client module catalog entry must be an object");
    }
    if (!/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/u.test(module.id || "")) {
      throw new Error("client module id is invalid");
    }
    if (ids.has(module.id)) {
      throw new Error(`duplicate client module id: ${module.id}`);
    }
    ids.add(module.id);
    if (typeof module.kind !== "string" || module.kind.length === 0) {
      throw new Error(`client module kind is missing: ${module.id}`);
    }
    if (typeof module.summary !== "string" || module.summary.length === 0) {
      throw new Error(`client module summary is missing: ${module.id}`);
    }
    if (!Array.isArray(module.inputs) || module.inputs.length === 0) {
      throw new Error(`client module inputs are missing: ${module.id}`);
    }
    const uniqueInputs = new Set();
    for (const input of module.inputs) {
      compileInput(input);
      if (uniqueInputs.has(input)) {
        throw new Error(`duplicate input in client module: ${module.id}`);
      }
      uniqueInputs.add(input);
    }
    const moduleCommand = module.command;
    if (!moduleCommand || typeof moduleCommand !== "object") {
      throw new Error(`client module command is missing: ${module.id}`);
    }
    if (!allowedPrograms.has(moduleCommand.program)) {
      throw new Error(`client module command program is not allowed: ${module.id}`);
    }
    if (!Array.isArray(moduleCommand.args) || moduleCommand.args.some((arg) => typeof arg !== "string")) {
      throw new Error(`client module command args are invalid: ${module.id}`);
    }
    if (moduleCommand.args.some((arg) => arg.includes("client:gate:"))) {
      throw new Error(`client module must not invoke an aggregate gate: ${module.id}`);
    }
    if (moduleCommand.cwd !== ".") {
      throw new Error(`client module command cwd must remain repository-relative: ${module.id}`);
    }
    if (!Number.isSafeInteger(moduleCommand.timeoutMs) || moduleCommand.timeoutMs <= 0) {
      throw new Error(`client module command timeout is invalid: ${module.id}`);
    }
  }
  return true;
}

function compileCatalog(catalog) {
  const cached = compiledCatalogs.get(catalog);
  if (cached) return cached;
  validateClientModuleCatalog(catalog);
  const compiled = catalog.map((module) => Object.freeze({
    module,
    matchers: Object.freeze(module.inputs.map(compileInput)),
  }));
  compiledCatalogs.set(catalog, compiled);
  return compiled;
}

export function selectModulesForChangedPaths(changedPaths, catalog = CLIENT_MODULE_CATALOG) {
  if (!Array.isArray(changedPaths)) {
    throw new Error("changed paths must be an array");
  }
  const candidates = [...new Set(changedPaths.map(normalizeRepoPath))];
  if (candidates.length === 0) return [];
  return compileCatalog(catalog)
    .filter(({ matchers }) => candidates.some((candidate) =>
      matchers.some((matches) => matches(candidate))))
    .map(({ module }) => module);
}

export function selectModulesById(moduleIds, catalog = CLIENT_MODULE_CATALOG) {
  if (!Array.isArray(moduleIds) || moduleIds.length === 0) {
    throw new Error("at least one client module id is required");
  }
  validateClientModuleCatalog(catalog);
  const requested = new Set();
  for (const id of moduleIds) {
    if (!/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/u.test(id || "")) {
      throw new Error("client module id is invalid");
    }
    requested.add(id);
  }
  const selected = catalog.filter((module) => requested.has(module.id));
  const missing = [...requested].filter((id) => !selected.some((module) => module.id === id));
  if (missing.length > 0) {
    throw new Error(`unknown client module: ${missing.join(", ")}`);
  }
  return selected;
}

export function validateChangedFromRevision(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 256) {
    throw new Error("changed-from revision is invalid");
  }
  if (value.startsWith("-") || /[\0-\x20\x7f]/u.test(value)) {
    throw new Error("changed-from revision is invalid");
  }
  return value;
}

export function parseNulDelimitedPaths(value) {
  const text = Buffer.isBuffer(value) ? value.toString("utf8") : String(value || "");
  return text
    .split("\0")
    .filter(Boolean)
    .map(normalizeRepoPath);
}

export function changedPathsSince({
  revision,
  repoRoot,
  spawnSyncImpl = spawnSync,
}) {
  const safeRevision = validateChangedFromRevision(revision);
  const commonOptions = Object.freeze({
    cwd: repoRoot,
    encoding: "buffer",
    maxBuffer: 16 * 1024 * 1024,
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const tracked = spawnSyncImpl(
    "git",
    ["diff", "--no-renames", "--name-only", "-z", safeRevision, "--"],
    commonOptions,
  );
  if (tracked.error || tracked.status !== 0) {
    throw new Error("unable to inspect tracked changes from the requested revision");
  }
  const untracked = spawnSyncImpl(
    "git",
    ["ls-files", "--others", "--exclude-standard", "-z", "--"],
    commonOptions,
  );
  if (untracked.error || untracked.status !== 0) {
    throw new Error("unable to inspect untracked changes");
  }
  return [...new Set([
    ...parseNulDelimitedPaths(tracked.stdout),
    ...parseNulDelimitedPaths(untracked.stdout),
  ])];
}
