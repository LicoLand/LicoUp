#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const requiredFutureModules = [
  "desktop-app",
  "native-sidecar",
  "portable-data",
  "target-adapters",
  "mcp-plugins",
  "skill-hub",
  "model-forwarding",
  "mobile-relay",
  "activity-snapshots",
  "settings",
  "source-queue",
  "client-connectors",
  "knowledge-cache",
  "mail-import-runtime",
  "openai-dashboard-runtime",
  "mcp-local-bridge"
];
const optionalFutureModules = [
  "multi-agent-routing"
];
const allFutureModules = [...requiredFutureModules, ...optionalFutureModules];
const defaultGuiSurfacePaths = [
  "apps/desktop/lib/app.dart",
  "apps/desktop/lib/src/application/controller/future_client_controller.dart",
  "apps/desktop/lib/src/application/controller/controller_lifecycle_actions.dart",
  "apps/desktop/lib/src/application/features/agents/controller/agent_conversation_actions.dart",
  "apps/desktop/lib/src/application/features/agents/controller/agent_usage_actions.dart",
  "apps/desktop/lib/src/application/features/mcp_plugins/controller/mcp_plugin_actions.dart",
  "apps/desktop/lib/src/application/features/mobile_relay/controller/secure_mesh_actions.dart",
  "apps/desktop/lib/src/application/features/mobile_relay/controller/mobile_relay_actions.dart",
  "apps/desktop/lib/src/application/features/local_runtime/controller/local_runtime_actions.dart",
  "apps/desktop/lib/src/application/features/settings/controller/proxy_bridge_actions.dart",
  "apps/desktop/lib/src/application/features/settings/controller/client_log_export_actions.dart",
  "apps/desktop/lib/src/application/features/skill_hub/controller/skill_hub_actions.dart",
  "apps/desktop/lib/src/application/features/targets/controller/target_actions.dart",
  "apps/desktop/lib/src/application/models/future_client_models.dart",
  "apps/desktop/lib/src/platform/storage/client_log_export_service.dart",
  "apps/desktop/lib/src/platform/storage/client_workspace_manifest.dart",
  "apps/desktop/lib/src/backend/features/agents/services/agent_conversation_service.dart",
  "apps/desktop/lib/src/backend/features/agents/services/agent_usage_service.dart",
  "apps/desktop/lib/src/platform/native_client/agent_service.dart",
  "apps/desktop/lib/src/platform/native_client/agent_service_actions.dart",
  "apps/desktop/lib/src/platform/native_client/proxy_bridge_service_actions.dart",
  "apps/desktop/lib/src/contracts/mobile_relay/mobile_relay_models.dart",
  "apps/desktop/lib/src/platform/mobile_relay/mobile_relay_service.dart",
  "apps/desktop/lib/src/platform/secure_mesh/secure_mesh_android_bridge.dart",
  "apps/desktop/lib/src/platform/storage/portable_data_root.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agents_empty_state.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agents_toolbar.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agents_canvas.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_panel.dart",
  "apps/desktop/lib/src/frontend/shell/client_shell.dart",
  "apps/desktop/lib/src/frontend/features/targets/ui/manual_target_dialog.dart",
  "apps/desktop/lib/src/frontend/features/mcp_plugins/ui/mcp_plugins_panel.dart",
  "apps/desktop/lib/src/frontend/shared/ui/panel_frame.dart",
  "apps/desktop/lib/src/frontend/features/settings/ui/settings_panel.dart",
  "apps/desktop/lib/src/frontend/features/settings/ui/proxy_bridge_settings.dart",
  "apps/desktop/lib/src/frontend/features/settings/ui/proxy_bridge_settings_widgets.dart",
  "apps/desktop/lib/src/frontend/features/settings/ui/settings_log_export_tile.dart",
  "apps/desktop/lib/src/frontend/shell/shell_navigation.dart",
  "apps/desktop/lib/src/frontend/features/skill_hub/ui/skill_hub_panel.dart",
  "apps/desktop/lib/src/frontend/features/targets/ui/target_card.dart",
  "apps/desktop/lib/src/frontend/l10n/lico_strings.dart"
];
const defaultGuiMaxLines = 340;
const flutterLibRoot = "apps/desktop/lib";
const flutterSrcRoot = "apps/desktop/lib/src";
const requiredFlutterPhysicalDirs = ["application", "frontend", "backend", "platform", "contracts"];
const allowedFlutterTopLevelDirs = new Set([
  ...requiredFlutterPhysicalDirs
]);
const requiredFrontendFeatureDirs = [
  "agents",
  "mobile_relay",
  "mcp_plugins",
  "skill_hub",
  "local_runtime",
  "settings",
  "targets"
];
const requiredBackendFeatureDirs = [
  "agents",
  "mobile_relay"
];
const flutterLayerImportRules = [
  {
    root: `${flutterSrcRoot}/frontend`,
    forbiddenTokens: [
      "package:flutter_client/src/backend/",
      "package:flutter_client/src/platform/"
    ],
    message: "frontend must depend on application/contracts/l10n, not backend or platform implementations"
  },
  {
    root: `${flutterSrcRoot}/backend`,
    forbiddenTokens: [
      "package:flutter_client/src/frontend/",
      "package:flutter_client/src/platform/"
    ],
    message: "backend must not import frontend UI or platform implementation code"
  },
  {
    root: `${flutterSrcRoot}/platform`,
    forbiddenTokens: [
      "package:flutter_client/src/frontend/",
      "package:flutter_client/src/backend/"
    ],
    message: "platform bridge code must not import frontend UI or backend implementation code"
  },
  {
    root: `${flutterSrcRoot}/contracts`,
    forbiddenTokens: [
      "package:flutter_client/src/frontend/",
      "package:flutter_client/src/backend/",
      "package:flutter_client/src/platform/"
    ],
    message: "contracts must not import implementation layers"
  }
];
const rustCliRoot = "crates/lico-client-native/src";
const rustNativePublicModules = ["core", "domain", "ffi", "platform"];
const rustNativePhysicalModuleDirs = [
  "crates/lico-client-native/src/core",
  "crates/lico-client-native/src/domain",
  "crates/lico-client-native/src/ffi",
  "crates/lico-client-native/src/platform"
];
const guiImplementationForbiddenTokens = [
  "dart:io",
  "Clipboard.",
  "MethodChannel",
  "EventChannel",
  "Process.run",
  "Process.start",
  "Platform.is",
  "path_provider",
  "secretOverrides",
  "secretOverrideTransport"
];
const backendImplementationForbiddenUiTokens = [
  "package:flutter/",
  "package:flutter/widgets.dart",
  "package:flutter/material.dart",
  "BuildContext",
  "Widget",
  "StatelessWidget",
  "StatefulWidget",
  "TextEditingController",
  "ChangeNotifier",
  "MaterialApp",
  "Theme.of("
];

const failures = [];
let dartSourceFilesCache = null;

function fail(message) {
  failures.push(message);
}

function assert(condition, message) {
  if (!condition) {
    fail(message);
  }
}

async function exists(relativePath) {
  try {
    await fs.access(path.join(repoRoot, relativePath));
    return true;
  } catch {
    return false;
  }
}

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function readJoinedText(relativePaths) {
  return (await Promise.all(relativePaths.map((relativePath) => readText(relativePath)))).join("\n");
}

async function readJson(relativePath) {
  return JSON.parse(await readText(relativePath));
}

async function readImmediateDirectoryNames(relativeRoot) {
  try {
    const items = await fs.readdir(path.join(repoRoot, relativeRoot), { withFileTypes: true });
    return items.filter((item) => item.isDirectory()).map((item) => item.name).sort();
  } catch (error) {
    fail(`${relativeRoot} must be readable`);
    return [];
  }
}

function sameSet(actual, expected) {
  return actual.length === expected.length && expected.every((item) => actual.includes(item));
}

function moduleSupportsPlatform(moduleConfig, platform) {
  const platforms = Array.isArray(moduleConfig?.platforms) ? moduleConfig.platforms : [];
  return platforms.length === 0 || platforms.includes(platform);
}

function runJson(command, args) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024
  });
  const commandLabel = path.basename(command);
  if (result.status !== 0) {
    fail(`${commandLabel} subprocess failed`);
    return null;
  }
  try {
    return JSON.parse(result.stdout);
  } catch {
    fail(`${commandLabel} subprocess did not return JSON`);
    return null;
  }
}

function collectEnumValues(source, enumName) {
  const match = source.match(new RegExp(`enum\\s+${enumName}\\s*\\{([\\s\\S]*?)\\}`));
  if (!match) {
    return [];
  }
  return match[1]
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean)
    .map((item) => item.split(/\s|\(/)[0]);
}

function collectRustPubMods(source) {
  return [...source.matchAll(/^pub mod ([A-Za-z0-9_]+);$/gm)]
    .map((match) => match[1])
    .sort();
}

async function collectSourceFiles(relativeRoot, extension) {
  const absoluteRoot = path.join(repoRoot, relativeRoot);
  const files = [];

  async function walk(relativeDir = "") {
    const items = await fs.readdir(path.join(absoluteRoot, relativeDir), { withFileTypes: true });
    for (const item of items) {
      const child = relativeDir ? `${relativeDir}/${item.name}` : item.name;
      if (item.isDirectory()) {
        await walk(child);
      } else if (item.isFile() && child.endsWith(extension)) {
        files.push(`${relativeRoot}/${child}`);
      }
    }
  }

  await walk();
  return files.sort();
}

