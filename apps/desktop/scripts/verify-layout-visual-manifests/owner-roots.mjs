import { createHash } from "node:crypto";
import { lstat, open, readdir } from "node:fs/promises";
import path from "node:path";

import {
  forbiddenDiagnosticBasename,
  forbiddenResidueBasenames,
  generatedDiagnosticDirectories,
  ignoredBasenames,
} from "./config.mjs";
import { fail } from "./errors.mjs";
import { compareCanonical, containedPath, normalizeRelative } from "./paths.mjs";

export function ownerKey(profile, surface) {
  return `${profile}/${surface}`;
}

export function productionSourceRoot(catalog, profile, surface) {
  return normalizeRelative(
    `${catalog.config.profileSourceRoot}/${profile}/${surface}`,
  );
}

export function mirroredBaseRoots(catalog) {
  return [
    catalog.config.assetRoot,
    catalog.config.profileTestRoot,
    catalog.config.goldenRoot,
  ];
}

export function ownerOccurrences(catalog, relativePath) {
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

export async function discoverOwnerSourceRoots(repositoryRoot, catalog) {
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

export async function existingDirectory(repositoryRoot, relativePath) {
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

export async function collectFiles(repositoryRoot, relativeDirectory, {
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

export async function sha256File(repositoryRoot, relativePath) {
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

export function ownerForMirroredPath(catalog, ownerRoots, relativePath) {
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
