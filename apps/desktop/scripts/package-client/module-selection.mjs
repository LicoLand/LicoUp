import { packageFailure } from "./cli-policy.mjs";

export function selectPackagingModules(config, options) {
  const activeProfile =
    options.profile || config.packageProfile || "licoup";
  if (activeProfile !== "licoup") {
    packageFailure("packaging_profile_unsupported");
  }
  const modules = Object.entries(config.modules).map(
    ([id, moduleConfig]) => ({ id, ...moduleConfig }),
  );
  const overrides = new Map();
  for (const id of options.enabledOverrides) overrides.set(id, true);
  for (const id of options.disabledOverrides) overrides.set(id, false);

  const knownIds = new Set(modules.map((item) => item.id));
  if ([...overrides.keys()].some((id) => !knownIds.has(id))) {
    packageFailure("packaging_module_override_unknown");
  }

  const selected = [];
  const skipped = [];
  for (const moduleConfig of modules) {
    const supported = platformSupportsModule(
      moduleConfig,
      options.platform,
    );
    const enabled = overrides.has(moduleConfig.id)
      ? overrides.get(moduleConfig.id)
      : moduleConfig.enabled !== false;
    if (!supported) {
      skipped.push({ ...moduleConfig, status: "skipped-platform" });
    } else if (moduleConfig.required && !enabled) {
      packageFailure("required_packaging_module_disabled");
    } else if (!enabled) {
      skipped.push({ ...moduleConfig, status: "disabled" });
    } else {
      selected.push({ ...moduleConfig, status: "enabled" });
    }
  }

  const selectedIds = new Set(selected.map((item) => item.id));
  for (const moduleConfig of selected) {
    if (
      (moduleConfig.requires || []).some(
        (dependency) => !selectedIds.has(dependency),
      )
    ) {
      packageFailure("packaging_module_dependency_not_selected");
    }
  }
  return Object.freeze({
    selected: Object.freeze(selected),
    skipped: Object.freeze(skipped),
  });
}

export function platformSupportsModule(moduleConfig, platform) {
  const platforms = Array.isArray(moduleConfig.platforms)
    ? moduleConfig.platforms
    : [];
  return platforms.length === 0 || platforms.includes(platform);
}

export function publicPackagingModuleRecord(moduleConfig) {
  return Object.freeze({
    id: moduleConfig.id,
    label: moduleConfig.label || moduleConfig.id,
    category: moduleConfig.category || "",
    packaging: moduleConfig.packaging || "",
    profile: moduleConfig.profile || "",
    required: moduleConfig.required === true,
    status: moduleConfig.status || "",
  });
}

export function targetSkippedModules(skipped) {
  return skipped.filter((item) => item.status !== "skipped-platform");
}
