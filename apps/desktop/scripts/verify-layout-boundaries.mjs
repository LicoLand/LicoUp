#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { lstat, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const scriptRepositoryRoot = path.resolve(path.dirname(scriptPath), "../../..");

export const DEFAULT_LAYOUT_BOUNDARY_CONFIG = Object.freeze({
  compositionPath:
    "apps/desktop/lib/src/frontend/layout/built_in_layout_composition.dart",
  surfaceContractPath:
    "apps/desktop/lib/src/contracts/presentation/layout_environment.dart",
  profileSourceRoot:
    "apps/desktop/lib/src/frontend/layout/profiles",
  profileTestRoot: "apps/desktop/test/layout/profiles",
  profileTestFixtureRoot: "apps/desktop/test/layout/fixtures",
  assetRoot: "apps/desktop/assets/layout-profiles",
  goldenRoot: "apps/desktop/test/goldens/layout",
  libraryRoot: "apps/desktop/lib",
  testRoot: "apps/desktop/test",
  preferencesPath:
    "apps/desktop/lib/src/platform/presentation/presentation_preferences_repository.dart",
  portableDataRootPath:
    "apps/desktop/lib/src/platform/storage/portable_data_root.dart",
  workspaceManifestPath:
    "apps/desktop/lib/src/platform/storage/client_workspace_manifest.dart",
});

const neutralLayoutContracts = new Set([
  "apps/desktop/lib/src/frontend/layout/layout_chrome_port.dart",
  "apps/desktop/lib/src/frontend/layout/layout_component_kit.dart",
  "apps/desktop/lib/src/frontend/layout/layout_destination_presentation.dart",
  "apps/desktop/lib/src/frontend/layout/layout_palette.dart",
  "apps/desktop/lib/src/frontend/layout/layout_scope.dart",
  "apps/desktop/lib/src/frontend/layout/layout_surface_bundle.dart",
  "apps/desktop/lib/src/frontend/layout/layout_visual_tokens.dart",
]);

export class LayoutBoundaryError extends Error {
  constructor(code, relativePath = "") {
    super(relativePath ? `${code}: ${relativePath}` : code);
    this.name = "LayoutBoundaryError";
    this.code = code;
    this.relativePath = relativePath;
  }
}

function fail(code, relativePath = "") {
  throw new LayoutBoundaryError(code, relativePath);
}

