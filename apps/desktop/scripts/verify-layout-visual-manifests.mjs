#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  lstat,
  mkdir,
  open,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  DEFAULT_LAYOUT_BOUNDARY_CONFIG,
  discoverLayoutBundleProduct,
} from "./verify-layout-boundaries.mjs";

const scriptRepositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);

const manifestSchema = "licolite.layout-visual-manifest";
const manifestSchemaVersion = 2;
const digestPattern = /^sha256:[a-f0-9]{64}$/u;
const generatedDiagnosticDirectories = new Set(["failures"]);
const ignoredBasenames = new Set([".DS_Store", "Thumbs.db"]);
const forbiddenResidueBasenames = new Set(["source-golden.sha256"]);
const forbiddenDiagnosticBasename =
  /_(?:masterImage|testImage|isolatedDiff|maskedDiff)\.png$/u;

export const DEFAULT_LAYOUT_VISUAL_CONFIG = Object.freeze({
  compositionPath:
    "apps/desktop/lib/src/frontend/layout/built_in_layout_composition.dart",
  surfaceContractPath:
    "apps/desktop/lib/src/contracts/presentation/layout_environment.dart",
  profileSourceRoot:
    "apps/desktop/lib/src/frontend/layout/profiles",
  assetRoot: "apps/desktop/assets/layout-profiles",
  profileTestRoot: "apps/desktop/test/layout/profiles",
  goldenRoot: "apps/desktop/test/goldens/layout",
  expectedManifestRoot:
    "apps/desktop/test/layout/visual-manifests",
  productionBaselineTestPath:
    "apps/desktop/test/layout/production_baseline/production_layout_baseline_test.dart",
  productionContinuityTestPath:
    "apps/desktop/test/layout/production_baseline/production_layout_switch_continuity_test.dart",
  productionBaselineFixturePath:
    "apps/desktop/test/layout/fixtures/production_client_shell_fixture.dart",
});

export class LayoutVisualManifestError extends Error {
  constructor(code, relativePath = "") {
    super(relativePath ? `${code}: ${relativePath}` : code);
    this.name = "LayoutVisualManifestError";
    this.code = code;
    this.relativePath = relativePath;
  }
}

function fail(code, relativePath = "") {
  throw new LayoutVisualManifestError(code, relativePath);
}