async function collectDartSourceFiles() {
  if (!dartSourceFilesCache) {
    dartSourceFilesCache = await collectSourceFiles(flutterLibRoot, ".dart");
  }
  return dartSourceFilesCache;
}

function isFlutterPresentationSource(relativePath) {
  const segments = relativePath.split("/");
  const basename = path.basename(relativePath);
  return segments.includes("ui") ||
    segments.includes("shell") ||
    segments.includes("widgets") ||
    segments.includes("views") ||
    segments.includes("pages") ||
    basename.endsWith("_panel.dart") ||
    basename.endsWith("_page.dart") ||
    basename.endsWith("_workspace.dart") ||
    basename.endsWith("_dialog.dart") ||
    basename.endsWith("_card.dart") ||
    basename.endsWith("_toolbar.dart") ||
    basename.endsWith("_field.dart") ||
    basename.endsWith("_badge.dart") ||
    basename.endsWith("_icon.dart") ||
    basename.includes("_navigation");
}

function isFlutterGuiImplementationSource(relativePath) {
  return relativePath.startsWith(`${flutterSrcRoot}/frontend/`);
}

function lineNumberForToken(source, token) {
  const lines = source.split(/\r?\n/);
  const index = lines.findIndex((line) => line.includes(token));
  return index >= 0 ? index + 1 : 1;
}

async function enforceFlutterLayerIsolation() {
  for (const rule of flutterLayerImportRules) {
    let files;
    try {
      files = await collectSourceFiles(rule.root, ".dart");
    } catch (error) {
      fail(`${rule.root} must be readable for Flutter layer isolation: ${error.message}`);
      continue;
    }
    for (const relativePath of files) {
      const source = await readText(relativePath);
      for (const token of rule.forbiddenTokens) {
        assert(
          !source.includes(token),
          `${relativePath}:${lineNumberForToken(source, token)} ${rule.message}; forbidden import token ${token}`
        );
      }
    }
  }
}

async function resolveDartSourceByBasename(basename) {
  const matches = (await collectDartSourceFiles())
    .filter((relativePath) => path.basename(relativePath) === basename);
  if (matches.length !== 1) {
    fail(`Flutter source file ${basename} must resolve to exactly one file under ${flutterLibRoot}; found ${matches.length}: ${matches.join(", ")}`);
    return null;
  }
  return matches[0];
}

async function readDartSourceByBasename(basename) {
  const relativePath = await resolveDartSourceByBasename(basename);
  if (!relativePath) {
    return "";
  }
  return readText(relativePath);
}

async function readJoinedDartSourcesByBasename(basenames) {
  return (await Promise.all(basenames.map((basename) => readDartSourceByBasename(basename)))).join("\n");
}

