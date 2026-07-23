#!/usr/bin/env node
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { loadClientReleaseTargetCatalog } from "./lib/client-release-targets.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const catalogPath = path.join(repoRoot, "tools", "client-support-matrix.json");
const driverInventoryPath = path.join(
  repoRoot,
  "crates",
  "lico-client-native",
  "resources",
  "agent-conversation-drivers.json",
);
const driverReadinessPath = path.join(
  repoRoot,
  "crates",
  "lico-client-native",
  "resources",
  "agent-conversation-readiness.json",
);
const reportPaths = Object.freeze({
  en: path.join(repoRoot, "docs", "COMPATIBILITY.md"),
  zhCN: path.join(repoRoot, "docs", "COMPATIBILITY.zh-CN.md")
});
const allowedStatuses = new Set(["supported", "preview", "deferred", "unsupported", "unverified"]);

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

export function validateClientSupportMatrix(raw) {
  requireValue(raw?.schema === "licoarc.client-support-matrix", "unexpected client support matrix schema");
  requireValue(Array.isArray(raw.services) && raw.services.length > 0, "support matrix services are empty");
  requireValue(Array.isArray(raw.targets) && raw.targets.length > 0, "support matrix targets are empty");
  const serviceIds = new Set();
  for (const service of raw.services) {
    requireValue(service?.id && service?.label && service?.category, "support matrix service fields are required");
    requireValue(!serviceIds.has(service.id), `duplicate support matrix service: ${service.id}`);
    serviceIds.add(service.id);
    requireValue(typeof service.releaseBlocking === "boolean", `service ${service.id} must declare releaseBlocking`);
    requireValue(service.category !== "manual-integration" || service.releaseBlocking === false,
      `manual integration ${service.id} must not block a client release`);
  }
  const releaseCatalog = loadClientReleaseTargetCatalog();
  const releaseTargetIds = releaseCatalog.targets.map((target) => target.id);
  const matrixTargetIds = raw.targets.map((target) => target.targetId);
  requireValue(new Set(matrixTargetIds).size === matrixTargetIds.length, "support matrix target ids must be unique");
  requireValue(JSON.stringify([...matrixTargetIds].sort()) === JSON.stringify([...releaseTargetIds].sort()),
    "support matrix must contain exactly one row for every release target");
  const rows = raw.targets.map((target) => {
    const defaults = raw.defaults?.[target.profile];
    requireValue(defaults && typeof defaults === "object", `unknown support matrix profile: ${target.profile}`);
    const statuses = { ...defaults, ...(target.overrides || {}) };
    requireValue(Object.keys(statuses).every((id) => serviceIds.has(id)),
      `target ${target.targetId} contains an unknown service`);
    for (const id of serviceIds) {
      requireValue(allowedStatuses.has(statuses[id]), `target ${target.targetId} has invalid status for ${id}`);
    }
    return { targetId: target.targetId, statuses };
  });
  return { services: raw.services, releaseCatalog, rows };
}

export function selectedReleaseBlockingSupportReady(validated, selectedTargetIds) {
  const ids = Array.isArray(selectedTargetIds) ? selectedTargetIds : [];
  if (ids.length === 0 || new Set(ids).size !== ids.length) return false;
  const rows = new Map(validated.rows.map((row) => [row.targetId, row]));
  const blockingServiceIds = validated.services
    .filter((service) => service.releaseBlocking === true)
    .map((service) => service.id);
  return blockingServiceIds.length > 0 && ids.every((targetId) => {
    const row = rows.get(targetId);
    return row && blockingServiceIds.every((serviceId) =>
      row.statuses[serviceId] === "supported");
  });
}

const chineseStatus = Object.freeze({
  supported: "支持",
  preview: "预览",
  deferred: "暂缓",
  unsupported: "不支持",
  unverified: "未验证"
});

function selectedStatus(row, serviceId) {
  return row.statuses[serviceId];
}

function validateDriverProjection(raw) {
  requireValue(
    raw?.schemaVersion === "v0.0.1:client-agent-conversation-drivers-1",
    "unexpected client driver inventory schema",
  );
  requireValue(Array.isArray(raw.drivers) && raw.drivers.length > 0,
    "client driver inventory is empty");
  const ids = new Set();
  for (const driver of raw.drivers) {
    requireValue(typeof driver?.agentId === "string" && driver.agentId.length > 0,
      "client driver agentId is required");
    requireValue(!ids.has(driver.agentId), `duplicate client driver: ${driver.agentId}`);
    ids.add(driver.agentId);
    requireValue(typeof driver.runtimeProtocol === "string" && driver.runtimeProtocol.length > 0,
      `client driver ${driver.agentId} runtimeProtocol is required`);
    requireValue(typeof driver.capabilityMatrix?.laneFamily === "string",
      `client driver ${driver.agentId} laneFamily is required`);
  }
  return raw.drivers;
}

