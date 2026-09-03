import { cpSync, mkdirSync, rmSync } from "node:fs";
import { randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";
import process from "node:process";

import {
  packageClientRuntime,
  packageFailure,
} from "./cli-policy.mjs";
import {
  ProjectTemporaryDirectoryLifecycleError,
  removeCurrentProjectTemporaryDirectory,
  retireInactiveProjectTemporaryDirectories,
} from "../../../../tools/scripts/lib/project-temporary-directory-lifecycle.mjs";

let buildRunId = "";
let buildRunPrepared = false;

export function cleanBuildBaseRoot(environment = process.env) {
  return path.resolve(
    environment.LICO_CLIENT_CLEAN_BUILD_ROOT || defaultCleanBuildRoot(),
  );
}

export function cleanBuildRoot() {
  buildRunId ||= `run-${process.pid}-${Date.now()}-${randomUUID()}`;
  const baseRoot = cleanBuildBaseRoot();
  if (!buildRunPrepared) {
    retireStaleCleanBuildRuns(baseRoot, buildRunId);
    buildRunPrepared = true;
  }
  return path.join(baseRoot, buildRunId);
}

export function stagedFlutterClientRoot() {
  return path.join(cleanBuildRoot(), "source", "apps", "desktop");
}

export function stagedPresentationContractRoot() {
  return path.join(cleanBuildRoot(), "source", "packages", "presentation_contract");
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
  const stagedPresentationContract = stagedPresentationContractRoot();
  const presentationContractSource = presentationContractSourceRoot();
  assertOutsideWorkspace(stagedRoot, "clean_source_inside_workspace");
  assertOutsideWorkspace(
    stagedPresentationContract,
    "clean_source_inside_workspace",
  );
  rmSync(stagedRoot, { recursive: true, force: true });
  rmSync(stagedPresentationContract, { recursive: true, force: true });
  mkdirSync(path.dirname(stagedRoot), { recursive: true });
  mkdirSync(path.dirname(stagedPresentationContract), { recursive: true });
  copyTree(packageClientRuntime.flutterClientRoot, stagedRoot, {
    filter: (sourcePath) =>
      !isExcludedDartSourcePath(
        sourcePath,
        packageClientRuntime.flutterClientRoot,
      ),
  });
  copyTree(
    presentationContractSource,
    stagedPresentationContract,
    {
      filter: (sourcePath) =>
        !isExcludedDartSourcePath(sourcePath, presentationContractSource),
    },
  );
  return stagedRoot;
}

export function cleanupFlutterBuildCache(flutterBuildAttempted) {
  if (!flutterBuildAttempted) return;
  const currentRoot = cleanBuildRoot();
  try {
    removeCurrentProjectTemporaryDirectory({
      root: path.dirname(currentRoot),
      name: path.basename(currentRoot),
      parseOwnerPid: parseCleanBuildRunOwnerPid,
    });
  } catch (error) {
    temporaryCleanupFailure(error, "flutter-clean-build-finalize");
  }
}

export function retireStaleCleanBuildRuns(
  baseRoot,
  currentName,
  operations = {},
) {
  try {
    return retireInactiveProjectTemporaryDirectories({
      root: baseRoot,
      parseOwnerPid: parseCleanBuildRunOwnerPid,
      currentNames: [currentName],
      ...operations,
    });
  } catch (error) {
    temporaryCleanupFailure(error, "flutter-clean-build-retire");
  }
}

export function parseCleanBuildRunOwnerPid(name) {
  const match = /^run-([1-9]\d*)-([1-9]\d*)-([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/u
    .exec(name);
  if (!match) return null;
  const pid = Number(match[1]);
  return Number.isSafeInteger(pid) ? pid : null;
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

function temporaryCleanupFailure(error, stage) {
  if (error instanceof ProjectTemporaryDirectoryLifecycleError) {
    packageFailure("packaging_temporary_cleanup_failed", {
      stage,
      reason: error.reason,
    });
  }
  throw error;
}

function presentationContractSourceRoot() {
  return path.join(
    packageClientRuntime.workspaceRoot,
    "packages",
    "presentation_contract",
  );
}

function isExcludedDartSourcePath(sourcePath, sourceRoot) {
  const relativePath = path.relative(
    sourceRoot,
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
