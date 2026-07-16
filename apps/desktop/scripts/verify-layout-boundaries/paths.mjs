import { lstat, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fail } from "./errors.mjs";

export function compareCanonical(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

export function normalizeRelative(value) {
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

export function normalizeConfig(config) {
  return Object.freeze(
    Object.fromEntries(
      Object.entries(config).map(([key, value]) => [
        key,
        normalizeRelative(value),
      ]),
    ),
  );
}

export function containedPath(repositoryRoot, relativePath) {
  const root = path.resolve(repositoryRoot);
  const relative = normalizeRelative(relativePath);
  const absolute = path.resolve(root, ...relative.split("/"));
  const fromRoot = path.relative(root, absolute);
  if (!fromRoot || fromRoot.startsWith("..") || path.isAbsolute(fromRoot)) {
    fail("layout_path_escapes_repository", relative);
  }
  return absolute;
}

export async function pathKind(repositoryRoot, relativePath) {
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

export async function readUtf8(repositoryRoot, relativePath) {
  try {
    return await readFile(containedPath(repositoryRoot, relativePath), "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      fail("layout_required_source_missing", relativePath);
    }
    throw error;
  }
}

export async function collectFiles(repositoryRoot, relativeDirectory) {
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
