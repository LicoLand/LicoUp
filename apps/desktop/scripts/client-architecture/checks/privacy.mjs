export async function checkProductContractsAndPortableData(context, { modules }) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
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
  const architectureSource = await readText("docs/architecture/README.md");
  const userGuideSource = await readText("docs/functionality/USER-GUIDE.md");
  const contributingSource = await readText("CONTRIBUTING.md");
  const normalizedArchitectureSource = architectureSource.replace(/\s+/gu, " ");
  const normalizedUserGuideSource = userGuideSource.replace(/\s+/gu, " ");
  const normalizedContributingSource = contributingSource.replace(/\s+/gu, " ");
  assert(
    normalizedArchitectureSource.includes("Agent conversations") &&
      normalizedArchitectureSource.includes("New and native continued sessions") &&
      normalizedArchitectureSource.includes("process-local") &&
      normalizedArchitectureSource.includes("Subagent MCP") &&
      normalizedArchitectureSource.includes("wakeable progress") &&
      normalizedArchitectureSource.includes("native steer") &&
      normalizedArchitectureSource.includes("exact-session safe-boundary follow-up"),
    "architecture docs must keep native continuation and the local Subagent MCP boundary"
  );
  assert(
    normalizedUserGuideSource.includes("prefers the agent's native attach or resume operation") &&
      normalizedUserGuideSource.includes("keeps projecting its live output") &&
      normalizedUserGuideSource.includes("starts the next turn only after the agent has completed its reply"),
    "USER-GUIDE.md must describe native continuation and the non-interleaving fallback"
  );
  assert(
    normalizedContributingSource.includes("is the sole verified delivery entry") &&
      normalizedContributingSource.includes("Independent checks must settle and report their failures together") &&
      normalizedContributingSource.includes("run the complete host profile in the local workflow once"),
    "CONTRIBUTING.md must preserve focused repair and complete local verification"
  );
  const portableDirs = modules["portable-data"]?.portableDirectories || [];
  const expectedPortableDirs = [
    "licoup",
    "licoup/settings",
    "licoup/targets",
    "licoup/pairings",
    "licoup/skills",
    "licoup/pins",
    "licoup/activity",
    "licoup/snapshots"
  ];
  assert(sameSet([...portableDirs].sort(), [...expectedPortableDirs].sort()),
    "portable-data module must list exactly the current portable runtime directories");

}

