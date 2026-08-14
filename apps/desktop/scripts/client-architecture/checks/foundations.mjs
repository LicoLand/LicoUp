import path from "node:path";
import process from "node:process";

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
  "subagents-mcp",
  "conversations-mcp",
  "gateway-sidecar",
  "lico-agent-sidecar",
  "codex-plugin"
];
const allFutureModules = [...requiredFutureModules];
const packageClientFacadePath = "apps/desktop/scripts/package-client.mjs";
const packageClientModuleRoot = "apps/desktop/scripts/package-client";
const packageClientSourceBundleTestPath =
  "tests/contract/client/package-client/package-client-source-bundle.test.mjs";
const packageClientLeafResponsibilities = new Map([
  ["build/flutter.mjs", "function buildFlutterApp("],
  ["build/native.mjs", "function buildNativeSidecars("],
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
  const runtimeAdaptersSource = await readText("crates/licoup-native/src/platform/runtime_adapters.rs");
  const runtimeAdapterIdsBlock = runtimeAdaptersSource.match(/PACKAGED_RUNTIME_ADAPTER_IDS\s*:\s*&\[&str\]\s*=\s*&\[([\s\S]*?)\];/);
  assert(runtimeAdapterIdsBlock,
    "native runtime dispatch must expose its packaged adapter projection");
  const nativeRuntimeAdapterIds = [...runtimeAdapterIdsBlock[1].matchAll(/"([^"]+)"/g)]
    .map((match) => match[1]);
  assert(sameSet([...nativeRuntimeAdapterIds].sort(), [...packagedTargets].sort()),
    "native runtime dispatch projection must exactly match target-adapters.targetAdapters");
  const platformModuleSource = await readText("crates/licoup-native/src/platform/mod.rs");
  for (const target of packagedTargets) {
    const moduleName = target === "codex"
      ? "codex_app_server"
      : `${target.replaceAll("-", "_")}_driver`;
    assert(platformModuleSource.includes(`mod ${moduleName};`),
      `packaged target ${target} must have canonical native driver module ${moduleName}`);
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
    "package-client must own exactly the architecture-approved nineteen-leaf source bundle",
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
        "package client migration owns exactly nineteen bounded ordinary modules",
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
      const expectedPlanModules = futureModules
        .filter((moduleId) => moduleSupportsPlatform(modules[moduleId], platform))
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
