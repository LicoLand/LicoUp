export async function checkDocsReadiness({ assert, files }) {
  const { readJson, readText } = files;
  const documentPairs = [
    ["CONTRIBUTING.md", "CONTRIBUTING.zh-CN.md"],
    ["docs/RUNBOOK.md", "docs/RUNBOOK.zh-CN.md"],
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
