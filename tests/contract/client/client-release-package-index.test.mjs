// Local release fixture for the independent package asset and its signed index.
//
// The fixture proves the release configuration, the payload packaging and the
// signed index format work end to end on synthetic bytes in a disposable
// directory: the committed synthetic package is packaged deterministically, the
// index is authenticated with the same Ed25519 role mechanism the client update
// manifest already uses, and re-verification refuses a payload that is not the
// one the index describes. Nothing here signs with a protected key, reaches the
// network or publishes anything.
//
// The offline import of the same fixture package is exercised by the native
// package lifecycle harness (`crates/licoup-native/tests/package_lifecycle`),
// which imports the fixture through `PackageStore::install_local_import`.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  PACKAGE_INDEX_ROLE,
  PACKAGE_INDEX_SCHEMA,
  PACKAGE_PAYLOAD_ROLE,
  PACKAGE_RELEASE_SCHEMA,
  PACKAGE_SET_SCHEMA,
  buildIndex,
  clientVersionSatisfies,
  indexEntry,
  loadPackageSet,
  planPackageRelease,
  producePackagePayload,
  publicClientCompatibility,
  signIndex,
  verifyIndexPayloads,
  verifyPackageIndex,
} from "../../../tools/scripts/client-release-package-index.mjs";
import {
  PACKAGE_PAYLOAD_DECLARATION_NAME,
  PACKAGE_PAYLOAD_MANIFEST_NAME,
  interpreterScriptEntryName,
  readPackagePayload,
} from "../../../tools/scripts/lib/client-release-package-payload.mjs";
import {
  loadClientReleaseTargetCatalog,
} from "../../../tools/scripts/lib/client-release-targets.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const script = "tools/scripts/client-release-package-index.mjs";
const fixtureSource = "tests/fixtures/client_package_release/fixture-native-converter";
const payloadAsset = "LicoUp-package-fixture-native-converter.licopkg";
const indexAsset = "LicoUp-package-index.json";
// The MCP service package is the first real declared package: it is released
// beside the synthetic fixture under the same contract, on its own payload role.
const mcpPackageId = "org.licoland.feature.mcp";
const mcpPackageSource = "crates/licoup-mcp/package";
const mcpPayloadRole = "mcp-package-payload";
const mcpPayloadAsset = `LicoUp-package-${mcpPackageId}.licopkg`;
// The Codex adapter package is the first Agent adapter released this way: it is
// declared beside the MCP service and the synthetic fixture, on its own payload
// role, so one package's asset can never stand in for another's.
const codexPackageId = "org.licoland.adapter.codex";
const codexPackageSource = "crates/licoup-agent-codex/package";
const codexPayloadRole = "codex-adapter-package-payload";
const codexPayloadAsset = `LicoUp-package-${codexPackageId}.licopkg`;
// The OpenClaw adapter package is the second Agent adapter released this way: it
// carries its own payload role for the same reason Codex's does.
const openclawPackageId = "org.licoland.adapter.openclaw";
const openclawPackageSource = "crates/licoup-agent-openclaw/package";
const openclawPayloadRole = "openclaw-adapter-package-payload";
const openclawPayloadAsset = `LicoUp-package-${openclawPackageId}.licopkg`;
const clientProductVersion = JSON.parse(readFileSync(
  path.join(repoRoot, "tools/client-version.json"), "utf8",
)).productVersion;

function readJson(relativePath) {
  return JSON.parse(readFileSync(path.join(repoRoot, relativePath), "utf8"));
}

