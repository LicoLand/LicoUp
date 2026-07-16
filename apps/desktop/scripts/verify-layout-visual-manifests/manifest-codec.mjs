import {
  digestPattern,
  manifestSchema,
  manifestSchemaVersion,
} from "./config.mjs";
import { fail } from "./errors.mjs";
import { ownerForMirroredPath } from "./owner-roots.mjs";
import {
  canonicalJson,
  compareCanonical,
  exactKeys,
  normalizeRelative,
  sha256,
} from "./paths.mjs";

function manifestBody(manifest) {
  return {
    schema: manifest.schema,
    schemaVersion: manifest.schemaVersion,
    profile: manifest.profile,
    surface: manifest.surface,
    bundleEntry: manifest.bundleEntry,
    sourceRoots: manifest.sourceRoots,
    authorityEntries: manifest.authorityEntries,
    entries: manifest.entries,
  };
}

export function manifestDigest(manifest) {
  return sha256(Buffer.from(canonicalJson(manifestBody(manifest)), "utf8"));
}

export function expectedManifestPath(catalog, profile, surface) {
  return normalizeRelative(
    `${catalog.config.expectedManifestRoot}/${profile}/${surface}.json`,
  );
}

export function renderLayoutVisualManifest(manifest) {
  return `${JSON.stringify(manifest, null, 2)}\n`;
}

export function validateStoredManifest({ catalog, ownerRoots, expected, stored }) {
  const expectedPath = expected.path;
  exactKeys(
    stored,
    [
      "schema",
      "schemaVersion",
      "profile",
      "surface",
      "bundleEntry",
      "sourceRoots",
      "authorityEntries",
      "entries",
      "manifestDigest",
    ],
    "layout_visual_manifest_shape_invalid",
    expectedPath,
  );
  if (
    stored.profile !== expected.manifest.profile ||
    stored.surface !== expected.manifest.surface
  ) {
    fail("layout_visual_manifest_copied", expectedPath);
  }
  if (
    stored.schema !== manifestSchema ||
    stored.schemaVersion !== manifestSchemaVersion
  ) {
    fail("layout_visual_manifest_schema_invalid", expectedPath);
  }
  if (typeof stored.bundleEntry !== "string") {
    fail("layout_visual_manifest_bundle_entry_invalid", expectedPath);
  }
  const owner = `${stored.profile}/${stored.surface}`;
  const bundleEntryOwners = ownerForMirroredPath(
    catalog,
    ownerRoots,
    normalizeRelative(stored.bundleEntry),
  );
  if (bundleEntryOwners.length !== 1 || bundleEntryOwners[0] !== owner) {
    fail("layout_visual_manifest_cross_profile_path", expectedPath);
  }
  if (!Array.isArray(stored.sourceRoots) || stored.sourceRoots.length === 0) {
    fail("layout_visual_manifest_roots_invalid", expectedPath);
  }
  let previousRoot = "";
  for (const value of stored.sourceRoots) {
    const root = normalizeRelative(value);
    if (root !== value || compareCanonical(previousRoot, root) >= 0) {
      fail("layout_visual_manifest_roots_noncanonical", expectedPath);
    }
    const owners = ownerForMirroredPath(catalog, ownerRoots, root);
    if (owners.length !== 1 || owners[0] !== owner) {
      fail("layout_visual_manifest_cross_profile_path", expectedPath);
    }
    previousRoot = root;
  }
  if (!Array.isArray(stored.entries) || stored.entries.length === 0) {
    fail("layout_visual_manifest_entries_invalid", expectedPath);
  }
  if (!Array.isArray(stored.authorityEntries)) {
    fail("layout_visual_manifest_authority_invalid", expectedPath);
  }
  const expectedAuthorityPaths = new Set([
    catalog.config.productionBaselineFixturePath,
    catalog.config.productionBaselineTestPath,
    catalog.config.productionContinuityTestPath,
  ]);
  if (stored.authorityEntries.length !== expectedAuthorityPaths.size) {
    fail("layout_visual_manifest_authority_invalid", expectedPath);
  }
  let previousAuthorityPath = "";
  for (const entry of stored.authorityEntries) {
    exactKeys(
      entry,
      ["path", "digest"],
      "layout_visual_manifest_authority_invalid",
      expectedPath,
    );
    const relativePath = normalizeRelative(entry.path);
    if (
      relativePath !== entry.path ||
      compareCanonical(previousAuthorityPath, relativePath) >= 0 ||
      !expectedAuthorityPaths.has(relativePath) ||
      !digestPattern.test(String(entry.digest || ""))
    ) {
      fail("layout_visual_manifest_authority_invalid", expectedPath);
    }
    previousAuthorityPath = relativePath;
  }
  let previousPath = "";
  for (const entry of stored.entries) {
    exactKeys(
      entry,
      ["path", "digest"],
      "layout_visual_manifest_entry_shape_invalid",
      expectedPath,
    );
    const relativePath = normalizeRelative(entry.path);
    if (
      relativePath !== entry.path ||
      compareCanonical(previousPath, relativePath) >= 0 ||
      !digestPattern.test(String(entry.digest || ""))
    ) {
      fail("layout_visual_manifest_entry_invalid", expectedPath);
    }
    const owners = ownerForMirroredPath(
      catalog,
      ownerRoots,
      relativePath,
    );
    if (owners.length !== 1 || owners[0] !== owner) {
      fail("layout_visual_manifest_cross_profile_path", expectedPath);
    }
    previousPath = relativePath;
  }
  if (
    !digestPattern.test(String(stored.manifestDigest || "")) ||
    manifestDigest(stored) !== stored.manifestDigest
  ) {
    fail("layout_visual_manifest_stale", expectedPath);
  }
}