function compareCanonical(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function normalizeRelative(value) {
  if (typeof value !== "string" || !value || value.includes("\0")) {
    fail("layout_path_invalid");
  }
  const posix = value.replaceAll("\\", "/");
  const normalized = path.posix.normalize(posix).replace(/^\.\//u, "");
  if (
    path.posix.isAbsolute(posix) ||
    normalized === "." ||
    normalized === ".." ||
    normalized.startsWith("../")
  ) {
    fail("layout_path_invalid", value);
  }
  return normalized.replace(/\/$/u, "");
}

function normalizeConfig(config) {
  return Object.freeze(
    Object.fromEntries(
      Object.entries(config).map(([key, value]) => [
        key,
        normalizeRelative(value),
      ]),
    ),
  );
}

function containedPath(repositoryRoot, relativePath) {
  const root = path.resolve(repositoryRoot);
  const relative = normalizeRelative(relativePath);
  const absolute = path.resolve(root, ...relative.split("/"));
  const fromRoot = path.relative(root, absolute);
  if (!fromRoot || fromRoot.startsWith("..") || path.isAbsolute(fromRoot)) {
    fail("layout_path_escapes_repository", relative);
  }
  return absolute;
}

async function pathKind(repositoryRoot, relativePath) {
  try {
    const info = await lstat(containedPath(repositoryRoot, relativePath));
    if (info.isSymbolicLink()) {
      fail("layout_owned_symlink_forbidden", relativePath);
    }
    if (info.isDirectory()) {
      return "directory";
    }
    if (info.isFile()) {
      return "file";
    }
    fail("layout_owned_entry_unsupported", relativePath);
  } catch (error) {
    if (error?.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

async function readUtf8(repositoryRoot, relativePath) {
  try {
    return await readFile(containedPath(repositoryRoot, relativePath), "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      fail("layout_required_source_missing", relativePath);
    }
    throw error;
  }
}

async function collectFiles(repositoryRoot, relativeDirectory) {
  const directory = normalizeRelative(relativeDirectory);
  if ((await pathKind(repositoryRoot, directory)) == null) {
    return [];
  }
  if ((await pathKind(repositoryRoot, directory)) !== "directory") {
    fail("layout_owned_root_not_directory", directory);
  }
  const files = [];
  async function visit(current) {
    const entries = await readdir(containedPath(repositoryRoot, current), {
      withFileTypes: true,
    });
    entries.sort((left, right) => compareCanonical(left.name, right.name));
    for (const entry of entries) {
      const child = normalizeRelative(path.posix.join(current, entry.name));
      if (entry.isSymbolicLink()) {
        fail("layout_owned_symlink_forbidden", child);
      }
      if (entry.isDirectory()) {
        await visit(child);
      } else if (entry.isFile()) {
        files.push(child);
      } else {
        fail("layout_owned_entry_unsupported", child);
      }
    }
  }
  await visit(directory);
  return files.sort(compareCanonical);
}

function importsFrom(source) {
  const uncommented = stripDartComments(source);
  const imports = [];
  const directive =
    /^\s*(?:import|export|part)(?!\s+of\b)\s+([\s\S]*?);/gmu;
  for (const match of uncommented.matchAll(directive)) {
    for (const uri of match[1].matchAll(/['"]([^'"\r\n]+)['"]/gu)) {
      imports.push(uri[1]);
    }
  }
  return imports;
}

function stripDartComments(source) {
  let result = "";
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (character === "\n") {
        lineComment = false;
        result += "\n";
      } else {
        result += " ";
      }
      continue;
    }
    if (blockComment) {
      if (character === "*" && next === "/") {
        result += "  ";
        blockComment = false;
        index += 1;
      } else {
        result += character === "\n" ? "\n" : " ";
      }
      continue;
    }
    if (quote != null) {
      result += character;
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === "/" && next === "/") {
      result += "  ";
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      result += "  ";
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
    }
    result += character;
  }
  return result;
}

function resolveDartImport(importer, specifier) {
  if (specifier.startsWith("package:flutter_client/")) {
    return normalizeRelative(
      `apps/desktop/lib/${specifier.slice("package:flutter_client/".length)}`,
    );
  }
  if (specifier.startsWith(".") || !specifier.includes(":")) {
    return normalizeRelative(
      path.posix.join(path.posix.dirname(importer), specifier),
    );
  }
  return null;
}

function parseSurfaceIdentities(source, relativePath) {
  const declaration = /\benum\s+LayoutRuntimeSurface\s*\{([^}]*)\}/su.exec(
    source,
  );
  if (!declaration) {
    fail("layout_surface_contract_missing", relativePath);
  }
  const identities = new Set();
  for (const candidate of declaration[1].split(";", 1)[0].split(",")) {
    const identity = candidate
      .replace(/\/\*[\s\S]*?\*\//gu, "")
      .replace(/\/\/.*$/gmu, "")
      .trim();
    if (!identity) {
      continue;
    }
    if (!/^[a-z][A-Za-z0-9_]*$/u.test(identity)) {
      fail("layout_surface_contract_invalid", relativePath);
    }
    if (identities.has(identity)) {
      fail("layout_surface_identity_duplicate", relativePath);
    }
    identities.add(identity);
  }
  if (identities.size === 0) {
    fail("layout_surface_contract_missing", relativePath);
  }
  return identities;
}

function matchingDelimiter(
  source,
  openIndex,
  openToken,
  closeToken,
  code,
  relativePath = "",
) {
  let depth = 0;
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = openIndex; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (character === "\n") {
        lineComment = false;
      }
      continue;
    }
    if (blockComment) {
      if (character === "*" && next === "/") {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === "/" && next === "/") {
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      continue;
    }
    if (character === openToken) {
      depth += 1;
    } else if (character === closeToken) {
      depth -= 1;
      if (depth === 0) {
        return index;
      }
    }
  }
  fail(code, relativePath);
}

function parseDefinitionBundleSymbols(source, relativePath) {
  const groups = [];
  const expression = /\bLayoutDefinition\s*\(/gu;
  for (const match of source.matchAll(expression)) {
    const openParenthesis = source.indexOf("(", match.index);
    const closeParenthesis = matchingDelimiter(
      source,
      openParenthesis,
      "(",
      ")",
      "layout_composition_definition_unclosed",
      relativePath,
    );
    const body = source.slice(openParenthesis + 1, closeParenthesis);
    const openBracket = body.search(/\[/u);
    if (openBracket < 0) {
      fail("layout_composition_definition_invalid", relativePath);
    }
    const closeBracket = matchingDelimiter(
      body,
      openBracket,
      "[",
      "]",
      "layout_composition_bundle_list_unclosed",
      relativePath,
    );
    if (body.slice(closeBracket + 1).replace(/[,\s]/gu, "")) {
      fail("layout_composition_definition_invalid", relativePath);
    }
    const symbols = body
      .slice(openBracket + 1, closeBracket)
      .split(",")
      .map((value) => value.replace(/\/\*[\s\S]*?\*\//gu, "").trim())
      .filter(Boolean);
    if (
      symbols.length === 0 ||
      symbols.some((symbol) => !/^[A-Za-z_]\w*$/u.test(symbol))
    ) {
      fail("layout_composition_bundle_list_invalid", relativePath);
    }
    groups.push(symbols);
  }
  if (groups.length === 0) {
    fail("layout_composition_definition_missing", relativePath);
  }
  return groups;
}

function uniqueMatch(source, expression, code, relativePath) {
  const matches = new Set();
  for (const match of source.matchAll(expression)) {
    matches.add(match[1]);
  }
  if (matches.size !== 1) {
    fail(code, relativePath);
  }
  return [...matches][0];
}

function profileSurfaceFromPath(relativePath, profileSourceRoot) {
  const prefix = `${normalizeRelative(profileSourceRoot)}/`;
  if (!relativePath.startsWith(prefix)) {
    return null;
  }
  const [profile, surface, ...remainder] = relativePath
    .slice(prefix.length)
    .split("/");
  if (!profile || !surface || remainder.length === 0) {
    return null;
  }
  return { profile, surface };
}

async function discoverImportedBundles({
  repositoryRoot,
  config,
  compositionSource,
  surfaceIdentities,
}) {
  const declarations = new Map();
  const entryPaths = new Set();
  for (const specifier of importsFrom(compositionSource)) {
    const importedPath = resolveDartImport(config.compositionPath, specifier);
    if (importedPath == null) {
      continue;
    }
    const pathIdentity = profileSurfaceFromPath(
      importedPath,
      config.profileSourceRoot,
    );
    if (pathIdentity == null) {
      continue;
    }
    if (entryPaths.has(importedPath)) {
      fail("layout_composition_bundle_entry_duplicate", importedPath);
    }
    entryPaths.add(importedPath);
    const source = await readUtf8(repositoryRoot, importedPath);
    const matches = [
      ...source.matchAll(
        /\bfinal\s+LayoutSurfaceBundle\s+([A-Za-z_]\w*)\s*=\s*LayoutSurfaceBundle\s*\(/gu,
      ),
    ];
    if (matches.length !== 1) {
      fail("layout_bundle_entry_declaration_invalid", importedPath);
    }
    const symbol = matches[0][1];
    if (declarations.has(symbol)) {
      fail("layout_bundle_symbol_duplicate", importedPath);
    }
    const profile = uniqueMatch(
      source,
      /\bid\s*:\s*LayoutProfileId\.parse\(\s*['"]([a-z]+(?:-[a-z]+)*)['"]\s*\)/gu,
      "layout_bundle_profile_identity_invalid",
      importedPath,
    );
    const surface = uniqueMatch(
      source,
      /\bsurface\s*:\s*LayoutRuntimeSurface\.([A-Za-z_]\w*)/gu,
      "layout_bundle_surface_identity_invalid",
      importedPath,
    );
    if (!surfaceIdentities.has(surface)) {
      fail("layout_bundle_surface_identity_unknown", importedPath);
    }
    if (profile !== pathIdentity.profile) {
      fail("layout_bundle_path_profile_mismatch", importedPath);
    }
    if (surface !== pathIdentity.surface) {
      fail("layout_bundle_path_surface_mismatch", importedPath);
    }
    declarations.set(symbol, {
      symbol,
      profile,
      surface,
      entryPath: importedPath,
    });
  }
  if (declarations.size === 0) {
    fail("layout_composition_bundle_missing", config.compositionPath);
  }
  return declarations;
}

function sameSet(left, right) {
  return left.size === right.size && [...left].every((value) => right.has(value));
}

export async function discoverLayoutBundleProduct({
  repositoryRoot = scriptRepositoryRoot,
  config = DEFAULT_LAYOUT_BOUNDARY_CONFIG,
} = {}) {
  const normalizedConfig = normalizeConfig(config);
  const [compositionSource, surfaceContractSource] = await Promise.all([
    readUtf8(repositoryRoot, normalizedConfig.compositionPath),
    readUtf8(repositoryRoot, normalizedConfig.surfaceContractPath),
  ]);
  const surfaceIdentities = parseSurfaceIdentities(
    surfaceContractSource,
    normalizedConfig.surfaceContractPath,
  );
  const declarations = await discoverImportedBundles({
    repositoryRoot,
    config: normalizedConfig,
    compositionSource,
    surfaceIdentities,
  });
  const definitionGroups = parseDefinitionBundleSymbols(
    compositionSource,
    normalizedConfig.compositionPath,
  );
  const referencedSymbols = new Set();
  const definitions = definitionGroups.map((symbols) => {
    const bundles = symbols.map((symbol) => {
      const declaration = declarations.get(symbol);
      if (declaration == null) {
        fail(
          "layout_composition_bundle_symbol_unknown",
          normalizedConfig.compositionPath,
        );
      }
      if (referencedSymbols.has(symbol)) {
        fail(
          "layout_composition_bundle_symbol_duplicate",
          normalizedConfig.compositionPath,
        );
      }
      referencedSymbols.add(symbol);
      return declaration;
    });
    const profiles = new Set(bundles.map((bundle) => bundle.profile));
    if (profiles.size !== 1) {
      fail(
        "layout_composition_definition_profile_mixed",
        normalizedConfig.compositionPath,
      );
    }
    return { profile: [...profiles][0], bundles };
  });

  for (const declaration of declarations.values()) {
    if (!referencedSymbols.has(declaration.symbol)) {
      fail("layout_composition_bundle_stale", declaration.entryPath);
    }
  }

  const definitionByProfile = new Map();
  for (const definition of definitions) {
    if (definitionByProfile.has(definition.profile)) {
      fail(
        "layout_composition_profile_definition_duplicate",
        normalizedConfig.compositionPath,
      );
    }
    definitionByProfile.set(definition.profile, definition);
  }
  const profiles = [...definitionByProfile.keys()].sort(compareCanonical);
  const surfaces = [...surfaceIdentities].sort(compareCanonical);
  const bundleByOwner = new Map();
  for (const definition of definitions) {
    const definitionSurfaces = new Set();
    for (const bundle of definition.bundles) {
      if (definitionSurfaces.has(bundle.surface)) {
        fail("layout_bundle_owner_duplicate", bundle.entryPath);
      }
      definitionSurfaces.add(bundle.surface);
      const owner = `${bundle.profile}/${bundle.surface}`;
      if (bundleByOwner.has(owner)) {
        fail("layout_bundle_owner_duplicate", bundle.entryPath);
      }
      bundleByOwner.set(owner, bundle);
    }
    if (!sameSet(definitionSurfaces, surfaceIdentities)) {
      fail(
        "layout_composition_profile_surface_product_incomplete",
        normalizedConfig.compositionPath,
      );
    }
  }
  if (bundleByOwner.size !== profiles.length * surfaces.length) {
    fail(
      "layout_composition_profile_surface_product_invalid",
      normalizedConfig.compositionPath,
    );
  }

  const bundles = [...bundleByOwner.values()].sort((left, right) =>
    compareCanonical(
      `${left.profile}/${left.surface}`,
      `${right.profile}/${right.surface}`,
    ),
  );
  return Object.freeze({
    config: normalizedConfig,
    profiles: Object.freeze(profiles),
    surfaces: Object.freeze(surfaces),
    bundles: Object.freeze(bundles.map((bundle) => Object.freeze(bundle))),
    bundleByOwner,
    compositionSource,
  });
}

function ownerKey(profile, surface) {
  return `${profile}/${surface}`;
}

function exactOwnerFor(catalog, relativePath, root) {
  const prefix = `${root}/`;
  if (!relativePath.startsWith(prefix)) {
    return null;
  }
  const [profile, surface, ...remainder] = relativePath
    .slice(prefix.length)
    .split("/");
  if (remainder.length === 0) {
    return null;
  }
  if (!catalog.profiles.includes(profile) || !catalog.surfaces.includes(surface)) {
    return null;
  }
  return { profile, surface, id: ownerKey(profile, surface) };
}

function sourceOwnerFor(catalog, relativePath) {
  return exactOwnerFor(catalog, relativePath, catalog.config.profileSourceRoot);
}

function testOwnerFor(catalog, relativePath) {
  return exactOwnerFor(catalog, relativePath, catalog.config.profileTestRoot);
}

function codeOwnerFor(catalog, relativePath) {
  return sourceOwnerFor(catalog, relativePath) ?? testOwnerFor(catalog, relativePath);
}

async function validateCanonicalOwnerRoot({
  repositoryRoot,
  catalog,
  root,
  rootRequired,
  productRequired,
}) {
  const kind = await pathKind(repositoryRoot, root);
  if (kind == null) {
    if (rootRequired) {
      fail("layout_owned_root_missing", root);
    }
    return [];
  }
  if (kind !== "directory") {
    fail("layout_owned_root_not_directory", root);
  }
  const observedOwners = new Set();
  const profileEntries = await readdir(containedPath(repositoryRoot, root), {
    withFileTypes: true,
  });
  for (const profileEntry of profileEntries) {
    const profilePath = normalizeRelative(
      path.posix.join(root, profileEntry.name),
    );
    if (profileEntry.isSymbolicLink()) {
      fail("layout_owned_symlink_forbidden", profilePath);
    }
    if (!profileEntry.isDirectory()) {
      fail("layout_owner_path_unowned", profilePath);
    }
    if (!catalog.profiles.includes(profileEntry.name)) {
      fail("layout_stale_profile_ownership", profilePath);
    }
    const surfaceEntries = await readdir(
      containedPath(repositoryRoot, profilePath),
      { withFileTypes: true },
    );
    for (const surfaceEntry of surfaceEntries) {
      const surfacePath = normalizeRelative(
        path.posix.join(profilePath, surfaceEntry.name),
      );
      if (surfaceEntry.isSymbolicLink()) {
        fail("layout_owned_symlink_forbidden", surfacePath);
      }
      if (!surfaceEntry.isDirectory()) {
        fail("layout_owner_path_unowned", surfacePath);
      }
      if (!catalog.surfaces.includes(surfaceEntry.name)) {
        fail("layout_stale_surface_ownership", surfacePath);
      }
      observedOwners.add(ownerKey(profileEntry.name, surfaceEntry.name));
    }
  }
  if (productRequired) {
    for (const profile of catalog.profiles) {
      for (const surface of catalog.surfaces) {
        const owner = ownerKey(profile, surface);
        if (!observedOwners.has(owner)) {
          fail("layout_owner_product_missing", `${root}/${owner}`);
        }
      }
    }
  }
  return collectFiles(repositoryRoot, root);
}

async function validateGoldenOwnership(repositoryRoot, catalog) {
  if ((await pathKind(repositoryRoot, catalog.config.goldenRoot)) == null) {
    return [];
  }
  const files = await collectFiles(repositoryRoot, catalog.config.goldenRoot);
  const profileSet = new Set(catalog.profiles);
  const surfaceSet = new Set(catalog.surfaces);
  const prefix = `${catalog.config.goldenRoot}/`;
  for (const relativePath of files) {
    const segments = relativePath.slice(prefix.length).split("/");
    const owners = [];
    for (let index = 0; index + 1 < segments.length; index += 1) {
      if (profileSet.has(segments[index]) && surfaceSet.has(segments[index + 1])) {
        owners.push(ownerKey(segments[index], segments[index + 1]));
      } else if (
        surfaceSet.has(segments[index + 1]) &&
        !profileSet.has(segments[index])
      ) {
        fail("layout_stale_profile_ownership", relativePath);
      }
    }
    if (new Set(owners).size > 1) {
      fail("layout_owned_path_ambiguous", relativePath);
    }
  }
  return files;
}

function isDirectNeutralDependency(relativePath) {
  return (
    relativePath.startsWith("apps/desktop/lib/src/contracts/presentation/") ||
    relativePath.startsWith("apps/desktop/lib/src/frontend/l10n/") ||
    neutralLayoutContracts.has(relativePath)
  );
}

function isNeutralClosureDependency(relativePath) {
  return (
    relativePath.startsWith("apps/desktop/lib/src/contracts/") ||
    relativePath.startsWith("apps/desktop/lib/src/frontend/l10n/") ||
    neutralLayoutContracts.has(relativePath) ||
    relativePath ===
      "apps/desktop/lib/src/application/features/layout/layout_state_store.dart" ||
    relativePath ===
      "apps/desktop/lib/src/application/features/layout/layout_catalog.dart" ||
    relativePath ===
      "apps/desktop/lib/src/application/features/navigation/semantic_destination_catalog.dart"
  );
}

function forbiddenDependencyCode(relativePath) {
  if (
    relativePath.includes("/application/controller/") ||
    relativePath.endsWith("/client_controller.dart") ||
    relativePath.includes("/controller/") ||
    /(?:^|\/)[A-Za-z0-9_]*controller\.dart$/u.test(relativePath)
  ) {
    return "layout_complete_controller_import";
  }
  if (/controller_scope\.dart$/u.test(relativePath)) {
    return "layout_controller_scope_import";
  }
  if (relativePath.includes("/frontend/layout/chrome/")) {
    return "layout_shared_styled_chrome_import";
  }
  if (relativePath.endsWith("/frontend/shared/ui/theme.dart")) {
    return "layout_concrete_theme_import";
  }
  if (relativePath.includes("/frontend/shared/ui/")) {
    return "layout_shared_styled_import";
  }
  if (relativePath.includes("/frontend/features/")) {
    return "layout_shared_feature_ui_import";
  }
  if (relativePath.includes("/frontend/shell/")) {
    return "layout_shell_implementation_import";
  }
  if (relativePath.includes("/application/")) {
    return "layout_application_import_forbidden";
  }
  if (
    relativePath.includes("/backend/") ||
    relativePath.includes("/platform/")
  ) {
    return "layout_implementation_import";
  }
  return null;
}

function maskCommentsAndStrings(source) {
  let result = "";
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (character === "\n") {
        lineComment = false;
        result += "\n";
      } else {
        result += " ";
      }
      continue;
    }
    if (blockComment) {
      if (character === "*" && next === "/") {
        result += "  ";
        blockComment = false;
        index += 1;
      } else {
        result += character === "\n" ? "\n" : " ";
      }
      continue;
    }
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      result += character === "\n" ? "\n" : " ";
      continue;
    }
    if (character === "/" && next === "/") {
      result += "  ";
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      result += "  ";
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      result += " ";
      continue;
    }
    result += character;
  }
  return result;
}

function containsPublicBusinessPortDeclaration(catalog, relativePath, source) {
  const masked = maskCommentsAndStrings(source);
  const sharedLayoutRoot = path.posix.dirname(catalog.config.profileSourceRoot);
  const isSharedLayoutSource =
    relativePath.startsWith(`${sharedLayoutRoot}/`) &&
    !relativePath.startsWith(`${catalog.config.profileSourceRoot}/`);
  const isDestinationContract = relativePath.startsWith(
    "apps/desktop/lib/src/contracts/presentation/destinations/",
  );
  if (!isSharedLayoutSource && !isDestinationContract) {
    return false;
  }
  if (isSharedLayoutSource && /_port\.dart$/u.test(relativePath)) {
    return true;
  }
  return (
    /\b(?:abstract\s+interface\s+|abstract\s+|base\s+|final\s+|interface\s+|sealed\s+)?class\s+[A-Z][A-Za-z0-9_]*Port\b/u.test(
      masked,
    ) ||
    /\btypedef\s+[A-Z][A-Za-z0-9_]*Port[A-Za-z0-9_]*\b/u.test(masked)
  );
}

function forbiddenNeutralPortApiCode(source) {
  const masked = maskCommentsAndStrings(source);
  if (/\bClientController\b/u.test(masked)) {
    return "layout_complete_controller_reference";
  }
  if (/\bBuildContext\b/u.test(masked)) {
    return "layout_neutral_build_context_forbidden";
  }
  if (
    /\bWidgetBuilder\b/u.test(masked) ||
    /\b(?:Widget|[A-Z][A-Za-z0-9_]+Widget)\b/u.test(masked)
  ) {
    return "layout_widget_producing_port_forbidden";
  }
  return null;
}

function containsDestinationPresentationScope(source) {
  return /\bLayoutDestinationPresentationScope\b/u.test(
    maskCommentsAndStrings(source),
  );
}

function containsCompleteControllerReference(source) {
  return /\bClientController\b/u.test(maskCommentsAndStrings(source));
}

function importsFlutterWidgetFramework(source) {
  return importsFrom(source).some((specifier) =>
    /^package:flutter\/(?:cupertino|material|widgets)\.dart$/u.test(specifier),
  );
}

function validatePublicLayoutPortApis(catalog, sourceByPath, graph) {
  const publicPortSeeds = [...sourceByPath]
    .filter(
      ([relativePath, source]) =>
        sourceOwnerFor(catalog, relativePath) == null &&
        containsPublicBusinessPortDeclaration(catalog, relativePath, source),
    )
    .map(([relativePath]) => relativePath);
  const publicPortSeedSet = new Set(publicPortSeeds);
  const publicPortClosure = transitiveClosure(graph, publicPortSeeds);
  for (const relativePath of publicPortClosure) {
    const source = sourceByPath.get(relativePath);
    if (source == null) {
      continue;
    }
    if (containsDestinationPresentationScope(source)) {
      fail("layout_destination_presentation_scope_forbidden", relativePath);
    }
    if (
      publicPortSeedSet.has(relativePath) &&
      importsFlutterWidgetFramework(source)
    ) {
      fail("layout_widget_producing_port_forbidden", relativePath);
    }
    const forbiddenCode = forbiddenNeutralPortApiCode(source);
    if (forbiddenCode != null) {
      fail(forbiddenCode, relativePath);
    }
  }
}

function containsProfileIdentityBranch(source) {
  const masked = maskCommentsAndStrings(source);
  const identity = /\bprofileId\b|\bprofile\.id\b|\bLayoutProfileId\.[A-Za-z_]\w*/u;
  const conditional = /\b(?:if|switch)\s*\(/gu;
  for (const match of masked.matchAll(conditional)) {
    const open = masked.indexOf("(", match.index);
    const close = matchingDelimiter(
      masked,
      open,
      "(",
      ")",
      "layout_profile_identity_branch_unclosed",
    );
    if (identity.test(masked.slice(open + 1, close))) {
      return true;
    }
  }
  return (
    /(?:\bprofileId\b|\bprofile\.id\b)\s*(?:==|!=)|(?:==|!=)\s*(?:\bprofileId\b|\bprofile\.id\b)/u.test(
      masked,
    ) ||
    /\bLayoutProfileId\.[A-Za-z_]\w*\s*(?:==|!=)|(?:==|!=)\s*LayoutProfileId\.[A-Za-z_]\w*/u.test(
      masked,
    ) ||
    /(?:\bprofileId\b|\bprofile\.id\b)[^;\n?]*\?/u.test(masked) ||
    /\bcase\s+LayoutProfileId\.[A-Za-z_]\w*/u.test(masked)
  );
}

function containsConcreteProfileIdentityBranch(source) {
  const uncommented = stripDartComments(source);
  return (
    (uncommented.includes("LayoutProfileId.parse(") &&
      containsProfileIdentityBranch(source)) ||
    /(?:\bprofileId\b|\bprofile\.id\b)(?:\.value)?\s*(?:==|!=)\s*['"][a-z]+(?:-[a-z]+)*['"]|['"][a-z]+(?:-[a-z]+)*['"]\s*(?:==|!=)\s*(?:\bprofileId\b|\bprofile\.id\b)(?:\.value)?/u.test(
      uncommented,
    )
  );
}

function validateOwnedDartSource(catalog, relativePath, source) {
  const sourceOwner = sourceOwnerFor(catalog, relativePath);
  const testOwner = testOwnerFor(catalog, relativePath);
  const owner = sourceOwner ?? testOwner;
  if (owner == null) {
    fail("layout_owned_path_ambiguous", relativePath);
  }
  if (sourceOwner != null && containsProfileIdentityBranch(source)) {
    fail("layout_profile_identity_branch_forbidden", relativePath);
  }
  if (sourceOwner != null && containsDestinationPresentationScope(source)) {
    fail("layout_destination_presentation_scope_forbidden", relativePath);
  }
  if (sourceOwner != null && containsCompleteControllerReference(source)) {
    fail("layout_complete_controller_reference", relativePath);
  }
  for (const specifier of importsFrom(source)) {
    if (
      specifier.startsWith("dart:") ||
      specifier.startsWith("package:flutter/") ||
      (testOwner != null && specifier.startsWith("package:flutter_test/"))
    ) {
      continue;
    }
    const resolved = resolveDartImport(relativePath, specifier);
    if (resolved == null) {
      fail("layout_external_import_forbidden", relativePath);
    }
    const importedOwner = codeOwnerFor(catalog, resolved);
    if (importedOwner != null) {
      if (importedOwner.profile !== owner.profile) {
        fail("layout_cross_profile_import", relativePath);
      }
      if (importedOwner.surface !== owner.surface) {
        fail("layout_cross_surface_import", relativePath);
      }
      continue;
    }
    if (
      isDirectNeutralDependency(resolved) ||
      (testOwner != null &&
        (resolved.startsWith(`${catalog.config.profileTestFixtureRoot}/`) ||
          resolved ===
            "apps/desktop/lib/src/frontend/shared/ui/theme.dart"))
    ) {
      continue;
    }
    const forbiddenCode = forbiddenDependencyCode(resolved);
    if (forbiddenCode != null) {
      fail(forbiddenCode, relativePath);
    }
    if (resolved.includes("/application/")) {
      fail("layout_application_import_forbidden", relativePath);
    }
    fail("layout_import_not_allowlisted", relativePath);
  }
  for (const token of [
    "LayoutRegistry(",
    "registerLayout(",
    "registerLayoutProfile(",
    "built_in_layout_composition",
  ]) {
    if (source.includes(token)) {
      fail("layout_mutable_registration_forbidden", relativePath);
    }
  }
}

function validateBundleImporter(catalog, relativePath, source) {
  const bundleEntries = new Set(
    catalog.bundles.map((bundle) => bundle.entryPath),
  );
  for (const specifier of importsFrom(source)) {
    const resolved = resolveDartImport(relativePath, specifier);
    if (resolved == null || !bundleEntries.has(resolved)) {
      continue;
    }
    if (relativePath === catalog.config.compositionPath) {
      continue;
    }
    const importerOwner = testOwnerFor(catalog, relativePath);
    const importedOwner = sourceOwnerFor(catalog, resolved);
    if (importerOwner != null && importerOwner.id === importedOwner?.id) {
      continue;
    }
    fail("layout_bundle_importer_unauthorized", relativePath);
  }
}

function validateProfilePrivateImporter(catalog, relativePath, source) {
  const bundleEntries = new Set(
    catalog.bundles.map((bundle) => bundle.entryPath),
  );
  const importerOwner = codeOwnerFor(catalog, relativePath);
  for (const specifier of importsFrom(source)) {
    const resolved = resolveDartImport(relativePath, specifier);
    if (resolved == null) {
      continue;
    }
    const importedOwner = sourceOwnerFor(catalog, resolved);
    if (importedOwner == null) {
      continue;
    }
    if (
      relativePath === catalog.config.compositionPath &&
      bundleEntries.has(resolved)
    ) {
      continue;
    }
    if (importerOwner?.id === importedOwner.id) {
      continue;
    }
    fail("layout_profile_private_importer_unauthorized", relativePath);
  }
}

function buildImportGraph(sourceByPath) {
  const graph = new Map();
  for (const [relativePath, source] of sourceByPath) {
    graph.set(
      relativePath,
      importsFrom(source)
        .map((specifier) => resolveDartImport(relativePath, specifier))
        .filter((candidate) => candidate != null && sourceByPath.has(candidate)),
    );
  }
  return graph;
}

function transitiveClosure(graph, starts) {
  const visited = new Set();
  const pending = [...starts];
  while (pending.length > 0) {
    const current = pending.pop();
    if (visited.has(current)) {
      continue;
    }
    visited.add(current);
    for (const dependency of graph.get(current) ?? []) {
      if (!visited.has(dependency)) {
        pending.push(dependency);
      }
    }
  }
  return visited;
}

function validateTransitiveClosures(catalog, sourceByPath, sourceFiles) {
  const graph = buildImportGraph(sourceByPath);
  for (const [relativePath, source] of sourceByPath) {
    if (containsDestinationPresentationScope(source)) {
      fail("layout_destination_presentation_scope_forbidden", relativePath);
    }
  }
  const neutralSeeds = [...sourceByPath.keys()].filter(isDirectNeutralDependency);
  const neutralClosure = transitiveClosure(graph, neutralSeeds);
  for (const relativePath of neutralClosure) {
    const forbiddenCode = forbiddenDependencyCode(relativePath);
    if (forbiddenCode != null) {
      fail(forbiddenCode, relativePath);
    }
    if (!isNeutralClosureDependency(relativePath)) {
      fail("layout_neutral_contract_closure_forbidden", relativePath);
    }
  }
  validatePublicLayoutPortApis(catalog, sourceByPath, graph);

  const closureByOwner = new Map();
  for (const bundle of catalog.bundles) {
    const owner = ownerKey(bundle.profile, bundle.surface);
    const starts = sourceFiles.filter(
      (relativePath) => sourceOwnerFor(catalog, relativePath)?.id === owner,
    );
    const closure = transitiveClosure(graph, starts);
    for (const relativePath of closure) {
      const dependencyOwner = sourceOwnerFor(catalog, relativePath);
      if (dependencyOwner != null && dependencyOwner.id !== owner) {
        if (dependencyOwner.profile !== bundle.profile) {
          fail("layout_cross_profile_import", bundle.entryPath);
        }
        fail("layout_cross_surface_import", bundle.entryPath);
      }
      const forbiddenCode = forbiddenDependencyCode(relativePath);
      if (forbiddenCode != null) {
        fail(forbiddenCode, bundle.entryPath);
      }
      const source = sourceByPath.get(relativePath);
      if (source != null && containsCompleteControllerReference(source)) {
        fail("layout_complete_controller_reference", bundle.entryPath);
      }
      if (source != null && containsDestinationPresentationScope(source)) {
        fail("layout_destination_presentation_scope_forbidden", bundle.entryPath);
      }
    }
    closureByOwner.set(owner, closure);
  }

  const owners = [...closureByOwner.keys()].sort(compareCanonical);
  for (let leftIndex = 0; leftIndex < owners.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < owners.length; rightIndex += 1) {
      const leftOwner = owners[leftIndex];
      const rightOwner = owners[rightIndex];
      const rightClosure = closureByOwner.get(rightOwner);
      for (const relativePath of closureByOwner.get(leftOwner)) {
        if (rightClosure.has(relativePath) && !neutralClosure.has(relativePath)) {
          fail(
            "layout_transitive_closure_intersection_forbidden",
            `${leftOwner}:${rightOwner}:${relativePath}`,
          );
        }
      }
    }
  }
  return closureByOwner;
}

function validateCurrentStateAuthority({ preferences, dataRoot, manifest, config }) {
  const preferencesUsesCurrentRoot =
    preferences.includes(
      "static const _fileName = 'appearance-preferences.json';",
    ) &&
    preferences.includes("final root = await _portableData.clientDirectory();") &&
    preferences.includes("return File(p.join(root.path, _fileName));") &&
    importsFrom(preferences).filter((specifier) =>
      specifier.includes("/platform/storage/"),
    ).length === 1;
  const dataRootOwnsOneCurrentWorkspace =
    dataRoot.includes("Future<Directory> clientDirectory() async") &&
    dataRoot.includes(
      "final directory = Directory(p.join(dataDir.path, 'lico-client'));",
    ) &&
    dataRoot.includes(
      "static const String _workspaceManifestFileName = '.lico-workspace.json';",
    ) &&
    manifest.includes("static const licoClientAppId = 'lico-client';");
  if (!preferencesUsesCurrentRoot || !dataRootOwnsOneCurrentWorkspace) {
    fail("layout_current_state_authority_invalid", config.preferencesPath);
  }
  const stateSources = `${preferences}\n${dataRoot}\n${manifest}`;
  if (
    /\b(?:discover|import|translate|prompt|migrate)[A-Za-z0-9_]*(?:Root|Preference|Namespace)\b/iu.test(
      stateSources,
    )
  ) {
    fail("layout_named_state_compatibility_behavior_present", config.preferencesPath);
  }
}

function digestManifest(files) {
  const hash = createHash("sha256");
  for (const [relativePath, source] of [...files].sort(([left], [right]) =>
    compareCanonical(left, right),
  )) {
    hash.update(relativePath);
    hash.update("\0");
    hash.update(source);
    hash.update("\0");
  }
  return hash.digest("hex");
}

export async function verifyLayoutBoundaries({
  repositoryRoot = scriptRepositoryRoot,
  config = DEFAULT_LAYOUT_BOUNDARY_CONFIG,
} = {}) {
  const catalog = await discoverLayoutBundleProduct({ repositoryRoot, config });
  const sourceFiles = await validateCanonicalOwnerRoot({
    repositoryRoot,
    catalog,
    root: catalog.config.profileSourceRoot,
    rootRequired: true,
    productRequired: true,
  });
  const testFiles = await validateCanonicalOwnerRoot({
    repositoryRoot,
    catalog,
    root: catalog.config.profileTestRoot,
    rootRequired: true,
    productRequired: true,
  });
  const assetFiles = await validateCanonicalOwnerRoot({
    repositoryRoot,
    catalog,
    root: catalog.config.assetRoot,
    rootRequired: false,
    productRequired: false,
  });
  const goldenFiles = await validateGoldenOwnership(repositoryRoot, catalog);

  const ownedDartFiles = [...sourceFiles, ...testFiles].filter((relativePath) =>
    relativePath.endsWith(".dart"),
  );
  const ownedSourceEntries = await Promise.all(
    ownedDartFiles.map(async (relativePath) => [
      relativePath,
      await readUtf8(repositoryRoot, relativePath),
    ]),
  );
  for (const [relativePath, source] of ownedSourceEntries) {
    validateOwnedDartSource(catalog, relativePath, source);
  }

  const libraryFiles = (await collectFiles(repositoryRoot, catalog.config.libraryRoot)).filter(
    (relativePath) => relativePath.endsWith(".dart"),
  );
  const allTestFiles = (await collectFiles(repositoryRoot, catalog.config.testRoot)).filter(
    (relativePath) => relativePath.endsWith(".dart"),
  );
  const sourceByPath = new Map(
    await Promise.all(
      libraryFiles.map(async (relativePath) => [
        relativePath,
        await readUtf8(repositoryRoot, relativePath),
      ]),
    ),
  );
  for (const relativePath of [...libraryFiles, ...allTestFiles]) {
    const source = sourceByPath.get(relativePath) ??
      (await readUtf8(repositoryRoot, relativePath));
    validateBundleImporter(catalog, relativePath, source);
    validateProfilePrivateImporter(catalog, relativePath, source);
    if (
      sourceByPath.has(relativePath) &&
      sourceOwnerFor(catalog, relativePath) == null &&
      containsConcreteProfileIdentityBranch(source)
    ) {
      fail("layout_profile_identity_branch_forbidden", relativePath);
    }
  }
  validateTransitiveClosures(catalog, sourceByPath, sourceFiles);

  const [preferences, dataRoot, manifest] = await Promise.all([
    readUtf8(repositoryRoot, catalog.config.preferencesPath),
    readUtf8(repositoryRoot, catalog.config.portableDataRootPath),
    readUtf8(repositoryRoot, catalog.config.workspaceManifestPath),
  ]);
  validateCurrentStateAuthority({
    preferences,
    dataRoot,
    manifest,
    config: catalog.config,
  });

  const allOwnedFiles = [...sourceFiles, ...testFiles, ...assetFiles, ...goldenFiles];
  const allOwnedEntries = await Promise.all(
    allOwnedFiles.map(async (relativePath) => [
      relativePath,
      await readFile(containedPath(repositoryRoot, relativePath)),
    ]),
  );
  const ownerDigests = Object.fromEntries(
    catalog.bundles.map((bundle) => {
      const owner = ownerKey(bundle.profile, bundle.surface);
      return [
        owner,
        digestManifest(
          allOwnedEntries.filter(([relativePath]) => {
            const exactOwner = codeOwnerFor(catalog, relativePath) ??
              exactOwnerFor(catalog, relativePath, catalog.config.assetRoot);
            if (exactOwner?.id === owner) {
              return true;
            }
            const segments = relativePath.split("/");
            return segments.some(
              (segment, index) =>
                segment === bundle.profile && segments[index + 1] === bundle.surface,
            );
          }),
        ),
      ];
    }),
  );
  return Object.freeze({
    profiles: catalog.profiles.length,
    surfaces: catalog.surfaces.length,
    bundles: catalog.bundles.length,
    ownedFiles: allOwnedFiles.length,
    profileDartFiles: sourceFiles.filter((file) => file.endsWith(".dart")).length,
    ownerDigests: Object.freeze(ownerDigests),
    compositionDigest: digestManifest([
      [catalog.config.compositionPath, catalog.compositionSource],
    ]),
    currentStateAuthority: true,
    retiredNameStateMigrationSupported: false,
    retiredNameStateCompatibilityBehaviorPresent: false,
  });
}

const isMain =
  process.argv[1] != null &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isMain) {
  if (process.argv.includes("--self-test")) {
    const selfTestPath = path.join(
      path.dirname(scriptPath),
      "verify-layout-boundaries-self-test.mjs",
    );
    const result = spawnSync(process.execPath, [selfTestPath], {
      stdio: "inherit",
    });
    if (result.error) {
      throw result.error;
    }
    process.exitCode = result.status ?? 1;
  } else {
    const result = await verifyLayoutBoundaries();
    process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
  }
}
