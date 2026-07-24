import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export const packageClientRuntime = Object.freeze((() => {
  const workspaceRoot = path.resolve(
    fileURLToPath(new URL("../../../..", import.meta.url)),
  );
  const flutterClientRoot = path.join(workspaceRoot, "apps", "desktop");
  return {
    workspaceRoot,
    flutterClientRoot,
    clientBuildRoot: path.join(workspaceRoot, "build", "apps", "desktop"),
    nativeTargetRoot: path.join(
      workspaceRoot,
      "build",
      "crates",
      "licoup-native",
      "target",
    ),
    defaultConfigPath: path.join(flutterClientRoot, "packaging.modules.json"),
    canonicalPackagingConfigRef: "apps/desktop/packaging.modules.json",
    canonicalBundleManifestRef:
      "package-metadata/licoup/packaging-modules.json",
    windowsX64TargetId: "windows-x64",
    windowsX64RustTarget: "x86_64-pc-windows-msvc",
    bundleId: "land.lico.licoup",
    appName: "Arc.app",
  };
})());

export const packageClientSchemas = Object.freeze({
  packagingModules: "v0.0.1:client-desktop:packaging-modules-1",
  bundleManifest: "v0.0.1:client-desktop:bundle-manifest-2",
  windowsPlatformManifest:
    "v0.0.1:client-desktop:windows-platform-manifest-1",
});

export const packageClientConfigPolicy = Object.freeze({
  moduleIdPattern: /^[a-z0-9]+(?:-[a-z0-9]+)*$/u,
  artifactNamePattern: /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u,
  sourceDigestPattern: /^sha256:[a-f0-9]{64}$/u,
  platforms: Object.freeze(["macos", "linux", "windows"]),
  kinds: Object.freeze([
    "flutter-app",
    "module-resources",
    "portable-data",
    "runtime-capability",
    "sidecar-binary",
    "swift-sidecar",
  ]),
});

export class PackageClientError extends Error {
  constructor(code, details = null) {
    super(code);
    this.code = code;
    this.details = details;
  }
}

export function packageFailure(code, details = null) {
  throw new PackageClientError(code, details);
}

export function publicPackageFailure(error) {
  if (!(error instanceof PackageClientError)) {
    return Object.freeze({
      ok: false,
      error: "package_client_failed",
      privatePathsIncluded: false,
    });
  }
  return Object.freeze({
    ok: false,
    error: error.code,
    ...(error.details || {}),
    privatePathsIncluded: false,
  });
}

export function parsePackageClientArgs(
  argv = process.argv.slice(2),
  environment = process.env,
) {
  const options = {
    platform: normalizePlatform(process.platform),
    mode: "release",
    configPath: packageClientRuntime.defaultConfigPath,
    enabledOverrides: [],
    disabledOverrides: [],
    profile: null,
    skipFlutterBuild: false,
    skipNativeBuild: false,
    keepFlutterBuildCache: environment.LICO_KEEP_FLUTTER_BUILD_CACHE === "1",
    install: false,
    installDir: "",
    dryRun: false,
    productionEntitlements: false,
    targetId: "",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--platform" && next) {
      options.platform = normalizePlatform(next);
      index += 1;
    } else if (arg === "--mode" && next) {
      options.mode = normalizeMode(next);
      index += 1;
    } else if (arg === "--config" && next) {
      options.configPath = path.resolve(next);
      index += 1;
    } else if ((arg === "--with" || arg === "--modules") && next) {
      options.enabledOverrides.push(...splitList(next));
      index += 1;
    } else if (arg === "--without" && next) {
      options.disabledOverrides.push(...splitList(next));
      index += 1;
    } else if (arg === "--profile" && next) {
      options.profile = normalizeProfile(next);
      index += 1;
    } else if (arg === "--skip-flutter-build") {
      options.skipFlutterBuild = true;
    } else if (arg === "--skip-native-build") {
      options.skipNativeBuild = true;
    } else if (arg === "--keep-flutter-build-cache") {
      options.keepFlutterBuildCache = true;
    } else if (arg === "--install") {
      options.install = true;
    } else if (arg === "--install-dir" && next) {
      options.installDir = path.resolve(next);
      index += 1;
    } else if (arg === "--production-entitlements") {
      if (next && !next.startsWith("--")) {
        options.productionEntitlements = normalizeBooleanOption(next);
        index += 1;
      } else {
        options.productionEntitlements = true;
      }
    } else if (arg === "--target" && next) {
      options.targetId = String(next).trim();
      index += 1;
    } else if (arg === "--dry-run") {
      options.dryRun = true;
      options.skipFlutterBuild = true;
      options.skipNativeBuild = true;
    } else {
      packageFailure("packaging_option_unknown");
    }
  }
  return validatePackagingOptions(options, environment);
}