function compareCanonical(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function normalizeRelative(value) {
  if (typeof value !== "string" || !value || value.includes("\0")) {
    fail("layout_visual_path_invalid");
  }
  const posix = value.replaceAll("\\", "/");
  const normalized = path.posix.normalize(posix).replace(/^\.\//u, "");
  if (
    path.posix.isAbsolute(posix) ||
    normalized === "." ||
    normalized === ".." ||
    normalized.startsWith("../")
  ) {
    fail("layout_visual_path_invalid", value);
  }
  return normalized.replace(/\/$/u, "");
}

function containedPath(repositoryRoot, relativePath) {
  const root = path.resolve(repositoryRoot);
  const relative = normalizeRelative(relativePath);
  const absolute = path.resolve(root, ...relative.split("/"));
  const fromRoot = path.relative(root, absolute);
  if (
    !fromRoot ||
    fromRoot.startsWith("..") ||
    path.isAbsolute(fromRoot)
  ) {
    fail("layout_visual_path_escapes_repository", relative);
  }
  return absolute;
}

function canonicalJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort(compareCanonical)
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function sha256(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function exactKeys(value, expectedKeys, code, relativePath = "") {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    canonicalJson(Object.keys(value).sort(compareCanonical)) !==
      canonicalJson([...expectedKeys].sort(compareCanonical))
  ) {
    fail(code, relativePath);
  }
}

async function readUtf8(repositoryRoot, relativePath) {
  try {
    return await readFile(containedPath(repositoryRoot, relativePath), "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      fail("layout_visual_required_source_missing", relativePath);
    }
    throw error;
  }
}

export async function discoverLayoutCatalog({
  repositoryRoot = scriptRepositoryRoot,
  config = DEFAULT_LAYOUT_VISUAL_CONFIG,
} = {}) {
  const normalizedConfig = Object.fromEntries(
    Object.entries(config).map(([key, value]) => [key, normalizeRelative(value)]),
  );
  const product = await discoverLayoutBundleProduct({
    repositoryRoot,
    config: {
      ...DEFAULT_LAYOUT_BOUNDARY_CONFIG,
      compositionPath: normalizedConfig.compositionPath,
      surfaceContractPath: normalizedConfig.surfaceContractPath,
      profileSourceRoot: normalizedConfig.profileSourceRoot,
      profileTestRoot: normalizedConfig.profileTestRoot,
      assetRoot: normalizedConfig.assetRoot,
      goldenRoot: normalizedConfig.goldenRoot,
    },
  });
  return Object.freeze({
    config: Object.freeze(normalizedConfig),
    profiles: product.profiles,
    surfaces: product.surfaces,
    bundles: product.bundles,
  });
}

function ownerKey(profile, surface) {
  return `${profile}/${surface}`;
}

function productionSourceRoot(catalog, profile, surface) {
  return normalizeRelative(
    `${catalog.config.profileSourceRoot}/${profile}/${surface}`,
  );
}

function mirroredBaseRoots(catalog) {
  return [
    catalog.config.assetRoot,
    catalog.config.profileTestRoot,
    catalog.config.goldenRoot,
  ];
}

function ownerOccurrences(catalog, relativePath) {
  const candidate = normalizeRelative(relativePath);
  const profileSet = new Set(catalog.profiles);
  const surfaceSet = new Set(catalog.surfaces);
  const occurrences = [];
  for (const baseRoot of [
    catalog.config.profileSourceRoot,
    ...mirroredBaseRoots(catalog),
  ]) {
    const prefix = `${baseRoot}/`;
    if (!candidate.startsWith(prefix)) {
      continue;
    }
    const segments = candidate.slice(prefix.length).split("/");
    for (let index = 0; index + 1 < segments.length; index += 1) {
      const profile = segments[index];
      const surface = segments[index + 1];
      if (profileSet.has(profile) && surfaceSet.has(surface)) {
        occurrences.push({
          owner: ownerKey(profile, surface),
          root: normalizeRelative(
            `${baseRoot}/${segments.slice(0, index + 2).join("/")}`,
          ),
        });
      }
    }
  }
  return occurrences;
}

async function discoverOwnerSourceRoots(repositoryRoot, catalog) {
  const byOwner = new Map(
    catalog.bundles.map((bundle) => [
      ownerKey(bundle.profile, bundle.surface),
      new Set(),
    ]),
  );
  for (const bundle of catalog.bundles) {
    const owner = ownerKey(bundle.profile, bundle.surface);
    const root = productionSourceRoot(
      catalog,
      bundle.profile,
      bundle.surface,
    );
    if (!(await existingDirectory(repositoryRoot, root))) {
      fail("layout_visual_production_source_missing", bundle.entryPath);
    }
    byOwner.get(owner).add(root);
  }

  for (const baseRoot of mirroredBaseRoots(catalog)) {
    if (!(await existingDirectory(repositoryRoot, baseRoot))) {
      continue;
    }
    async function visit(relativeDirectory) {
      const occurrences = ownerOccurrences(catalog, relativeDirectory);
      const ending = occurrences.filter(
        (occurrence) => occurrence.root === relativeDirectory,
      );
      if (ending.length > 1) {
        fail("layout_visual_source_owner_ambiguous", relativeDirectory);
      }
      if (ending.length === 1) {
        byOwner.get(ending[0].owner).add(relativeDirectory);
        return;
      }
      if (occurrences.length > 0) {
        fail("layout_visual_source_owner_ambiguous", relativeDirectory);
      }
      const entries = await readdir(
        containedPath(repositoryRoot, relativeDirectory),
        { withFileTypes: true },
      );
      entries.sort((left, right) => compareCanonical(left.name, right.name));
      for (const entry of entries) {
        const child = normalizeRelative(
          path.posix.join(relativeDirectory, entry.name),
        );
        if (entry.isSymbolicLink()) {
          fail("layout_visual_source_symlink_forbidden", child);
        }
        if (entry.isDirectory()) {
          await visit(child);
        }
      }
    }
    await visit(baseRoot);
  }

  const normalizedByOwner = new Map();
  const rootOwners = new Map();
  for (const [owner, roots] of byOwner) {
    const sortedRoots = [...roots].sort(compareCanonical);
    normalizedByOwner.set(owner, sortedRoots);
    for (const root of sortedRoots) {
      if (rootOwners.has(root) && rootOwners.get(root) !== owner) {
        fail("layout_visual_source_owner_ambiguous", root);
      }
      rootOwners.set(root, owner);
    }
  }
  return Object.freeze({
    byOwner: normalizedByOwner,
    rootOwners,
  });
}

async function existingDirectory(repositoryRoot, relativePath) {
  let info;
  try {
    info = await lstat(containedPath(repositoryRoot, relativePath));
  } catch (error) {
    if (error?.code === "ENOENT") {
      return false;
    }
    throw error;
  }
  if (info.isSymbolicLink()) {
    fail("layout_visual_source_symlink_forbidden", relativePath);
  }
  if (!info.isDirectory()) {
    fail("layout_visual_source_root_not_directory", relativePath);
  }
  return true;
}

async function collectFiles(repositoryRoot, relativeDirectory, {
  excludeGeneratedDiagnostics = true,
} = {}) {
  const directory = normalizeRelative(relativeDirectory);
  if (!(await existingDirectory(repositoryRoot, directory))) {
    return [];
  }
  const files = [];
  async function visit(relativePath) {
    const entries = await readdir(containedPath(repositoryRoot, relativePath), {
      withFileTypes: true,
    });
    entries.sort((left, right) => compareCanonical(left.name, right.name));
    for (const entry of entries) {
      const child = normalizeRelative(
        path.posix.join(relativePath, entry.name),
      );
      if (
        (entry.isDirectory() &&
          generatedDiagnosticDirectories.has(entry.name)) ||
        (entry.isFile() &&
          (forbiddenResidueBasenames.has(entry.name) ||
            forbiddenDiagnosticBasename.test(entry.name)))
      ) {
        fail("layout_visual_generated_residue_forbidden", child);
      }
      if (excludeGeneratedDiagnostics && ignoredBasenames.has(entry.name)) {
        continue;
      }
      if (entry.isSymbolicLink()) {
        fail("layout_visual_source_symlink_forbidden", child);
      }
      if (entry.isDirectory()) {
        await visit(child);
      } else if (entry.isFile()) {
        files.push(child);
      } else {
        fail("layout_visual_source_entry_unsupported", child);
      }
    }
  }
  await visit(directory);
  return files.sort(compareCanonical);
}

async function sha256File(repositoryRoot, relativePath) {
  const absolutePath = containedPath(repositoryRoot, relativePath);
  const handle = await open(absolutePath, "r");
  try {
    const before = await handle.stat({ bigint: true });
    if (!before.isFile()) {
      fail("layout_visual_source_entry_not_file", relativePath);
    }
    const hash = createHash("sha256");
    for await (const chunk of handle.createReadStream({ autoClose: false })) {
      hash.update(chunk);
    }
    const after = await handle.stat({ bigint: true });
    if (
      before.dev !== after.dev ||
      before.ino !== after.ino ||
      before.size !== after.size ||
      before.mtimeNs !== after.mtimeNs ||
      before.ctimeNs !== after.ctimeNs
    ) {
      fail("layout_visual_source_changed_during_hash", relativePath);
    }
    return `sha256:${hash.digest("hex")}`;
  } finally {
    await handle.close();
  }
}

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

function manifestDigest(manifest) {
  return sha256(Buffer.from(canonicalJson(manifestBody(manifest)), "utf8"));
}

function expectedManifestPath(catalog, profile, surface) {
  return normalizeRelative(
    `${catalog.config.expectedManifestRoot}/${profile}/${surface}.json`,
  );
}

export function renderLayoutVisualManifest(manifest) {
  return `${JSON.stringify(manifest, null, 2)}\n`;
}

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

function ownerForMirroredPath(catalog, ownerRoots, relativePath) {
  const candidate = normalizeRelative(relativePath);
  const occurrences = ownerOccurrences(catalog, candidate);
  const semanticOwners = new Set(
    occurrences.map((occurrence) => occurrence.owner),
  );
  const rootedOwners = new Set();
  for (const occurrence of occurrences) {
    const owner = ownerRoots.rootOwners.get(occurrence.root);
    if (owner != null) {
      rootedOwners.add(owner);
    }
  }
  if (
    semanticOwners.size !== 1 ||
    rootedOwners.size !== 1 ||
    [...semanticOwners][0] !== [...rootedOwners][0]
  ) {
    return [...new Set([...semanticOwners, ...rootedOwners])].sort(
      compareCanonical,
    );
  }
  return [[...semanticOwners][0]];
}

function validateStoredManifest({ catalog, ownerRoots, expected, stored }) {
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

export async function checkLayoutVisualManifests({
  repositoryRoot = scriptRepositoryRoot,
  config = DEFAULT_LAYOUT_VISUAL_CONFIG,
} = {}) {
  const generated = await generateLayoutVisualManifests({
    repositoryRoot,
    config,
  });
  const expectedByPath = new Map(
    generated.manifests.map((entry) => [entry.path, entry]),
  );
  const storedFiles = await collectFiles(
    repositoryRoot,
    generated.catalog.config.expectedManifestRoot,
    { excludeGeneratedDiagnostics: false },
  );
  const storedFileSet = new Set(storedFiles);
  for (const relativePath of storedFiles) {
    if (!expectedByPath.has(relativePath)) {
      fail("layout_visual_manifest_unexpected", relativePath);
    }
  }
  let entryCount = 0;
  for (const expected of generated.manifests) {
    if (!storedFileSet.has(expected.path)) {
      fail("layout_visual_manifest_missing", expected.path);
    }
    const source = await readUtf8(repositoryRoot, expected.path);
    let stored;
    try {
      stored = JSON.parse(source);
    } catch {
      fail("layout_visual_manifest_json_invalid", expected.path);
    }
    validateStoredManifest({
      catalog: generated.catalog,
      ownerRoots: generated.ownerRoots,
      expected,
      stored,
    });
    if (source !== renderLayoutVisualManifest(expected.manifest)) {
      fail("layout_visual_manifest_stale", expected.path);
    }
    entryCount +=
      expected.manifest.entries.length +
      expected.manifest.authorityEntries.length;
  }
  return Object.freeze({
    profiles: generated.catalog.profiles.length,
    surfaces: generated.catalog.surfaces.length,
    manifests: generated.manifests.length,
    entries: entryCount,
  });
}

export async function writeLayoutVisualManifests({
  repositoryRoot = scriptRepositoryRoot,
  config = DEFAULT_LAYOUT_VISUAL_CONFIG,
} = {}) {
  const generated = await generateLayoutVisualManifests({
    repositoryRoot,
    config,
  });
  const expectedRoot = generated.catalog.config.expectedManifestRoot;
  const absoluteExpectedRoot = containedPath(repositoryRoot, expectedRoot);
  await rm(absoluteExpectedRoot, { recursive: true, force: true });
  for (const expected of generated.manifests) {
    const absolutePath = containedPath(repositoryRoot, expected.path);
    await mkdir(path.dirname(absolutePath), { recursive: true });
    await writeFile(
      absolutePath,
      renderLayoutVisualManifest(expected.manifest),
      "utf8",
    );
  }
  return Object.freeze({
    profiles: generated.catalog.profiles.length,
    surfaces: generated.catalog.surfaces.length,
    manifests: generated.manifests.length,
    entries: generated.manifests.reduce(
      (total, expected) => total + expected.manifest.entries.length,
      0,
    ) + generated.manifests.reduce(
      (total, expected) => total + expected.manifest.authorityEntries.length,
      0,
    ),
  });
}

async function runCli() {
  const modes = process.argv.slice(2);
  const valid =
    modes.length === 0 ||
    (modes.length === 1 && ["--check", "--write"].includes(modes[0]));
  if (!valid) {
    fail("layout_visual_manifest_arguments_invalid");
  }
  const mode = modes[0] === "--write" ? "write" : "check";
  const result =
    mode === "write"
      ? await writeLayoutVisualManifests()
      : await checkLayoutVisualManifests();
  process.stdout.write(`${JSON.stringify({ ok: true, mode, ...result })}\n`);
}

const isDirectExecution =
  process.argv[1] != null &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectExecution) {
  try {
    await runCli();
  } catch (error) {
    const code =
      error instanceof LayoutVisualManifestError
        ? error.code
        : "layout_visual_manifest_internal_error";
    const relativePath =
      error instanceof LayoutVisualManifestError && error.relativePath
        ? error.relativePath
        : undefined;
    process.stderr.write(
      `${JSON.stringify({ ok: false, code, path: relativePath })}\n`,
    );
    process.exitCode = 1;
  }
}
