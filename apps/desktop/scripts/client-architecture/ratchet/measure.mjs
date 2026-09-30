/**
 * Static architecture ratchet measurements (QA-05).
 *
 * Every measurement is deterministic over the repository source and returns a
 * payload shaped as `{id, ratchet, details}`: `ratchet` contains only numbers
 * and ordered string sets that the baseline comparator tracks; `details`
 * carries evidence for people and never affects pass/fail. Missing required
 * inputs, unresolved ownership, malformed manifests and unjustified execution
 * sites are measurement problems: the check fails and recording refuses, so a
 * broken state can never appear as an improvement.
 */

import fs from "node:fs/promises";
import path from "node:path";
import {
  activeRuntimeDependencies,
  binaryOwners,
  collectManifestGraph,
} from "./cargo-manifest.mjs";
import { findMatching, inspectDeveloperToolSites } from "./developer-tools.mjs";
import { lexicalView } from "./lexical.mjs";
import {
  KERNEL_HOST_CRATE,
  KERNEL_PACKAGING_ARTIFACTS,
  OPTIONAL_CAPABILITY_ARTIFACTS,
  OPTIONAL_CAPABILITY_BUNDLES,
  OPTIONAL_CAPABILITY_CRATES,
} from "./definitions.mjs";

const NATIVE_ROOT = "crates/licoup-native/src";
const DOMAIN_ROOT = `${NATIVE_ROOT}/domain`;
const PLATFORM_ROOT = `${NATIVE_ROOT}/platform`;
const DEPLOYMENT_SOURCE = "crates/licoup-extension-contracts/src/deployment.rs";
const PACKAGING_MODULES = "apps/desktop/packaging.modules.json";

async function readText(repoRoot, relativePath) {
  try {
    return await fs.readFile(path.join(repoRoot, relativePath), "utf8");
  } catch {
    return null;
  }
}

async function walkFiles(repoRoot, relativeRoot, extension, { excludeDirectories = [] } = {}) {
  const found = [];
  async function visit(relativeDirectory) {
    let entries = [];
    try {
      entries = await fs.readdir(path.join(repoRoot, relativeDirectory), { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of [...entries].sort((left, right) => left.name.localeCompare(right.name))) {
      const relativePath = relativeDirectory
        ? `${relativeDirectory}/${entry.name}`
        : entry.name;
      if (entry.isDirectory()) {
        if (excludeDirectories.includes(entry.name)) {
          continue;
        }
        await visit(relativePath);
      } else if (entry.isFile() && entry.name.endsWith(extension)) {
        found.push(relativePath.replaceAll("\\", "/"));
      }
    }
  }
  await visit(relativeRoot);
  return found;
}

/** Extract `CAPABILITY_OWNERSHIP` rows from the deployment contract. */
export function parseCapabilityOwnership(source) {
  const normalized = source.replace(/\s+/gu, " ");
  const pattern =
    /"([^"]+)"\s*,\s*PackOwnership::(Core|Optional)\(\s*"?([A-Za-z0-9_.-]+)"?\s*\)/gu;
  return [...normalized.matchAll(pattern)].map((match) => ({
    capability: match[1],
    set: match[2] === "Core" ? "core" : "optional",
    package: match[3],
  }));
}

function optionalPackageIds(ownershipRows) {
  return [...new Set(
    ownershipRows.filter((row) => row.set === "optional").map((row) => row.package),
  )].sort();
}

function namingConventionCandidates(packageId) {
  const withoutNamespace = packageId.replace(/^org\.licoland\./u, "");
  const parts = withoutNamespace.split(".").filter(Boolean);
  const candidates = new Set();
  if (parts.length > 0) {
    candidates.add(`licoup-${parts.join("-")}`);
    candidates.add(`licoup-${parts[parts.length - 1]}`);
  }
  return candidates;
}

