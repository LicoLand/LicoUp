import path from "node:path";
import process from "node:process";
import {
  OPTIONAL_CAPABILITY_ARTIFACTS,
  OPTIONAL_CAPABILITY_BUNDLES,
} from "../ratchet/definitions.mjs";

const requiredFutureModules = [
  "desktop-app",
  "native-sidecar",
  "portable-data",
  "target-adapters",
  "local-task-queue",
  "protocol-adapters",
  "skill-hub",
  "mobile-relay",
  "activity-snapshots",
  "settings",
  "lico-agent-sidecar",
  "codex-plugin"
];
const optionalFutureModules = [
  "extension-packages",
  "subagents-mcp",
  // The Gateway Runtime is an optional capability: `org.licoland.feature.gateway`
  // is released as its own package and appears in `OPTIONAL_CAPABILITY_CRATES`.
  // The default client still ships the sidecar, so the module stays enabled, but
  // it is no longer a prerequisite every distribution must contain.
  "gateway-sidecar"
];
// Optional modules whose implementation an independently released package
// carries. The minimal client must not bundle a second copy: an enabled module
// here would put the payload back into every distribution and make the
// package's own install state a lie.
const packageDeliveredModules = [
  "subagents-mcp"
];
const allFutureModules = [...requiredFutureModules, ...optionalFutureModules];
const packageClientFacadePath = "apps/desktop/scripts/package-client.mjs";
const packageClientModuleRoot = "apps/desktop/scripts/package-client";
const packageClientSourceBundleTestPath =
  "tests/contract/client/package-client/package-client-source-bundle.test.mjs";
const packageClientLeafResponsibilities = new Map([
  ["build/flutter.mjs", "function buildFlutterApp("],
  ["build/native.mjs", "function buildNativeSidecars("],
  ["build/release-tools.mjs", "function buildReleaseTools("],
  ["build/swift.mjs", "function buildSwiftSidecars("],
  ["bundle-resolver/linux.mjs", "function findLinuxBundleSource("],
  ["bundle-resolver/macos.mjs", "function findMacosBundleSource("],
  ["bundle-resolver/windows.mjs", "function findWindowsBundleSource("],
  ["cli-policy.mjs", "function runtimeDataPolicyRecord("],
  ["config-codec.mjs", "function validatePackagingConfig("],
  ["macos/install.mjs", "function installRunnableClient("],
  ["macos/metadata.mjs", "function updateMacosAppMetadata("],
  ["macos/signing.mjs", "function signMacosBundle("],
  ["module-selection.mjs", "function selectPackagingModules("],
  ["orchestrator.mjs", "function packageClient("],
  ["portable-manifest.mjs", "function preparePortableManifest("],
  ["process-runner.mjs", "function runPackageProcess("],
  ["pub-cache.mjs", "function prepareStagedPubCache("],
  ["resource-assembly.mjs", "function assemblePackageResources("],
  ["source-staging.mjs", "function prepareStagedFlutterSource("],
  ["windows-manifest.mjs", "function writeWindowsPlatformManifest("],
]);

