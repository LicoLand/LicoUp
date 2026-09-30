/**
 * Cargo manifest graph for the architecture ratchet, built on the approved
 * maintained `smol-toml` parser (devDependency, rationale below) instead of a
 * hand-written TOML subset.
 *
 * It resolves the facts the metrics need and plain name matching cannot:
 * workspace-inherited dependency specifications, renamed packages, path
 * locality (a version or git dependency is external even when its name matches
 * a first-party crate), installed binary targets, and whether an optional
 * dependency is actually activated by the default feature set.
 *
 * Rationale for the dependency: Cargo.toml is TOML with dotted keys, inline
 * tables, arrays of tables, and comments, and an ad-hoc grammar silently
 * mis-parses valid manifests. `smol-toml` is already the approved maintained
 * parser in the wider tooling and is pinned here at the same version.
 */

import path from "node:path";
import fs from "node:fs/promises";
import { parse as parseToml } from "smol-toml";
import { FIRST_PARTY_CRATE_ROOTS } from "./definitions.mjs";

export { parseToml };

/** Parse a Cargo.toml document. Throws on invalid TOML. */
export function parseCargoToml(text) {
  return parseToml(text);
}

function rawSpec(value) {
  if (typeof value === "string") {
    return { version: value };
  }
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return { ...value };
  }
  return {};
}

function dependencyEntries(document) {
  const entries = [];
  const push = (table, kind, target) => {
    if (!table || typeof table !== "object") {
      return;
    }
    for (const [alias, value] of Object.entries(table)) {
      entries.push({ alias, kind, target, spec: rawSpec(value) });
    }
  };
  push(document.dependencies, "dependencies", null);
  push(document["build-dependencies"], "build-dependencies", null);
  push(document["dev-dependencies"], "dev-dependencies", null);
  const targets = document.target;
  if (targets && typeof targets === "object") {
    for (const [target, tables] of Object.entries(targets)) {
      if (!tables || typeof tables !== "object") {
        continue;
      }
      push(tables.dependencies, "dependencies", target);
      push(tables["build-dependencies"], "build-dependencies", target);
      push(tables["dev-dependencies"], "dev-dependencies", target);
    }
  }
  return entries;
}

function mergeDependencySpec(base, local) {
  const merged = { ...base };
  for (const [key, value] of Object.entries(local)) {
    if (key === "workspace") {
      continue;
    }
    merged[key] = value;
  }
  return merged;
}

/** Optional dependencies activated by the default feature set. */
export function defaultActivatedDependencies(features, dependencies) {
  const featureMap = features && typeof features === "object" ? features : {};
  const optionalAliases = new Set(
    dependencies.filter((dependency) => dependency.optional === true)
      .map((dependency) => dependency.alias),
  );
  const activated = new Set();
  const queue = Array.isArray(featureMap.default) ? [...featureMap.default] : [];
  const seen = new Set();
  while (queue.length > 0) {
    const entry = queue.shift();
    if (typeof entry !== "string") {
      continue;
    }
    if (entry.startsWith("dep:")) {
      activated.add(entry.slice(4));
      continue;
    }
    if (entry.includes("/")) {
      const [dependencyName, featureName] = entry.split("/", 2);
      if (!featureName.startsWith("?")) {
        activated.add(dependencyName);
      } else if (activated.has(dependencyName)) {
        activated.add(dependencyName);
      }
      continue;
    }
    if (optionalAliases.has(entry)) {
      activated.add(entry);
      continue;
    }
    if (Array.isArray(featureMap[entry]) && !seen.has(entry)) {
      seen.add(entry);
      queue.push(...featureMap[entry]);
    }
  }
  return activated;
}

function resolveDependencyManifestPath(baseDirectory, dependencyPath) {
  const target = path.posix.normalize(path.posix.join(baseDirectory, dependencyPath));
  if (target.startsWith("..")) {
    return null;
  }
  return target.endsWith(".toml") ? target : `${target}/Cargo.toml`;
}

async function childManifestPaths(readdir, repoRoot, relativeRoot) {
  const paths = [];
  let entries = [];
  try {
    entries = await readdir(path.join(repoRoot, relativeRoot), { withFileTypes: true });
  } catch {
    return paths;
  }
  for (const entry of [...entries].sort((left, right) => left.name.localeCompare(right.name))) {
    if (entry.isDirectory()) {
      paths.push(`${relativeRoot}/${entry.name}/Cargo.toml`);
    }
  }
  return paths;
}

/**
 * Build the first-party manifest graph.
 *
 * @returns {Promise<{
 *   records: Map<string, object>,
 *   byPath: Map<string, object>,
 *   problems: string[],
 * }>}
 */
