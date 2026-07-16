import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
} from "node:fs";
import path from "node:path";

import { clientPubCacheRoot } from "../../../../tools/scripts/client-toolchain-env.mjs";
import {
  packageClientRuntime,
  packageFailure,
} from "./cli-policy.mjs";
import {
  assertOutsideWorkspace,
  copyTree,
  stagedPubCacheRoot,
} from "./source-staging.mjs";

export function prepareStagedPubCache() {
  const stagedPubCache = stagedPubCacheRoot();
  const sourcePubCache = clientPubCacheRoot();
  assertOutsideWorkspace(stagedPubCache, "clean_pub_cache_inside_workspace");
  if (path.resolve(sourcePubCache) === path.resolve(stagedPubCache)) {
    mkdirSync(stagedPubCache, { recursive: true });
    return stagedPubCache;
  }
  rmSync(stagedPubCache, { recursive: true, force: true });
  mkdirSync(stagedPubCache, { recursive: true });
  if (!existsSync(sourcePubCache)) {
    packageFailure("local_pub_cache_missing");
  }
  const lockFile = path.join(
    packageClientRuntime.flutterClientRoot,
    "pubspec.lock",
  );
  for (const packageRef of lockedHostedPackages(lockFile)) {
    copyLockedHostedPackage(sourcePubCache, stagedPubCache, packageRef);
  }
  return stagedPubCache;
}

export function lockedHostedPackages(lockFilePath) {
  const packages = [];
  let current = null;
  const finishCurrent = () => {
    if (!current || current.source !== "hosted") return;
    if (!current.version) packageFailure("locked_pub_package_version_missing");
    packages.push({
      name: current.descriptionName || current.name,
      version: current.version,
      host: pubCacheHostForUrl(current.url),
    });
  };

  for (const line of readFileSync(lockFilePath, "utf8").split(/\r?\n/u)) {
    const packageMatch = /^  ([A-Za-z0-9_]+):\s*$/u.exec(line);
    if (packageMatch) {
      finishCurrent();
      current = {
        name: packageMatch[1],
        descriptionName: null,
        source: null,
        url: null,
        version: null,
      };
      continue;
    }
    if (!current) continue;
    const sourceMatch = /^    source:\s+(.+?)\s*$/u.exec(line);
    const versionMatch = /^    version:\s+(.+?)\s*$/u.exec(line);
    const nameMatch = /^      name:\s+(.+?)\s*$/u.exec(line);
    const urlMatch = /^      url:\s+(.+?)\s*$/u.exec(line);
    if (sourceMatch) current.source = trimYamlScalar(sourceMatch[1]);
    else if (versionMatch) current.version = trimYamlScalar(versionMatch[1]);
    else if (nameMatch) current.descriptionName = trimYamlScalar(nameMatch[1]);
    else if (urlMatch) current.url = trimYamlScalar(urlMatch[1]);
  }
  finishCurrent();
  return packages;
}

function copyLockedHostedPackage(sourceCache, stagedCache, packageRef) {
  const packageDirName = `${packageRef.name}-${packageRef.version}`;
  const sourcePackageDir = path.join(
    sourceCache,
    "hosted",
    packageRef.host,
    packageDirName,
  );
  if (!existsSync(sourcePackageDir)) {
    packageFailure("locked_pub_package_missing");
  }
  const stagedPackageDir = path.join(
    stagedCache,
    "hosted",
    packageRef.host,
    packageDirName,
  );
  mkdirSync(path.dirname(stagedPackageDir), { recursive: true });
  copyTree(sourcePackageDir, stagedPackageDir);

  const hashRef = `${packageDirName}.sha256`;
  const sourceHashFile = path.join(
    sourceCache,
    "hosted-hashes",
    packageRef.host,
    hashRef,
  );
  if (!existsSync(sourceHashFile)) return;
  const stagedHashFile = path.join(
    stagedCache,
    "hosted-hashes",
    packageRef.host,
    hashRef,
  );
  mkdirSync(path.dirname(stagedHashFile), { recursive: true });
  copyFileSync(sourceHashFile, stagedHashFile);
}

function trimYamlScalar(value) {
  const trimmed = String(value || "").trim();
  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function pubCacheHostForUrl(value) {
  const normalized = trimYamlScalar(value || "https://pub.dev");
  try {
    return new URL(normalized).host || "pub.dev";
  } catch {
    return normalized || "pub.dev";
  }
}
