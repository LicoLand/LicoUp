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
  merged.features = [...new Set([...(base.features ?? []), ...(local.features ?? [])])];
  // Cargo workspace features are additive; a member cannot disable defaults
  // enabled by the workspace dependency.
  if (base["default-features"] !== false) merged["default-features"] = true;
  return merged;
}

/** Optional dependencies activated by the default feature set. */
export function defaultActivatedDependencies(features, dependencies) {
  return featureActivation(features, ["default"], dependencies).optionalDependencies;
}

/**
 * Resolve a requested feature set against a crate's feature table: feature
 * indirection, `dep:` syntax, `dep/feature` activation and implicit optional
 * dependency features all activate optional dependencies.
 *
 * Weak `alias?/feature` forwarding never activates an optional dependency.
 * Forwarding is retained until all activation requests have reached a fixed point.
 */
export function featureActivation(features, requested, dependencies = []) {
  const featureMap = features && typeof features === "object" ? features : {};
  const optionalAliases = new Set(
    dependencies.filter((dependency) => dependency.optional === true)
      .map((dependency) => dependency.alias),
  );
  const active = new Set();
  const optionalDependencies = new Set();
  const dependencyFeatures = new Map();
  const problems = [];
  const aliases = new Set(dependencies.map((dependency) => dependency.alias));
  const suppressed = new Set(Object.values(featureMap).flat()
    .filter((entry) => typeof entry === "string" && entry.startsWith("dep:"))
    .map((entry) => entry.slice(4)));
  const queue = [...requested ?? []];
  while (queue.length > 0) {
    const entry = queue.shift();
    if (active.has(entry)) continue;
    active.add(entry);
    if (typeof entry !== "string") { problems.push("feature request is not a string"); continue; }
    if (entry.startsWith("dep:")) {
      const alias = entry.slice(4);
      if (!optionalAliases.has(alias)) problems.push(`feature ${entry} names no optional dependency`);
      else optionalDependencies.add(alias);
      continue;
    }
    if (entry.includes("/")) {
      const forward = entry.match(/^([^/?]+)(\?)?\/([^/?]+)$/u);
      if (!forward || !aliases.has(forward[1])) {
        problems.push(`feature forwarding ${entry} names no dependency or is unsupported`);
        continue;
      }
      const [, alias, weak, feature] = forward;
      if (!weak && optionalAliases.has(alias)) optionalDependencies.add(alias);
      const forwarded = dependencyFeatures.get(alias) ?? new Set();
      forwarded.add(feature);
      dependencyFeatures.set(alias, forwarded);
      continue;
    }
    if (Array.isArray(featureMap[entry])) {
      queue.push(...featureMap[entry]);
      continue;
    }
    if (optionalAliases.has(entry) && !suppressed.has(entry)) {
      optionalDependencies.add(entry);
    } else if (entry !== "default") {
      problems.push(`feature ${entry} is not declared`);
    }
  }
  return { features: active, optionalDependencies, dependencyFeatures, problems };
}

/** Whether a declared dependency is part of the activated build. */
export function dependencyActivated(dependency, activation) {
  if (!dependency.optional) {
    return true;
  }
  return activation.optionalDependencies.has(dependency.alias);
}

function resolveDependencyManifestPath(baseDirectory, dependencyPath) {
  const target = path.posix.normalize(path.posix.join(baseDirectory, dependencyPath));
  if (target.startsWith("..")) {
    return null;
  }
  return target.endsWith(".toml") ? target : `${target}/Cargo.toml`;
}

async function childManifestPaths(readdir, repoRoot, relativeRoot, problems) {
  const paths = [];
  let entries = [];
  try {
    entries = await readdir(path.join(repoRoot, relativeRoot), { withFileTypes: true });
  } catch (error) {
    if (error?.code !== "ENOENT") {
      problems.push(
        `${relativeRoot} cannot be read: ${error?.code ?? error?.message ?? "unknown"}`,
      );
    }
    return paths;
  }
  for (const entry of [...entries].sort((left, right) => left.name.localeCompare(right.name))) {
    if (entry.isDirectory()) {
      const directory = `${relativeRoot}/${entry.name}`;
      try {
        const children = await readdir(path.join(repoRoot, directory), { withFileTypes: true });
        if (children.some((child) => child.name === "Cargo.toml")) paths.push(`${directory}/Cargo.toml`);
      } catch (error) {
        problems.push(`${directory} cannot be read: ${error?.code ?? "unknown"}`);
      }
    } else if (entry.isSymbolicLink()) {
      problems.push(`${relativeRoot}/${entry.name} is a symbolic link; manifest scope is unresolved`);
    }
  }
  return paths;
}

