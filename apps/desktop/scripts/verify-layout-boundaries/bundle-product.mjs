import {
  DEFAULT_LAYOUT_BOUNDARY_CONFIG,
  scriptRepositoryRoot,
} from "./config.mjs";
import { importsFrom, resolveDartImport } from "./dart-source.mjs";
import { fail } from "./errors.mjs";
import {
  compareCanonical,
  normalizeConfig,
  readUtf8,
} from "./paths.mjs";
import {
  parseDefinitionBundleSymbols,
  parseSurfaceIdentities,
  profileSurfaceFromPath,
  uniqueMatch,
} from "./surface-parse.mjs";

function sameSet(left, right) {
  return left.size === right.size && [...left].every((value) => right.has(value));
}

export async function discoverImportedBundles({
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
