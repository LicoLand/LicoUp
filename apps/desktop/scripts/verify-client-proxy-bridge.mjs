#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { atomicWriteReportJson } from "../../../tools/scripts/lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const reportRef = "build/reports/client-proxy-bridge.json";
const failures = [];

function assert(condition, message) {
  if (!condition) failures.push(message);
}

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

const native = await readText("crates/lico-client-native/src/domain/proxy_bridge.rs");
const commandMod = await readText("crates/lico-client-native/src/ffi/commands/mod.rs");
const commandProxy = await readText("crates/lico-client-native/src/ffi/commands/proxy_bridge.rs");
const stateStore = await readText("crates/lico-client-native/src/platform/client_state.rs");
const agentService = await readText("apps/desktop/lib/src/platform/native_client/agent_service.dart");
const agentActions = await readText("apps/desktop/lib/src/platform/native_client/agent_service_actions.dart");
const proxyServiceActions = await readText("apps/desktop/lib/src/platform/native_client/proxy_bridge_service_actions.dart");
const controller = await readText("apps/desktop/lib/src/application/controller/client_controller.dart");
const controllerActions = await readText("apps/desktop/lib/src/application/features/settings/controller/proxy_bridge_actions.dart");
const settingsUi = await readText("apps/desktop/lib/src/frontend/features/settings/ui/proxy_bridge_settings.dart");
const settingsPanel = await readText("apps/desktop/lib/src/frontend/features/settings/ui/settings_panel.dart");
const serviceTest = await readText("apps/desktop/test/agent_service_test.dart");
const settingsTest = await readText("apps/desktop/test/settings_panel_test.dart");
const clientDocs = await readText("docs/functionality/CLIENT-DESKTOP.md");
const readme = await readText("apps/desktop/README.md");

for (const token of [
  "proxy-bridge",
  "detect",
  "status",
  "plan",
  "apply",
  "rollback",
  "willModifyClashConfig",
  "transparentTrafficHijack",
  "managedWrapperDirectoryOnly",
  "tunAssist",
  "PROCESS-NAME",
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "ALL_PROXY",
  "NO_PROXY"
]) {
  assert(native.includes(token), `proxy_bridge.rs must include ${token}`);
}

assert(commandMod.includes("proxy_bridge::register_commands"), "command table must register proxy_bridge commands");
assert(commandProxy.includes('"proxy-bridge", "detect"') &&
  commandProxy.includes('"proxy-bridge", "apply"') &&
  commandProxy.includes('"proxy-bridge", "rollback"'),
  "proxy_bridge command module must expose detect/apply/rollback");
assert(stateStore.includes('"proxy-bridge"'), "client state store must include proxy-bridge collection");

assert(agentService.includes("_proxyBridgeEnvironment") &&
  agentService.includes("lico-client") &&
  agentService.includes("proxy-bridge.json") &&
  agentService.includes("LICO_PORTABLE_DIR"),
  "AgentService must inject proxy bridge environment from portable state");
assert((agentActions.includes("proxyBridgeDetect") || proxyServiceActions.includes("proxyBridgeDetect")) &&
  proxyServiceActions.includes("proxyBridgeApply") &&
  proxyServiceActions.includes("proxyBridgeRollback"),
  "AgentServiceActions must expose proxy bridge CLI calls");
assert(controller.includes("proxyBridgeStatus") &&
  controller.includes("isProxyBridgeBusy") &&
  controller.includes("proxy_bridge_actions.dart"),
  "controller must own proxy bridge status and busy state");
assert(controllerActions.includes("applyProxyBridge") &&
  controllerActions.includes("rollbackProxyBridge") &&
  controllerActions.includes("setProxyBridgeTargetSelected"),
  "controller actions must expose apply/rollback and target selection");
assert(settingsPanel.includes("ProxyBridgeSettings") &&
  settingsUi.includes("Clash") &&
  settingsUi.includes("FilterChip") &&
  settingsUi.includes("SelectableText"),
  "Settings UI must expose proxy bridge controls, agent selection, and TUN snippet");
assert(serviceTest.includes("injects enabled proxy bridge environment") &&
  serviceTest.includes("proxyBridgeApply") &&
  settingsTest.includes("Clash 代理桥接"),
  "Flutter tests must cover proxy bridge service and settings UI");

for (const token of [
  "Clash Proxy Bridge",
  "mixed-port",
  "wrapper",
  "TUN Assist",
  "不静默修改 Clash",
  "transparent"
]) {
  assert(clientDocs.includes(token) || readme.includes(token),
    `client docs must mention ${token}`);
}

const report = {
  ok: failures.length === 0,
  productionReady: false,
  generatedAt: new Date().toISOString(),
  artifactKind: "client-proxy-bridge-evidence",
  scenario: "clash-proxy-bridge",
  nativeCommand: "proxy-bridge detect|status|plan|apply|rollback",
  ui: "Settings",
  boundaries: {
    modifiesClashConfig: native.includes("willModifyClashConfig") && native.includes("false"),
    transparentTrafficHijack: native.includes("transparentTrafficHijack") && native.includes("false"),
    managedWrapperDirectoryOnly: native.includes("managedWrapperDirectoryOnly")
  },
  nativeEvidence: {
    commandRegistered: commandMod.includes("proxy_bridge::register_commands"),
    stateCollection: stateStore.includes('"proxy-bridge"'),
    loopbackProxyOnly: native.includes("proxy URL must point to loopback"),
    tunAssistAdvisory: native.includes('"advisory-only"')
  },
  uiEvidence: {
    settingsPanel: settingsPanel.includes("ProxyBridgeSettings"),
    targetSelection: settingsUi.includes("FilterChip"),
    tunSnippet: settingsUi.includes("SelectableText")
  },
  testEvidence: {
    serviceEnvironment: serviceTest.includes("injects enabled proxy bridge environment"),
    actionCommands: serviceTest.includes("proxyBridgeApply"),
    settingsUi: settingsTest.includes("Clash 代理桥接")
  },
  remainingProductionBlockers: [
    "TUN authorization can only be advised/detected from local config; the client does not request privileged network extensions or service-mode authorization.",
    "Wrapper invocation requires users or launcher integrations to call the generated wrapper path for each selected agent."
  ],
  failures
};

atomicWriteReportJson(repoRoot, reportRef, report);

if (failures.length > 0) {
  console.error(JSON.stringify(report, null, 2));
  process.exit(1);
}

console.log(JSON.stringify(report, null, 2));
