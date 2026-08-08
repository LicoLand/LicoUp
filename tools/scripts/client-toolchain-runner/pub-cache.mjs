import {
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
} from "node:fs";
import path from "node:path";
import {
  clientPubCacheRoot,
  defaultSystemPubCacheRoot,
} from "../client-toolchain-env.mjs";
import { ROOT } from "./constants.mjs";

export function trimYamlScalar(value) {
  const trimmed = String(value || "").trim();
  if (
    (trimmed.startsWith("\"") && trimmed.endsWith("\"")) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

export function pubCacheHostForUrl(value) {
  const normalized = trimYamlScalar(value || "https://pub.dev");
  try {
    return new URL(normalized).host || "pub.dev";
  } catch {
    return normalized || "pub.dev";
  }
}

export function lockFilePath(projectRoot) {
  return path.join(projectRoot, "pubspec.lock");
}

export function parseLockedHostedPackages(lockPath) {
  if (!existsSync(lockPath)) {
    return [];
  }
  const packages = [];
  let current = null;
  const finishCurrent = () => {
    if (!current || current.source !== "hosted") {
      return;
    }
    if (!current.version) {
      throw new Error(`Hosted pub package has no locked version: ${current.name}`);
    }
    packages.push({
      name: current.descriptionName || current.name,
      version: current.version,
      url: current.url || "https://pub.dev",
      host: pubCacheHostForUrl(current.url)
    });
  };

  for (const line of readFileSync(lockPath, "utf8").split(/\r?\n/)) {
    const packageMatch = /^  ([A-Za-z0-9_]+):\s*$/.exec(line);
    if (packageMatch) {
      finishCurrent();
      current = {
        name: packageMatch[1],
        descriptionName: null,
        source: null,
        url: null,
        version: null
      };
      continue;
    }
    if (!current) {
      continue;
    }
    const sourceMatch = /^    source:\s+(.+?)\s*$/.exec(line);
    if (sourceMatch) {
      current.source = trimYamlScalar(sourceMatch[1]);
      continue;
    }
    const versionMatch = /^    version:\s+(.+?)\s*$/.exec(line);
    if (versionMatch) {
      current.version = trimYamlScalar(versionMatch[1]);
      continue;
    }
    const descriptionNameMatch = /^      name:\s+(.+?)\s*$/.exec(line);
    if (descriptionNameMatch) {
      current.descriptionName = trimYamlScalar(descriptionNameMatch[1]);
      continue;
    }
    const urlMatch = /^      url:\s+(.+?)\s*$/.exec(line);
    if (urlMatch) {
      current.url = trimYamlScalar(urlMatch[1]);
    }
  }
  finishCurrent();
  return packages;
}

export function preferredPubHostedUrl(projectRoot) {
  return process.env.LICO_CLIENT_PUB_HOSTED_URL ||
    parseLockedHostedPackages(lockFilePath(projectRoot))[0]?.url ||
    process.env.PUB_HOSTED_URL ||
    "https://pub.dev";
}

export function sourcePubCacheRoots(targetPubCache) {
  const roots = [
    process.env.PUB_CACHE ? path.resolve(process.env.PUB_CACHE) : null,
    defaultSystemPubCacheRoot()
  ].filter(Boolean);
  return [...new Set(roots)].filter((root) => path.resolve(root) !== path.resolve(targetPubCache));
}

export function hostedCacheDirs(pubCacheRoot) {
  const hostedRoot = path.join(pubCacheRoot, "hosted");
  if (!existsSync(hostedRoot)) {
    return [];
  }
  return statSync(hostedRoot).isDirectory()
    ? readDirectoryNames(hostedRoot)
    : [];
}

export function readDirectoryNames(root) {
  return Array.from(new Set(
    readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
  ));
}

export function candidateHostedCacheHosts(packageRef, sourcePubCache) {
  return [
    packageRef.host,
    process.env.PUB_HOSTED_URL ? pubCacheHostForUrl(process.env.PUB_HOSTED_URL) : null,
    "pub.dev",
    "pub.flutter-io.cn",
    ...hostedCacheDirs(sourcePubCache)
  ].filter(Boolean).filter((value, index, list) => list.indexOf(value) === index);
}

export function copyLockedPackageFromCache(sourcePubCache, targetPubCache, packageRef) {
  const packageDirName = `${packageRef.name}-${packageRef.version}`;
  const targetPackageDir = path.join(targetPubCache, "hosted", packageRef.host, packageDirName);
  if (existsSync(targetPackageDir)) {
    return "present";
  }

  for (const sourceHost of candidateHostedCacheHosts(packageRef, sourcePubCache)) {
    const sourcePackageDir = path.join(sourcePubCache, "hosted", sourceHost, packageDirName);
    if (!existsSync(sourcePackageDir)) {
      continue;
    }
    mkdirSync(path.dirname(targetPackageDir), { recursive: true });
    cpSync(sourcePackageDir, targetPackageDir, { recursive: true, dereference: false });
    const sourceHashFile = path.join(sourcePubCache, "hosted-hashes", sourceHost, `${packageDirName}.sha256`);
    if (existsSync(sourceHashFile)) {
      const targetHashFile = path.join(targetPubCache, "hosted-hashes", packageRef.host, `${packageDirName}.sha256`);
      mkdirSync(path.dirname(targetHashFile), { recursive: true });
      cpSync(sourceHashFile, targetHashFile);
    }
    return "copied";
  }
  return "missing";
}

export function seedStablePubCache(projectRoot, env) {
  const lockPath = lockFilePath(projectRoot);
  const packageRefs = parseLockedHostedPackages(lockPath);
  if (packageRefs.length === 0) {
    return;
  }
  const targetPubCache = env.PUB_CACHE;
  mkdirSync(targetPubCache, { recursive: true });
  let copied = 0;
  const missing = new Set();
  for (const packageRef of packageRefs) {
    let status = "missing";
    for (const sourceRoot of sourcePubCacheRoots(targetPubCache)) {
      status = copyLockedPackageFromCache(sourceRoot, targetPubCache, packageRef);
      if (status !== "missing") {
        break;
      }
    }
    if (status === "copied") {
      copied += 1;
    } else if (status === "missing") {
      missing.add(`${packageRef.name}-${packageRef.version}`);
    }
  }
  console.log(`[client-toolchain-runner] Flutter pub cache: ${path.relative(ROOT, targetPubCache) || targetPubCache}`);
  if (copied > 0) {
    console.log(`[client-toolchain-runner] Seeded ${copied} locked pub package(s) into the local cache.`);
  }
  if (missing.size > 0) {
    console.warn(
      `[client-toolchain-runner] ${missing.size} locked pub package(s) are not in existing caches; ` +
        "run npm run client:get once if offline analysis cannot resolve them."
    );
  }
}