function unknownOwnershipProblems({
  packageIds,
  records,
  manifestTexts,
}) {
  const problems = [];
  const unknownPackages = [];
  const unknownManifests = [];
  for (const packageId of packageIds) {
    if (!OPTIONAL_CAPABILITY_CRATES[packageId]) {
      unknownPackages.push(packageId);
      problems.push(
        `optional capability ${packageId} has no declared crate implementation; declare it before measuring`,
      );
      continue;
    }
    if (!OPTIONAL_CAPABILITY_ARTIFACTS[packageId]) {
      unknownPackages.push(`${packageId} (packaging artifact ownership)`);
      problems.push(
        `optional capability ${packageId} has no declared packaging artifact ownership`,
      );
    }
  }
  for (const [crateName, record] of records) {
    const manifestText = manifestTexts.get(record.path) ?? "";
    const declaredIds = new Set(
      [...manifestText.matchAll(/org\.licoland\.[a-z0-9.-]+/gu)].map((match) => match[0]),
    );
    for (const packageId of packageIds) {
      const declaredCrates = OPTIONAL_CAPABILITY_CRATES[packageId]?.crates ?? [];
      const textual = declaredIds.has(packageId);
      const conventional = namingConventionCandidates(packageId).has(crateName);
      if ((textual || conventional) && !declaredCrates.includes(crateName)) {
        const reason = textual
          ? "manifest declares the optional package id"
          : "crate name matches the optional package naming convention";
        unknownManifests.push(`${crateName} (${packageId}; ${reason})`);
      }
    }
  }
  for (const entry of new Set(unknownManifests)) {
    problems.push(`optional capability ownership is undeclared: ${entry}`);
  }
  return { unknownPackages: [...new Set(unknownPackages)].sort(), unknownManifests: [...new Set(unknownManifests)].sort(), problems };
}

/** Metric 1: kernel -> optional capability crate Cargo edges. */
export async function measureKernelOptionalCargoEdges({ repoRoot }) {
  const problems = [];
  const deploymentSource = await readText(repoRoot, DEPLOYMENT_SOURCE);
  if (deploymentSource === null) {
    problems.push(`${DEPLOYMENT_SOURCE} is missing; optional capability ownership cannot be read`);
  }
  const ownershipRows = deploymentSource === null ? [] : parseCapabilityOwnership(deploymentSource);
  const packageIds = optionalPackageIds(ownershipRows);

  const graph = await collectManifestGraph({ repoRoot });
  problems.push(...graph.problems);
  const manifestTexts = new Map();
  for (const manifestPath of graph.byPath.keys()) {
    manifestTexts.set(manifestPath, await readText(repoRoot, manifestPath) ?? "");
  }
  if (!graph.byPath.has("Cargo.toml")) {
    problems.push("Cargo.toml is missing; the workspace manifest graph cannot be resolved");
  }
  const kernelRecord = graph.records.get(KERNEL_HOST_CRATE);
  if (!kernelRecord) {
    problems.push(`${KERNEL_HOST_CRATE} manifest is missing; the kernel build closure cannot be resolved`);
  }

  const cratesByPackage = new Map();
  for (const packageId of packageIds) {
    for (const crateName of OPTIONAL_CAPABILITY_CRATES[packageId]?.crates ?? []) {
      cratesByPackage.set(crateName, packageId);
    }
  }
  const optionalCrates = new Set(cratesByPackage.keys());

  const closure = new Set();
  const queue = kernelRecord ? [KERNEL_HOST_CRATE] : [];
  while (queue.length > 0) {
    const name = queue.shift();
    if (closure.has(name) || optionalCrates.has(name)) {
      continue;
    }
    const record = graph.records.get(name);
    if (!record) {
      continue;
    }
    closure.add(name);
    for (const dependency of activeRuntimeDependencies(record)) {
      if (dependency.localName && graph.records.has(dependency.localName)) {
        queue.push(dependency.localName);
      }
    }
  }

  const edges = [];
  const inactiveOptionalEdges = [];
  for (const source of [...closure].sort()) {
    const record = graph.records.get(source);
    for (const dependency of activeRuntimeDependencies(record)) {
      if (!dependency.localName || !optionalCrates.has(dependency.localName)) {
        continue;
      }
      const kind = dependency.optional ? "optional-active" : dependency.kind;
      edges.push(`${source} -> ${dependency.localName} (${kind})`);
    }
    for (const dependency of record.deps) {
      if (dependency.kind === "dev-dependencies" || dependency.active) {
        continue;
      }
      if (dependency.localName && optionalCrates.has(dependency.localName)) {
        inactiveOptionalEdges.push(
          `${source} -> ${dependency.localName} (optional, inactive by default features)`,
        );
      }
    }
  }

  const ownership = unknownOwnershipProblems({
    packageIds,
    records: graph.records,
    manifestTexts,
  });
  problems.push(...ownership.problems);

  return {
    id: "kernel_optional_cargo_edges",
    ratchet: {
      value: edges.length,
      edges: [...edges].sort(),
      unknown_optional_packages: ownership.unknownPackages,
      unknown_optional_manifests: ownership.unknownManifests,
    },
    details: {
      definition:
        "Direct normal/build Cargo edges from non-optional first-party crates reachable from licoup-native to crates declared as optional capability implementations. Dependencies resolved through workspace inheritance and path locality; optional dependencies activated by the default feature set count as edges. dev-dependencies and optional dependencies inactive by default are recorded separately.",
      kernel_crates: [...closure].sort(),
      optional_crates: [...optionalCrates].sort(),
      inactive_optional_edges: inactiveOptionalEdges.sort(),
      ownership_rows: ownershipRows.length,
      problems,
    },
  };
}

