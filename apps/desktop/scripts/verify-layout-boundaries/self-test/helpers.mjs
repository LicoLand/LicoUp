import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  DEFAULT_LAYOUT_BOUNDARY_CONFIG,
  LayoutBoundaryError,
} from "../../verify-layout-boundaries.mjs";

export function assert(condition, code) {
  if (!condition) {
    throw new Error(code);
  }
}

export function title(value) {
  return `${value[0].toUpperCase()}${value.slice(1)}`;
}

export function bundleSymbol(profile, surface) {
  return `${profile}${title(surface)}Bundle`;
}

export function bundlePath(profile, surface) {
  return `${DEFAULT_LAYOUT_BOUNDARY_CONFIG.profileSourceRoot}/${profile}/${surface}/${profile}_${surface}_bundle.dart`;
}

export async function writeRelative(rootDir, relativePath, source) {
  const absolutePath = path.join(rootDir, ...relativePath.split("/"));
  await mkdir(path.dirname(absolutePath), { recursive: true });
  await writeFile(absolutePath, source);
}

export async function appendRelative(rootDir, relativePath, source) {
  const absolutePath = path.join(rootDir, ...relativePath.split("/"));
  const current = await readFile(absolutePath, "utf8");
  await writeFile(absolutePath, `${current}${source}`, "utf8");
}

export async function resetFixture(rootDir) {
  await rm(rootDir, { recursive: true, force: true });
  await mkdir(rootDir, { recursive: true });
}

export async function expectViolation(code, operation) {
  try {
    await operation();
  } catch (error) {
    if (error instanceof LayoutBoundaryError && error.code === code) {
      return;
    }
    throw error;
  }
  throw new Error(`layout_boundary_self_test_missing_${code}`);
}
