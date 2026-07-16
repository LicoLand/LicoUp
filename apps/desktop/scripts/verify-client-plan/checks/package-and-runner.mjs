export async function checkPackageAndRunner({ assert, files, context }) {
  const { readJson, readSourceBundle, readText } = files;
  const { releaseBoundarySelfTestScripts, requiredVerifierScripts } = context;
const packageJson = await readJson("package.json");
const scripts = packageJson.scripts || {};
assert(packageJson.private === false, "package.json must identify the open-source client repository");
assert(packageJson.license === "GPL-3.0-or-later", "package.json must use GPL-3.0-or-later");
const scriptNamesByCommand = new Map();
for (const [scriptName, command] of Object.entries(scripts)) {
  if (typeof command !== "string") {
    continue;
  }
  const normalizedCommand = command.trim();
  const scriptNames = scriptNamesByCommand.get(normalizedCommand) || [];
  scriptNames.push(scriptName);
  scriptNamesByCommand.set(normalizedCommand, scriptNames);
}
for (const scriptNames of scriptNamesByCommand.values()) {
  assert(
    scriptNames.length === 1,
    `package.json scripts must use one canonical name per command: ${scriptNames.join(", ")}`
  );
}
for (const scriptName of requiredVerifierScripts) {
  assert(Boolean(scripts[scriptName]), `package.json must define ${scriptName}`);
}
for (const scriptName of [
  "repo:client-boundary",
  "repo:local-info-hygiene",
  "repo:local-info-hygiene:self-test",
  "repo:workspace-cache-boundary",
  "client:version:check",
  "client:version:sync",
  "client:get",
  "client:package:plan",
  "client:cli:vm:list",
  "client:cli:vm:prepare",
  "client:cli:vm:verify",
  "client:cli:vm:linux-product-bootstrap",
  "client:cli:vm:linux-product",
  "client:run:macos",
  "client:icon:macos",
  "client:build:macos",
  "client:verify:macos-bundle",
  "client:build:linux",
  "client:build:windows",
  "client:build:android",
  "client:install:macos",
  "client:analyze",
  "client:test",
  "client:native:test"
]) {
  assert(Boolean(scripts[scriptName]), `package.json must define ${scriptName}`);
}
const verifyRunner = await readText("tools/run-client-verify.mjs");
const clientToolchainRunner = await readSourceBundle(
  "tools/scripts/client-toolchain-runner.mjs",
  "tools/scripts/client-toolchain-runner",
  ".mjs",
);
for (const token of [
  "runPreparedCommand",
  "Online flutter pub get failed; retrying with the locked local cache.",
  "isFlutterPubGet(prepared.args)",
  "prepared.args.includes(\"--offline\")",
  "[...prepared.args, \"--offline\"]",
  "delete offlineEnv.PUB_HOSTED_URL"
]) {
  assert(clientToolchainRunner.includes(token),
    `client toolchain runner must preserve locked-cache pub get fallback token ${token}`);
}
for (const scriptName of [
  "repo:client-boundary",
  "repo:local-info-hygiene",
  "repo:local-info-hygiene:self-test",
  "repo:workspace-cache-boundary",
  "client:version:check",
  "client:verify:plan",
  "client:verify:architecture",
  ...releaseBoundarySelfTestScripts,
  "client:verify:agent-conversation-parity",
  "client:verify:agent-usage",
  "client:test:android:native",
  "client:verify:secure-client-relay-mock-e2e",
  "client:verify:secure-mesh-pairwise-content-audit",
  "client:verify:secure-mesh-platform-secret-store-matrix",
  "client:verify:secure-mesh-physical-device-matrix",
  "client:verify:secure-mesh-encrypted-file-handoff",
  "client:verify:secure-mesh-acp-relay-governed-baseline",
  "client:verify:secure-mesh-acp-archive-release-proof",
  "client:verify:secure-mesh-trust-ux:self-test",
  "client:verify:secure-mesh-trust-ux",
  "client:verify:secure-mesh-report-redaction",
  "client:verify:secure-mesh-report-redaction:self-test",
  "client:verify:secure-mesh-release-proof-bundle",
  "client:verify:secure-mesh-e2ee-evidence:contract-binding",
  "client:verify:secure-mesh-e2ee-evidence:authority-proof-self-test",
  "client:verify:secure-mesh-e2ee-evidence:readiness-self-test",
  "client:verify:secure-mesh-e2ee-evidence:leak-scan-self-test",
  "client:verify:secure-mesh-e2ee-evidence",
  "client:contracts:test",
  "client:analyze",
  "client:test",
  "client:native:test",
  "client:native:smoke"
]) {
  assert(verifyRunner.includes(scriptName), `tools/run-client-verify.mjs must include ${scriptName}`);
}
for (const scriptName of releaseBoundarySelfTestScripts) {
  assert(verifyRunner.includes(scriptName),
    `tools/run-client-verify.mjs must include ${scriptName}`);
}
assert(!verifyRunner.includes('["npm", ["run", "client:verify:client-release-acceptance"]]'),
  "default client verification must not invoke the side-effecting release reducer");
assert(scripts["client:verify:github-release"]?.includes(
  "client-github-release-acceptance.mjs"),
"explicit GitHub release must invoke the artifact-only reducer");
assert(scripts["client:verify:product-line-security"]?.includes(
  "client-release-acceptance.mjs"),
"product-line security must invoke the full evidence reducer");


}