function sanitizeRustSource(source) {
  return lexicalView(source, "rust").masked;
}

function moduleDepth(relativePath, layerRoot) {
  const remainder = relativePath.slice(layerRoot.length + 1);
  const segments = remainder.split("/").filter(Boolean);
  if (segments[segments.length - 1] === "mod.rs") {
    return segments.length;
  }
  return segments.length + 1;
}

function bracedCrateUseReferencesLayer(masked, layerName) {
  const pattern = /crate\s*::\s*\{/gu;
  for (const match of masked.matchAll(pattern)) {
    const open = match.index + match[0].length - 1;
    const end = findMatching(masked, open, "{", "}");
    if (end < 0) {
      continue;
    }
    const group = masked.slice(open + 1, end);
    if (new RegExp(`(^|[^A-Za-z0-9_])${layerName}\\s*(?:::|\\b)`, "u").test(group)) {
      return true;
    }
  }
  return false;
}

function referencesLayer(source, relativePath, layerRoot, layerName) {
  const masked = sanitizeRustSource(source);
  if (new RegExp(`crate\\s*::\\s*${layerName}\\b`, "u").test(masked)) {
    return true;
  }
  if (bracedCrateUseReferencesLayer(masked, layerName)) {
    return true;
  }
  const depth = moduleDepth(relativePath, layerRoot);
  if (depth < 1 || depth > 64) {
    return false;
  }
  return new RegExp(`(?:super\\s*::\\s*){${depth}}${layerName}\\b`, "u").test(masked);
}

async function layerImportFiles(repoRoot, layerRoot, targetLayerName) {
  const files = [];
  for (const relativePath of await walkFiles(repoRoot, layerRoot, ".rs")) {
    const source = await readText(repoRoot, relativePath);
    if (source === null) {
      continue;
    }
    if (referencesLayer(source, relativePath, layerRoot, targetLayerName)) {
      files.push(relativePath);
    }
  }
  return files;
}

/** Metric 2: domain/platform cross-layer importing files. */
export async function measureNativeLayerImports({ repoRoot }) {
  const problems = [];
  for (const layerRoot of [DOMAIN_ROOT, PLATFORM_ROOT]) {
    try {
      const stat = await fs.stat(path.join(repoRoot, layerRoot));
      if (!stat.isDirectory()) {
        problems.push(`${layerRoot} is missing; cross-layer imports cannot be measured`);
      }
    } catch {
      problems.push(`${layerRoot} is missing; cross-layer imports cannot be measured`);
    }
  }
  const [domainToPlatform, platformToDomain] = await Promise.all([
    layerImportFiles(repoRoot, DOMAIN_ROOT, "platform"),
    layerImportFiles(repoRoot, PLATFORM_ROOT, "domain"),
  ]);
  return {
    id: "native_layer_imports",
    ratchet: {
      domain_to_platform: domainToPlatform.length,
      platform_to_domain: platformToDomain.length,
      domain_to_platform_files: domainToPlatform,
      platform_to_domain_files: platformToDomain,
    },
    details: {
      definition:
        "Files under crates/licoup-native/src/domain that reference crate::platform (directly, through a braced crate:: use group, or the equivalent crate-root super chain), and files under crates/licoup-native/src/platform that reference crate::domain. Comments (including nested block comments) and string literals (including raw strings) are ignored; tests are included because the scope has no exemptions.",
      domain_root: DOMAIN_ROOT,
      platform_root: PLATFORM_ROOT,
      problems,
    },
  };
}

/** Metric 3: licoup-native Rust size over one defined scope. */
export async function measureNativeRustLoc({ repoRoot }) {
  const problems = [];
  let nativeSourceExists = false;
  try {
    nativeSourceExists = (await fs.stat(path.join(repoRoot, NATIVE_ROOT))).isDirectory();
  } catch {
    nativeSourceExists = false;
  }
  if (!nativeSourceExists) {
    problems.push(`${NATIVE_ROOT} is missing; native size cannot be measured`);
  }
  const files = nativeSourceExists ? await walkFiles(repoRoot, NATIVE_ROOT, ".rs") : [];
  if (nativeSourceExists && files.length === 0) {
    problems.push(`${NATIVE_ROOT} contains no Rust sources; native size cannot be measured`);
  }
  const perFile = [];
  let nonBlankLines = 0;
  for (const relativePath of files) {
    const source = await readText(repoRoot, relativePath);
    if (source === null) {
      continue;
    }
    const lines = source.split(/\r?\n/u).filter((line) => line.trim().length > 0).length;
    nonBlankLines += lines;
    perFile.push({ file: relativePath, lines });
  }
  if (nativeSourceExists && perFile.length === 0) {
    problems.push(`${NATIVE_ROOT} sources could not be read; native size cannot be measured`);
  }
  perFile.sort((left, right) =>
    right.lines - left.lines || left.file.localeCompare(right.file));
  return {
    id: "native_rust_loc",
    ratchet: {
      non_blank_lines: nonBlankLines,
    },
    details: {
      definition:
        "Non-blank lines (any non-whitespace content) of every .rs file under crates/licoup-native/src, including inline tests and test modules. No exclusions; the count is a size proxy, not a reviewed quality score.",
      files: files.length,
      largest_files: perFile.slice(0, 10),
      problems,
    },
  };
}

/** Metric 4: optional capabilities bundled by the packaging module set. */
export async function measureOptionalCapabilitiesInPackaging({ repoRoot }) {
  const problems = [];
  const deploymentSource = await readText(repoRoot, DEPLOYMENT_SOURCE);
  if (deploymentSource === null) {
    problems.push(`${DEPLOYMENT_SOURCE} is missing; optional capability ownership cannot be read`);
  }
  const packagingText = await readText(repoRoot, PACKAGING_MODULES);
  if (packagingText === null) {
    problems.push(`${PACKAGING_MODULES} is missing; packaging module set cannot be read`);
  }
  let modules = {};
  if (packagingText !== null) {
    try {
      modules = JSON.parse(packagingText).modules ?? {};
    } catch (error) {
      problems.push(`${PACKAGING_MODULES} is not valid JSON: ${error.message}`);
    }
  }
  const graph = await collectManifestGraph({ repoRoot });
  problems.push(...graph.problems);
  const owners = binaryOwners(graph.byPath);
  const ownershipRows = deploymentSource === null ? [] : parseCapabilityOwnership(deploymentSource);
  const packageIds = optionalPackageIds(ownershipRows);

  const artifactsByPackage = new Map();
  for (const packageId of packageIds) {
    const declaration = OPTIONAL_CAPABILITY_ARTIFACTS[packageId];
    if (!declaration) {
      problems.push(
        `optional capability ${packageId} has no declared packaging artifact ownership`,
      );
      continue;
    }
    artifactsByPackage.set(packageId, declaration.artifacts);
    for (const artifact of declaration.artifacts) {
      if (!owners.has(artifact)) {
        problems.push(
          `declared optional artifact ${artifact} (${packageId}) is not built by any first-party manifest`,
        );
      }
    }
    const declaredBundles = OPTIONAL_CAPABILITY_BUNDLES[packageId];
    if (!declaredBundles) {
      problems.push(
        `optional capability ${packageId} has no declared packaging bundle declaration`,
      );
      continue;
    }
    for (const moduleId of declaredBundles) {
      const module = modules[moduleId];
      if (!module) {
        problems.push(
          `declared packaging bundle ${packageId} -> ${moduleId} no longer exists`,
        );
      } else if (module.enabled === false) {
        problems.push(
          `declared packaging bundle ${packageId} -> ${moduleId} is disabled; update the declaration`,
        );
      }
    }
  }

  const kernelArtifacts = new Set(KERNEL_PACKAGING_ARTIFACTS);
  const artifactsToPackages = new Map();
  for (const [packageId, artifacts] of artifactsByPackage) {
    for (const artifact of artifacts) {
      const list = artifactsToPackages.get(artifact) ?? [];
      list.push(packageId);
      artifactsToPackages.set(artifact, list);
    }
  }

  const derived = new Map(packageIds.map((packageId) => [packageId, new Set()]));
  for (const [moduleId, module] of Object.entries(modules)) {
    if (module?.enabled === false) {
      continue;
    }
    for (const binary of [module?.cargoBin, module?.embeddedCargoBin]) {
      if (typeof binary !== "string" || binary.length === 0) {
        continue;
      }
      const owner = owners.get(binary);
      if (!owner) {
        problems.push(
          `packaging module ${moduleId} bundles ${binary}, which no first-party manifest builds`,
        );
        continue;
      }
      const carriers = artifactsToPackages.get(binary) ?? [];
      if (carriers.length === 0 && !kernelArtifacts.has(binary)) {
        problems.push(
          `packaging module ${moduleId} bundles ${binary} (built by ${owner}), which is not declared as a kernel or optional artifact`,
        );
        continue;
      }
      for (const packageId of carriers) {
        derived.get(packageId)?.add(moduleId);
      }
    }
  }

  const bindings = [];
  for (const packageId of packageIds) {
    const declared = new Set(OPTIONAL_CAPABILITY_BUNDLES[packageId] ?? []);
    const actual = derived.get(packageId) ?? new Set();
    for (const moduleId of actual) {
      bindings.push(`${packageId} -> ${moduleId}`);
      if (!declared.has(moduleId)) {
        problems.push(
          `packaging module ${moduleId} bundles the optional artifact of ${packageId} without a declaration`,
        );
      }
    }
    for (const moduleId of declared) {
      if (!actual.has(moduleId)) {
        problems.push(
          `declared packaging bundle ${packageId} -> ${moduleId} is not produced by the module's artifacts`,
        );
      }
    }
  }

  return {
    id: "optional_capabilities_in_packaging",
    ratchet: {
      bundled_bindings: bindings.length,
      bindings: [...new Set(bindings)].sort(),
      unknown_optional_packages: packageIds.filter(
        (packageId) => !OPTIONAL_CAPABILITY_ARTIFACTS[packageId],
      ),
      undeclared_bindings: [],
    },
    details: {
      definition:
        "Optional capability packages from CAPABILITY_OWNERSHIP that an enabled packaging module actually bundles, derived from each enabled module's cargoBin/embeddedCargoBin and the first-party manifest that builds that binary; declared bundles must match the derived set exactly, so stale, replaced or newly bundled owners fail instead of silently improving.",
      problems,
    },
  };
}

/** Metric 5: developer-tool execution sites in runtime sources. */
export async function measureDeveloperToolSites({ repoRoot, allowlist }) {
  const inspection = await inspectDeveloperToolSites({
    repoRoot,
    readdir: fs.readdir,
    readFile: fs.readFile,
    ...(allowlist === undefined ? {} : { allowlist }),
  });
  const executionSiteIds = inspection.executionSites.map((site) => site.id);
  const unallowlistedIds = inspection.unallowlisted.map((site) => site.id);
  return {
    id: "developer_tool_sites",
    ratchet: {
      execution_sites: executionSiteIds.length,
      unallowlisted_sites: unallowlistedIds.length,
      execution_site_ids: executionSiteIds,
      unallowlisted_site_ids: unallowlistedIds,
    },
    details: {
      definition:
        "Runtime execution sites that name node, npm, npx, python3, python, uvx, pip or pip3 in crates/**/src, components/**/src, sdk/**/src and apps/desktop/lib. Every occurrence is a distinct site with its own ordinal, so one allowlist entry cannot authorize a second call site; execution is classified from the enclosing statement, bound programs, wrapper calls, embedded guest scripts, and files that execute a variable program, and commented-out code is ignored. Every execution site must be justified in the declared allowlist. This is a declared-scope static lexical scan, not an exhaustive proof that no other runtime path can execute a developer tool.",
      scanned_files: inspection.scannedFiles,
      execution_sites: inspection.executionSites,
      unallowlisted_sites: inspection.unallowlisted,
      stale_allowlist: inspection.staleAllowlist,
      invalid_allowlist: inspection.invalidAllowlist,
      references: inspection.references,
      problems: [...inspection.invalidAllowlist],
    },
  };
}

/** Run every static metric and build the numeric record for check results. */
export async function measureArchitectureRatchet({ repoRoot }) {
  const metrics = [
    await measureKernelOptionalCargoEdges({ repoRoot }),
    await measureNativeLayerImports({ repoRoot }),
    await measureNativeRustLoc({ repoRoot }),
    await measureOptionalCapabilitiesInPackaging({ repoRoot }),
    await measureDeveloperToolSites({ repoRoot }),
  ];
  const byId = Object.fromEntries(metrics.map((metric) => [metric.id, metric]));
  const record = {
    kernelOptionalCargoEdges: byId.kernel_optional_cargo_edges.ratchet.value,
    nativeDomainToPlatformImportFiles:
      byId.native_layer_imports.ratchet.domain_to_platform,
    nativePlatformToDomainImportFiles:
      byId.native_layer_imports.ratchet.platform_to_domain,
    nativeRustNonBlankLines: byId.native_rust_loc.ratchet.non_blank_lines,
    optionalCapabilitiesBundledInPackaging:
      byId.optional_capabilities_in_packaging.ratchet.bundled_bindings,
    developerToolExecutionSites: byId.developer_tool_sites.ratchet.execution_sites,
    developerToolUnallowlistedSites:
      byId.developer_tool_sites.ratchet.unallowlisted_sites,
  };
  const problems = metrics.flatMap((metric) => metric.details.problems ?? []);
  return { metrics, record, problems };
}