export async function checkPackagingAndTargetProjection(context) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
  } = context;
  const packaging = await readJson("apps/desktop/packaging.modules.json");
  const futureModules = Object.keys(packaging.modules || {}).sort();
  assert(
    sameSet(futureModules, [...allFutureModules].sort()),
    `packaging.modules.json must define exactly ${allFutureModules.join(", ")}`
  );
  assert(packaging.packageProfile === "licoup", "default package profile must be licoup");
  const modules = packaging.modules || {};
  const enabledConfigModules = Object.entries(modules)
    .filter(([, module]) => module.enabled !== false)
    .map(([id]) => id)
    .sort();
  const requiredEnabled = requiredFutureModules.filter((id) => modules[id]?.enabled !== false).sort();
  assert(
    sameSet(requiredEnabled, [...requiredFutureModules].sort()),
    `required modules must remain enabled: ${requiredFutureModules.join(", ")}`
  );
  for (const moduleId of requiredFutureModules) {
    assert(modules[moduleId]?.required === true, `future module must be required: ${moduleId}`);
  }
  // A module whose implementation arrives as an independent package asset is
  // optional: the release must stay complete and startable without it, and no
  // required module may depend on it.
  for (const moduleId of optionalFutureModules) {
    assert(modules[moduleId]?.required === false,
      `package-provided module must stay optional: ${moduleId}`);
    assert(
      Object.entries(modules).every(([id, module]) =>
        !requiredFutureModules.includes(id) ||
        !(module.requires || []).includes(moduleId)),
      `required module must not depend on optional module: ${moduleId}`
    );
  }
  for (const moduleId of packageDeliveredModules) {
    assert(optionalFutureModules.includes(moduleId),
      `package-delivered module must stay optional: ${moduleId}`);
    assert(modules[moduleId]?.enabled === false,
      `package-delivered module must not be bundled: ${moduleId}`);
    assert(
      modules[moduleId]?.cargoBin === undefined &&
        modules[moduleId]?.embeddedCargoBin === undefined,
      `no packaging module may bundle the package's own binary: ${moduleId}`
    );
  }
  // An optional capability's payload may still be bundled by the default client,
  // but never by a module the release cannot omit, and never by more modules
  // than the reviewed declaration already names. Both halves are measured from
  // this config against the ratchet's own declaration, so re-bundling the
  // payload is a reviewed declaration change rather than a quiet packaging
  // edit, and `optionalCapabilitiesBundledInPackaging` can only fall.
  const optionalCapabilityPayloads = new Set(Object.values(OPTIONAL_CAPABILITY_ARTIFACTS)
    .flatMap((record) => record.artifacts));
  assert(optionalCapabilityPayloads.size > 0,
    "the optional capability declaration must name at least one payload");
  const declaredCarriers = new Set(Object.values(OPTIONAL_CAPABILITY_BUNDLES)
    .flatMap((moduleIds) => moduleIds));
  const bundlingCarriers = Object.entries(modules)
    .filter(([, module]) => module.enabled !== false)
    .filter(([, module]) => [module.cargoBin, module.embeddedCargoBin]
      .some((binary) => binary !== undefined && optionalCapabilityPayloads.has(binary)))
    .map(([id]) => id);
  for (const moduleId of bundlingCarriers) {
    assert(modules[moduleId]?.required === false,
      `a module bundling an optional capability payload must not be required: ${moduleId}`);
    assert(declaredCarriers.has(moduleId),
      `enabled module ${moduleId} bundles an optional capability payload the reviewed declaration does not name; optionalCapabilitiesBundledInPackaging may only fall, never grow`);
  }
  for (const moduleId of enabledConfigModules) {
    assert(allFutureModules.includes(moduleId), `enabled module must be known: ${moduleId}`);
  }
  const deferredCapabilities = packaging.deferredCapabilities || {};
  assert(
    Object.keys(deferredCapabilities).length === 0,
    "default packaging must not embed deferred service or plugin implementations"
  );
  const packagedTargets = modules["target-adapters"]?.targetAdapters || [];
  assert(Array.isArray(packagedTargets) && packagedTargets.length > 0,
    "target-adapters module must define the canonical packaged target set");
  assert(new Set(packagedTargets).size === packagedTargets.length && packagedTargets.every((target) => typeof target === "string" && target.trim().length > 0),
    "target-adapters module targetAdapters must contain unique non-empty target ids");
  // The packaged adapter projection is declared by the crate that owns the
  // registry, `licoup-agent-drivers`; the host's `runtime_adapters.rs` is the
  // composition above it and reaches the name through a re-export.
  const runtimeAdaptersSource = await readText(
    "crates/licoup-agent-drivers/src/runtime_adapters.rs"
  );
  const runtimeAdapterIdsBlock = runtimeAdaptersSource.match(/PACKAGED_RUNTIME_ADAPTER_IDS\s*:\s*&\[&str\]\s*=\s*&\[([\s\S]*?)\];/);
  assert(runtimeAdapterIdsBlock,
    "the driver core must expose its packaged adapter projection");
  const nativeRuntimeAdapterIds = [...runtimeAdapterIdsBlock[1].matchAll(/"([^"]+)"/g)]
    .map((match) => match[1]);
  assert(sameSet([...nativeRuntimeAdapterIds].sort(), [...packagedTargets].sort()),
    "native runtime dispatch projection must exactly match target-adapters.targetAdapters");
  const platformModuleSource = await readText("crates/licoup-native/src/platform/mod.rs");
  // The host's own composition of the packaged targets: the one place that names
  // every Agent's driver. `runtimeAdaptersSource` above is the driver core's
  // protocol-agnostic projection, so the reach itself is read here.
  const hostDriverCompositionSource = await readText(
    "crates/licoup-native/src/platform/runtime_adapters/drivers.rs"
  );
  // Every packaged target's driver is the adapter package's. The host reaches it
  // through that package's own driver module and owns no driver module for the
  // target itself: neither a declaration in its module tree nor an artefact on
  // disk. A kernel copy reappearing for any target fails this check rather than
  // silently becoming a second owner of one Agent's protocol.
  //
  // This table is the reviewed declaration of who carries each target's driver.
  // `module` is the path inside the crate, so the rule can prove both halves: the
  // composition names that exact path, and the crate really carries it. A new
  // packaged target must be declared here, which is what keeps the projection
  // from drifting into a host-owned driver again.
  const packagedTargetDrivers = new Map([
    ["antigravity", { crate: "licoup-agent-antigravity", module: "driver",
      source: "crates/licoup-agent-antigravity/src/driver.rs" }],
    ["claude-code", { crate: "licoup-agent-claude-code", module: "driver",
      source: "crates/licoup-agent-claude-code/src/driver.rs" }],
    ["codex", { crate: "licoup-agent-codex", module: "app_server::driver",
      source: "crates/licoup-agent-codex/src/app_server/driver.rs" }],
    ["copilot", { crate: "licoup-agent-copilot", module: "driver",
      source: "crates/licoup-agent-copilot/src/driver.rs" }],
    ["cursor", { crate: "licoup-agent-cursor", module: "driver",
      source: "crates/licoup-agent-cursor/src/driver.rs" }],
    ["deepseek-harness", { crate: "licoup-agent-deepseek", module: "driver",
      source: "crates/licoup-agent-deepseek/src/driver.rs" }],
    ["hermes", { crate: "licoup-agent-hermes", module: "driver",
      source: "crates/licoup-agent-hermes/src/driver.rs" }],
    ["kilo-code", { crate: "licoup-agent-kilo", module: "driver",
      source: "crates/licoup-agent-kilo/src/driver.rs" }],
    ["kimi-code", { crate: "licoup-agent-kimi", module: "driver",
      source: "crates/licoup-agent-kimi/src/driver.rs" }],
    ["lico-agent", { crate: "licoup-agent-lico-agent", module: "driver",
      source: "crates/licoup-agent-lico-agent/src/driver.rs" }],
    ["openclaw", { crate: "licoup-agent-openclaw", module: "driver",
      source: "crates/licoup-agent-openclaw/src/driver.rs" }],
    ["opencode", { crate: "licoup-agent-opencode", module: "driver",
      source: "crates/licoup-agent-opencode/src/driver.rs" }],
    ["pi", { crate: "licoup-agent-pi", module: "driver",
      source: "crates/licoup-agent-pi/src/driver.rs" }],
  ]);
  assert(
    sameSet([...packagedTargetDrivers.keys()].sort(), [...packagedTargets].sort()),
    "every packaged target must declare the crate that carries its driver, and no other target may be declared"
  );
  const kernelPlatformRoot = "crates/licoup-native/src/platform";
  // The modules the host's own tree declares, parsed rather than substring
  // matched, so a driver cannot hide behind a different declaration spelling.
  const declaredPlatformModules = new Set(
    [...platformModuleSource.matchAll(/^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+([a-z0-9_]+)\s*;/gmu)]
      .map((match) => match[1])
  );
  for (const target of packagedTargets) {
    const driver = packagedTargetDrivers.get(target);
    const prefix = `${target.replaceAll("-", "_")}_`;
    // The host owns no driver module for the target: not a declaration, not a
    // file, not a tree. The pattern covers the target's own driver module and
    // every lane beside it — Hermes reaches one target through two protocols, so
    // `hermes_driver` and `hermes_tui_gateway_driver` are both the target's and
    // both the package's.
    const moduleName = `${prefix}driver`;
    const hostedDrivers = [...declaredPlatformModules]
      .filter((name) => name.endsWith("_driver") &&
        (name === moduleName || name.startsWith(prefix)))
      .sort();
    assert(hostedDrivers.length === 0,
      `the host must declare no ${prefix}*_driver module, found ${hostedDrivers.join(", ")}: packaged target ${target}'s driver is ${driver.crate}'s`);
    for (const name of new Set([moduleName, ...hostedDrivers])) {
      for (const retired of [`${kernelPlatformRoot}/${name}.rs`,
        `${kernelPlatformRoot}/${name}`]) {
        assert(!(await exists(retired)),
          `the host still carries ${retired}: packaged target ${target}'s driver is ${driver.crate}'s`);
      }
    }
    // The host reaches the target through exactly one path: the crate's own
    // driver module, named by the composition that composes every target.
    const driverPath = `${driver.crate.replaceAll("-", "_")}::${driver.module}`;
    assert(hostDriverCompositionSource.includes(driverPath),
      `the host composition must reach packaged target ${target} through ${driverPath}`);
    // And the crate really carries what the composition named.
    assert(await exists(driver.source),
      `${driver.crate} must carry the driver module the composition names: ${driver.source}`);
  }
  return { futureModules, modules, packagedTargets };
}

