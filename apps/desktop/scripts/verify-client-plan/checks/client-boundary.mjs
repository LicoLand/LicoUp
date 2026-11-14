export async function checkClientBoundary({ assert, files }) {
  const { readJson, readText } = files;
const clientBoundaryVerifier = await readText("tools/verify-client-boundary.mjs");
const clientBoundaryConfig = await readText("tools/scripts/config/client-boundary.json");
const clientBoundaryConfigJson = await readJson("tools/scripts/config/client-boundary.json");
const clientBoundaryConfigHelper = await readText("tools/scripts/lib/client-boundary-config.mjs");
for (const token of [
  "loadClientBoundaryConfig",
  "enforceConfiguredClientBoundary",
  "clientBoundarySummary",
  "clientBoundary: clientBoundarySummary",
  "ruleAllowsToken",
  "sourceChecks"
]) {
  assert(clientBoundaryVerifier.includes(token),
    `client boundary verifier must keep config-driven boundary token ${token}`);
}
assert(clientBoundaryVerifier.includes("await enforceConfiguredClientBoundary(await loadClientBoundaryConfig())"),
  "client boundary verifier must load and enforce the client boundary config");
for (const token of [
  "licoup.client-boundary-config.v1",
  "flutter-gui-no-native-platform-implementation",
  "dart-services-are-bridges-not-protocol-implementations",
  "dart-method-channel-confined-to-platform-bridge",
  "macos-agent-service-reuses-one-native-stdio-workflow",
  "macos-agent-service-preserves-stable-authorization-required"
]) {
  assert(clientBoundaryConfig.includes(token),
    `client boundary config must preserve frontend/backend split token ${token}`);
}
assert(Array.isArray(clientBoundaryConfigJson.rules) &&
  clientBoundaryConfigJson.rules.length >= 3 &&
  Array.isArray(clientBoundaryConfigJson.sourceChecks) &&
  clientBoundaryConfigJson.sourceChecks.length >= 2,
  "client boundary config must define scan rules and source checks");
for (const token of [
  "loadClientBoundaryConfig",
  "normalizeSafeRootRef",
  "normalizeSafeSourceRef",
	  "normalizeRules",
	  "normalizeAllowedMatches",
	  "normalizeSourceChecks",
	  "normalizeOptionalTokenList",
	  "const forbiddenTokens = normalizeOptionalTokenList",
	  "must define tokens or forbidden tokens",
	  "assertNoLeak",
  "rules must have unique ids",
  "source checks must have unique ids"
]) {
  assert(clientBoundaryConfigHelper.includes(token),
    `client boundary config helper must keep safety token ${token}`);
}


}
