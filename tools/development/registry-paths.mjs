#!/usr/bin/env node
/**
 * Every repository path a development registry names must exist.
 *
 * A code move also moves the paths that name the code. The registries under
 * `tools/development/` drive change impact, module ownership, state-machine execution and
 * closure steps, and every one of them names repository paths. When a module moves and
 * the registry is not updated in the same change, the tooling silently stops seeing it
 * instead of failing: the ownership test could not reach an adapter through a transport
 * that had moved, and the change-impact analysis for four Agents watched files that do
 * not exist. Nothing checked the references themselves, so this does.
 *
 * A value is treated as a path when it is repository-relative, carries no glob or shell
 * metacharacter, and starts with a tracked top-level root. A module prefix is resolved
 * against the source extensions these repositories use, so both `…/pty_transport` and
 * `…/pty_transport.rs` are accepted while a moved module is not.
 *
 * Usage:
 *   node tools/development/registry-paths.mjs [--json]
 *
 * Read-only. Exits 1 and prints every missing path when a registry is stale.
 */

import { existsSync } from "node:fs";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export const repositoryRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

/** Directories a repository-relative reference can start with. */
const TRACKED_ROOTS = Object.freeze([
  ".github", "apps", "components", "contracts", "crates", "docs", "packages",
  "resources", "schemas", "scripts", "services", "tests", "tools",
]);

/** Values that look like a path but never are: commands, globs, templates, URLs. */
const NEVER_A_PATH = /[*?{}[\]$<>|"'`\s\\]/u;

/** Extensions a module prefix is completed with before it is called missing. */
const SOURCE_EXTENSIONS = Object.freeze([".rs", ".mjs", ".js", ".md", ".json", ".toml", ".dart"]);

/** The registries whose whole purpose is to name repository paths. */
export function developmentRegistries(root = repositoryRoot) {
  const directory = path.join(root, "tools", "development");
  const registries = ["modules.json", "state-machines.json", "architecture-views.json", "closure-steps.json"]
    .filter((name) => existsSync(path.join(directory, name)));
  const workflows = path.join(directory, "workflows");
  if (existsSync(workflows)) {
    for (const name of readdirSync(workflows).sort()) {
      if (name.endsWith(".json")) registries.push(path.posix.join("workflows", name));
    }
  }
  return registries.map((name) => path.posix.join("tools/development", name));
}

/** Walk a decoded registry and yield every string with the pointer that reached it. */
export function* registryStrings(value, pointer = "") {
  if (typeof value === "string") {
    yield { pointer, value };
    return;
  }
  if (Array.isArray(value)) {
    for (const [index, item] of value.entries()) {
      yield* registryStrings(item, `${pointer}[${index}]`);
    }
    return;
  }
  if (value && typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      yield* registryStrings(item, pointer ? `${pointer}.${key}` : key);
    }
  }
}

export function looksLikeRepositoryPath(value) {
  if (typeof value !== "string" || value.length === 0) return false;
  if (NEVER_A_PATH.test(value)) return false;
  if (!value.includes("/")) return false;
  if (value.startsWith("-") || value.startsWith("http://") || value.startsWith("https://")) return false;
  if (value.startsWith("/")) return false;
  return TRACKED_ROOTS.includes(value.split("/")[0]);
}

/** The on-disk entry a registry value names, or null when nothing matches it. */
export function resolveRepositoryPath(root, value) {
  for (const candidate of [value, ...SOURCE_EXTENSIONS.map((extension) => `${value}${extension}`)]) {
    if (existsSync(path.join(root, candidate))) return candidate;
  }
  return null;
}

/**
 * Every registry entry that names a path which does not exist.
 *
 * Returns `{ registry, pointer, path }` for each, so a failure names the file, the JSON
 * pointer inside it and the missing path.
 */
export function missingRegistryPaths({ root = repositoryRoot, registries = developmentRegistries(root) } = {}) {
  const missing = [];
  for (const registry of registries) {
    const decoded = JSON.parse(readFileSync(path.join(root, registry), "utf8"));
    for (const { pointer, value } of registryStrings(decoded)) {
      if (!looksLikeRepositoryPath(value)) continue;
      if (resolveRepositoryPath(root, value)) continue;
      missing.push({ registry, pointer, path: value });
    }
  }
  return missing;
}

export function formatMissingRegistryPaths(missing) {
  return missing
    .map((entry) => `${entry.registry} ${entry.pointer} names ${entry.path}, which does not exist`)
    .join("\n");
}

function main(argv) {
  const missing = missingRegistryPaths();
  if (argv.includes("--json")) {
    process.stdout.write(`${JSON.stringify({ ok: missing.length === 0, missing }, null, 2)}\n`);
  } else if (missing.length === 0) {
    process.stdout.write("registry paths: every named path exists\n");
  } else {
    process.stdout.write(`${formatMissingRegistryPaths(missing)}\n`);
  }
  return missing.length === 0 ? 0 : 1;
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) process.exitCode = main(process.argv.slice(2));
