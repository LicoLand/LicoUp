import {
  DEFAULT_LAYOUT_VISUAL_CONFIG,
  manifestSchema,
  manifestSchemaVersion,
  scriptRepositoryRoot,
} from "./config.mjs";
import { fail } from "./errors.mjs";
import { discoverLayoutCatalog } from "./catalog.mjs";
import {
  expectedManifestPath,
  manifestDigest,
} from "./manifest-codec.mjs";
import {
  collectFiles,
  discoverOwnerSourceRoots,
  ownerForMirroredPath,
  ownerKey,
  productionSourceRoot,
  sha256File,
} from "./owner-roots.mjs";
import { compareCanonical } from "./paths.mjs";

export async function generateLayoutVisualManifests({
  repositoryRoot = scriptRepositoryRoot,
  config = DEFAULT_LAYOUT_VISUAL_CONFIG,
} = {}) {
  const catalog = await discoverLayoutCatalog({ repositoryRoot, config });
  const ownerRoots = await discoverOwnerSourceRoots(repositoryRoot, catalog);
  const authorityEntries = Object.freeze(
    await Promise.all(
      [
        catalog.config.productionBaselineFixturePath,
        catalog.config.productionBaselineTestPath,
        catalog.config.productionContinuityTestPath,
      ]
        .sort(compareCanonical)
        .map(async (relativePath) =>
          Object.freeze({
            path: relativePath,
            digest: await sha256File(repositoryRoot, relativePath),
          }),
        ),
    ),
  );
  const manifests = [];
  for (const bundle of catalog.bundles) {
    const owner = ownerKey(bundle.profile, bundle.surface);
    const sourceRoots = ownerRoots.byOwner.get(owner);
    const files = [];
    for (const root of sourceRoots) {
      files.push(...(await collectFiles(repositoryRoot, root)));
    }
    const productionRoot = productionSourceRoot(
      catalog,
      bundle.profile,
      bundle.surface,
    );
    if (
      !files.some((relativePath) =>
        relativePath.startsWith(`${productionRoot}/`),
      )
    ) {
      fail("layout_visual_production_source_missing", bundle.entryPath);
    }
    const uniqueFiles = [...new Set(files)].sort(compareCanonical);
    const entries = [];
    for (const relativePath of uniqueFiles) {
      const owners = ownerForMirroredPath(
        catalog,
        ownerRoots,
        relativePath,
      );
      if (owners.length !== 1 || owners[0] !== owner) {
        fail("layout_visual_source_owner_ambiguous", relativePath);
      }
      entries.push({
        path: relativePath,
        digest: await sha256File(repositoryRoot, relativePath),
      });
    }
    const body = {
      schema: manifestSchema,
      schemaVersion: manifestSchemaVersion,
      profile: bundle.profile,
      surface: bundle.surface,
      bundleEntry: bundle.entryPath,
      sourceRoots,
      authorityEntries,
      entries,
    };
    const manifest = Object.freeze({
      ...body,
      manifestDigest: manifestDigest(body),
    });
    manifests.push(
      Object.freeze({
        path: expectedManifestPath(
          catalog,
          bundle.profile,
          bundle.surface,
        ),
        manifest,
      }),
    );
  }
  return Object.freeze({
    catalog,
    ownerRoots,
    manifests: Object.freeze(manifests),
  });
}