export async function checkPackageDryRuns(context, { futureModules, modules }) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
  } = context;
  const packageClientLeafPaths = [...packageClientLeafResponsibilities.keys()]
    .map((leaf) => `${packageClientModuleRoot}/${leaf}`);
  const discoveredPackageClientLeaves = await collectSourceFiles(
    packageClientModuleRoot,
    ".mjs",
  );
  assert(
    sameSet(discoveredPackageClientLeaves, packageClientLeafPaths),
    "package-client must own exactly the architecture-approved source bundle",
  );
  const packageClientFacadeSource = await readText(packageClientFacadePath);
  assert(
    packageClientFacadeSource.includes(
        'export { validateReleaseBuildPolicy } from "./package-client/cli-policy.mjs";',
      ) &&
      packageClientFacadeSource.includes(
        'export { validatePackagingConfig } from "./package-client/config-codec.mjs";',
      ) &&
      packageClientFacadeSource.includes(
        'export { packageClient } from "./package-client/orchestrator.mjs";',
      ) &&
      packageClientFacadeSource.includes("assertReleaseSourceDigestStable") &&
      packageClientFacadeSource.includes("diffReleaseSourceManifests") &&
      packageClientFacadeSource.includes("packageSourceStateBinding"),
    "package-client root must remain a thin six-export CLI facade over the split source bundle",
  );
  for (const retiredRootToken of [
    "execFileSync",
    "readFileSync",
    "function packageClient(",
    "function validatePackagingConfig(",
    "function buildFlutterApp(",
    "function buildNativeSidecars(",
    "function preparePortableManifest(",
    "function assemblePackageResources(",
    "function signMacosBundle(",
  ]) {
    assert(
      !packageClientFacadeSource.includes(retiredRootToken),
      `package-client root must not restore retired implementation ownership via ${retiredRootToken}`,
    );
  }
  const packageClientLeafSources = Object.fromEntries(await Promise.all(
    [...packageClientLeafResponsibilities].map(async ([leaf]) => [
      leaf,
      await readText(`${packageClientModuleRoot}/${leaf}`),
    ]),
  ));
  const packageClientJoinedSource = await readJoinedText(packageClientLeafPaths);
  for (const [leaf, responsibilityToken] of packageClientLeafResponsibilities) {
    assert(
      packageClientLeafSources[leaf].includes(responsibilityToken),
      `${packageClientModuleRoot}/${leaf} must retain its package-client responsibility ${responsibilityToken}`,
    );
    assert(
      !packageClientLeafSources[leaf].includes("../package-client.mjs"),
      `${packageClientModuleRoot}/${leaf} must not depend back on the retired root implementation`,
    );
  }
  assert(
    packageClientJoinedSource.includes("if (options.dryRun)") &&
      packageClientJoinedSource.includes("preflight(options)") &&
      packageClientJoinedSource.includes("captureReleaseSourceState") &&
      packageClientJoinedSource.includes("assertReleaseSourceStateStable") &&
      packageClientJoinedSource.includes("publicPackageFailure"),
    "package-client joined leaves must preserve dry-run, build preflight, source-state, and redacted-failure semantics",
  );
  const packageClientSourceBundleTestExists = await exists(
    packageClientSourceBundleTestPath,
  );
  assert(
    packageClientSourceBundleTestExists,
    `${packageClientSourceBundleTestPath} must own the focused package-client regression`,
  );
  if (packageClientSourceBundleTestExists) {
    const packageClientSourceBundleTest = await readText(
      packageClientSourceBundleTestPath,
    );
    assert(
      packageClientSourceBundleTest.includes(
        "package client keeps an exact bounded module inventory",
      ) &&
        packageClientSourceBundleTest.includes(
          "assert.deepEqual(await collectModules(moduleRoot), [...leaves]);",
        ) &&
        packageClientSourceBundleTest.includes(
          'assert.equal(facade.includes("function packageClient("), false);',
        ) &&
        packageClientSourceBundleTest.includes(
          "assert.equal(findImportCycle(source), null);",
        ) &&
        [...packageClientLeafResponsibilities.keys()].every((leaf) =>
          packageClientSourceBundleTest.includes(`"${leaf}"`)
        ),
      "package-client source-bundle regression must own the exact leaves, no-old-root boundary, and import DAG",
    );
  }
  const packagePlanCheckedPlatforms = [];
  for (const platform of ["macos", "linux", "windows"]) {
    const packagePlan = runJson(process.execPath, [
      "apps/desktop/scripts/package-client.mjs",
      "--dry-run",
      "--platform",
      platform
    ]);
    if (packagePlan) {
      packagePlanCheckedPlatforms.push(platform);
      const enabledPlanModules = packagePlan.enabledModules.map((item) => item.id).sort();
      // A module the configuration disables is not enabled by any platform; it
      // is reported as a target-skipped module instead.
      const expectedPlanModules = futureModules
        .filter((moduleId) =>
          modules[moduleId]?.enabled !== false &&
          moduleSupportsPlatform(modules[moduleId], platform))
        .sort();
      assert(packagePlan.platform === platform, `package dry-run must report platform ${platform}`);
      assert(
        typeof packagePlan.configPath === "string" &&
          !path.isAbsolute(packagePlan.configPath) &&
          !packagePlan.configPath.startsWith(".."),
        `package dry-run for ${platform} must not disclose an absolute or parent-local config path`
      );
      assert(
        sameSet(enabledPlanModules, expectedPlanModules),
        `package dry-run for ${platform} must enable only supported future modules`
      );
    }
  }

  return { packagePlanCheckedPlatforms };
}