function validateDriverReadiness(raw, drivers) {
  requireValue(
    raw?.schemaVersion === "v0.0.1:client-agent-conversation-readiness-1",
    "unexpected client driver readiness schema",
  );
  requireValue(Array.isArray(raw.adapters), "client driver readiness adapters are required");
  const statuses = new Map();
  for (const adapter of raw.adapters) {
    requireValue(
      typeof adapter?.agentId === "string" &&
        typeof adapter?.status === "string" &&
        typeof adapter?.sendEnabled === "boolean",
      "client driver readiness fields are required",
    );
    requireValue(!statuses.has(adapter.agentId),
      `duplicate client driver readiness: ${adapter.agentId}`);
    statuses.set(adapter.agentId, adapter);
  }
  requireValue(
    JSON.stringify([...statuses.keys()].sort()) ===
      JSON.stringify(drivers.map((driver) => driver.agentId).sort()),
    "client driver inventory and readiness ids differ",
  );
  return statuses;
}

function yesNo(value) {
  return value === true ? "yes" : "no";
}

function chineseYesNo(value) {
  return value === true ? "是" : "否";
}

function renderEnglishReport(validated, productVersion, drivers, readiness) {
  const targetById = new Map(validated.releaseCatalog.targets.map((target) => [target.id, target]));
  const lines = [
    "# Lico Arc Compatibility",
    "",
    "English (normative) · [简体中文](COMPATIBILITY.zh-CN.md) · [Documentation](README.md) · [Project](../README.md)",
    "",
    `Product version: \`${productVersion}\``,
    "",
    "Generated sources: `tools/client-support-matrix.json`, `tools/client-release-targets.json`, `tools/client-version.json`, `crates/lico-client-native/resources/agent-conversation-drivers.json`, and `crates/lico-client-native/resources/agent-conversation-readiness.json`.",
    "",
    "Update with `npm run client:support-matrix:sync`; verify with `npm run client:support-matrix:check`. Do not edit this projection by hand.",
    "",
    "## Platform targets",
    "",
    "A build target is not a support claim.",
    "",
    "| Target | Build | GitHub Release eligible | Physical/device evidence | Store publication | Client | Peer encryption | Mobile relay |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |"
  ];
  for (const row of validated.rows) {
    const target = targetById.get(row.targetId);
    const deviceEvidence = target.deviceClass === "simulator"
      ? "simulator only"
      : "not claimed";
    lines.push(`| ${row.targetId} | ${target.supported ? "available" : "unavailable"} | ${target.releaseSupported ? "eligible" : "not eligible"} | ${deviceEvidence} | not claimed | ${selectedStatus(row, "client-shell")} | ${selectedStatus(row, "secure-mesh-pairwise")} | ${selectedStatus(row, "mobile-relay")} |`);
  }
  lines.push(
    "",
    "## Meaning",
    "",
    "- `supported` means the current target-specific client checks accept the feature; it does not imply distribution readiness.",
    "- `preview` means the feature is still changing.",
    "- `unverified` means there is no current support claim.",
    "- `unsupported` means the feature must not be presented as available.",
    "- `eligible` means a release operator may explicitly select that target; it does not mean any current release includes it.",
    "- Feature status does not establish native-host, physical-device, biometric, hardware-custody, or cross-device evidence. Those claims remain `not claimed`; a simulator row proves only its simulator closure.",
    "- Store publication is not claimed by this matrix and requires a separate channel-specific result.",
    "- Peer content is encrypted by the sending client. Sensitive runtime data stays local.",
    "",
    "## Agent adapter targets",
    "",
    "This table projects the native driver inventory. Runtime protocol and capability fields remain owned by that inventory.",
    "",
    "| Agent ID | Driver mode | Readiness | Send enabled | Runtime protocol | Lane family | Exact resume | Streaming | Native interrupt/steer |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  );
  for (const driver of drivers) {
    const adapterReadiness = readiness.get(driver.agentId);
    lines.push(`| ${driver.agentId} | ${driver.driverMode} | ${adapterReadiness.status} | ${yesNo(adapterReadiness.sendEnabled)} | ${driver.runtimeProtocol} | ${driver.capabilityMatrix.laneFamily} | ${yesNo(driver.capabilityMatrix.exactResume)} | ${yesNo(driver.capabilityMatrix.streaming)} | ${yesNo(driver.capabilityMatrix.interruptSteer)} |`);
  }
  lines.push(
    ""
  );
  return lines.join("\n");
}

function renderChineseReport(validated, productVersion, drivers, readiness) {
  const targetById = new Map(validated.releaseCatalog.targets.map((target) => [target.id, target]));
  const lines = [
    "# Lico Arc 兼容性",
    "",
    "[English（规范版本）](COMPATIBILITY.md) · 简体中文（本地化） · [文档索引](README.md) · [项目首页](../README.zh-CN.md)",
    "",
    `产品版本：\`${productVersion}\``,
    "",
    "生成来源：`tools/client-support-matrix.json`、`tools/client-release-targets.json`、`tools/client-version.json`、`crates/lico-client-native/resources/agent-conversation-drivers.json` 和 `crates/lico-client-native/resources/agent-conversation-readiness.json`。",
    "",
    "使用 `npm run client:support-matrix:sync` 更新，使用 `npm run client:support-matrix:check` 验证。请勿手工维护本投影。",
    "",
    "## 平台目标",
    "",
    "可以构建，不代表已经支持。",
    "",
    "| 目标 | 构建 | 可选入 GitHub Release | 真机/设备证据 | 商店发布 | 客户端 | 对端加密 | 移动中转 |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |"
  ];
  for (const row of validated.rows) {
    const target = targetById.get(row.targetId);
    const deviceEvidence = target.deviceClass === "simulator"
      ? "仅模拟器"
      : "未声明";
    lines.push(`| ${row.targetId} | ${target.supported ? "可用" : "不可用"} | ${target.releaseSupported ? "可选入" : "不可选入"} | ${deviceEvidence} | 未声明 | ${chineseStatus[selectedStatus(row, "client-shell")]} | ${chineseStatus[selectedStatus(row, "secure-mesh-pairwise")]} | ${chineseStatus[selectedStatus(row, "mobile-relay")]} |`);
  }
  lines.push(
    "",
    "## 状态说明",
    "",
    "- “支持”表示当前目标的客户端专项检查接受该功能，不代表已经具备分发条件。",
    "- “预览”表示功能仍在变化。",
    "- “未验证”表示当前没有支持声明。",
    "- “不支持”表示界面不得把该功能显示为可用。",
    "- “可选入”表示发布人员可以明确选择该目标，不表示任何当前发布已经包含它。",
    "- 功能状态不能证明原生宿主、真机、生物识别、硬件密钥保管或跨设备证据；这些结论保持“未声明”，模拟器行只证明模拟器闭环。",
    "- 本矩阵不声明商店发布；商店发布必须有独立的渠道结论。",
    "- 对端内容由发送客户端加密，敏感运行时数据留在本机。",
    "",
    "## 智能体适配目标",
    "",
    "本表投影原生驱动清单。运行协议和能力字段仍由该清单负责。",
    "",
    "| 智能体 ID | 驱动模式 | 就绪状态 | 可发送 | 运行协议 | 通道族 | 准确继续 | 流式事件 | 原生中断/steer |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  );
  for (const driver of drivers) {
    const adapterReadiness = readiness.get(driver.agentId);
    lines.push(`| ${driver.agentId} | ${driver.driverMode} | ${adapterReadiness.status} | ${chineseYesNo(adapterReadiness.sendEnabled)} | ${driver.runtimeProtocol} | ${driver.capabilityMatrix.laneFamily} | ${chineseYesNo(driver.capabilityMatrix.exactResume)} | ${chineseYesNo(driver.capabilityMatrix.streaming)} | ${chineseYesNo(driver.capabilityMatrix.interruptSteer)} |`);
  }
  lines.push(
    ""
  );
  return lines.join("\n");
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "")) {
  const action = process.argv[2] || "check";
  const productVersion = readJson(path.join(repoRoot, "tools", "client-version.json")).productVersion;
  const validated = validateClientSupportMatrix(readJson(catalogPath));
  const drivers = validateDriverProjection(readJson(driverInventoryPath));
  const readiness = validateDriverReadiness(readJson(driverReadinessPath), drivers);
  const reports = Object.freeze({
    en: renderEnglishReport(validated, productVersion, drivers, readiness),
    zhCN: renderChineseReport(validated, productVersion, drivers, readiness)
  });
  if (action === "sync") {
    for (const [locale, reportPath] of Object.entries(reportPaths)) {
      mkdirSync(path.dirname(reportPath), { recursive: true });
      writeFileSync(reportPath, reports[locale], "utf8");
    }
  } else if (action === "check") {
    for (const [locale, reportPath] of Object.entries(reportPaths)) {
      requireValue(readFileSync(reportPath, "utf8") === reports[locale],
        `client support matrix ${locale} report is stale; run npm run client:support-matrix:sync`);
    }
  } else {
    throw new Error(`unknown client support matrix action: ${action}`);
  }
  console.log(JSON.stringify({
    ok: true,
    productVersion,
    targetCount: validated.rows.length,
    serviceCount: validated.services.length,
    agentAdapterCount: drivers.length,
  }));
}
