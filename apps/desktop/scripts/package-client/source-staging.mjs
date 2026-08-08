import { cpSync, mkdirSync, rmSync } from "node:fs";
import { randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";
import process from "node:process";

import {
  packageClientRuntime,
  packageFailure,
} from "./cli-policy.mjs";

let buildRunId = "";

export function cleanBuildBaseRoot(environment = process.env) {
  return path.resolve(
    environment.LICO_CLIENT_CLEAN_BUILD_ROOT || defaultCleanBuildRoot(),
  );
}

export function cleanBuildRoot() {
  buildRunId ||= `run-${process.pid}-${Date.now()}-${randomUUID()}`;
  return path.join(cleanBuildBaseRoot(), buildRunId);
}

export function stagedFlutterClientRoot() {
  return path.join(cleanBuildRoot(), "source", "apps", "desktop");
}

export function stagedPubCacheRoot() {
  return path.join(cleanBuildRoot(), "pub-cache");
}

export function buildSymbolsRoot(options) {
  return path.join(
    packageClientRuntime.clientBuildRoot,
    "symbols",
    options.platform,
    options.mode,
  );
}

export function assertOutsideWorkspace(targetPath, code) {
  const relativePath = path.relative(
    packageClientRuntime.workspaceRoot,
    targetPath,
  );
  if (
    !relativePath ||
    (!relativePath.startsWith("..") && !path.isAbsolute(relativePath))
  ) {
    packageFailure(code);
  }
}

export function copyTree(source, target, options = {}) {
  cpSync(source, target, {
    recursive: true,
    dereference: false,
    verbatimSymlinks: true,
    ...options,
  });
}

export function prepareStagedFlutterSource() {
  const stagedRoot = stagedFlutterClientRoot();
  assertOutsideWorkspace(stagedRoot, "clean_source_inside_workspace");
  rmSync(stagedRoot, { recursive: true, force: true });
  mkdirSync(path.dirname(stagedRoot), { recursive: true });
  copyTree(packageClientRuntime.flutterClientRoot, stagedRoot, {
    filter: (sourcePath) => !isExcludedFlutterSourcePath(sourcePath),
  });
  return stagedRoot;
}

export function cleanupFlutterBuildCache(options, flutterBuildAttempted) {
  if (!flutterBuildAttempted || options.keepFlutterBuildCache) return;
  rmSync(cleanBuildRoot(), { recursive: true, force: true });
}

export function isInsideDirectory(root, candidate) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return (
    Boolean(relative) &&
    !relative.startsWith("..") &&
    !path.isAbsolute(relative)
  );
}

export function isMacosBuildArtifactCandidate(candidate) {
  return [
    packageClientRuntime.workspaceRoot,
    cleanBuildBaseRoot(),
  ].some((root) => isInsideDirectory(root, candidate));
}

function defaultCleanBuildRoot() {
  if (process.platform === "darwin") {
    return path.join(path.sep, "private", "tmp", "licoup-build");
  }
  if (process.platform === "win32") {
    return path.join(os.tmpdir(), "licoup-build");
  }
  return path.join(path.sep, "tmp", "licoup-build");
}

function isExcludedFlutterSourcePath(sourcePath) {
  const relativePath = path.relative(
    packageClientRuntime.flutterClientRoot,
    sourcePath,
  );
  if (
    !relativePath ||
    relativePath.startsWith("..") ||
    path.isAbsolute(relativePath)
  ) {
    return false;
  }
  const parts = relativePath.split(path.sep);
  const normalized = parts.join("/");
  if (
    [
      ".dart_tool",
      ".idea",
      "build",
      ".flutter-plugins",
      ".flutter-plugins-dependencies",
    ].includes(parts[0])
  ) {
    return true;
  }
  return [
    "macos/Flutter/ephemeral",
    "macos/Pods",
    "macos/Podfile.lock",
    "linux/flutter/ephemeral",
    "windows/flutter/ephemeral",
    "android/.gradle",
    "android/build",
  ].some(
    (prefix) =>
      normalized === prefix || normalized.startsWith(`${prefix}/`),
  );
}
