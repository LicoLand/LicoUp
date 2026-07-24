import { readFileSync } from "node:fs";
import path from "node:path";

import {
  resolveContainedExistingPath,
  sha256Buffer,
  sha256File,
  stableReadFileSnapshot,
} from "../../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import {
  packageClientConfigPolicy,
  packageClientRuntime,
  packageClientSchemas,
  packageFailure,
} from "./cli-policy.mjs";

export function readPackageJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

export function loadPackagingConfig(configPath, options) {
  const snapshot = stableReadFileSnapshot(configPath, {
    maxBytes: 2 * 1024 * 1024,
  });
  const config = validatePackagingConfig(
    JSON.parse(snapshot.bytes.toString("utf8")),
  );
  options.packagingConfigDigest = sha256Buffer(snapshot.bytes);
  return config;
}

export function assertPackagingConfigDigestStable(options) {
  if (
    sha256File(packageClientRuntime.defaultConfigPath, {
      maxBytes: 2 * 1024 * 1024,
    }) !== options.packagingConfigDigest
  ) {
    packageFailure("release_packaging_config_changed_during_build");
  }
  return true;
}

export function validatePackagingConfig(
  config,
  { sourceRoot = packageClientRuntime.workspaceRoot } = {},
) {
  requireExactKeys(
    config,
    new Set([
      "schemaVersion",
      "description",
      "packageProfile",
      "bundle",
      "modules",
      "deferredCapabilities",
    ]),
    "packaging_config_schema_invalid",
  );
  if (
    config.schemaVersion !== packageClientSchemas.packagingModules ||
    config.packageProfile !== "licoup" ||
    typeof config.description !== "string" ||
    !config.description.trim()
  ) {
    packageFailure("packaging_config_schema_invalid");
  }
  requireExactKeys(
    config.bundle,
    new Set(["moduleResourceDirectory", "manifestPath"]),
    "packaging_bundle_schema_invalid",
  );
  if (
    config.bundle.moduleResourceDirectory !== "modules" ||
    config.bundle.manifestPath !==
      packageClientRuntime.canonicalBundleManifestRef
  ) {
    packageFailure("packaging_bundle_path_invalid");
  }
  const modules = requirePlainObject(
    config.modules,
    "packaging_modules_invalid",
  );
  const moduleIds = Object.keys(modules);
  if (
    moduleIds.length === 0 ||
    new Set(moduleIds).size !== moduleIds.length ||
    moduleIds.some(
      (id) => !packageClientConfigPolicy.moduleIdPattern.test(id),
    )
  ) {
    packageFailure("packaging_module_id_invalid");
  }
  const knownIds = new Set(moduleIds);
  const moduleKeys = new Set([
    "artifactName",
    "cargoBin",
    "category",
    "enabled",
    "includePaths",
    "label",
    "packaging",
    "platforms",
    "portableDirectories",
    "profile",
    "required",
    "requires",
    "runtimeToggle",
    "settingsKeys",
    "stateDirectories",
    "swiftSource",
    "targetAdapters",
  ]);
  for (const [id, moduleConfig] of Object.entries(modules)) {
    requireExactKeys(
      moduleConfig,
      moduleKeys,
      "packaging_module_schema_invalid",
    );
    if (
      typeof moduleConfig.label !== "string" ||
      !moduleConfig.label.trim() ||
      typeof moduleConfig.category !== "string" ||
      !moduleConfig.category.trim() ||
      !packageClientConfigPolicy.kinds.includes(moduleConfig.packaging) ||
      typeof moduleConfig.enabled !== "boolean" ||
      typeof moduleConfig.required !== "boolean"
    ) {
      packageFailure("packaging_module_schema_invalid");
    }
    validateStringList(
      moduleConfig.platforms,
      (entry) => packageClientConfigPolicy.platforms.includes(entry),
      "packaging_module_platform_invalid",
    );
    validateStringList(
      moduleConfig.requires || [],
      (entry) =>
        packageClientConfigPolicy.moduleIdPattern.test(entry) &&
        knownIds.has(entry),
      "packaging_module_dependency_invalid",
    );
    for (const field of ["portableDirectories", "stateDirectories"]) {
      validateStringList(
        moduleConfig[field] || [],
        (entry) => {
          try {
            safeConfigRelativePath(
              entry,
              "packaging_module_target_path_invalid",
            );
            return true;
          } catch {
            return false;
          }
        },
        "packaging_module_target_path_invalid",
      );
    }
    validateStringList(
      moduleConfig.targetAdapters || [],
      (entry) => packageClientConfigPolicy.moduleIdPattern.test(entry),
      "packaging_target_adapter_id_invalid",
    );
    validateStringList(
      moduleConfig.settingsKeys || [],
      (entry) =>
        /^[a-z][A-Za-z0-9-]*(?:\.[a-z][A-Za-z0-9-]*)+$/u.test(entry),
      "packaging_settings_key_invalid",
    );
    if (
      moduleConfig.runtimeToggle !== undefined &&
      typeof moduleConfig.runtimeToggle !== "boolean"
    ) {
      packageFailure("packaging_runtime_toggle_invalid");
    }
    if (
      moduleConfig.cargoBin !== undefined &&
      !packageClientConfigPolicy.moduleIdPattern.test(moduleConfig.cargoBin)
    ) {
      packageFailure("packaging_cargo_bin_invalid");
    }
    if (
      moduleConfig.artifactName !== undefined &&
      !packageClientConfigPolicy.artifactNamePattern.test(
        moduleConfig.artifactName,
      )
    ) {
      packageFailure("packaging_artifact_name_invalid");
    }
    validateSwiftSource(moduleConfig, sourceRoot);
    for (const includePath of moduleConfig.includePaths || []) {
      const includeRef = safeConfigRelativePath(
        includePath,
        "packaging_resource_source_invalid",
      );
      resolveContainedExistingPath(
        sourceRoot,
        path.join(sourceRoot, includeRef),
      );
    }
    if (
      moduleConfig.profile !== undefined &&
      (typeof moduleConfig.profile !== "string" ||
        !moduleConfig.profile.trim())
    ) {
      packageFailure("packaging_module_profile_invalid");
    }
    if (id === "native-sidecar" && moduleConfig.cargoBin !== "licoup") {
      packageFailure("packaging_native_sidecar_authority_invalid");
    }
  }
  validateDeferredCapabilities(config.deferredCapabilities);
  return config;
}