function temporaryRoot(t) {
  const root = mkdtempSync(path.join(realpathSync(os.tmpdir()), "lico-package-index-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

function invoke(args, options = {}) {
  return spawnSync(process.execPath, [script, ...args], {
    cwd: repoRoot,
    env: { ...process.env, ...(options.env || {}) },
    encoding: "utf8",
    shell: false,
    stdio: "pipe",
    timeout: 60_000,
    maxBuffer: 4 * 1024 * 1024,
  });
}

test("the canonical release configuration declares every package payload role exactly", () => {
  const catalog = readJson("tools/client-release-targets.json");
  const template = readJson("tools/client-release-template.json");
  const stable = readJson("tools/apple-release/macos-direct-arm64.json");
  const nightly = readJson("tools/apple-release/macos-direct-arm64-nightly.json");
  const macos = catalog.targets.find((target) => target.id === "macos-direct-arm64");

  assert.deepEqual(
    macos.artifacts.filter((artifact) => artifact.role.endsWith("-payload") ||
      artifact.role === PACKAGE_INDEX_ROLE),
    [
      {
        role: codexPayloadRole,
        file: codexPayloadAsset,
        source: `build/apps/desktop/native-release/macos-direct-arm64/${codexPayloadAsset}`,
      },
      {
        role: openclawPayloadRole,
        file: openclawPayloadAsset,
        source: `build/apps/desktop/native-release/macos-direct-arm64/${openclawPayloadAsset}`,
      },
      {
        role: mcpPayloadRole,
        file: mcpPayloadAsset,
        source: `build/apps/desktop/native-release/macos-direct-arm64/${mcpPayloadAsset}`,
      },
      {
        role: PACKAGE_PAYLOAD_ROLE,
        file: payloadAsset,
        source: `build/apps/desktop/native-release/macos-direct-arm64/${payloadAsset}`,
      },
      {
        role: PACKAGE_INDEX_ROLE,
        file: indexAsset,
        source: `build/apps/desktop/native-release/macos-direct-arm64/${indexAsset}`,
      },
    ],
  );
  // The payload assets belong to the one target that owns a release closure
  // today; no other target silently inherits a package asset.
  for (const target of catalog.targets) {
    const roles = target.artifacts.map((artifact) => artifact.role);
    assert.equal(
      roles.includes(PACKAGE_PAYLOAD_ROLE) || roles.includes(PACKAGE_INDEX_ROLE) ||
        roles.includes(mcpPayloadRole) || roles.includes(codexPayloadRole) ||
        roles.includes(openclawPayloadRole),
      target.id === "macos-direct-arm64",
      `${target.id} must not carry an independent package asset`,
    );
  }

  // The publication authority owns a closed draft asset contract, so the package
  // assets are declared beside the client draft rather than inside it.
  const publication = template.publication;
  assert.equal(publication.exactDraftAssetSetRequired, true);
  assert.deepEqual(publication.independentPackageAssets, {
    payloadRoles: [codexPayloadRole, openclawPayloadRole, mcpPayloadRole, PACKAGE_PAYLOAD_ROLE],
    indexRole: PACKAGE_INDEX_ROLE,
    producer: "tools/scripts/client-release-package-index.mjs",
    clientDraftCarries: false,
    signedIndexRequired: true,
  });
  assert.equal(publication.assetRoles.includes(PACKAGE_PAYLOAD_ROLE), false);
  assert.equal(publication.assetRoles.includes(mcpPayloadRole), false);
  assert.equal(publication.assetRoles.includes(codexPayloadRole), false);
  assert.equal(publication.assetRoles.includes(openclawPayloadRole), false);
  assert.equal(publication.assetRoles.includes(PACKAGE_INDEX_ROLE), false);
  for (const config of [stable, nightly]) {
    assert.deepEqual(
      config.artifacts.map((entry) => entry.role),
      publication.assetRoles,
      "exactDraftAssetSetRequired still holds with the independent package assets",
    );
    for (const role of [PACKAGE_PAYLOAD_ROLE, mcpPayloadRole, codexPayloadRole,
      openclawPayloadRole, PACKAGE_INDEX_ROLE]) {
      assert.equal(config.artifacts.some((entry) => entry.role === role), false,
        `${role} must not enter the closed client draft`);
    }
  }
  // The declared set and the publication contract name the same payload roles:
  // a package without a role, or a role without a package, is a release that
  // cannot be staged.
  const set = readJson("tools/client-release-package-set.json");
  assert.deepEqual(
    [...set.packages.map((entry) => entry.payloadRole)].sort(),
    [...publication.independentPackageAssets.payloadRoles].sort(),
  );
});

test("the trial packages every declared payload and one signed index without protected keys or network", (t) => {
  const root = temporaryRoot(t);
  const first = invoke(["fixture", "--output", path.join(root, "first")]);
  assert.equal(first.status, 0, first.stderr);
  const firstResult = JSON.parse(first.stdout);
  assert.equal(firstResult.ok, true);
  assert.equal(firstResult.protectedKeysUsed, false);
  assert.equal(firstResult.publicationPerformed, false);
  assert.equal(firstResult.signingKeysGeneratedInMemory, true);
  assert.equal(firstResult.privatePathsIncluded, false);
  assert.deepEqual(firstResult.payloads.map((entry) => entry.payloadRole),
    [codexPayloadRole, openclawPayloadRole, mcpPayloadRole, PACKAGE_PAYLOAD_ROLE]);
  assert.equal(firstResult.payloads[0].payloadPath.endsWith(codexPayloadAsset), true);
  assert.equal(firstResult.payloads[1].payloadPath.endsWith(openclawPayloadAsset), true);
  assert.equal(firstResult.payloads[2].payloadPath.endsWith(mcpPayloadAsset), true);
  assert.equal(firstResult.payloads[3].payloadPath.endsWith(payloadAsset), true);
  assert.equal(firstResult.indexPath.endsWith(indexAsset), true);

  const indexText = readFileSync(path.join(root, "first", indexAsset), "utf8");
  const publicKeysText = readFileSync(
    path.join(root, "first", firstResult.publicKeysPath.split("/").at(-1)), "utf8",
  );
  const index = verifyPackageIndex(indexText, publicKeysText);
  assert.equal(index.schemaVersion, PACKAGE_INDEX_SCHEMA);
  // One index carries one entry per declared package, ordered by identity, and
  // every entry is the package's own declaration rather than the caller's.
  assert.deepEqual(index.packages.map((item) => item.packageId),
    [codexPackageId, openclawPackageId, mcpPackageId,
      "org.licoland.fixture.native-converter"]);
  const entry = index.packages[3];
  const manifest = JSON.parse(readFileSync(path.join(repoRoot, fixtureSource, "manifest.json"), "utf8"));
  const declaration = JSON.parse(
    readFileSync(path.join(repoRoot, fixtureSource, "package-release.json"), "utf8"),
  );
  assert.equal(entry.packageId, declaration.packageId);
  assert.equal(entry.packageVersion, declaration.packageVersion);
  // The package version is chosen independently of the client product version.
  assert.notEqual(entry.packageVersion, clientProductVersion);
  assert.deepEqual(entry.hostProtocol, manifest.hostProtocol);
  assert.deepEqual(entry.converter, declaration.converter);
  assert.deepEqual(entry.clientCompatibility, declaration.clientCompatibility);
  assert.equal(entry.payload.fileName, payloadAsset);
  assert.match(entry.payload.sha256, /^sha256:[0-9a-f]{64}$/u);
  assert.deepEqual(verifiedPackageIds(index, path.join(root, "first")),
    [codexPackageId, openclawPackageId, mcpPackageId,
      "org.licoland.fixture.native-converter"]);

  // The payload carries exactly the package's own declaration and no
  // interpreter entry, and the release document names no network location: the
  // index and its payload are self-contained beside each other.
  const payload = readFileSync(path.join(root, "first", payloadAsset));
  assert.equal(indexText.includes("http://"), false);
  assert.equal(indexText.includes("https://"), false);
  assert.equal(payload.includes(Buffer.from("https://")), false);
  const entries = readPackagePayload(payload);
  const names = entries.map((item) => item.name).sort();
  assert.deepEqual(names, ["bin/licoup-fixture-converter", "manifest.json", "package-release.json"]);
  assert.deepEqual(
    JSON.parse(entries.find((item) => item.name === PACKAGE_PAYLOAD_MANIFEST_NAME)
      .content.toString("utf8")).runtime,
    { mode: "process", entry: declaration.converter.entry },
  );
  assert.equal(entries.find((item) =>
    item.name === declaration.converter.entry).mode & 0o111, 0o111);
  for (const item of entries) {
    assert.equal(interpreterScriptEntryName(item.name), "");
    assert.notEqual(item.content.subarray(0, 2).toString("utf8"), "#!");
  }

  // The same declared sources package to the same bytes on a second run, so the
  // signed digest binds what the release stages.
  const second = invoke(["fixture", "--output", path.join(root, "second")]);
  assert.equal(second.status, 0, second.stderr);
  const secondResult = JSON.parse(second.stdout);
  assert.deepEqual(secondResult.payloads.map((entry) => entry.payloadDigest),
    firstResult.payloads.map((entry) => entry.payloadDigest));
  for (const [position, asset] of [codexPayloadAsset, openclawPayloadAsset, mcpPayloadAsset,
    payloadAsset].entries()) {
    assert.equal(
      readFileSync(path.join(root, "second", asset))
        .equals(readFileSync(path.join(root, "first", asset))),
      true,
      `${firstResult.payloads[position].packageId} packages to the same bytes`,
    );
  }
  assert.notEqual(
    readFileSync(path.join(root, "second", indexAsset), "utf8"),
    indexText,
    "a disposable trial signs with a fresh key pair each run",
  );
});

test("a tampered payload or index is refused", (t) => {
  const root = temporaryRoot(t);
  const fixture = invoke(["fixture", "--output", path.join(root, "assets")]);
  assert.equal(fixture.status, 0, fixture.stderr);
  const result = JSON.parse(fixture.stdout);
  const indexText = readFileSync(path.join(root, "assets", indexAsset), "utf8");
  const publicKeysPath = path.join(
    root, "assets", result.publicKeysPath.split("/").at(-1),
  );
  const publicKeysText = readFileSync(publicKeysPath, "utf8");
  const index = verifyPackageIndex(indexText, publicKeysText);

  // A payload that does not match the signed digest is refused.
  const payloadPath = path.join(root, "assets", payloadAsset);
  const original = readFileSync(payloadPath);
  writeFileSync(payloadPath, Buffer.concat([original, Buffer.from("tampered")]));
  assert.throws(() => verifyIndexPayloads(index, path.join(root, "assets")),
    /package_index_payload_invalid/u);
  writeFileSync(payloadPath, original);
  assert.deepEqual(verifiedPackageIds(index, path.join(root, "assets")),
    index.packages.map((entry) => entry.packageId));

  // A tampered index loses its signatures.
  const tampered = JSON.parse(indexText);
  tampered.packages[0].payload.sha256 = `sha256:${"0".repeat(64)}`;
  assert.throws(() => verifyPackageIndex(JSON.stringify(tampered), publicKeysText),
    /package_index_signature_invalid/u);
  const extended = JSON.parse(indexText);
  extended.eligibilityOverride = true;
  assert.throws(() => verifyPackageIndex(JSON.stringify(extended), publicKeysText),
    /package_index_invalid/u);
  const foreignKeys = JSON.parse(publicKeysText);
  foreignKeys.keys["fixture-offline-root"].publicKey =
    Buffer.alloc(32, 7).toString("base64");
  assert.throws(() => verifyPackageIndex(indexText, JSON.stringify(foreignKeys)),
    /package_index_signature_invalid/u);

  // The release-authority keys are never read from a fixture, and the build
  // command fails closed before writing without them.
  const env = { ...process.env };
  delete env.LICO_PACKAGE_INDEX_OFFLINE_ROOT_KEY;
  delete env.LICO_PACKAGE_INDEX_ONLINE_SIGNING_KEY;
  const build = invoke(["build", "--output", path.join(root, "build-output")], { env });
  assert.notEqual(build.status, 0);
  assert.equal(JSON.parse(build.stderr).code, "package_index_signing_key_required");
  assert.equal(JSON.parse(build.stderr).privatePathsIncluded, false);
  assert.throws(() => readFileSync(path.join(root, "build-output", indexAsset)));
});

test("the plan reports every declared package without writing, and the tool reaches no network", (t) => {
  const root = temporaryRoot(t);
  const plan = planPackageRelease();
  assert.equal(plan.ok, true);
  assert.equal(plan.writesPerformed, false);
  assert.equal(plan.publicationPerformed, false);
  assert.equal(plan.indexFile, indexAsset);
  assert.deepEqual(plan.packages.map((entry) => [entry.packageId, entry.payloadRole,
    entry.payloadFile]),
  [
    [codexPackageId, codexPayloadRole, codexPayloadAsset],
    [openclawPackageId, openclawPayloadRole, openclawPayloadAsset],
    [mcpPackageId, mcpPayloadRole, mcpPayloadAsset],
    ["org.licoland.fixture.native-converter", PACKAGE_PAYLOAD_ROLE, payloadAsset],
  ]);
  const fixturePlan = plan.packages[3];
  assert.match(fixturePlan.payloadDigest, /^sha256:[0-9a-f]{64}$/u);
  assert.equal(fixturePlan.source, fixtureSource);
  assert.deepEqual(fixturePlan.clientCompatibility,
    { kind: "range", range: ">=0.2.0, <1.0.0" });
  assert.equal(fixturePlan.converterEntry, "bin/licoup-fixture-converter");
  const mcpPlan = plan.packages[2];
  assert.equal(mcpPlan.source, mcpPackageSource);
  assert.match(mcpPlan.payloadDigest, /^sha256:[0-9a-f]{64}$/u);
  assert.deepEqual(mcpPlan.clientCompatibility,
    { kind: "range", range: ">=0.3.0, <1.0.0" });
  assert.equal(mcpPlan.converterEntry, "bin/lico-subagent-mcp");
  const codexPlan = plan.packages[0];
  assert.equal(codexPlan.source, codexPackageSource);
  assert.match(codexPlan.payloadDigest, /^sha256:[0-9a-f]{64}$/u);
  assert.deepEqual(codexPlan.clientCompatibility,
    { kind: "range", range: ">=0.3.0, <1.0.0" });
  assert.equal(codexPlan.converterEntry, "bin/lico-agent-codex");
  assert.equal(readdirSync(root).length, 0, "plan must not write anything");

  const sources = [
    "tools/scripts/client-release-package-index.mjs",
    "tools/scripts/lib/client-release-package-payload.mjs",
  ].map((relative) => readFileSync(path.join(repoRoot, relative), "utf8"));
  for (const source of sources) {
    for (const forbidden of [
      "node:http", "node:https", "node:net", "node:dgram", "node:tls",
      "fetch(", "XMLHttpRequest", "require(\"http\")",
    ]) {
      assert.equal(source.includes(forbidden), false,
        `the package index tool must not reach the network: ${forbidden}`);
    }
  }
});

test("the package's own declaration decides its identity, compatibility form and converter", (t) => {
  const root = temporaryRoot(t);
  // A second declaration of the same payload shape: the index must carry the
  // major-version compatibility form and the version the package declares, not
  // anything the caller supplies.
  const packageRoot = path.join(root, "package");
  mkdirSync(path.join(packageRoot, "bin"), { recursive: true });
  const manifest = JSON.parse(readFileSync(path.join(repoRoot, fixtureSource, "manifest.json"), "utf8"));
  writeFileSync(path.join(packageRoot, "manifest.json"), `${JSON.stringify({
    ...manifest,
    version: "2.0.0",
  }, null, 2)}\n`);
  writeFileSync(path.join(packageRoot, "bin", "licoup-fixture-converter"),
    readFileSync(path.join(repoRoot, fixtureSource, "bin", "licoup-fixture-converter")));
  writeFileSync(path.join(packageRoot, "package-release.json"), `${JSON.stringify({
    schemaVersion: PACKAGE_RELEASE_SCHEMA,
    packageId: manifest.id,
    packageVersion: "2.0.0",
    clientCompatibility: { kind: "major", majors: [1, 2] },
    converter: {
      kind: "native-executable",
      entry: "bin/licoup-fixture-converter",
      sourceFormat: "fixture.agent-session.v2",
      targetFormat: "licoup.conversation.v1",
    },
  }, null, 2)}\n`);
  // The entry must stay executable in the copied fixture.
  chmodSync(path.join(packageRoot, "bin", "licoup-fixture-converter"), 0o755);
  const setPath = path.join(root, "package-set.json");
  writeFileSync(setPath, `${JSON.stringify({
    schemaVersion: PACKAGE_SET_SCHEMA,
    packages: [{
      packageId: manifest.id,
      source: "package",
      payloadRole: PACKAGE_PAYLOAD_ROLE,
    }],
  }, null, 2)}\n`);

  const produced = producePackagePayload(
    loadPackageSet(setPath, { root }).packages[0],
  );
  assert.equal(produced.manifest.packageVersion, "2.0.0");
  assert.deepEqual(publicClientCompatibility(produced.declaration.clientCompatibility),
    { kind: "major", majors: [1, 2] });
  assert.equal(clientVersionSatisfies({ kind: "major", majors: [1, 2] }, "1.3.0"), true);
  assert.equal(clientVersionSatisfies({ kind: "major", majors: [1, 2] }, "0.3.0"), false);
  assert.equal(
    clientVersionSatisfies({ kind: "range", range: ">=0.2.0, <1.0.0" }, "0.3.0"),
    true,
  );
  assert.equal(
    clientVersionSatisfies({ kind: "range", range: ">=0.2.0, <1.0.0" }, "1.0.0"),
    false,
  );

  const keyPair = () => {
    const pair = generateKeyPairSync("ed25519");
    return {
      privateKey: pair.privateKey,
      publicKey: Buffer.from(pair.publicKey.export({ type: "spki", format: "der" }))
        .subarray(-32).toString("base64"),
    };
  };
  const offlineRoot = keyPair();
  const onlineSigning = keyPair();
  const keys = [
    { keyId: "fixture-offline-root", privateKey: offlineRoot.privateKey },
    { keyId: "fixture-online-signing", privateKey: onlineSigning.privateKey },
  ];
  const signedIndex = signIndex(buildIndex({
    releaseTrack: "nightly",
    packages: [indexEntry(produced, payloadAsset)],
    offlineRootKeyId: "fixture-offline-root",
    onlineSigningKeyId: "fixture-online-signing",
  }), keys);
  const payloadRoot = path.join(root, "payloads");
  mkdirSync(payloadRoot, { recursive: true });
  writeFileSync(path.join(payloadRoot, payloadAsset), produced.payload);
  const verified = verifyPackageIndex(JSON.stringify(signedIndex), JSON.stringify({
    keys: {
      "fixture-offline-root": { publicKey: offlineRoot.publicKey },
      "fixture-online-signing": { publicKey: onlineSigning.publicKey },
    },
  }));
  assert.equal(verified.releaseTrack, "nightly");
  assert.deepEqual(verified.packages[0].clientCompatibility,
    { kind: "major", majors: [1, 2] });
  assert.deepEqual(verifiedPackageIds(verified, payloadRoot), [manifest.id]);

  // The declared identity is not decorative: a caller that expects another
  // package id cannot publish this source.
  assert.throws(() => producePackagePayload(
    loadPackageSet(setPath, { root }).packages[0],
    { expectedPackageId: "org.licoland.fixture.other" },
  ), /package_index_package_identity_mismatch/u);
});

test("the real MCP service package builds a deterministic payload and its own index entry", () => {
  const declared = loadPackageSet().packages.find((entry) =>
    entry.packageId === mcpPackageId);
  assert.ok(declared, `${mcpPackageId} must be a declared package`);
  assert.equal(declared.payloadRole, mcpPayloadRole);
  assert.equal(declared.source, mcpPackageSource);

  // The committed sources package to the same bytes on every run, so the signed
  // digest binds exactly what the release stages.
  const produced = producePackagePayload(declared);
  const repeated = producePackagePayload(declared);
  assert.equal(produced.sha256, repeated.sha256);
  assert.equal(produced.payload.equals(repeated.payload), true);
  assert.equal(produced.byteSize, produced.payload.length);

  // The payload carries the package's own committed documents verbatim, its
  // native entry and the resources its contributions declare, and nothing else.
  const entries = readPackagePayload(produced.payload);
  assert.deepEqual(entries.map((entry) => entry.name),
    ["bin/lico-subagent-mcp", "contributions/service-status.json", "manifest.json",
      "package-release.json"]);
  const manifestText = readFileSync(path.join(repoRoot, mcpPackageSource, "manifest.json"), "utf8");
  const declarationText = readFileSync(
    path.join(repoRoot, mcpPackageSource, "package-release.json"), "utf8",
  );
  assert.equal(entries.find((entry) => entry.name === PACKAGE_PAYLOAD_MANIFEST_NAME)
    .content.toString("utf8"), manifestText);
  assert.equal(entries.find((entry) => entry.name === PACKAGE_PAYLOAD_DECLARATION_NAME)
    .content.toString("utf8"), declarationText);
  const manifest = JSON.parse(manifestText);
  const declaration = JSON.parse(declarationText);
  assert.equal(manifest.id, mcpPackageId);
  assert.equal(produced.manifest.packageId, mcpPackageId);
  assert.equal(manifest.version, declaration.packageVersion);
  assert.deepEqual(manifest.hostProtocol, produced.manifest.hostProtocol);
  // The manifest's required compatibility list and the release declaration's
  // compatibility form are the same claim in the two formats the host reads.
  assert.deepEqual(manifest.compatibility.clientVersions, [declaration.clientCompatibility.range]);

  // The declared runtime is a native process: no interpreter, no runtime
  // reference and no install script anywhere in the payload.
  assert.deepEqual(manifest.runtime, {
    mode: "process",
    entry: declaration.converter.entry,
  });
  assert.equal(manifest.runtime.entry, "bin/lico-subagent-mcp");
  assert.equal(Object.hasOwn(manifest, "installScript"), false);
  const nativeEntry = entries.find((entry) => entry.name === manifest.runtime.entry);
  assert.equal(nativeEntry.mode & 0o111, 0o111, "the declared entry is executable");
  for (const entry of entries) {
    assert.equal(interpreterScriptEntryName(entry.name), "");
    assert.notEqual(entry.content.subarray(0, 2).toString("utf8"), "#!");
  }

  // The declared data footprint is attributable: every permission belongs to the
  // package's own namespace, and every contribution names a resource the payload
  // actually ships and that parses as a declarative interface contribution.
  assert.equal(manifest.permissions.length, 3);
  for (const permission of manifest.permissions) {
    assert.equal(permission.capability.startsWith(`${mcpPackageId}/`), true,
      `${permission.capability} must be requested under the package's own namespace`);
    assert.equal(permission.scope.length > 0, true);
  }
  assert.equal(manifest.profiles.length, 1);
  assert.deepEqual(manifest.profiles[0].capabilities, ["mcp-server.v1"]);
  assert.equal(manifest.contributions.length, 1);
  const contribution = manifest.contributions[0];
  assert.equal(contribution.id, "org.licoland.feature.mcp/service-status");
  const resource = JSON.parse(entries.find((entry) =>
    entry.name === contribution.definition).content.toString("utf8"));
  assert.deepEqual(resource, {
    schema: "licoup.ui-contribution.v1",
    id: contribution.id,
    kind: contribution.kind,
    title: "Subagent MCP service status",
    actionRef: "org.licoland.feature.mcp/service/status",
  });

  // The package's own compatibility list admits the declared client line and
  // refuses a client outside it, before any client reads the index.
  const compatibility = publicClientCompatibility(produced.declaration.clientCompatibility);
  assert.equal(clientVersionSatisfies(compatibility, "0.3.0"), true);
  assert.equal(clientVersionSatisfies(compatibility, "0.9.9"), true);
  assert.equal(clientVersionSatisfies(compatibility, "0.2.9"), false);
  assert.equal(clientVersionSatisfies(compatibility, "1.0.0"), false);

  // The signed index republishes that declaration beside the payload digest, and
  // re-verification reads the payload back and finds the same package.
  const root = mkdtempSync(path.join(realpathSync(os.tmpdir()), "lico-mcp-package-"));
  try {
    const keys = ["mcp-offline-root", "mcp-online-signing"].map((keyId) => ({
      keyId,
      ...(() => {
        const pair = generateKeyPairSync("ed25519");
        return {
          privateKey: pair.privateKey,
          publicKey: Buffer.from(pair.publicKey.export({ type: "spki", format: "der" }))
            .subarray(-32).toString("base64"),
        };
      })(),
    }));
    const signed = signIndex(buildIndex({
      releaseTrack: "stable",
      packages: [indexEntry(produced, mcpPayloadAsset)],
      offlineRootKeyId: keys[0].keyId,
      onlineSigningKeyId: keys[1].keyId,
    }), keys);
    writeFileSync(path.join(root, mcpPayloadAsset), produced.payload);
    const verified = verifyPackageIndex(JSON.stringify(signed), JSON.stringify({
      keys: Object.fromEntries(keys.map((key) => [key.keyId, { publicKey: key.publicKey }])),
    }));
    const entry = verified.packages[0];
    assert.equal(entry.packageId, mcpPackageId);
    assert.equal(entry.packageVersion, declaration.packageVersion);
    assert.deepEqual(entry.hostProtocol, manifest.hostProtocol);
    assert.deepEqual(entry.clientCompatibility, declaration.clientCompatibility);
    assert.deepEqual(entry.converter, declaration.converter);
    assert.equal(entry.payload.fileName, mcpPayloadAsset);
    assert.equal(entry.payload.sha256, produced.sha256);
    assert.deepEqual(verifiedPackageIds(verified, root), [mcpPackageId]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

function verifiedPackageIds(index, payloadRoot) {
  return [...verifyIndexPayloads(index, payloadRoot)];
}
