import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import path from "node:path";
import {
  artifactTreeSnapshot,
  CLIENT_RELEASE_ARTIFACT_TREE_LIMITS,
  sha256Buffer,
  stableReadFile,
} from "./client-release-artifact-digest.mjs";

export const MACOS_CODE_INSPECTION_LIMITS = Object.freeze({
  artifactTree: CLIENT_RELEASE_ARTIFACT_TREE_LIMITS,
  maxNestedCodePaths: 4096,
  maxDurationMs: 120_000,
});

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function run(command, args, options = {}) {
  const { deadlineMs, ...spawnOptions } = options;
  const remainingMs = deadlineMs === undefined
    ? 30_000
    : Math.min(30_000, Math.floor(Number(deadlineMs) - Date.now()));
  requireValue(Number.isFinite(remainingMs) && remainingMs > 0,
    "macOS code signature inspection deadline exceeded");
  return spawnSync(command, args, {
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 16 * 1024 * 1024,
    timeout: remainingMs,
    ...spawnOptions,
  });
}

function plistToCanonicalJson(plistBytes, { deadlineMs } = {}) {
  const converted = run("/usr/bin/plutil", ["-convert", "json", "-o", "-", "--", "-"], {
    input: plistBytes,
    deadlineMs,
  });
  requireValue(converted.status === 0, "macOS entitlements plist could not be normalized");
  const decoded = JSON.parse(String(converted.stdout || ""));
  return canonicalJson(decoded);
}

export function normalizedMacosEntitlementsFile(entitlementsPath, options = {}) {
  return plistToCanonicalJson(stableReadFile(entitlementsPath, {
    maxBytes: 1024 * 1024,
  }), options);
}

export function inspectMacosCodeSignature(
  appPath,
  expectedEntitlementsPath,
  { deadlineMs } = {},
) {
  const verification = run(
    "/usr/bin/codesign",
    ["--verify", "--deep", "--strict", appPath],
    { deadlineMs },
  );
  const details = run(
    "/usr/bin/codesign",
    ["-dv", "--verbose=4", appPath],
    { deadlineMs },
  );
  const entitlementResult = run(
    "/usr/bin/codesign",
    ["-d", "--entitlements", ":-", appPath],
    { deadlineMs },
  );
  const detailText = `${String(details.stdout || "")}\n${String(details.stderr || "")}`;
  const signatureKind = detailText.includes("Signature=adhoc")
    ? "local-ad-hoc-codesign"
    : /(?:^|\n)Authority=/u.test(detailText)
      ? "local-identity-codesign"
      : "unknown";
  const hardenedRuntime = /(?:^|\n)flags=0x[0-9a-f]+\([^\n)]*runtime[^\n)]*\)/iu.test(
    detailText,
  );
  let actualEntitlements = "";
  let expectedEntitlements = "";
  try {
    actualEntitlements = plistToCanonicalJson(
      Buffer.from(entitlementResult.stdout || "", "utf8"),
      { deadlineMs },
    );
    expectedEntitlements = expectedEntitlementsPath
      ? normalizedMacosEntitlementsFile(expectedEntitlementsPath, { deadlineMs })
      : "";
  } catch {
    actualEntitlements = "";
    expectedEntitlements = "";
  }
  const entitlementsMatch = Boolean(expectedEntitlementsPath) &&
    actualEntitlements !== "" &&
    actualEntitlements === expectedEntitlements;
  const entitlementsReadable = entitlementResult.status === 0;
  const entitlementsEmpty = entitlementsReadable &&
    (actualEntitlements === "" || actualEntitlements === "{}");
  return Object.freeze({
    verified: verification.status === 0 && details.status === 0 &&
      entitlementsReadable,
    signatureKind,
    hardenedRuntime,
    entitlementsMatch,
    entitlementsEmpty,
    entitlementsDigest: entitlementsMatch
      ? sha256Buffer(Buffer.from(expectedEntitlements, "utf8"))
      : "",
  });
}

