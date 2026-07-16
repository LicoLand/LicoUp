#!/usr/bin/env node
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { loadClientReleaseTargetCatalog } from "./lib/client-release-targets.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const catalogPath = path.join(repoRoot, "tools", "client-support-matrix.json");
const reportPaths = Object.freeze({
  en: path.join(repoRoot, "docs", "releases", "client-support-matrix.md"),
  zhCN: path.join(repoRoot, "docs", "releases", "client-support-matrix.zh-CN.md")
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

function renderEnglishReport(validated, productVersion) {
  const targetById = new Map(validated.releaseCatalog.targets.map((target) => [target.id, target]));
  const lines = [
    "# Lico Arc Client Support Matrix",
    "",
    "English · [简体中文](client-support-matrix.zh-CN.md) · [Home](../../README.md)",
    "",
    `Product version: \`${productVersion}\``,
    "",
    "This file is generated from the client catalogs. A build target is not a support claim.",
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
    ""
  );
  return lines.join("\n");
}

function renderChineseReport(validated, productVersion) {
  const targetById = new Map(validated.releaseCatalog.targets.map((target) => [target.id, target]));
  const lines = [
    "# Lico Arc 客户端支持状态",
    "",
    "[English](client-support-matrix.md) · 简体中文 · [首页](../../README.zh-CN.md)",
    "",
    `产品版本：\`${productVersion}\``,
    "",
    "本文件根据客户端目录自动生成。可以构建，不代表已经支持。",
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
    ""
  );
  return lines.join("\n");
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "")) {
  const action = process.argv[2] || "check";
  const productVersion = readJson(path.join(repoRoot, "tools", "client-version.json")).productVersion;
  const validated = validateClientSupportMatrix(readJson(catalogPath));
  const reports = Object.freeze({
    en: renderEnglishReport(validated, productVersion),
    zhCN: renderChineseReport(validated, productVersion)
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
  console.log(JSON.stringify({ ok: true, productVersion, targetCount: validated.rows.length, serviceCount: validated.services.length }));
}
