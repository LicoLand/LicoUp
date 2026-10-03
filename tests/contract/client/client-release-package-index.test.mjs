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

test("the canonical release configuration declares the independent package pair exactly", () => {
  const catalog = readJson("tools/client-release-targets.json");
  const template = readJson("tools/client-release-template.json");
  const stable = readJson("tools/apple-release/macos-direct-arm64.json");
  const nightly = readJson("tools/apple-release/macos-direct-arm64-nightly.json");
  const macos = catalog.targets.find((target) => target.id === "macos-direct-arm64");

  assert.deepEqual(
    macos.artifacts.filter((artifact) =>
      artifact.role === PACKAGE_PAYLOAD_ROLE || artifact.role === PACKAGE_INDEX_ROLE),
    [
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
  // The pair belongs to the one target that owns a release closure today; no
  // other target silently inherits a package asset.
  for (const target of catalog.targets) {
    const roles = target.artifacts.map((artifact) => artifact.role);
    assert.equal(
      roles.includes(PACKAGE_PAYLOAD_ROLE) || roles.includes(PACKAGE_INDEX_ROLE),
      target.id === "macos-direct-arm64",
      `${target.id} must not carry an independent package asset`,
    );
  }

  // The publication authority owns a closed draft asset contract, so the
  // package pair is declared beside the client draft rather than inside it.
  const publication = template.publication;
  assert.equal(publication.exactDraftAssetSetRequired, true);
  assert.deepEqual(publication.independentPackageAssets, {
    payloadRole: PACKAGE_PAYLOAD_ROLE,
    indexRole: PACKAGE_INDEX_ROLE,
    producer: "tools/scripts/client-release-package-index.mjs",
    clientDraftCarries: false,
    signedIndexRequired: true,
  });
  assert.equal(publication.assetRoles.includes(PACKAGE_PAYLOAD_ROLE), false);
  assert.equal(publication.assetRoles.includes(PACKAGE_INDEX_ROLE), false);
  for (const config of [stable, nightly]) {
    assert.deepEqual(
      config.artifacts.map((entry) => entry.role),
      publication.assetRoles,
      "exactDraftAssetSetRequired still holds with the independent package pair",
    );
    for (const role of [PACKAGE_PAYLOAD_ROLE, PACKAGE_INDEX_ROLE]) {
      assert.equal(config.artifacts.some((entry) => entry.role === role), false,
        `${role} must not enter the closed client draft`);
    }
  }
});

test("the fixture packages a native converter and a signed index without protected keys or network", (t) => {
  const root = temporaryRoot(t);
  const first = invoke(["fixture", "--output", path.join(root, "first")]);
  assert.equal(first.status, 0, first.stderr);
  const firstResult = JSON.parse(first.stdout);
  assert.equal(firstResult.ok, true);
  assert.equal(firstResult.protectedKeysUsed, false);
  assert.equal(firstResult.publicationPerformed, false);
  assert.equal(firstResult.signingKeysGeneratedInMemory, true);
  assert.equal(firstResult.privatePathsIncluded, false);
  assert.equal(firstResult.payloadPath.endsWith(payloadAsset), true);
  assert.equal(firstResult.indexPath.endsWith(indexAsset), true);

  const indexText = readFileSync(path.join(root, "first", indexAsset), "utf8");
  const publicKeysText = readFileSync(
    path.join(root, "first", firstResult.publicKeysPath.split("/").at(-1)), "utf8",
  );
  const index = verifyPackageIndex(indexText, publicKeysText);
  assert.equal(index.schemaVersion, PACKAGE_INDEX_SCHEMA);
  assert.equal(index.packages.length, 1);
  const entry = index.packages[0];
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
  assert.equal(verifiedPackageIds(index, path.join(root, "first")).length, 1);

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
  assert.equal(secondResult.payloadDigest, firstResult.payloadDigest);
  assert.equal(
    readFileSync(path.join(root, "second", payloadAsset)).equals(payload),
    true,
  );
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
    [index.packages[0].packageId]);

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

test("the plan reports the declared package without writing, and the tool reaches no network", (t) => {
  const root = temporaryRoot(t);
  const plan = planPackageRelease();
  assert.equal(plan.ok, true);
  assert.equal(plan.writesPerformed, false);
  assert.equal(plan.publicationPerformed, false);
  assert.equal(plan.indexFile, indexAsset);
  assert.equal(plan.packages.length, 1);
  assert.equal(plan.packages[0].payloadFile, payloadAsset);
  assert.match(plan.packages[0].payloadDigest, /^sha256:[0-9a-f]{64}$/u);
  assert.equal(plan.packages[0].source, fixtureSource);
  assert.deepEqual(plan.packages[0].clientCompatibility,
    { kind: "range", range: ">=0.2.0 <1.0.0" });
  assert.equal(plan.packages[0].converterEntry, "bin/licoup-fixture-converter");
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
    packages: [{ packageId: manifest.id, source: "package" }],
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
    clientVersionSatisfies({ kind: "range", range: ">=0.2.0 <1.0.0" }, "0.3.0"),
    true,
  );
  assert.equal(
    clientVersionSatisfies({ kind: "range", range: ">=0.2.0 <1.0.0" }, "1.0.0"),
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

function verifiedPackageIds(index, payloadRoot) {
  return [...verifyIndexPayloads(index, payloadRoot)];
}