export async function collectManifestGraph({
  repoRoot,
  readdir = fs.readdir,
  readFile = fs.readFile,
}) {
  const problems = [];
  const queue = ["Cargo.toml"];
  for (const root of FIRST_PARTY_CRATE_ROOTS) {
    queue.push(...await childManifestPaths(readdir, repoRoot, root));
  }
  const documents = new Map();
  const visited = new Set();
  while (queue.length > 0) {
    const manifestPath = queue.shift();
    if (visited.has(manifestPath)) {
      continue;
    }
    visited.add(manifestPath);
    let text;
    try {
      text = await readFile(path.join(repoRoot, manifestPath), "utf8");
    } catch {
      continue;
    }
    try {
      documents.set(manifestPath, parseToml(text));
    } catch (error) {
      problems.push(`${manifestPath} is not valid TOML: ${error.message}`);
    }
  }

  const workspaceRoots = [];
  for (const [manifestPath, document] of documents) {
    if (document.workspace && typeof document.workspace === "object") {
      const directory = path.posix.dirname(manifestPath);
      workspaceRoots.push({
        prefix: directory === "." ? "" : `${directory}/`,
        baseDirectory: directory === "." ? "" : directory,
        dependencies: document.workspace.dependencies ?? {},
      });
    }
  }
  workspaceRoots.sort((left, right) => right.prefix.length - left.prefix.length);

  const workspaceFor = (manifestPath) => {
    const match = workspaceRoots.find((root) =>
      root.prefix === "" || manifestPath.startsWith(root.prefix));
    return match ?? { baseDirectory: "", dependencies: {} };
  };

  const records = new Map();
  const byPath = new Map();
  // Follow path dependencies discovered during resolution.
  const processQueue = [...documents.keys()];
  const processed = new Set();
  while (processQueue.length > 0) {
    const manifestPath = processQueue.shift();
    if (processed.has(manifestPath)) {
      continue;
    }
    processed.add(manifestPath);
    const document = documents.get(manifestPath);
    if (!document) {
      continue;
    }
    const workspace = workspaceFor(manifestPath);
    const workspaceDependencies = workspace.dependencies;
    const dependencies = [];
    for (const entry of dependencyEntries(document)) {
      const localDirectory = path.posix.dirname(manifestPath);
      let spec = entry.spec;
      let pathBase = localDirectory === "." ? "" : localDirectory;
      if (spec.workspace === true) {
        const inherited =
          workspaceDependencies[entry.alias] ??
          (typeof spec.package === "string" ? workspaceDependencies[spec.package] : undefined);
        if (!inherited) {
          problems.push(
            `${manifestPath}: dependency ${entry.alias} inherits workspace settings but none are declared`,
          );
          continue;
        }
        spec = mergeDependencySpec(rawSpec(inherited), spec);
        pathBase = workspace.baseDirectory;
      }
      dependencies.push({
        alias: entry.alias,
        kind: entry.kind,
        target: entry.target,
        spec,
        pathBase,
        optional: spec.optional === true,
      });
    }
    const packageName =
      document.package && typeof document.package.name === "string"
        ? document.package.name
        : null;
    const record = {
      path: manifestPath,
      name: packageName,
      bins: Array.isArray(document.bin)
        ? document.bin.map((entry) => entry?.name).filter((name) => typeof name === "string")
        : [],
      features: document.features && typeof document.features === "object"
        ? document.features
        : {},
      deps: dependencies,
    };
    if (packageName) {
      const existing = records.get(packageName);
      if (existing && existing.path !== manifestPath) {
        problems.push(
          `package name ${packageName} is declared by both ${existing.path} and ${manifestPath}`,
        );
      } else {
        records.set(packageName, record);
      }
    }
    byPath.set(manifestPath, record);
    for (const dependency of dependencies) {
      if (typeof dependency.spec.path !== "string") {
        continue;
      }
      const resolved = resolveDependencyManifestPath(dependency.pathBase, dependency.spec.path);
      if (!resolved) {
        problems.push(
          `${manifestPath}: path dependency ${dependency.alias} points outside the repository`,
        );
        continue;
      }
      if (documents.has(resolved)) {
        processQueue.push(resolved);
        continue;
      }
      let text;
      try {
        text = await readFile(path.join(repoRoot, resolved), "utf8");
      } catch {
        problems.push(
          `${manifestPath}: path dependency ${dependency.alias} does not resolve to ${resolved}`,
        );
        continue;
      }
      try {
        documents.set(resolved, parseToml(text));
        processQueue.push(resolved);
      } catch (error) {
        problems.push(`${resolved} is not valid TOML: ${error.message}`);
      }
    }
  }

  // Resolve locality and default activation against the completed graph.
  for (const record of byPath.values()) {
    const activated = defaultActivatedDependencies(record.features, record.deps);
    for (const dependency of record.deps) {
      dependency.active = !dependency.optional || activated.has(dependency.alias);
      dependency.localName = null;
      if (typeof dependency.spec.path === "string") {
        const resolved = resolveDependencyManifestPath(dependency.pathBase, dependency.spec.path);
        const target = resolved ? byPath.get(resolved) : null;
        if (target?.name) {
          dependency.localName = target.name;
        }
      }
    }
  }

  return { records, byPath, problems };
}

/** Installed binary target names mapped to the package name that builds them. */
export function binaryOwners(byPath) {
  const owners = new Map();
  for (const record of byPath.values()) {
    for (const binary of record.bins) {
      if (!owners.has(binary)) {
        owners.set(binary, record.name);
      }
    }
  }
  return owners;
}

export function activeRuntimeDependencies(record) {
  return record.deps.filter(
    (dependency) => dependency.kind !== "dev-dependencies" && dependency.active,
  );
}
