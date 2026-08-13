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
  "licoup-native",
  "resources",
  "agent-conversation-drivers.json",
);
const nativeCapabilityInventoryPath = path.join(
  repoRoot,
  "crates",
  "licoup-native",
  "resources",
  "agent-native-capabilities.json",
);
const driverReadinessPath = path.join(
  repoRoot,
  "crates",
  "licoup-native",
  "resources",
  "agent-conversation-readiness.json",
);
const reportPaths = Object.freeze({
  en: path.join(repoRoot, "docs", "COMPATIBILITY.md"),
  zhCN: path.join(repoRoot, "docs", "COMPATIBILITY.zh-CN.md")
});
const allowedStatuses = new Set(["supported", "preview", "deferred", "unsupported", "unverified"]);
const nativeCapabilityKinds = new Set([
  "desktop", "cli", "acp", "rpc", "app-server", "gateway", "local-server",
  "web-server", "tui-gateway",
]);
const nativeCapabilityLabels = Object.freeze({
  en: Object.freeze({
    desktop: "Desktop", cli: "CLI", acp: "ACP", rpc: "RPC",
    "app-server": "App Server", gateway: "Gateway",
    "local-server": "Local Server", "web-server": "Web Server",
    "tui-gateway": "TUI Gateway",
  }),
  zhCN: Object.freeze({
    desktop: "桌面端", cli: "CLI", acp: "ACP", rpc: "RPC",
    "app-server": "App Server", gateway: "Gateway",
    "local-server": "Local Server", "web-server": "Web Server",
    "tui-gateway": "TUI Gateway",
  }),
});
const laneTransports = Object.freeze({
  en: Object.freeze({
    acp: "stdio ACP", "app-server": "stdio JSON-RPC", cli: "CLI process",
    rpc: "stdio JSONL", "serve-http": "loopback HTTP + SSE",
    "stream-json": "stdio stream-json",
  }),
  zhCN: Object.freeze({
    acp: "stdio ACP", "app-server": "stdio JSON-RPC", cli: "CLI 进程",
    rpc: "stdio JSONL", "serve-http": "回环 HTTP + SSE",
    "stream-json": "stdio stream-json",
  }),
});

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