/** Cargo auto-discovers src/main.rs and src/bin/* as binary targets. */
async function discoverImplicitBins({
  readdir,
  stat,
  repoRoot,
  manifestPath,
  packageName,
  autobins,
  explicitSources,
  explicitNames,
  problems,
}) {
  if (!autobins || !packageName) {
    return [];
  }
  const directory = path.posix.dirname(manifestPath);
  const base = directory === "." ? "" : directory;
  const bins = [];
  const mainPath = base ? `${base}/src/main.rs` : "src/main.rs";
  try {
    if ((await stat(path.join(repoRoot, mainPath))).isFile() && !explicitSources.has(mainPath) && !explicitNames.has(packageName)) {
      bins.push(packageName);
    }
  } catch (error) {
    if (error?.code !== "ENOENT") {
      problems.push(`${mainPath} cannot be read: ${error?.code ?? error?.message ?? "unknown"}`);
    }
  }
  const binDirectory = base ? `${base}/src/bin` : "src/bin";
  let entries = [];
  try {
    entries = await readdir(path.join(repoRoot, binDirectory), { withFileTypes: true });
  } catch (error) {
    if (error?.code !== "ENOENT") {
      problems.push(
        `${binDirectory} cannot be read: ${error?.code ?? error?.message ?? "unknown"}`,
      );
    }
    return bins;
  }
  for (const entry of [...entries].sort((left, right) => left.name.localeCompare(right.name))) {
    if (entry.isFile() && entry.name.endsWith(".rs")) {
      if (!explicitSources.has(`${binDirectory}/${entry.name}`) && !explicitNames.has(entry.name.slice(0, -3))) bins.push(entry.name.slice(0, -3));
    } else if (entry.isDirectory()) {
      try {
        if ((await stat(path.join(repoRoot, binDirectory, entry.name, "main.rs"))).isFile() &&
            !explicitSources.has(`${binDirectory}/${entry.name}/main.rs`) && !explicitNames.has(entry.name)) {
          bins.push(entry.name);
        }
      } catch (error) {
        if (error?.code !== "ENOENT") {
          problems.push(
            `${binDirectory}/${entry.name}/main.rs cannot be read: ${error?.code ?? error?.message ?? "unknown"}`,
          );
        }
      }
    }
  }
  return bins;
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
  stat = fs.stat,
}) {
  const problems = [];
  const queue = ["Cargo.toml"];
  for (const root of FIRST_PARTY_CRATE_ROOTS) {
    queue.push(...await childManifestPaths(readdir, repoRoot, root, problems));
  }
  const documents = new Map();
  const texts = new Map();
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
    } catch (error) {
      problems.push(`${manifestPath} cannot be read: ${error?.code ?? "unknown"}`);
      continue;
    }
    try {
      documents.set(manifestPath, parseToml(text));
      texts.set(manifestPath, text);
      const directory = path.posix.dirname(manifestPath);
      for (const member of documents.get(manifestPath).workspace?.members ?? []) {
        if (typeof member !== "string" || /[*?\[\]{}]/u.test(member)) {
          problems.push(`${manifestPath}: workspace member pattern is unsupported; manifest graph is incomplete`);
          continue;
        }
        const resolved = resolveDependencyManifestPath(directory, member);
        if (resolved) queue.push(resolved);
        else problems.push(`${manifestPath}: workspace member is outside the repository`);
      }
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
    for (const table of [...Object.values(document.patch ?? {}), document.replace ?? {}]) {
      if (Object.values(table).some((spec) => typeof spec?.path === "string")) {
        problems.push(`${manifestPath}: local dependency overrides require explicit graph resolution; refusing a partial graph`);
      }
    }
    if (document.package?.workspace !== undefined) {
      problems.push(`${manifestPath}: explicit package.workspace is unsupported; workspace inheritance is unresolved`);
    }
    const workspace = workspaceFor(manifestPath);
    const workspaceDependencies = workspace.dependencies;
    const dependencies = [];
    for (const entry of dependencyEntries(document)) {
      const localDirectory = path.posix.dirname(manifestPath);
      let spec = entry.spec;
      let pathBase = localDirectory === "." ? "" : localDirectory;
      if (Object.keys(spec).length === 0 ||
          (spec.features !== undefined && (!Array.isArray(spec.features) || spec.features.some((feature) => typeof feature !== "string")))) {
        problems.push(`${manifestPath}: dependency ${entry.alias} has an invalid specification`);
        continue;
      }
      if (spec.workspace === true) {
        const inherited = workspaceDependencies[entry.alias];
        if (!inherited) {
          problems.push(
            `${manifestPath}: dependency ${entry.alias} inherits workspace settings but none are declared`,
          );
          continue;
        }
        if (inherited.features !== undefined && (!Array.isArray(inherited.features) || inherited.features.some((feature) => typeof feature !== "string"))) {
          problems.push(`${manifestPath}: inherited dependency ${entry.alias} has invalid features`);
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
    const explicitBins = Array.isArray(document.bin)
      ? document.bin.map((entry) => entry?.name).filter((name) => typeof name === "string")
      : [];
    const explicitSources = new Set();
    if (document.package?.autobins !== undefined && typeof document.package.autobins !== "boolean") {
      problems.push(`${manifestPath}: package.autobins must be a boolean`);
    }
    if (document.bin !== undefined && (!Array.isArray(document.bin) || explicitBins.length !== document.bin.length)) {
      problems.push(`${manifestPath}: binary targets must declare names`);
    }
    for (const binary of Array.isArray(document.bin) ? document.bin : []) {
      const base = path.posix.dirname(manifestPath);
      const candidates = binary.path !== undefined ? [binary.path] : [
        `src/bin/${binary.name}.rs`, `src/bin/${binary.name}/main.rs`,
        ...(explicitBins.length === 1 ? ["src/main.rs"] : []),
      ];
      let found = false;
      for (const candidate of candidates) {
        if (typeof candidate !== "string" || path.posix.isAbsolute(candidate) || path.posix.normalize(candidate).startsWith("../")) {
          problems.push(`${manifestPath}: binary target ${binary.name} has an unsupported source path`);
          continue;
        }
        const relative = path.posix.join(base, candidate);
        try {
          if ((await stat(path.join(repoRoot, relative))).isFile()) {
            found = true;
            explicitSources.add(relative);
            break;
          }
        } catch (error) {
          if (error?.code !== "ENOENT") problems.push(`${relative} cannot be read: ${error?.code ?? "unknown"}`);
        }
      }
      if (!found) problems.push(`${manifestPath}: binary target ${binary.name} has no source file`);
    }
    for (const [feature, requests] of Object.entries(document.features ?? {})) {
      if (!Array.isArray(requests) || requests.some((entry) => typeof entry !== "string")) {
        problems.push(`${manifestPath}: feature ${feature} must be an array of feature requests`);
      }
    }
    const implicitBins = await discoverImplicitBins({
      readdir,
      stat,
      repoRoot,
      manifestPath,
      packageName,
      autobins: document.package?.autobins !== false,
      explicitSources,
      explicitNames: new Set(explicitBins),
      problems,
    });
    const record = {
      path: manifestPath,
      source: texts.get(manifestPath),
      name: packageName,
      publish: document.package?.publish,
      libraryTypes: Array.isArray(document.lib?.["crate-type"])
        ? [...document.lib["crate-type"]]
        : document.lib?.["crate-type"] === undefined ? ["lib"] : null,
      bins: [...new Set([...explicitBins, ...implicitBins])],
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
      } catch (error) {
        problems.push(
          error?.code === "ENOENT"
            ? `${manifestPath}: path dependency ${dependency.alias} does not resolve to ${resolved}`
            : `${resolved} cannot be read: ${error?.code ?? error?.message ?? "unknown"}`,
        );
        continue;
      }
      try {
        documents.set(resolved, parseToml(text));
        texts.set(resolved, text);
        if (documents.get(resolved).workspace) {
          problems.push(`${resolved}: dependency-owned workspace was not inventoried; workspace inheritance is unresolved`);
        }
        processQueue.push(resolved);
      } catch (error) {
        problems.push(`${resolved} is not valid TOML: ${error.message}`);
      }
    }
  }

  // Resolve locality against the completed graph.
  for (const record of byPath.values()) {
    for (const dependency of record.deps) {
      dependency.localName = null;
      if (typeof dependency.spec.path === "string") {
        const resolved = resolveDependencyManifestPath(dependency.pathBase, dependency.spec.path);
        const target = resolved ? byPath.get(resolved) : null;
        if (target?.name && target.name === (dependency.spec.package ?? dependency.alias)) {
          dependency.localName = target.name;
        } else {
          problems.push(`${record.path}: dependency ${dependency.alias} does not match the local package name`);
        }
      }
    }
  }

  const bins = new Map();
  for (const record of byPath.values()) {
    for (const binary of record.bins) {
      if (bins.has(binary) && bins.get(binary) !== record.name) {
        problems.push(`binary target ${binary} has ambiguous first-party owners`);
      }
      bins.set(binary, record.name);
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
