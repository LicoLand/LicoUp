/**
 * Static architecture ratchet measurements (QA-05).
 *
 * Every measurement is deterministic over the repository source and returns a
 * payload shaped as `{id, ratchet, details}`: `ratchet` contains only numbers
 * and ordered string sets that the baseline comparator tracks; `details`
 * carries evidence and input problems. Missing required
 * inputs, unresolved ownership, malformed manifests and unjustified execution
 * sites are measurement problems: the check fails and recording refuses, so a
 * broken state can never appear as an improvement.
 */

import fs from "node:fs/promises";
import path from "node:path";
import {
  binaryOwners,
  collectManifestGraph,
  dependencyActivated,
  featureActivation,
} from "./cargo-manifest.mjs";
import { findMatching, inspectDeveloperToolSites } from "./developer-tools.mjs";
import { lexicalView } from "./lexical.mjs";
import { parseCapabilityOwnership } from "./ownership.mjs";
export { parseCapabilityOwnership } from "./ownership.mjs";
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

async function readText(repoRoot, relativePath, io = fs) {
  try {
    return await io.readFile(path.join(repoRoot, relativePath), "utf8");
  } catch {
    return null;
  }
}

async function walkFiles(
  repoRoot,
  relativeRoot,
  extension,
  { excludeDirectories = [], problems = [], io = fs } = {},
) {
  const found = [];
  async function visit(relativeDirectory) {
    let entries = [];
    try {
      entries = await io.readdir(path.join(repoRoot, relativeDirectory), { withFileTypes: true });
    } catch (error) {
      problems.push(`${relativeDirectory} cannot be read: ${error?.code ?? "unknown"}`);
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
      } else if (entry.isSymbolicLink()) {
        problems.push(`${relativePath} is a symbolic link; source scope cannot be established`);
      }
    }
  }
  await visit(relativeRoot);
  return found;
}

function sameStringSet(left, right) {
  if (left.size !== right.size) {
    return false;
  }
  for (const value of left) {
    if (!right.has(value)) {
      return false;
    }
  }
  return true;
}