async function collectRustUnsafeFiles(relativeRoot) {
  const absoluteRoot = path.join(repoRoot, relativeRoot);
  const unsafeFiles = [];

  async function walk(relativeDir = "") {
    const items = await fs.readdir(path.join(absoluteRoot, relativeDir), { withFileTypes: true });
    for (const item of items) {
      if (item.name === "target") {
        continue;
      }
      const child = relativeDir ? `${relativeDir}/${item.name}` : item.name;
      if (item.isDirectory()) {
        await walk(child);
      } else if (item.isFile() && child.endsWith(".rs")) {
        const content = await fs.readFile(path.join(absoluteRoot, child), "utf8");
        const scannedContent = child === "android_ffi.rs"
          ? content.replace(/#\s*\[\s*unsafe\s*\(\s*no_mangle\s*\)\s*\]/g, "")
          : content;
        if (/(^|[^A-Za-z0-9_])unsafe([^A-Za-z0-9_]|$)/.test(scannedContent)) {
          unsafeFiles.push(`${relativeRoot}/${child}`);
        }
      }
    }
  }

  await walk();
  return unsafeFiles.sort();
}

const packaging = await readJson("apps/desktop/packaging.modules.json");
const futureModules = Object.keys(packaging.modules || {}).sort();
assert(
  sameSet(futureModules, [...allFutureModules].sort()),
  `packaging.modules.json must define exactly ${allFutureModules.join(", ")}`
);
assert(packaging.packageProfile === "future-client", "default package profile must be future-client");
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
for (const moduleId of optionalFutureModules) {
  assert(modules[moduleId]?.required === false, `optional module must set required=false: ${moduleId}`);
  assert(
    modules[moduleId]?.runtimeToggle === true,
    `optional module must expose runtimeToggle: ${moduleId}`
  );
}
// Optional modules may be enabled or disabled; when enabled they appear in the enabled set.
for (const moduleId of enabledConfigModules) {
  assert(allFutureModules.includes(moduleId), `enabled module must be known: ${moduleId}`);
}
const deferredCapabilities = packaging.deferredCapabilities || {};
assert(
  sameSet(Object.keys(deferredCapabilities).sort(), ["clientd"]),
  "deferred client capabilities must be explicit TODO placeholders, not hidden package modules"
);
for (const [capabilityId, capability] of Object.entries(deferredCapabilities)) {
  assert(capability.status === "todo", `deferred client capability must be status=todo: ${capabilityId}`);
  assert(!modules[capabilityId], `deferred client capability must not be packaged as an active module: ${capabilityId}`);
}
const packagedTargets = modules["target-adapters"]?.targetAdapters || [];
assert(Array.isArray(packagedTargets) && packagedTargets.length > 0,
  "target-adapters module must define the canonical packaged target set");
assert(new Set(packagedTargets).size === packagedTargets.length && packagedTargets.every((target) => typeof target === "string" && target.trim().length > 0),
  "target-adapters module targetAdapters must contain unique non-empty target ids");
const runtimeAdaptersSource = await readText("crates/lico-client-native/src/platform/runtime_adapters.rs");
const runtimeAdapterIdsBlock = runtimeAdaptersSource.match(/PACKAGED_RUNTIME_ADAPTER_IDS\s*:\s*&\[&str\]\s*=\s*&\[([\s\S]*?)\];/);
assert(runtimeAdapterIdsBlock,
  "native runtime dispatch must expose its packaged adapter projection");
const nativeRuntimeAdapterIds = [...runtimeAdapterIdsBlock[1].matchAll(/"([^"]+)"/g)]
  .map((match) => match[1]);
assert(sameSet([...nativeRuntimeAdapterIds].sort(), [...packagedTargets].sort()),
  "native runtime dispatch projection must exactly match target-adapters.targetAdapters");
const platformModuleSource = await readText("crates/lico-client-native/src/platform/mod.rs");
for (const target of packagedTargets) {
  const moduleName = target === "codex"
    ? "codex_app_server"
    : `${target.replaceAll("-", "_")}_driver`;
  assert(platformModuleSource.includes(`mod ${moduleName};`),
    `packaged target ${target} must have canonical native driver module ${moduleName}`);
}
const productContractSource = await readText("PRODUCT.md");
const clientFunctionalityContractSource = await readText("docs/functionality/CLIENT-DESKTOP.md");
assert(productContractSource.includes("Native-agent fidelity") &&
  productContractSource.includes("Only adapters that pass the canonical native-conversation parity contract"),
  "PRODUCT.md must keep native-agent conversation parity as a release product invariant");
assert(clientFunctionalityContractSource.includes("Feature CL-06 Native Agent Conversation Dispatch") &&
  clientFunctionalityContractSource.includes("target-adapters.targetAdapters") &&
  clientFunctionalityContractSource.includes("P-01") &&
  clientFunctionalityContractSource.includes("P-10") &&
  clientFunctionalityContractSource.includes("C-01") &&
  clientFunctionalityContractSource.includes("C-06") &&
  clientFunctionalityContractSource.includes("only reducer-owned `ready` may advertise `runtime.message.send`"),
  "CLIENT-DESKTOP.md CL-06 must define the canonical all-adapter parity, evidence, and readiness contract");
const portableDirs = modules["portable-data"]?.portableDirectories || [];
const expectedPortableDirs = [
  "future-client",
  "future-client/settings",
  "future-client/targets",
  "future-client/pairings",
  "future-client/skills",
  "future-client/pins",
  "future-client/mobile-relay",
  "future-client/activity",
  "future-client/snapshots",
  "future-client/source-queue",
  "future-client/mail-imports",
  "future-client/connectors",
  "future-client/knowledge-cache",
  "future-client/mcp-local-bridge",
  "target-config-cache"
];
assert(sameSet([...portableDirs].sort(), [...expectedPortableDirs].sort()),
  "portable-data module must list exactly the current portable runtime directories");
for (const requiredDir of ["future-client/source-queue", "future-client/mail-imports", "future-client/connectors", "future-client/knowledge-cache", "future-client/mcp-local-bridge"]) {
  assert(portableDirs.includes(requiredDir), `portable data must include runtime directory: ${requiredDir}`);
}

const flutterTopLevelDirs = await readImmediateDirectoryNames(flutterSrcRoot);
for (const requiredDir of requiredFlutterPhysicalDirs) {
  assert(
    flutterTopLevelDirs.includes(requiredDir),
    `${flutterSrcRoot}/${requiredDir} must exist for hard frontend/backend/platform architecture`
  );
}
for (const topLevelDir of flutterTopLevelDirs) {
  assert(
    allowedFlutterTopLevelDirs.has(topLevelDir),
    `${flutterSrcRoot}/${topLevelDir} is not an allowed top-level Flutter source directory`
  );
}
const flutterFrontendFeatureDirs = await readImmediateDirectoryNames(`${flutterSrcRoot}/frontend/features`);
for (const featureDir of requiredFrontendFeatureDirs) {
  assert(
    flutterFrontendFeatureDirs.includes(featureDir),
    `${flutterSrcRoot}/frontend/features/${featureDir} must exist as a frontend feature directory`
  );
}
const flutterBackendFeatureDirs = await readImmediateDirectoryNames(`${flutterSrcRoot}/backend/features`);
for (const featureDir of requiredBackendFeatureDirs) {
  assert(
    flutterBackendFeatureDirs.includes(featureDir),
    `${flutterSrcRoot}/backend/features/${featureDir} must exist as a backend feature directory`
  );
}
await enforceFlutterLayerIsolation();

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

const libRs = await readText("crates/lico-client-native/src/lib.rs");
const publicRustModules = collectRustPubMods(libRs);
assert(
  sameSet(publicRustModules, rustNativePublicModules),
  `client native crate must publicly expose only ${rustNativePublicModules.join(", ")}`
);
assert(!libRs.includes("#[path ="), "client native lib.rs must use physical module directories, not #[path] remounts");
for (const relativePath of rustNativePhysicalModuleDirs) {
  assert(await exists(relativePath), `${relativePath} must exist as a physical native module directory`);
  const modSource = await readText(`${relativePath}/mod.rs`);
  assert(!modSource.includes("#[path ="), `${relativePath}/mod.rs must not remount flat native files with #[path]`);
}
const cliSource = await readText("crates/lico-client-native/src/bin/lico-client.rs");
for (const token of ["targets scan", "mcp config plan", "mcp plugin status", "forward --profile", "agents pair", "conversations list|append|delete", "agent message send", "mobile relay", "source-queue add|list", "connectors list|sync", "knowledge-cache sync|search", "mail preview|enqueue", "mcp-local-bridge plan|start"]) {
  assert(cliSource.includes(token), `lico-client usage must expose future command: ${token}`);
}

const reviewedRustUnsafeFiles = new Set([
  "crates/lico-client-native/src/ffi/android_ffi.rs",
  "crates/lico-client-native/src/ffi/ios_ffi.rs",
  "crates/lico-client-native/src/platform/secure_mesh_secret_store.rs"
]);
const rustCliUnsafeFiles = (await collectRustUnsafeFiles(rustCliRoot))
  .filter((relativePath) => !reviewedRustUnsafeFiles.has(relativePath));
assert(
  rustCliUnsafeFiles.length === 0,
  `Rust CLI source path must not contain unreviewed unsafe: ${rustCliUnsafeFiles.join(", ")}`
);

const futureClientModels = await readDartSourceByBasename("future_client_models.dart");
const appSections = collectEnumValues(futureClientModels, "FutureClientSection");
assert(sameSet(appSections, ["controlPanel", "agents", "feed", "monitoring", "mcpPlugins", "skillHub", "localRuntime", "mobileRelay", "settings"]), "FutureClientSection enum must contain only the current client shell modules");
for (const relativePath of (await collectDartSourceFiles())
  .filter(isFlutterGuiImplementationSource)) {
  const source = await readText(relativePath);
  for (const token of guiImplementationForbiddenTokens) {
    assert(!source.includes(token), `${relativePath} must not implement backend/platform behavior outside the platform root via ${token}`);
  }
}
for (const relativePath of (await collectDartSourceFiles())
  .filter((sourcePath) => sourcePath.startsWith(`${flutterSrcRoot}/backend/`))) {
  const source = await readText(relativePath);
  for (const token of backendImplementationForbiddenUiTokens) {
    assert(!source.includes(token), `${relativePath} must not depend on frontend Flutter UI via ${token}`);
  }
}

const agentServiceActionsSource = await readDartSourceByBasename("agent_service_actions.dart");
assert(agentServiceActionsSource.includes("'agents'") && agentServiceActionsSource.includes("'pair'"), "agent_service_actions.dart must contain 'agents' and 'pair' tokens for CLI execution");
assert(!agentServiceActionsSource.match(/\[\s*'pair'/), "GUI service layer must not use top-level 'pair' command");
const agentConversationServiceSource = await readDartSourceByBasename("agent_conversation_service.dart");
assert(agentConversationServiceSource.includes("'conversations'") && agentConversationServiceSource.includes("agentService.runCli"),
  "agent_conversation_service.dart must delegate conversation IO to lico-client CLI"
);
assert(agentConversationServiceSource.includes("AgentDispatchLane") &&
  agentConversationServiceSource.includes("implements AgentDispatchLane") &&
  agentConversationServiceSource.includes("'agent'") &&
  agentConversationServiceSource.includes("'message'") &&
  agentConversationServiceSource.includes("'send'") &&
  agentConversationServiceSource.includes("runCliWithStdin") &&
  agentConversationServiceSource.includes("'--stdin-json'") &&
  agentConversationServiceSource.includes("requireReady") &&
  !agentConversationServiceSource.includes("sendRuntimeMessage"),
  "agent_conversation_service.dart must implement AgentDispatchLane and send private runtime requests through the stdin JSON contract"
);
assert(
  (await readDartSourceByBasename("agent_dispatch_lane.dart")).includes("abstract class AgentDispatchLane"),
  "contracts/agent_dispatch_lane.dart must define the unified AgentDispatchLane port"
);
for (const token of ["appendLocalMessage", "deleteSession", "'append'", "'delete'"]) {
  assert(!agentConversationServiceSource.includes(token), `agent_conversation_service.dart must not expose LicoLite-local write path: ${token}`);
}
const conversationsRustSource = await readText("crates/lico-client-native/src/domain/conversations.rs");
assert(
  conversationsRustSource.includes('"native-history"') &&
    conversationsRustSource.includes('"readOnly": true') &&
    conversationsRustSource.includes('"precise-adapter"') &&
    conversationsRustSource.includes("enum HistoryAdapter") &&
    conversationsRustSource.includes("fn adapter_for_agent") &&
    conversationsRustSource.includes("unsupported native history adapter") &&
    conversationsRustSource.includes("ValueRef::Blob") &&
    conversationsRustSource.includes("native agent history is read-only"),
  "native sidecar conversations.rs must expose per-agent precise native history adapters, not LicoLite-local conversation storage"
);
for (const target of packagedTargets) {
  assert(conversationsRustSource.includes(`"${target}"`), `native history scanner must include first-batch target: ${target}`);
}
const agentConversationActionsSource = await readJoinedDartSourcesByBasename([
  "agent_conversation_actions.dart",
  "agent_conversation_messaging_actions.dart",
  "agent_conversation_session_ordering.dart"
]);
assert(!agentConversationActionsSource.includes("conversationService.appendLocalMessage"),
  "agent_conversation_actions.dart must not append LicoLite-local messages for native history"
);
assert(agentConversationActionsSource.includes("conversationService.send(") &&
  !agentConversationActionsSource.includes("sendRuntimeMessage"),
  "agent_conversation messaging must send through AgentDispatchLane instead of local history or legacy sendRuntimeMessage"
);
const agentConversationWorkspaceSource = await readDartSourceByBasename("agent_conversation_workspace.dart");
assert(agentConversationWorkspaceSource.includes("_RuntimeMessageComposer") &&
  agentConversationWorkspaceSource.includes("sendConversationMessage") &&
  agentConversationWorkspaceSource.includes("TextField("),
  "agent_conversation_workspace.dart must expose runtime message composer while keeping history read-only"
);
const cargoToml = await readText("crates/lico-client-native/Cargo.toml");
const mobileRelayRustSource = await readText("crates/lico-client-native/src/domain/mobile_relay.rs");
const secureMeshSecretStoreRustSource =
  await readText("crates/lico-client-native/src/platform/secure_mesh_secret_store.rs");
const macosUserPresenceProofSource =
  await readText("tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs");
const platformSecretStoreMatrixSource =
  await readText("tools/scripts/client-secure-mesh-platform-secret-store-matrix.mjs");
const mobileCommandsSource = await readText("crates/lico-client-native/src/ffi/commands/mobile.rs");
const clientCliVmSource = await readText("tools/scripts/client-cli-vm.mjs");
const runtimeAdaptersRustSource = await readText("crates/lico-client-native/src/platform/runtime_adapters.rs");
const codexAppServerRustSource = await readText("crates/lico-client-native/src/platform/codex_app_server.rs");
assert(runtimeAdaptersRustSource.includes("enum RuntimeAdapter") &&
  runtimeAdaptersRustSource.includes('"runtime-adapter"') &&
  runtimeAdaptersRustSource.includes("PACKAGED_RUNTIME_ADAPTER_IDS") &&
  runtimeAdaptersRustSource.includes("parse_runtime_driver_registry") &&
  runtimeAdaptersRustSource.includes("DRIVER_INVENTORY_JSON") &&
  runtimeAdaptersRustSource.includes("READINESS_JSON") &&
  runtimeAdaptersRustSource.includes("codex_app_server::execute") &&
  runtimeAdaptersRustSource.includes("nativeSessionId") &&
  runtimeAdaptersRustSource.includes("approvalOwner") &&
  codexAppServerRustSource.includes('"codex-app-server-stdio-jsonrpc"') &&
  codexAppServerRustSource.includes('"thread/start"') &&
  codexAppServerRustSource.includes('"thread/resume"') &&
  codexAppServerRustSource.includes('"turn/start"') &&
  codexAppServerRustSource.includes('"turn/completed"') &&
  codexAppServerRustSource.includes("codex_user_interaction_required"),
  "runtime adapters must expose canonical per-agent transports and explicit approval ownership"
);
assert(mobileRelayRustSource.includes("fn relay_capabilities") &&
  mobileRelayRustSource.includes('"commands"') &&
  mobileRelayRustSource.includes("SECURE_MESH_ENVELOPE_COMMAND") &&
  mobileRelayRustSource.includes("mobile_relay_capabilities_advertise_phone_pairing_runtime_commands") &&
  mobileRelayRustSource.includes("MobileRelaySecurePairwiseTransport") &&
  mobileRelayRustSource.includes("reject_plaintext_relay_command") &&
  mobileRelayRustSource.includes("mobile_relay_plaintext_command_rejected") &&
  mobileRelayRustSource.includes("plaintext_relay_commands_are_rejected_without_echoing_payload") &&
  mobileRelayRustSource.includes("secure_mesh_envelope_command_is_transport_only") &&
  mobileRelayRustSource.includes("mobile_relay_public_config_redacts_secret_material") &&
  mobileRelayRustSource.includes("adversarial_loopback_gateway_cannot_read_or_forge_mobile_relay_e2ee") &&
  mobileRelayRustSource.includes("plaintext-canary-compromised-relay"),
  "mobile_relay.rs must advertise only the secure pairwise relay transport and keep compromised-gateway E2EE behavior covered by tests"
);
assert(!mobileRelayRustSource.includes("fn execute_command("),
  "mobile_relay.rs must not keep a plaintext command execution path for relayed server commands"
);
assert(mobileRelayRustSource.includes("RUNTIME_SECRET_OVERRIDE_TRANSPORT") &&
  mobileRelayRustSource.includes('"secretOverrideTransport"') &&
  mobileRelayRustSource.includes("runtime_secret_overrides_require_platform_transport_marker"),
  "mobile_relay.rs must gate runtime secretOverrides behind an explicit platform bridge transport marker"
);
assert(mobileRelayRustSource.includes("SecureMeshPairwiseDurableStore") &&
  mobileRelayRustSource.includes("SecureMeshPairwiseSession::initiate") &&
  mobileRelayRustSource.includes("SecureMeshPairwiseSession::accept") &&
  mobileRelayRustSource.includes("complete_initiator_handshake") &&
  mobileRelayRustSource.includes('"preKeyBundle"') &&
  mobileRelayRustSource.includes('"pairwiseIntro"') &&
  mobileRelayRustSource.includes('"pairwiseAccepted"') &&
  mobileRelayRustSource.includes("mobile_relay_pairwise_initialization_requires_x3dh_prekey_bundle") &&
  mobileRelayRustSource.includes("mobile_relay_pairwise_rejects_tampered_prekey_signature") &&
  mobileRelayRustSource.includes("seal_payload_envelope") &&
  mobileRelayRustSource.includes("open_payload_envelope"),
  "mobile_relay.rs must use X3DH signed-prekey initialization and durable pairwise envelopes"
);
assert(mobileRelayRustSource.includes("mobile_relay_e2ee_secret_store_status") &&
  mobileRelayRustSource.includes("privateKeyBoundToPlatform") &&
  mobileRelayRustSource.includes("signingKeyBoundToPlatform") &&
  mobileRelayRustSource.includes("signedPrekeyPrivateKeyBoundToPlatform") &&
  mobileRelayRustSource.includes("oneTimePrekeyPrivateKeyBoundToPlatform") &&
  mobileRelayRustSource.includes("allPrivateKeysBoundToPlatform") &&
  mobileRelayRustSource.includes("e2ee_status_blocks_production_when_private_key_is_only_in_portable_config") &&
  mobileRelayRustSource.includes("e2ee_status_accepts_mobile_relay_secret_store_override_without_leaking_key_material") &&
  mobileRelayRustSource.includes("with_mobile_relay_secret_store_override") &&
  mobileRelayRustSource.includes("secure_command_create_rejects_raw_runtime_e2ee_secret_overrides") &&
  mobileRelayRustSource.includes("secure_command_create_uses_mobile_relay_secret_store_override_without_raw_e2ee_json") &&
  mobileRelayRustSource.includes("load_config_without_persistence") &&
  mobileRelayRustSource.includes("should_authorize_secret_read") &&
  mobileRelayRustSource.includes("public_config_get_does_not_begin_secret_store_authorization_session") &&
  mobileRelayRustSource.includes("e2ee_status_without_authorization_does_not_begin_secret_store_session") &&
  mobileRelayRustSource.includes("authorizationRequiredForFullStatus") &&
  mobileRelayRustSource.includes("e2ee_status_redacts_pairing_invite_secret"),
  "mobile_relay.rs must expose E2EE production readiness only when all endpoint private keys are platform secret-store bound through callback stores, while public config/status reads remain no-authorize and never hydrate secrets"
);
assert(cargoToml.includes("keyring =") &&
  cargoToml.includes("target_os = \"macos\"") &&
  cargoToml.includes("target_os = \"linux\"") &&
  cargoToml.includes("target_os = \"windows\"") &&
  mobileRelayRustSource.includes("NATIVE_SECRET_STORE_SERVICE") &&
  mobileRelayRustSource.includes("persist_config_secret_material_to_native_store") &&
  mobileRelayRustSource.includes("hydrate_config_secret_material_from_native_store") &&
  mobileRelayRustSource.includes("SecretStoreAuthorizationSession") &&
  mobileRelayRustSource.includes("begin_authorized_session") &&
  mobileRelayRustSource.includes("set_secret_with_session") &&
  mobileRelayRustSource.includes("get_secret_with_session") &&
  mobileRelayRustSource.includes("delete_secret_with_session") &&
  mobileRelayRustSource.includes("struct MobileRelayPairwiseOperation") &&
  mobileRelayRustSource.includes("Mobile Relay secure command operation authorization batch") &&
  mobileRelayRustSource.includes("Mobile Relay secure result operation authorization batch") &&
  mobileRelayRustSource.includes("Mobile Relay secure result replay proof authorization batch") &&
  mobileRelayRustSource.includes("Mobile Relay commands sync operation authorization batch") &&
  mobileRelayRustSource.includes("command_result_secure_reuses_single_operation_auth_batch_for_fetch_and_result_open") &&
  mobileRelayRustSource.includes("command_result_replay_proof_reuses_single_operation_auth_batch_for_fetch_and_replay_check") &&
  mobileRelayRustSource.includes("mobile_relay_commands_sync_reuses_single_operation_auth_batch_for_secure_commands") &&
  mobileRelayRustSource.includes("mobile_relay_secure_command_execute_reuses_single_operation_auth_batch_for_open_and_result_seal") &&
  mobileRelayRustSource.includes("e2ee_secret_store_self_test") &&
  mobileRelayRustSource.includes("MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS") &&
  mobileRelayRustSource.includes("macos-keychain") &&
  mobileRelayRustSource.includes("linux-secret-service-keyring") &&
  mobileRelayRustSource.includes("windows-credential-manager") &&
  mobileCommandsSource.includes('"secret-store-self-test"'),
  "desktop and CLI Mobile Relay E2EE private keys must migrate through a shared native keyring backend on macOS, Linux, and Windows"
);
assert(cargoToml.includes("objc2-local-authentication") &&
  cargoToml.includes("security-framework =") &&
  cargoToml.includes("security-framework-sys =") &&
  secureMeshSecretStoreRustSource.includes("objc2_local_authentication::{LAContext, LAPolicy}") &&
  secureMeshSecretStoreRustSource.includes("LAPolicy::DeviceOwnerAuthentication") &&
  secureMeshSecretStoreRustSource.includes("setTouchIDAuthenticationAllowableReuseDuration") &&
  secureMeshSecretStoreRustSource.includes("setInteractionNotAllowed") &&
  secureMeshSecretStoreRustSource.includes("evaluatePolicy_localizedReason_reply") &&
  secureMeshSecretStoreRustSource.includes("block2::RcBlock::new") &&
  secureMeshSecretStoreRustSource.includes("system_authorization_attempt_count") &&
  secureMeshSecretStoreRustSource.includes("system_authorization_completed") &&
  secureMeshSecretStoreRustSource.includes("kSecUseDataProtectionKeychain") &&
  secureMeshSecretStoreRustSource.includes("kSecUseAuthenticationContext") &&
  secureMeshSecretStoreRustSource.includes("SecAccessControl::create_with_protection") &&
  secureMeshSecretStoreRustSource.includes("ProtectionMode::AccessibleWhenUnlockedThisDeviceOnly") &&
  secureMeshSecretStoreRustSource.includes("kSecAccessControlUserPresence") &&
  secureMeshSecretStoreRustSource.includes("MacosAuthorizationContext") &&
  secureMeshSecretStoreRustSource.includes("LICO_SECURE_MESH_MACOS_USER_PRESENCE_REQUIRED") &&
  secureMeshSecretStoreRustSource.includes("app_password_prompt_used: false"),
  "macOS Secure Mesh secret store must use one shared system LocalAuthentication context with Data Protection Keychain userPresence, not an app password prompt"
);
assert(macosUserPresenceProofSource.includes("productionEntitlementFailClosedReady") &&
  macosUserPresenceProofSource.includes("productionEntitlementGateAccepted") &&
  macosUserPresenceProofSource.includes("productionEntitlementMissingFailClosed") &&
	  macosUserPresenceProofSource.includes("interactiveAuthorizationRequested") &&
	  macosUserPresenceProofSource.includes("interactiveAuthorizationSucceeded") &&
	  macosUserPresenceProofSource.includes("summary.interactiveAuthorizationAttemptCount === 1") &&
	  macosUserPresenceProofSource.includes("options.interactive === true") &&
	  macosUserPresenceProofSource.includes("swiftProofEnv") &&
	  macosUserPresenceProofSource.includes("deleteQuery[kSecUseDataProtectionKeychain as String] = dataProtection") &&
  macosUserPresenceProofSource.includes("dataProtectionSecretReadBlockedOrUnavailable") &&
  macosUserPresenceProofSource.includes("dataProtectionKeychainItemCreatedOnlyWhenProductionEntitled") &&
  platformSecretStoreMatrixSource.includes("productionEntitlementFailClosedReady") &&
  platformSecretStoreMatrixSource.includes("productionEntitlementGateAccepted") &&
  platformSecretStoreMatrixSource.includes("standardKeychainUserPresenceAcceptedForProduction: false") &&
  platformSecretStoreMatrixSource.includes("singleSystemAuthorizationContextVerified") &&
  platformSecretStoreMatrixSource.includes("macosProductionEntitlementFailClosedReady"),
  "macOS Secure Mesh evidence must fail closed until Data Protection Keychain userPresence runs in a production-entitled app context"
);
assert(clientCliVmSource.includes("dbus-run-session") &&
  clientCliVmSource.includes("gnome-keyring-daemon") &&
  clientCliVmSource.includes("secret-store-self-test") &&
  clientCliVmSource.includes("linux-secret-service-keyring") &&
  clientCliVmSource.includes("allPrivateKeysBoundToPlatform") &&
  clientCliVmSource.includes("pairingSecretBoundToPlatform"),
  "Ubuntu CLI VM verifier must exercise Secret Service through dbus-run-session/gnome-keyring and assert platform-bound Mobile Relay E2EE keys"
);
assert(mobileRelayRustSource.includes("SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL") &&
  mobileRelayRustSource.includes("commands_sync_redacts_malicious_relay_crypto_errors") &&
  mobileRelayRustSource.includes("mobile_relay_command_error_result_redacts_internal_detail") &&
  !mobileRelayRustSource.includes("error.to_string()"),
  "mobile_relay.rs must redact endpoint crypto/runtime errors instead of returning raw local details"
);
const secureMeshIosBridgeSource = await readJoinedText([
  "apps/desktop/ios/Runner/SecureMeshIosBridge.swift",
  "apps/desktop/ios/Runner/SecureMeshIosBridge+SecretStore.swift",
  "apps/desktop/ios/Runner/SecureMeshIosBridge+LocalAuth.swift"
]);
const secureMeshIosBridgeHeaderSource = await readText("apps/desktop/ios/Runner/Runner-Bridging-Header.h");
const secureMeshIosFfiSource = await readText("crates/lico-client-native/src/ffi/ios_ffi.rs");
const iosXcodeProjectSource = await readText("apps/desktop/ios/Runner.xcodeproj/project.pbxproj");
const iosRelayVerifierSource = await readText("tools/scripts/client-mobile-relay-ios-e2e.mjs");
const iosRelayIntegrationTestSource = await readText("apps/desktop/integration_test/mobile_relay_ios_e2e_test.dart");
assert(secureMeshIosBridgeSource.includes("mobileRelaySecretOverrideTransport") &&
  secureMeshIosBridgeSource.includes('removeValue(forKey: "secretOverrides")') &&
  secureMeshIosBridgeSource.includes('removeValue(forKey: "secretOverrideTransport")') &&
  secureMeshIosBridgeSource.includes('params["secretOverrideTransport"]') &&
  secureMeshIosBridgeSource.includes("lico_secure_mesh_json_with_secret_store") &&
	  secureMeshIosBridgeSource.includes("LicoSecureMeshSecretStoreCallbacks") &&
	  secureMeshIosBridgeSource.includes("SecureMeshIosSecretStoreCallbackContext") &&
	  secureMeshIosBridgeSource.includes("kSecUseAuthenticationContext") &&
	  secureMeshIosBridgeSource.includes("callbackSecretReadCount") &&
	  secureMeshIosBridgeSource.includes("iosProductionCallbackAuth") &&
	  secureMeshIosBridgeSource.includes("iosCallbackReadsUseSharedLAContext") &&
	  secureMeshIosBridgeSource.includes("iosSingleSystemAuthorizationContextVerified") &&
	  secureMeshIosBridgeSource.includes("iosCallbackAuthContextAttachedToAllReads") &&
	  secureMeshIosBridgeSource.includes("iosSecretStoreSetCallback") &&
  secureMeshIosBridgeSource.includes("iosSecretStoreGetCallback") &&
  secureMeshIosBridgeSource.includes("iosSecretStoreDeleteCallback") &&
  secureMeshIosBridgeSource.includes("mobileRelayE2eeSecretStore") &&
  secureMeshIosBridgeSource.includes("rawJsonSecretOverridesUsed") &&
  secureMeshIosBridgeSource.includes("mobileRelaySecretStoreBackend") &&
  secureMeshIosBridgeSource.includes("ios-keychain") &&
  secureMeshIosBridgeHeaderSource.includes("LicoSecureMeshSecretStoreCallbacks") &&
  secureMeshIosBridgeHeaderSource.includes("lico_secure_mesh_json_with_secret_store") &&
  secureMeshIosFfiSource.includes("struct IosCallbackSecretStore") &&
  secureMeshIosFfiSource.includes("impl SecureMeshSecretStore for IosCallbackSecretStore") &&
  secureMeshIosFfiSource.includes("dispatch_json_with_files_dir_and_pairwise_secret_store") &&
  secureMeshIosFfiSource.includes("ios_callback_secret_store_round_trips_opaque_handles") &&
  !secureMeshIosBridgeSource.includes('overrides["mobileRelayE2ee"]') &&
  !secureMeshIosBridgeSource.includes('overrides["pcToken"]') &&
  !secureMeshIosBridgeSource.includes('overrides["mobileToken"]') &&
  !secureMeshIosBridgeSource.includes('overrides["pairedDevices"]') &&
  secureMeshIosBridgeSource.includes('"signingKeyBase64url"') &&
  secureMeshIosBridgeSource.includes('"signedPrekeyPrivateKeyBase64url"') &&
  secureMeshIosBridgeSource.includes('"oneTimePrekeyPrivateKeyBase64url"') &&
  secureMeshIosBridgeSource.includes('"e2eePairingSecret"') &&
  secureMeshIosBridgeSource.includes('"e2eePairingSecretMaterial"'),
  "SecureMeshIosBridge.swift must strip caller-supplied secretOverrides, inject the platform bridge marker plus opaque Keychain secret-store handle metadata, call Rust through the callback secret-store C ABI, and redact persisted Mobile Relay X3DH secrets without raw E2EE JSON overrides"
);
assert(iosRelayVerifierSource.includes("integration_test/mobile_relay_ios_e2e_test.dart") &&
  iosRelayVerifierSource.includes("--dart-define-from-file") &&
  iosRelayVerifierSource.includes("--allow-public-console") &&
  iosRelayVerifierSource.includes("desktopGateway") &&
  iosRelayVerifierSource.includes("deviceGateway") &&
  iosRelayVerifierSource.includes("gatewayUrl: deviceGateway") &&
  iosRelayVerifierSource.includes('"pairing", "status"') &&
  iosRelayVerifierSource.includes('"commands", "sync"') &&
	  iosRelayVerifierSource.includes("LICO_IOS_MOBILE_RELAY_E2E_SUMMARY") &&
	  iosRelayVerifierSource.includes("iosProductionCallbackAuth") &&
	  iosRelayVerifierSource.includes("iosCallbackReadsUseSharedLAContext") &&
	  iosRelayVerifierSource.includes("iosSingleSystemAuthorizationContextVerified") &&
	  iosRelayVerifierSource.includes("iosCallbackAuthContextAttachedToAllReads") &&
	  iosRelayVerifierSource.includes("appPasswordPromptUsedPresent") &&
	  iosRelayVerifierSource.includes("appCredentialPromptUsedPresent") &&
	  iosRelayVerifierSource.includes("keyMaterialExportedPresent") &&
	  !iosRelayVerifierSource.includes("configuredGatewayHost") &&
  !iosRelayVerifierSource.includes("deviceGatewayHost") &&
  iosRelayIntegrationTestSource.includes("IntegrationTestWidgetsFlutterBinding") &&
  iosRelayIntegrationTestSource.includes("SecureMeshIosBridge") &&
  iosRelayIntegrationTestSource.includes("mobile.relay.e2ee.status") &&
  iosRelayIntegrationTestSource.includes("mobile.relay.commands.createSecure") &&
	  iosRelayIntegrationTestSource.includes("mobile.relay.commands.resultSecure") &&
	  iosRelayIntegrationTestSource.includes("iosProductionCallbackAuth") &&
	  iosRelayIntegrationTestSource.includes("callbackSecretReadCount") &&
	  iosRelayIntegrationTestSource.includes("appPasswordPromptUsedPresent") &&
	  iosRelayIntegrationTestSource.includes("allPrivateKeysBoundToPlatform") &&
  iosRelayIntegrationTestSource.includes("portableConfigPrivateKeyPresent") &&
  iosRelayIntegrationTestSource.includes("iOS Keychain"),
  "iOS real-device Mobile Relay verifier must drive the Keychain bridge via Flutter integration tests, assert encrypted command/result flow, and avoid printing local gateway/device identifiers"
);
assert(iosXcodeProjectSource.includes("NATIVE_ARCH_ACTUAL") &&
  iosXcodeProjectSource.includes("undefined_arch") &&
  iosXcodeProjectSource.includes("aarch64-apple-ios-sim") &&
  iosXcodeProjectSource.includes("x86_64-apple-ios") &&
  iosXcodeProjectSource.includes("SecureMeshIosBridge+SecretStore.swift in Sources") &&
  iosXcodeProjectSource.includes("SecureMeshIosBridge+LocalAuth.swift in Sources"),
  "iOS Secure Mesh native build phase must resolve simulator Rust targets and compile split bridge extension files"
);
const secureMeshAndroidBridgeSource = await readText("apps/desktop/android/app/src/main/kotlin/com/liko/arc/MainActivity.kt");
const secureMeshAndroidSecretStoreSource = await readText("apps/desktop/android/app/src/main/kotlin/com/liko/arc/SecureMeshAndroidSecretStore.kt");
const secureMeshAndroidUserAuthenticatorSource =
  await readText("apps/desktop/android/app/src/main/kotlin/com/liko/arc/SecureMeshAndroidUserAuthenticator.kt");
const secureMeshAndroidAuthorizationPolicyTestSource =
  await readText("apps/desktop/android/app/src/test/kotlin/com/liko/arc/SecureMeshAndroidAuthorizationPolicyTest.kt");
const secureMeshAndroidManifestSource =
  await readText("apps/desktop/android/app/src/main/AndroidManifest.xml");
const secureMeshAndroidAuthBoundarySource = [
  secureMeshAndroidBridgeSource,
  secureMeshAndroidUserAuthenticatorSource
].join("\n");
assert(secureMeshAndroidBridgeSource.includes("SecureMeshAndroidSecretStore(filesDir)") &&
  secureMeshAndroidBridgeSource.includes("SecureMeshAndroidUserAuthenticator(this)") &&
  secureMeshAndroidBridgeSource.includes("private fun authorizeSecureMeshAction") &&
  secureMeshAndroidBridgeSource.includes('request.optBoolean("authorize", false)') &&
  secureMeshAndroidBridgeSource.includes("interactionAuthorized = allowPrompt") &&
  secureMeshAndroidBridgeSource.includes("authorizeSensitiveAction(action)") &&
  secureMeshAndroidBridgeSource.includes("hasActiveAuthorizationGrant()") &&
  secureMeshAndroidBridgeSource.includes("SECURE_MESH_NATIVE_EXPECTED_FEATURE_FLAGS = 223") &&
  secureMeshAndroidBridgeSource.includes("diagnostic_blocked_identity_welcome_and_membership_policy_unbound") &&
  secureMeshAndroidBridgeSource.includes('"mlsRuntimeReady" to false') &&
  secureMeshAndroidBridgeSource.includes('"mlsRuntimeFeatureEnabled" to false') &&
  secureMeshAndroidBridgeSource.includes("SECURE_MESH_DIAGNOSTIC_FILE_NAMES") &&
  !secureMeshAndroidBridgeSource.includes(".walkTopDown()") &&
  secureMeshAndroidBridgeSource.includes("secureMeshAndroidUserAuthenticator.request(params)") &&
  secureMeshAndroidBridgeSource.includes("secureMeshAndroidUserAuthenticator.status()") &&
  secureMeshAndroidBridgeSource.includes("secureMeshAndroidUserAuthenticator.onActivityResult(requestCode, resultCode)") &&
  secureMeshAndroidBridgeSource.includes("secureMeshAndroidSecretStore.requestTextWithMobileRelaySecretOverrides") &&
  secureMeshAndroidBridgeSource.includes("secureMeshAndroidSecretStore.captureMobileRelaySecretsFromNativeResponse") &&
  secureMeshAndroidBridgeSource.includes("secureMeshAndroidSecretStore.redactPersistedMobileRelaySecrets") &&
  secureMeshAndroidBridgeSource.includes("secretStoreBridge: SecureMeshAndroidSecretStore") &&
  secureMeshAndroidBridgeSource.includes("private fun runNativeSecureMeshJsonObject") &&
  secureMeshAndroidBridgeSource.includes("secureMeshAndroidSecretStore.captureMobileRelaySecretsFromNativeResponse(responseJson)") &&
  !secureMeshAndroidBridgeSource.includes("filesDir.absolutePath\n        )") &&
  !secureMeshAndroidBridgeSource.includes("fun secureMeshAndroidSecretStoreSet") &&
  !secureMeshAndroidBridgeSource.includes("ANDROID_MOBILE_RELAY_SECRET_STORE_KEY_ALIAS") &&
  secureMeshAndroidSecretStoreSource.includes("class SecureMeshAndroidSecretStore") &&
  secureMeshAndroidSecretStoreSource.includes("MOBILE_RELAY_SECRET_OVERRIDE_TRANSPORT") &&
  secureMeshAndroidSecretStoreSource.includes("requestTextWithMobileRelaySecretOverrides") &&
  secureMeshAndroidSecretStoreSource.includes('params.remove("secretOverrides")') &&
  secureMeshAndroidSecretStoreSource.includes('params.remove("secretOverrideTransport")') &&
  secureMeshAndroidSecretStoreSource.includes('params.put("secretOverrideTransport", MOBILE_RELAY_SECRET_OVERRIDE_TRANSPORT)') &&
  secureMeshAndroidSecretStoreSource.includes('"mobileRelayE2eeSecretStore"') &&
  secureMeshAndroidSecretStoreSource.includes('"rawJsonSecretOverridesUsed"') &&
  !secureMeshAndroidSecretStoreSource.includes('overrides.put("mobileRelayE2ee"') &&
  !secureMeshAndroidSecretStoreSource.includes('overrides.put("pcToken"') &&
  !secureMeshAndroidSecretStoreSource.includes('overrides.put("mobileToken"') &&
  !secureMeshAndroidSecretStoreSource.includes('overrides.put("pairedDevices"') &&
  secureMeshAndroidSecretStoreSource.includes("android-mobile-relay-secrets") &&
  secureMeshAndroidSecretStoreSource.includes("mobileRelaySecretStoreStatus") &&
  secureMeshAndroidSecretStoreSource.includes('"signingKeyBase64url"') &&
  secureMeshAndroidSecretStoreSource.includes('"signedPrekeyPrivateKeyBase64url"') &&
  secureMeshAndroidSecretStoreSource.includes('"oneTimePrekeyPrivateKeyBase64url"') &&
  secureMeshAndroidSecretStoreSource.includes('"e2eePairingSecret"') &&
  secureMeshAndroidSecretStoreSource.includes('"e2eePairingSecretMaterial"') &&
  secureMeshAndroidSecretStoreSource.includes("setUserAuthenticationRequired(true)") &&
  secureMeshAndroidSecretStoreSource.includes("setUserAuthenticationParameters") &&
  secureMeshAndroidSecretStoreSource.includes("AUTH_DEVICE_CREDENTIAL") &&
  secureMeshAndroidSecretStoreSource.includes("AUTH_BIOMETRIC_STRONG") &&
  secureMeshAndroidSecretStoreSource.includes("authorizationGrantIsActive") &&
  secureMeshAndroidSecretStoreSource.includes("requireActiveUserAuthorization") &&
  !secureMeshAndroidBridgeSource.includes("contentKeyBase64url") &&
  !secureMeshAndroidBridgeSource.includes("includeBodyBase64url") &&
  secureMeshAndroidUserAuthenticatorSource.includes("class SecureMeshAndroidUserAuthenticator") &&
  secureMeshAndroidUserAuthenticatorSource.includes("KeyguardManager") &&
  secureMeshAndroidUserAuthenticatorSource.includes("BiometricPrompt") &&
  secureMeshAndroidUserAuthenticatorSource.includes("BIOMETRIC_STRONG") &&
  secureMeshAndroidUserAuthenticatorSource.includes("DEVICE_CREDENTIAL") &&
  secureMeshAndroidUserAuthenticatorSource.includes("SystemClock.elapsedRealtime()") &&
  secureMeshAndroidUserAuthenticatorSource.includes("authorizationGrantExtendedByDispatch") &&
  secureMeshAndroidUserAuthenticatorSource.includes("mayStartAuthenticationPrompt") &&
  secureMeshAndroidAuthorizationPolicyTestSource.includes("unknownActionsFailClosed") &&
  secureMeshAndroidAuthorizationPolicyTestSource.includes("passiveOAuthCallbackCannotStartOrExtendAuthentication") &&
  secureMeshAndroidManifestSource.includes("android.permission.USE_BIOMETRIC") &&
  secureMeshAndroidUserAuthenticatorSource.includes("createConfirmDeviceCredentialIntent") &&
  secureMeshAndroidUserAuthenticatorSource.includes("physicalUserPresenceRequired") &&
  secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptAvailable") &&
  secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptStarted") &&
  secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptCompleted") &&
  secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptResultCodePresent") &&
  secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptResultCode") &&
  secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptResult") &&
  secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptReusedFromPendingRequest") &&
  secureMeshAndroidUserAuthenticatorSource.includes("pendingLatch") &&
  secureMeshAndroidUserAuthenticatorSource.includes("userActionRequired") &&
	  secureMeshAndroidUserAuthenticatorSource.includes("credentialEntrySurface") &&
	  secureMeshAndroidUserAuthenticatorSource.includes("android_system_credential_prompt") &&
	  secureMeshAndroidUserAuthenticatorSource.includes("systemAuthenticationOnly") &&
	  secureMeshAndroidUserAuthenticatorSource.includes("appLockScreenCredentialCollection") &&
	  secureMeshAndroidUserAuthenticatorSource.includes("appCredentialPromptUsed") &&
	  secureMeshAndroidUserAuthenticatorSource.includes("appPasswordPromptUsed") &&
	  secureMeshAndroidUserAuthenticatorSource.includes("keyMaterialExported") &&
  secureMeshAndroidBridgeSource.includes("bodyRedacted") &&
  !secureMeshAndroidSecretStoreSource.includes("setUserAuthenticationRequired(false)"),
  "Android Secure Mesh must keep system credential prompting in SecureMeshAndroidUserAuthenticator.kt while MainActivity delegates and Mobile Relay secret-store redaction, override injection, and AndroidKeyStore-backed records live in SecureMeshAndroidSecretStore.kt"
);
assert(!secureMeshAndroidBridgeSource.includes("ChaCha20-Poly1305") &&
  !secureMeshAndroidBridgeSource.includes("HmacSHA256") &&
  !secureMeshAndroidBridgeSource.includes("SecretKeySpec(derivedKey") &&
  !secureMeshAndroidBridgeSource.includes("contentKeyBase64url") &&
  !secureMeshAndroidBridgeSource.includes("includeBodyBase64url"),
  "Android Secure Mesh must not expose raw payload keys or plaintext body export through native actions"
);
for (const forbiddenToken of [
  "lockScreenPassword",
  "screenLockPassword",
  "devicePassword",
	  "deviceCredentialPassword",
	  "devicePasswordInput",
	  "userEnteredPassword",
	  "appLockPassword",
		  ".put(\"appCredentialPromptUsed\", true)",
		  ".put(\"appPasswordPromptUsed\", true)",
		  ".put(\"appLockScreenCredentialCollection\", true)",
		  "\"appCredentialPromptUsed\" to true",
		  "\"appPasswordPromptUsed\" to true",
		  "\"appLockScreenCredentialCollection\" to true",
		  "appCredentialPromptUsed = true",
		  "appPasswordPromptUsed = true",
		  "appLockScreenCredentialCollection = true",
		]) {
  assert(!secureMeshAndroidAuthBoundarySource.includes(forbiddenToken),
    `Android platform auth files must not collect lock-screen credentials in-app via ${forbiddenToken}`);
}
const androidPairingVerifierSource = await readText("tools/scripts/client-pairing-verify.mjs");
const androidHostileVerifierSource = await readText("tools/scripts/client-mobile-relay-hostile-server-canary.mjs");
assert(secureMeshAndroidBridgeSource.includes("SAFE_SECURE_MESH_ADB_STATUS_KEYS") &&
  secureMeshAndroidBridgeSource.includes('"allPrivateKeysBoundToPlatform"') &&
  androidPairingVerifierSource.includes("assertAndroidE2eeSecretStoreReady") &&
  androidPairingVerifierSource.includes("mobile.relay.e2ee.status") &&
  androidPairingVerifierSource.includes("allPrivateKeysBoundToPlatform") &&
  androidPairingVerifierSource.includes("assertAndroidSystemCredentialPromptStarted") &&
  androidPairingVerifierSource.includes("android_system_credential_prompt_not_completed_by_user") &&
  androidPairingVerifierSource.includes("systemPromptNotCompleted") &&
  androidHostileVerifierSource.includes("assertAndroidE2eeSecretStoreReady") &&
  androidHostileVerifierSource.includes("mobile.relay.e2ee.status") &&
  androidHostileVerifierSource.includes("allPrivateKeysBoundToPlatform"),
  "Android real-device Mobile Relay verifiers must assert KeyStore-bound E2EE private-key status without exposing secret values"
);
const secureMeshCommandRustSource = await readText("crates/lico-client-native/src/core/secure_mesh_command.rs");
assert(secureMeshCommandRustSource.includes("LOCAL_EXECUTION_FAILED_REMOTE_DETAIL") &&
  secureMeshCommandRustSource.includes("secure_mesh_command_execution_redacts_executor_error_detail") &&
  secureMeshCommandRustSource.includes("local-secret-canary") &&
  !secureMeshCommandRustSource.includes("&error.to_string()"),
  "secure_mesh_command.rs must not return raw local executor errors over Secure Mesh results"
);
const secureMeshFileRustSource = await readText("crates/lico-client-native/src/core/secure_mesh_file.rs");
assert(secureMeshFileRustSource.includes("file_manifest_delivery_json") &&
  secureMeshFileRustSource.includes("file_chunk_delivery_json") &&
  secureMeshFileRustSource.includes("secure_mesh_file_delivery_json_hides_manifest_and_chunk_plaintext") &&
  secureMeshFileRustSource.includes("evaluate_file_handoff_proof_json") &&
  secureMeshFileRustSource.includes("secure_mesh_file_handoff_proof_reseals_distinct_ciphertext_for_multiple_recipients") &&
  secureMeshFileRustSource.includes("multiRecipientIndependentResealReady") &&
  secureMeshFileRustSource.includes("file-body-plaintext-secret-canary-content"),
  "secure_mesh_file.rs must expose tested server-visible delivery JSON and multi-recipient handoff reseal proof without file metadata or chunk plaintext"
);
assert(secureMeshFileRustSource.includes("evaluate_file_receive_destination_json") &&
  secureMeshFileRustSource.includes("evaluate_file_receive_confirmation_json") &&
  secureMeshFileRustSource.includes("secure_mesh.file_receive.write") &&
  secureMeshFileRustSource.includes("secure_mesh.file_receive.confirm") &&
  secureMeshFileRustSource.includes("secure_mesh_file_receive_destination_redacts_local_paths_and_metadata") &&
  secureMeshFileRustSource.includes("secure_mesh_file_receive_destination_rejects_unapproved_paths") &&
  secureMeshFileRustSource.includes("secure_mesh_file_receive_confirmation_requires_user_action_and_disables_auto_open"),
  "secure_mesh_file.rs must keep local receive destination and confirmation policy covered by redaction and fail-closed tests"
);
const secureMeshCliSource = await readText("crates/lico-client-native/src/ffi/commands/secure_mesh.rs");
assert(secureMeshCliSource.includes('"receive-destination"') &&
  secureMeshCliSource.includes('"receive-confirmation"') &&
  secureMeshCliSource.includes("evaluate_file_receive_destination_json") &&
  secureMeshCliSource.includes("evaluate_file_receive_confirmation_json") &&
  secureMeshCliSource.includes("secure_mesh_file_receive_destination_cli_redacts_destination_paths") &&
  secureMeshCliSource.includes("secure_mesh_file_receive_confirmation_cli_requires_user_confirmation_without_auto_open"),
  "secure-mesh CLI must expose receive-destination and receive-confirmation policy evaluation without leaking destination paths"
);
const secureMeshMobileFfiSource = await readText("crates/lico-client-native/src/ffi/secure_mesh_mobile_ffi.rs");
assert(secureMeshMobileFfiSource.includes('"secure_mesh.file.route"') &&
  secureMeshMobileFfiSource.includes('"secure_mesh.file.receiveDestination"') &&
  secureMeshMobileFfiSource.includes('"secure_mesh.file.receiveConfirmation"') &&
  secureMeshMobileFfiSource.includes('"secure_mesh.file.handoffProof"') &&
  secureMeshMobileFfiSource.includes('"secure_mesh.lifecycle.serviceAction"') &&
  secureMeshMobileFfiSource.includes("FEATURE_LIFECYCLE_SERVICE_ACTIONS") &&
  !secureMeshMobileFfiSource.includes("contentKeyBase64url") &&
  !secureMeshMobileFfiSource.includes("includeBodyBase64url") &&
  secureMeshMobileFfiSource.includes("mobile_ffi_exposes_shared_file_route_and_receive_destination_policy") &&
  secureMeshMobileFfiSource.includes("mobile_ffi_exposes_shared_file_handoff_reseal_proof_without_plaintext") &&
  secureMeshMobileFfiSource.includes("mobile_ffi_exposes_shared_lifecycle_service_actions_without_plaintext"),
  "mobile Secure Mesh FFI must expose file and lifecycle policy actions without raw payload-key or plaintext-body actions"
);
const mobileRelayServiceSource = await readJoinedDartSourcesByBasename([
  "mobile_relay_service.dart",
  "mobile_relay_service_ops.dart"
]);
assert(mobileRelayServiceSource.includes("'mobile'") && mobileRelayServiceSource.includes("'relay'") && mobileRelayServiceSource.includes("agentService.runCli"),
  "mobile_relay_service.dart must delegate relay network/config operations to lico-client CLI"
);
const mobileRelaySecureMeshServiceSource = await readJoinedDartSourcesByBasename([
  "mobile_relay_secure_mesh_service.dart",
  "mobile_relay_service_ops.dart"
]);
assert(mobileRelayServiceSource.includes("evaluateSecureMeshFileReceiveDestination") &&
  mobileRelayServiceSource.includes("evaluateSecureMeshFileReceiveConfirmation") &&
  mobileRelaySecureMeshServiceSource.includes("'mobile.relay.e2ee.status'") &&
  mobileRelaySecureMeshServiceSource.includes("mobileRelayE2eeSecretStore") &&
  mobileRelaySecureMeshServiceSource.includes("'secure_mesh.file.receiveDestination'") &&
  mobileRelaySecureMeshServiceSource.includes("'secure_mesh.file.receiveConfirmation'") &&
  mobileRelaySecureMeshServiceSource.includes("'receive-destination'") &&
  mobileRelaySecureMeshServiceSource.includes("'receive-confirmation'"),
  "mobile relay service must route E2EE status and file receive-destination/confirmation policy through mobile native FFI and desktop CLI"
);
const futureClientControllerSource = await readDartSourceByBasename("future_client_controller.dart");
const controllerLifecycleActionsSource = await readDartSourceByBasename("controller_lifecycle_actions.dart");
const secureMeshActionsSource = await readDartSourceByBasename("secure_mesh_actions.dart");
assert(controllerLifecycleActionsSource.includes("authorizeSecrets: false") &&
  !controllerLifecycleActionsSource.includes("_refreshSecureMeshStatusSilently") &&
  !controllerLifecycleActionsSource.includes("refreshMobileProviderOAuthCredentials(silent: true)") &&
  !controllerLifecycleActionsSource.includes("syncMobileProviderCredentialsFromDesktopRelay(silent: true)") &&
  !controllerLifecycleActionsSource.includes("startMobileRelayPolling()") &&
  !controllerLifecycleActionsSource.includes("scanTargets()"),
  "controller lifecycle initialization must load only public Mobile Relay config and must not trigger Secure Mesh status, OAuth credential checks, relay credential sync, relay polling, or target scanning"
);
assert(futureClientControllerSource.includes("secureMeshFileReceiveDestination") &&
  secureMeshActionsSource.includes("evaluateSecureMeshFileReceiveDestination"),
  "future client controller must retain Secure Mesh file receive-destination policy state"
);
const mobileRelayPanelSource = await readDartSourceByBasename("mobile_relay_panel.dart");
assert(!mobileRelayPanelSource.includes("mobileRelayE2eeStatus") &&
  !mobileRelayPanelSource.includes("mobileRelayE2eeSecretStore") &&
  !mobileRelayPanelSource.includes("_e2eeReadinessText") &&
  !mobileRelayPanelSource.includes("_secretStoreText") &&
  !mobileRelayPanelSource.includes("pairwiseCryptoStatus"),
  "mobile relay panel must not expose Secure Mesh diagnostic state"
);
const clientLogExportServiceSource = await readDartSourceByBasename("client_log_export_service.dart");
const clientShellSource = await readDartSourceByBasename("client_shell.dart");
const futureClientModelsSource = await readDartSourceByBasename("future_client_models.dart");
assert(clientLogExportServiceSource.includes("activityLogFile") && clientLogExportServiceSource.includes("openRead") && clientLogExportServiceSource.includes("openWrite"),
  "client_log_export_service.dart must export the portable activity log without rendering it as a standalone page"
);
assert(futureClientModelsSource.includes("enum FutureClientSection") &&
  clientShellSource.includes("FutureClientSection.agents => AgentsCanvas") &&
  clientShellSource.includes("FutureClientSection.feed => AgentFeedHome") &&
  clientShellSource.includes("FutureClientSection.mcpPlugins => McpPluginsPanel") &&
  clientShellSource.includes("FutureClientSection.skillHub => SkillHubPanel") &&
  clientShellSource.includes("FutureClientSection.localRuntime => LocalRuntimePanel") &&
  clientShellSource.includes("FutureClientSection.mobileRelay => MobileRelayPanel") &&
  clientShellSource.includes("FutureClientSection.settings => SettingsPanel"),
  "future client shell must expose only the current top-level section bodies"
);
for (const [relativePath, source] of [
  ["agent_conversation_service.dart", agentConversationServiceSource],
  ["mobile_relay_service.dart", mobileRelayServiceSource]
]) {
  for (const token of ["HttpClient", "/api/mobile-relay", "readAsString", "writeAsString", "Directory(", "File("]) {
    assert(!source.includes(token), `${relativePath} must not perform runtime IO/network directly; use lico-client CLI`);
  }
}

const defaultGuiSurfaceBasenames = defaultGuiSurfacePaths.map((relativePath) => path.basename(relativePath));
for (const basename of defaultGuiSurfaceBasenames) {
  const relativePath = await resolveDartSourceByBasename(basename);
  const source = relativePath ? await readText(relativePath) : "";
  const lineCount = source.split(/\r?\n/).length;
  assert(lineCount <= defaultGuiMaxLines, `${relativePath || basename} must stay below ${defaultGuiMaxLines} lines; split cohesive modules instead of growing a super-file`);
}
const shellSource = (await Promise.all(
  defaultGuiSurfaceBasenames.map((basename) => readDartSourceByBasename(basename))
)).join("\n");
for (const label of ["Agents", "MCP Plugins", "Skill Hub", "Runtime", "Mobile Relay", "Settings"]) {
  assert(shellSource.includes(label), `future client shell must expose module label: ${label}`);
}

// New P0 checks

// 3. mcp_trust.rs must not contain handshakeVerified or metadata.signature direct trust
const mcpTrustSource = await readText("crates/lico-client-native/src/domain/mcp_trust.rs");
assert(!mcpTrustSource.includes("handshakeVerified") && !mcpTrustSource.includes("DevUnverifiedOverride"),
  "mcp_trust.rs must not contain handshakeVerified boolean trust or DevUnverifiedOverride in production code"
);
assert(mcpTrustSource.includes("verify_endpoint_trust_with_env") || mcpTrustSource.includes("TrustReceipt"),
  "mcp_trust.rs must implement receipt-based verification"
);

// 5. targets.rs must have unified adapter_capabilities function, not multiple hardcoded lists
const targetsSource = await readText("crates/lico-client-native/src/domain/targets.rs");
const supportsApplyMatches = targetsSource.match(/matches!\([\s\S]*?"openclaw".*?"kilo-code"\)/);
assert(supportsApplyMatches === null,
  "targets.rs must not contain duplicate supports_apply list; use adapter_capabilities_for or adapter_supports_action"
);
assert(targetsSource.includes("adapter_supports_action") || targetsSource.includes("adapter_capabilities_for"),
  "targets.rs must contain unified adapter capability function"
);
assert(targetsSource.includes('"runtime.message.send"') &&
  targetsSource.includes("candidate_runtime_is_ready") &&
  targetsSource.includes("runtime_evidence_matches"),
  "targets.rs must advertise runtime.message.send only through the candidate evidence gate"
);
assert(targetsSource.includes("runtime_driver_profile") &&
  targetsSource.includes('conversation_readiness = "ready"') &&
  targetsSource.includes("ready_runtime_executable"),
  "runtime.message.send must require canonical readiness and an exact local executable binding"
);
const targetCandidateSource = await readText("apps/desktop/lib/src/contracts/target_candidate.dart");
assert(targetCandidateSource.includes("conversationReadiness == 'ready'") &&
  targetCandidateSource.includes("supportsAction('runtime.message.send')"),
  "desktop runtime sending must require both reducer-owned ready and the advertised action"
);

// 6. mcp_plugins.rs must not unconditionally return status updated
const mcpPluginsSource = await readText("crates/lico-client-native/src/domain/mcp_plugins.rs");
const alwaysUpdatedStatus = mcpPluginsSource.match(/"updated"/);
assert(mcpPluginsSource.includes("apply_ok") || !mcpPluginsSource.includes('"updated"'),
  "mcp_plugins.rs must conditionally set status based on apply result"
);

// 7. mcp_plugins_panel.dart must reference supportedActions or supportsAction
const mcpPluginsPanelSource = await readDartSourceByBasename("mcp_plugins_panel.dart");
assert(mcpPluginsPanelSource.includes("supportedAction") || mcpPluginsPanelSource.includes("canUpdateMcpPlugin") ||
  mcpPluginsPanelSource.includes("canRollbackMcpPlugin"),
  "mcp_plugins_panel.dart must reference target capability methods"
);

// 8. mcp_plugin_actions.dart must not show success on result['ok'] false
const mcpPluginActionsSource = await readDartSourceByBasename("mcp_plugin_actions.dart");
assert(!mcpPluginActionsSource.includes('无条件') && mcpPluginActionsSource.includes("result['ok']"),
  "mcp_plugin_actions.dart must check result['ok'] before showing success"
);

// 9. set_json_path must not directly overwrite non-object
const setJsonPathMatch = targetsSource.match(/\*entry\s*=\s*Value::Object/);
assert(setJsonPathMatch === null,
  "set_json_path must not silently overwrite non-object paths with Value::Object"
);

// 10. list_model_profiles output must use masking
const forwardingSource = await readText("crates/lico-client-native/src/domain/forwarding.rs");
assert(forwardingSource.includes("mask_profile_secrets") || forwardingSource.includes('"***"'),
  "forwarding.rs list_model_profiles must mask secret values"
);
assert(forwardingSource.includes("PROVIDER_CREDENTIAL_REF_SCHEMA_VERSION") &&
  forwardingSource.includes("providerCredentialRef") &&
  forwardingSource.includes("PlatformSecretStore::new") &&
  forwardingSource.includes("store_provider_credential_secret") &&
  forwardingSource.includes("read_provider_credential_secret") &&
  forwardingSource.includes("remove_provider_credential_headers") &&
  forwardingSource.includes("list_model_profiles_uses_platform_secret_ref_for_api_key_secrets") &&
  forwardingSource.includes("credentialStorage") &&
  forwardingSource.includes("platform-secret-store"),
  "forwarding.rs must store provider API keys in the native platform secret store and persist only providerCredentialRef metadata"
);
assert(!forwardingSource.includes("assert!(raw.contains(\"Bearer deepseek-secret\")") &&
  !forwardingSource.includes("assert!(raw.contains(\"secret-value\")") &&
  !forwardingSource.includes("assert!(raw.contains(\"\\\"Authorization\\\"\")"),
  "forwarding.rs tests must not assert provider API key plaintext/header persistence in model-forwarding/profiles.json"
);

if (failures.length > 0) {
  console.error(JSON.stringify({ ok: false, failures }, null, 2));
  process.exit(1);
}

console.log(JSON.stringify({
  ok: true,
  futureModules,
  packagedTargets,
  packagePlanCheckedPlatforms
}, null, 2));