export function validateClientSupportMatrix(raw) {
  requireValue(raw?.schema === "licoup.client-support-matrix", "unexpected client support matrix schema");
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
  const matrixTargetIds = raw.targets.map((target) => target.targetId);
  requireValue(new Set(matrixTargetIds).size === matrixTargetIds.length, "support matrix target ids must be unique");
  const matrixTargetIdSet = new Set(matrixTargetIds);
  requireValue(releaseCatalog.targets.every((target) =>
    matrixTargetIdSet.has(target.runtimeTargetId)),
  "every release package target must reference a known runtime target");
  const rows = raw.targets.map((target) => {
    requireValue(typeof target.buildSupported === "boolean",
      `target ${target.targetId} must declare buildSupported`);
    requireValue(target.deviceClass === undefined ||
      ["physical-phone", "simulator"].includes(target.deviceClass),
    `target ${target.targetId} has an invalid deviceClass`);
    const defaults = raw.defaults?.[target.profile];
    requireValue(defaults && typeof defaults === "object", `unknown support matrix profile: ${target.profile}`);
    const statuses = { ...defaults, ...(target.overrides || {}) };
    requireValue(Object.keys(statuses).every((id) => serviceIds.has(id)),
      `target ${target.targetId} contains an unknown service`);
    for (const id of serviceIds) {
      requireValue(allowedStatuses.has(statuses[id]), `target ${target.targetId} has invalid status for ${id}`);
    }
    return {
      targetId: target.targetId,
      buildSupported: target.buildSupported,
      deviceClass: target.deviceClass || "",
      statuses,
    };
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
    for (const stage of ["accepted", "processing", "responding", "completed"]) {
      requireValue(typeof driver.lifecycleEvidence?.[stage] === "boolean",
        `client driver ${driver.agentId} lifecycleEvidence.${stage} is required`);
    }
  }
  return raw.drivers;
}

function validateNativeCapabilityProjection(raw, drivers) {
  requireValue(
    raw?.schemaVersion === "v0.0.1:client-agent-native-capabilities-1",
    "unexpected native capability inventory schema",
  );
  requireValue(Array.isArray(raw.agents) && raw.agents.length > 0,
    "native capability inventory is empty");
  const capabilitiesByAgent = new Map();
  for (const agent of raw.agents) {
    requireValue(typeof agent?.agentId === "string" && agent.agentId.length > 0,
      "native capability agentId is required");
    requireValue(!capabilitiesByAgent.has(agent.agentId),
      `duplicate native capability agent: ${agent.agentId}`);
    requireValue(
      Array.isArray(agent.capabilities)
        && agent.capabilities.length > 0
        && new Set(agent.capabilities).size === agent.capabilities.length
        && agent.capabilities.every((kind) => nativeCapabilityKinds.has(kind)),
      `native capabilities for ${agent.agentId} are invalid`,
    );
    capabilitiesByAgent.set(agent.agentId, agent.capabilities);
  }
  requireValue(
    JSON.stringify([...capabilitiesByAgent.keys()].sort()) ===
      JSON.stringify(drivers.map((driver) => driver.agentId).sort()),
    "native capability inventory and driver inventory ids differ",
  );
  return capabilitiesByAgent;
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

function capabilityList(capabilities, locale) {
  const labels = nativeCapabilityLabels[locale];
  return capabilities.map((kind) => labels[kind]).join(", ");
}

function listenerScope(capabilityList, locale) {
  const capabilities = new Set(capabilityList);
  if (["gateway", "local-server", "web-server"].some((kind) => capabilities.has(kind))) {
    return locale === "zhCN" ? "回环 TCP" : "loopback TCP";
  }
  if (capabilities.has("tui-gateway")) {
    return locale === "zhCN" ? "仅条件式远程连接" : "conditional remote only";
  }
  return locale === "zhCN" ? "无" : "none";
}

function capabilityRole(capabilityList, locale) {
  const capabilities = new Set(capabilityList);
  if (capabilities.has("gateway")) {
    return locale === "zhCN" ? "中间附着层" : "intermediate attach layer";
  }
  if (capabilities.has("tui-gateway")) {
    return locale === "zhCN" ? "ACP 直连；TUI Gateway 仅用于手动虚拟机" : "direct ACP; TUI Gateway only for manual VM";
  }
  if (capabilities.has("web-server")) {
    return locale === "zhCN" ? "直接控制面与 Web UI" : "direct control plane and Web UI";
  }
  if (capabilities.has("local-server")) {
    return locale === "zhCN" ? "直接本地智能体 API" : "direct local agent API";
  }
  if (capabilities.has("app-server")) {
    return locale === "zhCN" ? "直接 stdio App Server" : "direct stdio App Server";
  }
  return locale === "zhCN" ? "直接进程接口" : "direct process interface";
}

function renderEnglishReport(validated, productVersion, drivers, readiness, nativeCapabilities) {
  const lines = [
    "# LicoUp Compatibility",
    "",
    "English (normative) · [简体中文](COMPATIBILITY.zh-CN.md) · [Documentation](README.md) · [Project](../README.md)",
    "",
    `Product version: \`${productVersion}\``,
    "",
    "Generated sources: `tools/client-support-matrix.json`, `tools/client-release-targets.json`, `tools/client-version.json`, `crates/licoup-native/resources/agent-conversation-drivers.json`, `crates/licoup-native/resources/agent-native-capabilities.json`, and `crates/licoup-native/resources/agent-conversation-readiness.json`.",
    "",
    "Update with `npm run client:support-matrix:sync`; verify with `npm run client:support-matrix:check`. Do not edit this projection by hand.",
    "",
    "## Platform targets",
    "",
    "A build target is not a support claim.",
    "",
    "LicoUp for macOS supports Apple Silicon (`arm64`) on macOS 11 or later. Intel (`x86_64`) Macs and Rosetta are outside the supported product boundary; no Intel app or update package is produced.",
    "",
    "| Runtime target | Build | Physical/device evidence | Client | Peer encryption | Mobile relay |",
    "| --- | --- | --- | --- | --- | --- |"
  ];
  for (const row of validated.rows) {
    const deviceEvidence = row.deviceClass === "simulator"
      ? "simulator only"
      : "not claimed";
    lines.push(`| ${row.targetId} | ${row.buildSupported ? "available" : "unavailable"} | ${deviceEvidence} | ${selectedStatus(row, "client-shell")} | ${selectedStatus(row, "secure-mesh-pairwise")} | ${selectedStatus(row, "mobile-relay")} |`);
  }
  lines.push(
    "",
    "## Release package targets",
    "",
    "Runtime targets and release packages are intentionally different authorities. Each row below is one native package for one distribution channel; selecting several rows produces several independent package directories.",
    "",
    "| Package target | Runtime target | Platform | Channel | Format | Architecture | Package build | Release eligible | Update authority |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  );
  for (const target of validated.releaseCatalog.targets) {
    lines.push(`| ${target.id} | ${target.runtimeTargetId} | ${target.platform} | ${target.channel} | ${target.packageFormat} | ${target.arch} | ${target.packageBuildSupported ? "available" : "blocked"} | ${target.releaseSupported ? "eligible" : "not eligible"} | ${target.update.kind} |`);
  }
  lines.push(
    "",
    "## Meaning",
    "",
    "- `supported` means the current target-specific client checks accept the feature; it does not imply distribution readiness.",
    "- `preview` means the feature is still changing.",
    "- `unverified` means there is no current support claim.",
    "- `unsupported` means the feature must not be presented as available.",
    "- `eligible` means a release operator may explicitly select that exact package target; it does not mean any current release includes it.",
    "- A generic Linux archive is an internal verification carrier, not an installable release package. Linux distribution uses native package or repository targets.",
    "- Feature status does not establish native-host, physical-device, biometric, hardware-custody, or cross-device evidence. Those claims remain `not claimed`; a simulator row proves only its simulator closure.",
    "- Store publication is not claimed by this matrix and requires a separate channel-specific result.",
    "- Peer content is encrypted by the sending client. Sensitive runtime data stays local.",
    "",
    "## Agent adapter targets",
    "",
    "This table projects the native driver inventory. Runtime protocol and capability fields remain owned by that inventory.",
    "Lifecycle evidence columns describe whether the lane can emit a native receipt for that stage. `submitted` is always a local client fact. On each turn, the UI shows only receipts actually observed; unsupported or absent stages are skipped and are never inferred from a later response or terminal result.",
    "",
    "| Agent ID | Driver mode | Readiness | Send enabled | Runtime protocol | Lane family | Exact resume | Streaming | GUI-exit survival | Active-turn reattach | Ordered cursor replay | Accepted evidence | Processing evidence | Responding evidence | Completed evidence | Native interrupt/steer |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  );
  for (const driver of drivers) {
    const adapterReadiness = readiness.get(driver.agentId);
    lines.push(`| ${driver.agentId} | ${driver.driverMode} | ${adapterReadiness.status} | ${yesNo(adapterReadiness.sendEnabled)} | ${driver.runtimeProtocol} | ${driver.capabilityMatrix.laneFamily} | ${yesNo(driver.capabilityMatrix.exactResume)} | ${yesNo(driver.capabilityMatrix.streaming)} | ${yesNo(driver.capabilityMatrix.hostSurvivesGuiDisconnect)} | ${yesNo(driver.capabilityMatrix.activeTurnReattach)} | ${yesNo(driver.capabilityMatrix.orderedCursorReplay)} | ${yesNo(driver.lifecycleEvidence.accepted)} | ${yesNo(driver.lifecycleEvidence.processing)} | ${yesNo(driver.lifecycleEvidence.responding)} | ${yesNo(driver.lifecycleEvidence.completed)} | ${yesNo(driver.capabilityMatrix.interruptSteer)} |`);
  }
  lines.push(
    "",
    "## Native capability inventory",
    "",
    "This table is generated from the same native capability inventory used by the desktop runtime.",
    "",
    "Classification rules:",
    "",
    "- List only interfaces shipped by the agent. A LicoUp-managed bridge or `lico-llm-gateway` is not an agent-native capability.",
    "- `CLI` is the ordinary command process. Protocol subcommands such as `acp`, `serve`, `web`, `gateway`, `app-server`, or RPC mode are separate, mutually exclusive running capabilities.",
    "- `ACP`, `RPC`, and `App Server` are structured process protocols and do not imply a listening network port.",
    "- `Local Server` is the agent's direct loopback API. `Web Server` additionally owns a browser UI or broader web control plane.",
    "- `Gateway` is an intermediate reusable attachment layer between a client protocol process and the agent runtime. `TUI Gateway` is the Hermes remote/manual-VM specialization.",
    "- Installed/detected means the owning executable can provide the capability. Running requires a matching process; a network server or network gateway also requires its own listener evidence.",
    "",
    "| Agent ID | Native capabilities | Primary LicoUp lane | Primary transport | Listener | Role |",
    "| --- | --- | --- | --- | --- | --- |",
  );
  for (const driver of drivers) {
    const lane = driver.capabilityMatrix.laneFamily;
    const capabilities = nativeCapabilities.get(driver.agentId);
    lines.push(`| ${driver.agentId} | ${capabilityList(capabilities, "en")} | ${lane} | ${laneTransports.en[lane] ?? lane} | ${listenerScope(capabilities, "en")} | ${capabilityRole(capabilities, "en")} |`);
  }
  lines.push(
    "",
    "## Manual VM conversation transport",
    "",
    "The desktop manual-target flow can bind OpenClaw or Hermes to a user-owned VM through system OpenSSH stdio and ACP. It requires existing strict host verification and noninteractive SSH authentication; LicoUp accepts no SSH password or private key. Conversation history uses ACP session list/load instead of guest filesystem access. This source transport does not by itself promote the adapter readiness or release send-enabled claims in the table above.",
    ""
  );
  return lines.join("\n");
}

function renderChineseReport(validated, productVersion, drivers, readiness, nativeCapabilities) {
  const lines = [
    "# LicoUp 兼容性",
    "",
    "[English（规范版本）](COMPATIBILITY.md) · 简体中文（本地化） · [文档索引](README.md) · [项目首页](../README.zh-CN.md)",
    "",
    `产品版本：\`${productVersion}\``,
    "",
    "生成来源：`tools/client-support-matrix.json`、`tools/client-release-targets.json`、`tools/client-version.json`、`crates/licoup-native/resources/agent-conversation-drivers.json`、`crates/licoup-native/resources/agent-native-capabilities.json` 和 `crates/licoup-native/resources/agent-conversation-readiness.json`。",
    "",
    "使用 `npm run client:support-matrix:sync` 更新，使用 `npm run client:support-matrix:check` 验证。请勿手工维护本投影。",
    "",
    "## 平台目标",
    "",
    "可以构建，不代表已经支持。",
    "",
    "LicoUp macOS 客户端仅支持运行 macOS 11 或更高版本的 Apple Silicon（`arm64`）设备。Intel（`x86_64`）Mac 与 Rosetta 不在产品支持范围内，不提供 Intel 应用或更新包。",
    "",
    "| 运行目标 | 构建 | 真机/设备证据 | 客户端 | 对端加密 | 移动中转 |",
    "| --- | --- | --- | --- | --- | --- |"
  ];
  for (const row of validated.rows) {
    const deviceEvidence = row.deviceClass === "simulator"
      ? "仅模拟器"
      : "未声明";
    lines.push(`| ${row.targetId} | ${row.buildSupported ? "可用" : "不可用"} | ${deviceEvidence} | ${chineseStatus[selectedStatus(row, "client-shell")]} | ${chineseStatus[selectedStatus(row, "secure-mesh-pairwise")]} | ${chineseStatus[selectedStatus(row, "mobile-relay")]} |`);
  }
  lines.push(
    "",
    "## 发布包目标",
    "",
    "运行目标和发布包目标是有意分离的两套权威。下表每一行只代表一个分发渠道的一种原生包；同时选择多行时，会生成多个相互独立的发布包目录。",
    "",
    "| 发布包目标 | 运行目标 | 平台 | 渠道 | 格式 | 架构 | 包构建 | 可发布 | 更新权威 |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  );
  for (const target of validated.releaseCatalog.targets) {
    lines.push(`| ${target.id} | ${target.runtimeTargetId} | ${target.platform} | ${target.channel} | ${target.packageFormat} | ${target.arch} | ${target.packageBuildSupported ? "可用" : "阻塞"} | ${target.releaseSupported ? "可选入" : "不可选入"} | ${target.update.kind} |`);
  }
  lines.push(
    "",
    "## 状态说明",
    "",
    "- “支持”表示当前目标的客户端专项检查接受该功能，不代表已经具备分发条件。",
    "- “预览”表示功能仍在变化。",
    "- “未验证”表示当前没有支持声明。",
    "- “不支持”表示界面不得把该功能显示为可用。",
    "- “可选入”表示发布人员可以明确选择该精确发布包目标，不表示任何当前发布已经包含它。",
    "- 通用 Linux 压缩包只可作为内部验证载体，不是可安装发布包；Linux 分发必须使用原生包或软件仓库目标。",
    "- 功能状态不能证明原生宿主、真机、生物识别、硬件密钥保管或跨设备证据；这些结论保持“未声明”，模拟器行只证明模拟器闭环。",
    "- 本矩阵不声明商店发布；商店发布必须有独立的渠道结论。",
    "- 对端内容由发送客户端加密，敏感运行时数据留在本机。",
    "",
    "## 智能体适配目标",
    "",
    "本表投影原生驱动清单。运行协议和能力字段仍由该清单负责。",
    "生命周期证据列表示该通道是否能为对应阶段发出原生回执。“已发送”始终是客户端本地事实。每一轮中，界面只展示实际观测到的回执；不支持或未到达的阶段直接跳过，不得通过后续回复或终态结果倒推。",
    "",
    "| 智能体 ID | 驱动模式 | 就绪状态 | 可发送 | 运行协议 | 通道族 | 准确继续 | 流式事件 | GUI 退出后续跑 | 活动轮次重附着 | 有序游标重放 | 已接收证据 | 处理中证据 | 回复中证据 | 已完成证据 | 原生中断/steer |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  );
  for (const driver of drivers) {
    const adapterReadiness = readiness.get(driver.agentId);
    lines.push(`| ${driver.agentId} | ${driver.driverMode} | ${adapterReadiness.status} | ${chineseYesNo(adapterReadiness.sendEnabled)} | ${driver.runtimeProtocol} | ${driver.capabilityMatrix.laneFamily} | ${chineseYesNo(driver.capabilityMatrix.exactResume)} | ${chineseYesNo(driver.capabilityMatrix.streaming)} | ${chineseYesNo(driver.capabilityMatrix.hostSurvivesGuiDisconnect)} | ${chineseYesNo(driver.capabilityMatrix.activeTurnReattach)} | ${chineseYesNo(driver.capabilityMatrix.orderedCursorReplay)} | ${chineseYesNo(driver.lifecycleEvidence.accepted)} | ${chineseYesNo(driver.lifecycleEvidence.processing)} | ${chineseYesNo(driver.lifecycleEvidence.responding)} | ${chineseYesNo(driver.lifecycleEvidence.completed)} | ${chineseYesNo(driver.capabilityMatrix.interruptSteer)} |`);
  }
  lines.push(
    "",
    "## 原生能力清单",
    "",
    "本表与桌面运行时使用同一份原生能力清单生成。",
    "",
    "判断标准：",
    "",
    "- 只列智能体自身提供的接口；LicoUp 管理的桥接或 `lico-llm-gateway` 不属于智能体原生能力。",
    "- `CLI` 是普通命令进程；`acp`、`serve`、`web`、`gateway`、`app-server` 或 RPC 模式等协议子命令必须作为互斥的独立运行能力。",
    "- `ACP`、`RPC` 和 `App Server` 是结构化进程协议，不代表存在网络监听端口。",
    "- `Local Server` 是智能体直接提供的回环 API；`Web Server` 还拥有浏览器界面或更完整的 Web 控制面。",
    "- `Gateway` 是客户端协议进程与智能体运行时之间可复用的中间附着层；`TUI Gateway` 是 Hermes 的远程/手动虚拟机特化入口。",
    "- “已检测”表示所属可执行程序能够提供该能力；“运行中”必须匹配对应进程，网络 Server 或网络 Gateway 还必须具备自身监听证据。",
    "",
    "| 智能体 ID | 原生能力 | LicoUp 主通道 | 主传输 | 监听 | 定位 |",
    "| --- | --- | --- | --- | --- | --- |",
  );
  for (const driver of drivers) {
    const lane = driver.capabilityMatrix.laneFamily;
    const capabilities = nativeCapabilities.get(driver.agentId);
    lines.push(`| ${driver.agentId} | ${capabilityList(capabilities, "zhCN")} | ${lane} | ${laneTransports.zhCN[lane] ?? lane} | ${listenerScope(capabilities, "zhCN")} | ${capabilityRole(capabilities, "zhCN")} |`);
  }
  lines.push(
    "",
    "## 手动虚拟机对话传输",
    "",
    "桌面端手动目标流程可以通过系统 OpenSSH stdio 与 ACP，把 OpenClaw 或 Hermes 绑定到用户自有虚拟机。它要求已有严格主机校验和非交互 SSH 认证；LicoUp 不接受 SSH 密码或私钥。对话历史使用 ACP 会话列出/加载，而不是访问虚拟机文件系统。此源码传输能力本身不会提升上表中的适配器就绪状态或发布可发送声明。",
    ""
  );
  return lines.join("\n");
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "")) {
  const action = process.argv[2] || "check";
  const productVersion = readJson(path.join(repoRoot, "tools", "client-version.json")).productVersion;
  const validated = validateClientSupportMatrix(readJson(catalogPath));
  const drivers = validateDriverProjection(readJson(driverInventoryPath));
  const nativeCapabilities = validateNativeCapabilityProjection(
    readJson(nativeCapabilityInventoryPath),
    drivers,
  );
  const readiness = validateDriverReadiness(readJson(driverReadinessPath), drivers);
  const reports = Object.freeze({
    en: renderEnglishReport(validated, productVersion, drivers, readiness, nativeCapabilities),
    zhCN: renderChineseReport(validated, productVersion, drivers, readiness, nativeCapabilities)
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
    nativeCapabilityAgentCount: nativeCapabilities.size,
  }));
}