function optionalPackageIds(ownershipRows, problems) {
  const ids = new Set();
  for (const row of ownershipRows) {
    if (row.set !== "optional") {
      continue;
    }
    if (row.package === null) {
      problems.push(
        `optional capability ${row.capability} declares ${row.raw}, which does not resolve to a package id`,
      );
      continue;
    }
    ids.add(row.package);
  }
  return [...ids].sort();
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
export async function measureKernelOptionalCargoEdges({ repoRoot, io = fs }) {
  const problems = [];
  const deploymentSource = await readText(repoRoot, DEPLOYMENT_SOURCE, io);
  if (deploymentSource === null) {
    problems.push(`${DEPLOYMENT_SOURCE} is missing; optional capability ownership cannot be read`);
  }
  const ownershipRows = deploymentSource === null ? [] : parseCapabilityOwnership(deploymentSource, problems);
  const packageIds = optionalPackageIds(ownershipRows, problems);

  const graph = await collectManifestGraph({ repoRoot, ...io });
  problems.push(...graph.problems);
  const manifestTexts = new Map();
  for (const manifestPath of graph.byPath.keys()) {
    manifestTexts.set(manifestPath, graph.byPath.get(manifestPath).source);
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
  const edges = new Set();
  const inactiveOptionalEdges = new Set();
  if (kernelRecord) {
    const requestedFeatures = new Map([[KERNEL_HOST_CRATE, new Set(["default"])]]);
    const activated = new Map();
    while (requestedFeatures.size > 0) {
      const [name, request] = requestedFeatures.entries().next().value;
      requestedFeatures.delete(name);
      const record = graph.records.get(name);
      if (!record) {
        continue;
      }
      const previous = activated.get(name);
      const mergedRequest = new Set([...(previous?.request ?? []), ...request]);
      const activation = featureActivation(record.features, mergedRequest, record.deps);
      problems.push(...activation.problems.map((problem) => `${record.path}: ${problem}`));
      const unchanged = previous &&
        sameStringSet(previous.request, mergedRequest) &&
        sameStringSet(previous.features, activation.features) &&
        sameStringSet(previous.optionalDependencies, activation.optionalDependencies);
      if (unchanged) {
        continue;
      }
      activated.set(name, {
        request: mergedRequest,
        features: activation.features,
        optionalDependencies: activation.optionalDependencies,
      });
      const sourceIsKernel = !optionalCrates.has(name);
      if (sourceIsKernel) {
        closure.add(name);
      }
      for (const dependency of record.deps) {
        if (dependency.kind === "dev-dependencies") {
          continue;
        }
        const isActive = dependencyActivated(dependency, activation);
        if (!isActive) {
          if (
            sourceIsKernel &&
            dependency.localName &&
            optionalCrates.has(dependency.localName)
          ) {
            inactiveOptionalEdges.add(
              `${name} -> ${dependency.localName} (optional, inactive for the requested features)`,
            );
          }
          continue;
        }
        if (!dependency.localName || !graph.records.has(dependency.localName)) {
          continue;
        }
        if (sourceIsKernel && optionalCrates.has(dependency.localName)) {
          inactiveOptionalEdges.delete(`${name} -> ${dependency.localName} (optional, inactive for the requested features)`);
          edges.add(
            `${name} -> ${dependency.localName} (${dependency.optional ? "optional-active" : dependency.kind})`,
          );
        }
        const targetRequest = new Set(
          Array.isArray(dependency.spec.features) ? dependency.spec.features : [],
        );
        for (const feature of activation.dependencyFeatures.get(dependency.alias) ?? []) {
          targetRequest.add(feature);
        }
        if (dependency.spec["default-features"] !== false) {
          targetRequest.add("default");
        }
        const pending = requestedFeatures.get(dependency.localName) ?? new Set();
        for (const feature of targetRequest) {
          pending.add(feature);
        }
        requestedFeatures.set(dependency.localName, pending);
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
      value: edges.size,
      edges: [...edges].sort(),
      unknown_optional_packages: ownership.unknownPackages,
      unknown_optional_manifests: ownership.unknownManifests,
    },
    details: {
      definition:
        "Direct normal/build Cargo edges from non-optional first-party crates reachable from licoup-native to crates declared as optional capability implementations. Dependencies are resolved through workspace inheritance and path locality across all declared target tables; feature requests are unified through the reachable local graph, including optional implementations. Default, explicit, strong and weak forwarded features determine activation. dev-dependencies are excluded and inactive optional edges are recorded separately.",
      kernel_crates: [...closure].sort(),
      optional_crates: [...optionalCrates].sort(),
      inactive_optional_edges: [...inactiveOptionalEdges].sort(),
      ownership_rows: ownershipRows.length,
      problems,
    },
  };
}

function moduleDepth(relativePath, layerRoot) {
  const remainder = relativePath.slice(layerRoot.length + 1);
  const segments = remainder.split("/").filter(Boolean);
  if (segments[segments.length - 1] === "mod.rs") {
    return segments.length;
  }
  return segments.length + 1;
}

function referencesLayer(source, relativePath, layerRoot, layerName, problems) {
  const { masked, problems: lexicalProblems } = lexicalView(source, "rust");
  problems.push(...lexicalProblems.map((problem) => `${relativePath}: ${problem}`));
  const inlineModules = [...masked.matchAll(/\bmod\s+\w+\s*\{/gu)].map((match) => {
    const start = match.index + match[0].length - 1;
    return { start, end: findMatching(masked, start, "{", "}") };
  });
  function crosses(segments, offset) {
    const depth = moduleDepth(relativePath, layerRoot) +
      inlineModules.filter((entry) => entry.start < offset && entry.end > offset).length;
    if (segments[0] === "crate") return segments[1] === layerName;
    let supers = 0;
    while (segments[supers] === "super") supers += 1;
    return supers === depth && segments[supers] === layerName;
  }
  function groupCrosses(start, end, prefix, offset) {
    let index = start;
    while (index < end) {
      const match = masked.slice(index, end).match(/^\s*((?:\w+\s*::\s*)*(?:\w+|\*)?)\s*(\{)?/u);
      if (!match || !match[0].length) { index += 1; continue; }
      const segments = [...prefix, ...match[1].split(/\s*::\s*/u).filter(Boolean)];
      if (crosses(segments.map((segment) => segment === "*" ? layerName : segment), offset)) return true;
      index += match[0].length;
      if (match[2]) {
        const close = findMatching(masked, index - 1, "{", "}");
        if (close < 0) return false;
        if (groupCrosses(index, close, segments, offset)) return true;
        index = close + 1;
      }
      const comma = masked.indexOf(",", index);
      index = comma < 0 ? end : comma + 1;
    }
    return false;
  }
  for (const match of masked.matchAll(/(?<![\w:])(?:crate|super)\s*::\s*(?:(?:\w+)\s*::\s*)*\w*/gu)) {
    const segments = match[0].split(/\s*::\s*/u).filter(Boolean);
    if (crosses(segments, match.index)) return true;
    const open = match.index + match[0].length;
    if (masked[open] === "*" && crosses([...segments, layerName], match.index)) return true;
    if (masked[open] === "{") {
      const end = findMatching(masked, open, "{", "}");
      if (end >= 0 && groupCrosses(open + 1, end, segments, match.index)) return true;
    }
  }
  return false;
}

async function layerImportFiles(repoRoot, layerRoot, targetLayerName, problems, io) {
  const files = [];
  for (const relativePath of await walkFiles(repoRoot, layerRoot, ".rs", { problems, io })) {
    const source = await readText(repoRoot, relativePath, io);
    if (source === null) {
      problems.push(`${relativePath} cannot be read`);
      continue;
    }
    if (referencesLayer(source, relativePath, layerRoot, targetLayerName, problems)) {
      files.push(relativePath);
    }
  }
  return files;
}

/** Metric 2: domain/platform cross-layer importing files. */
export async function measureNativeLayerImports({ repoRoot, io = fs }) {
  const problems = [];
  for (const layerRoot of [DOMAIN_ROOT, PLATFORM_ROOT]) {
    try {
      const stat = await io.stat(path.join(repoRoot, layerRoot));
      if (!stat.isDirectory()) {
        problems.push(`${layerRoot} is missing; cross-layer imports cannot be measured`);
      }
    } catch {
      problems.push(`${layerRoot} is missing; cross-layer imports cannot be measured`);
    }
  }
  const [domainToPlatform, platformToDomain] = await Promise.all([
    layerImportFiles(repoRoot, DOMAIN_ROOT, "platform", problems, io),
    layerImportFiles(repoRoot, PLATFORM_ROOT, "domain", problems, io),
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
export async function measureNativeRustLoc({ repoRoot, io = fs }) {
  const problems = [];
  let nativeSourceExists = false;
  try {
    nativeSourceExists = (await io.stat(path.join(repoRoot, NATIVE_ROOT))).isDirectory();
  } catch {
    nativeSourceExists = false;
  }
  if (!nativeSourceExists) {
    problems.push(`${NATIVE_ROOT} is missing; native size cannot be measured`);
  }
  const files = nativeSourceExists
    ? await walkFiles(repoRoot, NATIVE_ROOT, ".rs", { problems, io })
    : [];
  if (nativeSourceExists && files.length === 0) {
    problems.push(`${NATIVE_ROOT} contains no Rust sources; native size cannot be measured`);
  }
  const perFile = [];
  let nonBlankLines = 0;
  for (const relativePath of files) {
    const source = await readText(repoRoot, relativePath, io);
    if (source === null) {
      problems.push(`${relativePath} cannot be read; native size is incomplete`);
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
export async function measureOptionalCapabilitiesInPackaging({ repoRoot, io = fs }) {
  const problems = [];
  const deploymentSource = await readText(repoRoot, DEPLOYMENT_SOURCE, io);
  if (deploymentSource === null) {
    problems.push(`${DEPLOYMENT_SOURCE} is missing; optional capability ownership cannot be read`);
  }
  const packagingText = await readText(repoRoot, PACKAGING_MODULES, io);
  if (packagingText === null) {
    problems.push(`${PACKAGING_MODULES} is missing; packaging module set cannot be read`);
  }
  let modules = {};
  if (packagingText !== null) {
    try {
      modules = JSON.parse(packagingText).modules;
      if (!modules || typeof modules !== "object" || Array.isArray(modules)) {
        problems.push(`${PACKAGING_MODULES} must declare a modules object`);
        modules = {};
      }
    } catch (error) {
      problems.push(`${PACKAGING_MODULES} is not valid JSON: ${error.message}`);
    }
  }
  const graph = await collectManifestGraph({ repoRoot, ...io });
  problems.push(...graph.problems);
  const owners = binaryOwners(graph.byPath);
  const ownershipRows = deploymentSource === null ? [] : parseCapabilityOwnership(deploymentSource, problems);
  const packageIds = optionalPackageIds(ownershipRows, problems);

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
    if (!module || typeof module !== "object" || Array.isArray(module)) {
      problems.push(`packaging module ${moduleId} must be an object`);
      continue;
    }
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

/** Metric 5: developer-tool execution sinks in runtime sources. */
export async function measureDeveloperToolSites({ repoRoot, allowlist, io = fs }) {
  const graph = await collectManifestGraph({ repoRoot, ...io });
  const inspection = await inspectDeveloperToolSites({
    repoRoot,
    readdir: io.readdir,
    readFile: io.readFile,
    manifests: graph.byPath,
    ...(allowlist === undefined ? {} : { allowlist }),
  });
  const unallowlistedIds = inspection.unallowlisted.flatMap((sink) =>
    sink.tools.map((tool) => `${sink.id}::${tool}`));
  return {
    id: "developer_tool_sites",
    ratchet: {
      execution_sites: inspection.executionSites.length,
      unallowlisted_sites: inspection.unallowlisted.length,
      execution_site_ids: inspection.siteIds,
      unallowlisted_site_ids: unallowlistedIds.sort(),
    },
    details: {
      definition:
        "Developer-tool execution sinks in crates/**/src, components/**/src, sdk/**/src and apps/desktop/lib. One statement containing an execution API is one sink; tools are attributed through the sink expression, same-file bindings and identifier chains, cross-file call-site arguments, and file-level tool evidence. Known process targets without resolvable attribution refuse measurement instead of becoming zero. Every relevant sink needs a reviewed allowlist entry with its fingerprint and exact attributed tool set; a second sink, replaced statement or changed tool set cannot inherit an exception. Literal bytes are preserved in fingerprints. The scan is static lexical analysis, not a compiler or an exhaustive proof about external runtime protocols.",
      scanned_files: inspection.scannedFiles,
      scanned_sink_statements: inspection.scannedSinkStatements,
      execution_sites: inspection.executionSites,
      unallowlisted_sites: inspection.unallowlisted,
      unresolved_sites: inspection.unresolved,
      resolved_non_tool_sites: inspection.resolvedNonTools,
      non_process_sites: inspection.nonProcess,
      non_runtime_crates: inspection.nonRuntimeCrates,
      stale_allowlist: inspection.staleAllowlist,
      invalid_allowlist: inspection.invalidAllowlist,
      references: inspection.references,
      problems: [...graph.problems, ...inspection.problems],
    },
  };
}

/** Run every static metric and build the numeric record for check results. */
export async function measureArchitectureRatchet({ repoRoot, io = fs }) {
  const metrics = [
    await measureKernelOptionalCargoEdges({ repoRoot, io }),
    await measureNativeLayerImports({ repoRoot, io }),
    await measureNativeRustLoc({ repoRoot, io }),
    await measureOptionalCapabilitiesInPackaging({ repoRoot, io }),
    await measureDeveloperToolSites({ repoRoot, io }),
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
  // Partial observations remain inspectable, but are not comparable numbers.
  // Consumers must not chart or record a lower value caused by lost input.
  return { metrics, record: problems.length ? null : record, problems };
}