export function validateReleaseBuildPolicy(options) {
  if (
    options.mode === "release" &&
    options.dryRun !== true &&
    (options.skipFlutterBuild === true || options.skipNativeBuild === true)
  ) {
    packageFailure("release_build_skip_not_permitted");
  }
  if (
    options.mode === "release" &&
    path.resolve(options.configPath || packageClientRuntime.defaultConfigPath) !==
      packageClientRuntime.defaultConfigPath
  ) {
    packageFailure("release_packaging_config_not_canonical");
  }
  if (
    options.mode === "release" &&
    ((options.enabledOverrides || []).length > 0 ||
      (options.disabledOverrides || []).length > 0 ||
      options.profile !== null)
  ) {
    packageFailure("release_packaging_override_not_permitted");
  }
  return true;
}

export function validatePackagingOptions(options, environment = process.env) {
  if (options.platform === "windows") {
    options.targetId ||= String(
      environment.LICO_WINDOWS_TARGET || packageClientRuntime.windowsX64TargetId,
    ).trim();
    if (options.targetId === "windows-arm64") {
      packageFailure("windows_arm64_flutter_upstream_unavailable");
    }
    if (options.targetId !== packageClientRuntime.windowsX64TargetId) {
      packageFailure("windows_target_unsupported");
    }
  } else if (options.targetId) {
    packageFailure("packaging_target_not_supported_for_platform");
  }
  validateReleaseBuildPolicy(options);
  if (options.productionEntitlements && options.platform !== "macos") {
    packageFailure("production_entitlements_platform_unsupported");
  }
  if (options.productionEntitlements && options.mode !== "release") {
    packageFailure("production_entitlements_require_release");
  }
  return options;
}

export function normalizePlatform(value) {
  const normalized = String(value || "").toLowerCase();
  if (normalized === "darwin") return "macos";
  if (normalized === "win32") return "windows";
  if (packageClientConfigPolicy.platforms.includes(normalized)) {
    return normalized;
  }
  packageFailure("packaging_platform_unsupported");
}

export function normalizeMode(value) {
  const normalized = String(value || "").toLowerCase();
  if (["debug", "profile", "release"].includes(normalized)) {
    return normalized;
  }
  packageFailure("packaging_mode_unsupported");
}

export function modeDirectoryName(mode) {
  return mode.charAt(0).toUpperCase() + mode.slice(1);
}

export function publicWorkspacePath(filePath, fallback = "<external-config>") {
  const relative = path.relative(
    packageClientRuntime.workspaceRoot,
    path.resolve(filePath),
  );
  if (!relative || relative === ".") return ".";
  if (relative.startsWith("..") || path.isAbsolute(relative)) return fallback;
  return relative.split(path.sep).join("/");
}

export function runtimeDataPolicyRecord(platform = "generic") {
  return Object.freeze({
    defaultLocation:
      platform === "windows"
        ? "system-appdata"
        : platform === "linux"
          ? "system-xdg-data"
          : "system-application-support",
    directoryName: "portable-data",
    environmentOverride: "LICOUP_PORTABLE_DIR",
    packagedMacAppIgnoresEnvironmentOverride: true,
  });
}

export function runtimeDataDescription(platform) {
  if (platform === "windows") {
    return "Runtime data: system AppData portable-data directory";
  }
  if (platform === "linux") {
    return "Runtime data: system XDG data portable-data directory";
  }
  return "Runtime data: system Application Support portable-data directory";
}

function normalizeBooleanOption(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  packageFailure("packaging_boolean_option_invalid");
}

function normalizeProfile(value) {
  const normalized = String(value || "").trim();
  if (normalized === "licoup") return normalized;
  packageFailure("packaging_profile_unsupported");
}

function splitList(value) {
  return String(value || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}
