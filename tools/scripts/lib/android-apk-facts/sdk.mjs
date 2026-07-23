import { existsSync, readdirSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import {
  resolveContainedExistingPath,
  stableHashFileSnapshot,
  stableReadFile,
} from "../client-release-artifact-digest.mjs";
import { minimalReleaseToolEnvironment } from "../release-tool-environment.mjs";
import { MAX_ANDROID_TOOL_BYTES } from "./limits.mjs";
import { requireValue } from "./require.mjs";

export function androidSdkRoot(repoRoot) {
  const configured = String(process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT || "").trim();
  if (configured) return configured;
  const propertiesPath = path.join(repoRoot, "apps/desktop/android/local.properties");
  if (!existsSync(propertiesPath)) return "";
  const sdkLine = stableReadFile(propertiesPath, { maxBytes: 1024 * 1024 })
    .toString("utf8")
    .split(/\r?\n/u)
    .find((line) => line.startsWith("sdk.dir="));
  return String(sdkLine || "")
    .slice("sdk.dir=".length)
    .trim()
    .replaceAll("\\\\", "\\")
    .replaceAll("\\:", ":");
}


export function findBuildTool(repoRoot, name) {
  const sdkRoot = androidSdkRoot(repoRoot);
  const buildToolsRoot = sdkRoot ? path.join(sdkRoot, "build-tools") : "";
  requireValue(buildToolsRoot && existsSync(buildToolsRoot),
    "Android SDK build tools are unavailable");
  const suffix = process.platform === "win32" ? ".bat" : "";
  const versions = readdirSync(buildToolsRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort((left, right) => right.localeCompare(left, undefined, { numeric: true }));
  const tool = versions
    .map((version) => path.join(buildToolsRoot, version, `${name}${suffix}`))
    .find((candidate) => existsSync(candidate));
  requireValue(tool, `Android SDK ${name} is unavailable`);
  return resolveContainedExistingPath(buildToolsRoot, tool, { expectedKind: "file" });
}


export function resolveAndroidAdbTool(repoRoot) {
  const sdkRoot = androidSdkRoot(repoRoot);
  requireValue(sdkRoot, "Android SDK platform tools are unavailable");
  const adbName = process.platform === "win32" ? "adb.exe" : "adb";
  return resolveContainedExistingPath(
    sdkRoot,
    path.join(sdkRoot, "platform-tools", adbName),
    { expectedKind: "file" },
  );
}


export function androidJavaEnvironment(requireApprovedToolchain = false) {
  const approvedDarwinJavaHome =
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home";
  const candidates = (requireApprovedToolchain && process.platform === "darwin"
    ? [approvedDarwinJavaHome]
    : [
        process.env.JAVA_HOME,
        process.env.LICO_ANDROID_JAVA_HOME,
        process.platform === "darwin" ? approvedDarwinJavaHome : "",
      ])
    .map((value) => String(value || "").trim()).filter(Boolean);
  const javaHome = candidates.find((candidate) => {
    const javaPath = path.join(
      candidate,
      "bin",
      process.platform === "win32" ? "java.exe" : "java",
    );
    return existsSync(javaPath);
  });
  requireValue(javaHome, "Android APK verification Java runtime is unavailable");
  const javaPath = resolveContainedExistingPath(
    javaHome,
    path.join(javaHome, "bin", process.platform === "win32" ? "java.exe" : "java"),
    { expectedKind: "file" },
  );
  const systemPath = process.platform === "win32"
    ? process.env.PATH || ""
    : "/usr/bin:/bin";
  return {
    javaPath,
    env: minimalReleaseToolEnvironment(process.env, {
      JAVA_HOME: javaHome,
      PATH: `${path.dirname(javaPath)}${path.delimiter}${systemPath}`,
    }),
  };
}


export function approvedAndroidToolchain(repoRoot, toolchain) {
  const manifestPath = resolveContainedExistingPath(
    path.join(repoRoot, "tools"),
    path.join(repoRoot, "tools/android-release-toolchain.json"),
    { expectedKind: "file" },
  );
  const manifest = JSON.parse(stableReadFile(manifestPath, {
    maxBytes: 1024 * 1024,
  }).toString("utf8"));
  const hostId = `${process.platform}-${process.arch}`;
  const approval = manifest?.schemaVersion ===
      "licomesh.android-release-toolchain-allowlist.v1"
    ? manifest.platforms?.[hostId]
    : null;
  requireValue(approval &&
    approval.buildToolsVersion === path.basename(path.dirname(toolchain.aapt2)),
  "Android release toolchain is not approved for this host");
  const expectedNames = [
    "adb",
    "aapt2",
    "apksigner",
    "apksignerJar",
    "zipalign",
    "java",
  ];
  requireValue(JSON.stringify(Object.keys(approval.digests || {}).sort()) ===
    JSON.stringify([...expectedNames].sort()),
  "Android release toolchain digest allowlist is incomplete");
  for (const name of expectedNames) {
    const expected = String(approval.digests[name] || "");
    requireValue(/^sha256:[a-f0-9]{64}$/u.test(expected) &&
      stableHashFileSnapshot(toolchain[name], {
        maxBytes: MAX_ANDROID_TOOL_BYTES,
      }).digest === expected,
    "Android release toolchain digest is not approved");
  }
  return true;
}


export function resolveAndroidToolchain(repoRoot, requireApprovedToolchain) {
  const aapt2 = findBuildTool(repoRoot, "aapt2");
  const apksigner = findBuildTool(repoRoot, "apksigner");
  const zipalign = findBuildTool(repoRoot, "zipalign");
  const java = androidJavaEnvironment(requireApprovedToolchain);
  const buildToolsDirectory = path.dirname(apksigner);
  const toolchain = {
    adb: resolveAndroidAdbTool(repoRoot),
    aapt2,
    apksigner,
    apksignerJar: resolveContainedExistingPath(
      buildToolsDirectory,
      path.join(buildToolsDirectory, "lib/apksigner.jar"),
      { expectedKind: "file" },
    ),
    zipalign,
    java: java.javaPath,
    env: java.env,
  };
  if (requireApprovedToolchain) approvedAndroidToolchain(repoRoot, toolchain);
  return toolchain;
}



export function findAndroidAdbTool(repoRoot, { requireApprovedToolchain = false } = {}) {
  return resolveAndroidToolchain(repoRoot, requireApprovedToolchain).adb;
}

export function run(tool, args, repoRoot, env) {
  const result = spawnSync(tool, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 32 * 1024 * 1024,
    timeout: 30_000,
    env,
  });
  requireValue(result.status === 0, "Android APK fact extraction failed");
  return `${String(result.stdout || "")}\n${String(result.stderr || "")}`;
}
