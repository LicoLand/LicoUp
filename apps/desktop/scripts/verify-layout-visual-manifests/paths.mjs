import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";

import { fail } from "./errors.mjs";

export function compareCanonical(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

export function normalizeRelative(value) {
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

export function containedPath(repositoryRoot, relativePath) {
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

export function canonicalJson(value) {
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

export function sha256(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

export function exactKeys(value, expectedKeys, code, relativePath = "") {
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

export async function readUtf8(repositoryRoot, relativePath) {
  try {
    return await readFile(containedPath(repositoryRoot, relativePath), "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      fail("layout_visual_required_source_missing", relativePath);
    }
    throw error;
  }
}
