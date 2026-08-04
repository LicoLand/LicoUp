export async function checkDocsReadiness({ assert, files }) {
  const { readJson, readText } = files;
  const documentPairs = [
    ["README.md", "README.zh-CN.md"],
    ["CONTRIBUTING.md", "CONTRIBUTING.zh-CN.md"],
    ["SECURITY.md", "SECURITY.zh-CN.md"],
    ["docs/functionality/USER-GUIDE.md", "docs/functionality/USER-GUIDE.zh-CN.md"],
    ["docs/architecture/README.md", "docs/architecture/README.zh-CN.md"],
    [
      "docs/COMPATIBILITY.md",
      "docs/COMPATIBILITY.zh-CN.md",
    ],
  ];
  const documents = new Map();
  for (const [englishPath, chinesePath] of documentPairs) {
    const english = await readText(englishPath);
    const chinese = await readText(chinesePath);
    documents.set(englishPath, english);
    documents.set(chinesePath, chinese);
    assert(
      english.includes(chinesePath.split("/").at(-1)),
      `${englishPath} must link to ${chinesePath}`,
    );
    assert(
      chinese.includes(englishPath.split("/").at(-1)),
      `${chinesePath} must link to ${englishPath}`,
    );
  }

  const normalized = (relativePath) => documents.get(relativePath).replace(/\s+/gu, " ");
  const readme = normalized("README.md");
  const chineseReadme = normalized("README.zh-CN.md");
  for (const token of [
    "open-source client",
    "Diverse",
    "Connected",
    "Open",
    "Integrated",
    "Sensitive runtime data stays on the device",
    "Default client scenarios do not",
    "protected one-shot user approval",
    "treats transport as untrusted",
    "GPL-3.0-or-later",
  ]) {
    assert(readme.includes(token), `README.md must keep public client token ${token}`);
  }
  for (const token of [
    "多元",
    "互联",
    "开放",
    "融合",
    "默认客户端场景不会把",
    "一次新的、受保护的用户确认",
    "把运输路径视为不可信环境",
  ]) {
    assert(chineseReadme.includes(token), `README.zh-CN.md must keep public client token ${token}`);
  }

  const architecture = normalized("docs/architecture/README.md");
  const chineseArchitecture = normalized("docs/architecture/README.zh-CN.md");
  for (const token of [
    "Compatible untrusted station",
    "Five-field Lico Arc envelope",
    "runtime data stay on the device",
    "Current platform key custody",
    "Caller-supplied flags or ordinary state files are not proof of approval",
    "no runtime crypto-patch loader",
    "Plans, temporary scripts, local skills",
  ]) {
    assert(architecture.includes(token), `ARCHITECTURE.md must keep boundary token ${token}`);
  }
  for (const token of [
    "兼容且不可信的通讯站",
    "五字段 Lico Arc 信封",
    "原始运行时数据留在设备上",
    "当前平台密钥保管",
    "调用方参数和普通状态文件都不能证明用户已经批准",
    "没有运行时加密补丁加载器",
    "计划、临时脚本、本地技能",
  ]) {
    assert(chineseArchitecture.includes(token), `ARCHITECTURE.zh-CN.md must keep boundary token ${token}`);
  }

  const security = normalized("SECURITY.md");
  const chineseSecurity = normalized("SECURITY.zh-CN.md");
  for (const token of [
    "Relay threat model",
    "native user authentication",
    "does not accept executable crypto patches from a relay or service",
    "There is no runtime crypto-patch loader",
  ]) {
    assert(security.includes(token), `SECURITY.md must keep security boundary ${token}`);
  }
  for (const token of [
    "中转端威胁边界",
    "系统身份验证",
    "不接受中转端或服务端提供的可执行加密补丁",
    "没有运行时加密补丁加载器",
  ]) {
    assert(chineseSecurity.includes(token), `SECURITY.zh-CN.md must keep security boundary ${token}`);
  }

  const publicSecurityDocs = [
    readme,
    chineseReadme,
    architecture,
    chineseArchitecture,
    security,
    chineseSecurity,
  ].join("\n");
  for (const forbidden of [
    "all algorithms stacked",
    "military-grade",
    "unbreakable",
    "relay cannot intercept",
    "relay never stores",
    "server hot-loads",
    "future local provider package",
    "future external helper",
    "target adapter model",
    "所有算法叠加",
    "中转端无法拦截",
    "中转端绝不存储",
    "服务端热加载",
    "未来的本机提供者包",
    "未来的外部辅助",
    "目标适配模型",
  ]) {
    assert(
      !publicSecurityDocs.toLowerCase().includes(forbidden.toLowerCase()),
      `public security docs must not contain unsafe claim ${forbidden}`,
    );
  }

  const contributing = documents.get("CONTRIBUTING.md");
  const chineseContributing = documents.get("CONTRIBUTING.zh-CN.md");
  for (const token of [
    "synthetic, redacted test data",
    "docs/plans/",
    "docs/reports/",
    "local skills",
  ]) {
    assert(contributing.includes(token), `CONTRIBUTING.md must keep repository rule ${token}`);
  }
  for (const token of ["合成数据", "docs/plans/", "docs/reports/", "本地技能"]) {
    assert(chineseContributing.includes(token), `CONTRIBUTING.zh-CN.md must keep repository rule ${token}`);
  }

  const gitignore = await readText(".gitignore");
  for (const localPath of ["/docs/plans/", "/docs/reports/"]) {
    assert(gitignore.split(/\r?\n/u).includes(localPath), `.gitignore must keep ${localPath} local`);
  }
  const packaging = await readJson("apps/desktop/packaging.modules.json");
  const driverInventory = await readJson(
    "crates/licoup-native/resources/agent-conversation-drivers.json",
  );
  const adapterIds = packaging.modules?.["target-adapters"]?.targetAdapters || [];
  const driverIds = driverInventory.drivers?.map((driver) => driver.agentId) || [];
  assert(
    adapterIds.length > 0 &&
      new Set(adapterIds).size === adapterIds.length &&
      JSON.stringify([...adapterIds].sort()) === JSON.stringify([...driverIds].sort()),
    "packaging and canonical driver inventory must contain the exact same adapters",
  );
  assert(
    packaging.packageProfile === "licoup",
    "packaging.modules.json must default to licoup profile",
  );
  return Object.freeze({ targets: [...adapterIds], adapterCount: adapterIds.length });
}