export function listMacosNestedCodePaths(appPath, mainExecutableName, {
  snapshot,
  limits = MACOS_CODE_INSPECTION_LIMITS.artifactTree,
  deadlineMs = Date.now() + MACOS_CODE_INSPECTION_LIMITS.maxDurationMs,
} = {}) {
  const candidates = [];
  const signableBundleSuffixes = [
    ".app",
    ".appex",
    ".bundle",
    ".framework",
    ".plugin",
    ".xpc",
  ];
  requireValue(Date.now() <= deadlineMs,
    "macOS code signature inspection deadline exceeded");
  const tree = snapshot || artifactTreeSnapshot(appPath, { limits, deadlineMs });
  const root = realpathSync(appPath);
  requireValue(tree?.root === root && Array.isArray(tree?.entries),
    "macOS code inventory does not match its app bundle");
  for (const entry of tree.entries) {
    if (entry.kind === "symlink" || !entry.path.startsWith("Contents/")) continue;
    const name = path.posix.basename(entry.path);
    if (entry.kind === "directory") {
      if (signableBundleSuffixes.some((suffix) => name.endsWith(suffix))) {
        candidates.push(path.join(root, ...entry.path.split("/")));
      }
      continue;
    }
    if (entry.kind !== "file") continue;
    const isMainExecutable = path.posix.dirname(entry.path) === "Contents/MacOS" &&
      name === mainExecutableName;
    const isNestedExecutable = !isMainExecutable &&
      (Number.parseInt(entry.mode, 8) & 0o111) !== 0;
    const isDynamicLibrary = name.endsWith(".dylib");
    if (isNestedExecutable || isDynamicLibrary) {
      candidates.push(path.join(root, ...entry.path.split("/")));
    }
  }
  return [...new Set(candidates)].sort((left, right) =>
    right.split(path.sep).length - left.split(path.sep).length || left.localeCompare(right));
}

export function inspectBoundedMacosCodePolicy(
  appPath,
  mainExecutableName,
  expectedEntitlementsPath,
  {
    limits = MACOS_CODE_INSPECTION_LIMITS.artifactTree,
    maxNestedCodePaths = MACOS_CODE_INSPECTION_LIMITS.maxNestedCodePaths,
    deadlineMs = Date.now() + MACOS_CODE_INSPECTION_LIMITS.maxDurationMs,
    inspectSignature = inspectMacosCodeSignature,
  } = {},
) {
  requireValue(Number.isSafeInteger(maxNestedCodePaths) && maxNestedCodePaths > 0,
    "macOS nested code path limit is invalid");
  const before = artifactTreeSnapshot(appPath, { limits, deadlineMs });
  const nestedCodePaths = listMacosNestedCodePaths(appPath, mainExecutableName, {
    snapshot: before,
    limits,
    deadlineMs,
  });
  requireValue(nestedCodePaths.length <= maxNestedCodePaths,
    "macOS app bundle exceeds its nested code path bound");
  requireValue(Date.now() <= deadlineMs,
    "macOS code signature inspection deadline exceeded");
  const signature = inspectSignature(appPath, expectedEntitlementsPath, { deadlineMs });
  const nestedSignatures = nestedCodePaths.map((nestedPath) => {
    requireValue(Date.now() <= deadlineMs,
      "macOS code signature inspection deadline exceeded");
    return {
      path: nestedPath,
      signature: inspectSignature(nestedPath, undefined, { deadlineMs }),
    };
  });
  const after = artifactTreeSnapshot(appPath, { limits, deadlineMs });
  requireValue(before.digest === after.digest,
    "macOS app bundle changed during code signature inspection");
  return Object.freeze({
    artifactDigest: before.digest,
    signature,
    nestedCodePaths: Object.freeze([...nestedCodePaths]),
    nestedSignatures: Object.freeze(nestedSignatures.map((entry) => Object.freeze(entry))),
    treeMetrics: before.metrics,
    deadlineMs,
  });
}