export function safeConfigRelativePath(value, code) {
  const ref = String(value || "");
  const components = ref.split("/");
  if (
    !ref ||
    ref !== ref.trim() ||
    path.isAbsolute(ref) ||
    ref.includes("\\") ||
    ref.includes("\0") ||
    path.posix.normalize(ref) !== ref ||
    components.some(
      (component) =>
        !component || component === "." || component === "..",
    )
  ) {
    packageFailure(code);
  }
  return ref;
}

function requirePlainObject(value, code) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    packageFailure(code);
  }
  return value;
}

function requireExactKeys(value, allowed, code) {
  requirePlainObject(value, code);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    packageFailure(code);
  }
}

function validateStringList(value, predicate, code) {
  if (
    !Array.isArray(value) ||
    new Set(value).size !== value.length ||
    value.some(
      (entry) => typeof entry !== "string" || !predicate(entry),
    )
  ) {
    packageFailure(code);
  }
}

function validateSwiftSource(moduleConfig, sourceRoot) {
  if (moduleConfig.swiftSource !== undefined) {
    const sourceRef = safeConfigRelativePath(
      moduleConfig.swiftSource,
      "packaging_swift_source_invalid",
    );
    if (
      !sourceRef.startsWith("apps/desktop/macos/") ||
      moduleConfig.packaging !== "swift-sidecar"
    ) {
      packageFailure("packaging_swift_source_invalid");
    }
    resolveContainedExistingPath(
      sourceRoot,
      path.join(sourceRoot, sourceRef),
      { expectedKind: "file" },
    );
  } else if (moduleConfig.packaging === "swift-sidecar") {
    packageFailure("packaging_swift_source_invalid");
  }
}

function validateDeferredCapabilities(capabilities) {
  requirePlainObject(capabilities, "packaging_deferred_schema_invalid");
  for (const [id, capability] of Object.entries(capabilities)) {
    if (!packageClientConfigPolicy.moduleIdPattern.test(id)) {
      packageFailure("packaging_deferred_id_invalid");
    }
    requireExactKeys(
      capability,
      new Set(["status", "reason"]),
      "packaging_deferred_schema_invalid",
    );
    if (
      capability.status !== "todo" ||
      typeof capability.reason !== "string" ||
      !capability.reason.trim()
    ) {
      packageFailure("packaging_deferred_schema_invalid");
    }
  }
}
