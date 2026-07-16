import path from "node:path";
import { readdir } from "node:fs/promises";
import { fail } from "./errors.mjs";
import {
  collectFiles,
  containedPath,
  normalizeRelative,
  pathKind,
} from "./paths.mjs";

export function ownerKey(profile, surface) {
  return `${profile}/${surface}`;
}

export function exactOwnerFor(catalog, relativePath, root) {
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

export function sourceOwnerFor(catalog, relativePath) {
  return exactOwnerFor(catalog, relativePath, catalog.config.profileSourceRoot);
}

export function testOwnerFor(catalog, relativePath) {
  return exactOwnerFor(catalog, relativePath, catalog.config.profileTestRoot);
}

export function codeOwnerFor(catalog, relativePath) {
  return sourceOwnerFor(catalog, relativePath) ?? testOwnerFor(catalog, relativePath);
}

export async function validateCanonicalOwnerRoot({
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

export async function validateGoldenOwnership(repositoryRoot, catalog) {
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
