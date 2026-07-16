import { readFile } from "node:fs/promises";
import { discoverLayoutBundleProduct } from "./bundle-product.mjs";
import {
  DEFAULT_LAYOUT_BOUNDARY_CONFIG,
  scriptRepositoryRoot,
} from "./config.mjs";
import { containsConcreteProfileIdentityBranch, validateOwnedDartSource } from "./dependency-policy.mjs";
import { fail } from "./errors.mjs";
import {
  validateBundleImporter,
  validateProfilePrivateImporter,
  validateTransitiveClosures,
} from "./import-graph.mjs";
import {
  codeOwnerFor,
  exactOwnerFor,
  ownerKey,
  sourceOwnerFor,
  validateCanonicalOwnerRoot,
  validateGoldenOwnership,
} from "./ownership.mjs";
import {
  collectFiles,
  containedPath,
  readUtf8,
} from "./paths.mjs";
import { digestManifest, validateCurrentStateAuthority } from "./state-authority.mjs";

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
