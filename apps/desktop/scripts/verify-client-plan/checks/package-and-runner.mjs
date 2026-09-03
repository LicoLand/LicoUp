export async function checkPackageAndRunner({ assert, files, context }) {
  const { readJson, readSourceBundle, readText } = files;
  const { releaseBoundarySelfTestScripts, requiredClientScripts } = context;
  const packageJson = await readJson("package.json");
  const scripts = packageJson.scripts || {};

  assert(
    packageJson.private === false,
    "package.json must identify the open-source client repository",
  );
  assert(
    packageJson.license === "AGPL-3.0-or-later",
    "package.json must use AGPL-3.0-or-later",
  );

  const scriptNamesByCommand = new Map();
  for (const [scriptName, command] of Object.entries(scripts)) {
    if (typeof command !== "string") continue;
    const normalizedCommand = command.trim();
    const scriptNames = scriptNamesByCommand.get(normalizedCommand) || [];
    scriptNames.push(scriptName);
    scriptNamesByCommand.set(normalizedCommand, scriptNames);
  }
  for (const scriptNames of scriptNamesByCommand.values()) {
    assert(
      scriptNames.length === 1,
      `package.json scripts must use one canonical name per command: ${scriptNames.join(", ")}`,
    );
  }

  for (const scriptName of requiredClientScripts) {
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
    "client:build",
    "client:verify:macos-bundle",
    "client:install:macos",
    "client:analyze",
    "client:test",
    "client:native:test",
  ]) {
    assert(Boolean(scripts[scriptName]), `package.json must define ${scriptName}`);
  }

  const gatePolicy = await readText("tools/scripts/client-gate-policy.mjs");
  const gateRunner = await readText("tools/scripts/client-gate.mjs");
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
    "delete offlineEnv.PUB_HOSTED_URL",
  ]) {
    assert(
      clientToolchainRunner.includes(token),
      `client toolchain runner must preserve locked-cache pub get fallback token ${token}`,
    );
  }

  for (const scriptName of releaseBoundarySelfTestScripts) {
    assert(
      gatePolicy.includes(scriptName),
      `release-policy lane must include ${scriptName}`,
    );
  }
  for (const lane of [
    "source",
    "flutter",
    "rust",
    "android",
    "dependencies",
    "release-policy",
  ]) {
    const declaration = lane.includes("-")
      ? `"${lane}": freezeLane([`
      : `${lane}: freezeLane([`;
    assert(
      gatePolicy.includes(declaration),
      `client gate policy must define independent ${lane} lane`,
    );
  }
  for (const token of [
    "classifyClientGatePaths",
    "validateClientGateTopology",
    "client-required",
    "validateDelegatedApplePublicationTopology",
  ]) {
    assert(gateRunner.includes(token), `client gate runner must enforce ${token}`);
  }
  const sourceLane = gatePolicy
    .split("source: freezeLane([")[1]
    ?.split("flutter: freezeLane([")[0] || "";
  for (const forbidden of [
    "client:get",
    "client:native:",
    "client:test:android:native",
    "client:deps:audit",
    "client:verify:release-artifact-io:self-test",
  ]) {
    assert(
      !sourceLane.includes(forbidden),
      `source gate must not include platform or release step ${forbidden}`,
    );
  }

  assert(
    scripts["client:release:macos"]?.includes("apple-release release start"),
    "macOS publication must be delegated to Apple Release",
  );
  assert(
    scripts["client:verify:product-line-security"]?.includes(
      "client-release-acceptance.mjs",
    ),
    "product-line security must invoke the full evidence reducer",
  );
}
