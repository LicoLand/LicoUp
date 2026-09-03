#!/usr/bin/env node

// Generates the signed LicoUp-update-manifest.json release asset that
// clients verify against the bundled public keys
// (crates/licoup-native/resources/client-update-public-keys.json) before
// selecting an update artifact. The manifest schema is
// v0.0.1:client-update:manifest-2 and the signatures must match the Rust
// canonical stable-stringify used by crates/licoup-native.

import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign,
  verify,
} from "node:crypto";
import {
  lstatSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { CLIENT_RELEASE_TARGETS } from "./client-gate-policy.mjs";
import { sha256File } from "./lib/client-release-artifact-digest.mjs";
import {
  loadClientReleaseTargetCatalog,
  selectClientReleaseTargets,
} from "./lib/client-release-targets.mjs";

const MANIFEST_SCHEMA = "v0.0.1:client-update:manifest-2";
const MANIFEST_NAME = "LicoUp-update-manifest.json";
const PUBLIC_KEYS_NAME = "LicoUp-update-public-keys.json";
const MAX_MANIFEST_BYTES = 1024 * 1024;

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const bundledPublicKeysPath = path.join(
  repoRoot,
  "crates",
  "licoup-native",
  "resources",
  "client-update-public-keys.json",
);
const MACOS_APPLICATION_NAME = "LicoUp.app";
const MACOS_BUNDLE_ID = "land.lico.licoup";
const migrationFrontierPath = path.join(
  repoRoot,
  "crates",
  "licoup-native",
  "resources",
  "client-state-migration-frontier.json",
);

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined) fail("invalid update manifest arguments");
    result[flag.slice(2)] = value;
  }
  return result;
}

function containedBuildDirectory(value, label) {
  const buildRoot = path.join(repoRoot, "build");
  const resolved = path.resolve(repoRoot, value || "");
  if (resolved === buildRoot || !resolved.startsWith(`${buildRoot}${path.sep}`)) {
    fail(`${label} must be a contained build directory`);
  }
  return resolved;
}

function exactRegularFiles(directory) {
  return readdirSync(directory, { withFileTypes: true })
    .map((entry) => {
      if (!entry.isFile() || entry.isSymbolicLink() || path.basename(entry.name) !== entry.name) {
        fail("update manifest assets must be regular files");
      }
      return entry.name;
    })
    .sort((left, right) => left.localeCompare(right));
}

function selectedTargetIds(value) {
  const ids = String(value || "").split(",");
  if (ids.length === 0 || ids.some((id) => !id || id !== id.trim()) ||
    new Set(ids).size !== ids.length) fail("invalid target selection");
  return selectClientReleaseTargets(loadClientReleaseTargetCatalog(), ids);
}

function stableStringify(value) {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return Number.isInteger(value) ? String(value) : JSON.stringify(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (typeof value === "object") {
    const keys = Object.keys(value).sort();
    return `{${keys
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(",")}}`;
  }
  throw new Error("unsupported manifest value");
}

function unsignedDocument(document) {
  const copy = { ...document };
  delete copy.signatures;
  return copy;
}

function hasExactKeys(value, expected) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const actual = Object.keys(value).sort();
  return actual.length === expected.length &&
    [...expected].sort().every((key, index) => actual[index] === key);
}

function sha256Hex(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function parseSemver(value) {
  const match = String(value).match(
    /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:[0-9A-Za-z-]+\.)*[0-9A-Za-z-]+))?(?:\+[0-9A-Za-z.-]+)?$/u,
  );
  if (!match) fail("release version is not valid SemVer");
  return { core: match.slice(1, 4).map(Number), pre: match[4]?.split(".") || [] };
}

function compareSemver(left, right) {
  const a = parseSemver(left);
  const b = parseSemver(right);
  for (let index = 0; index < 3; index += 1) {
    if (a.core[index] !== b.core[index]) return Math.sign(a.core[index] - b.core[index]);
  }
  if (a.pre.length === 0 || b.pre.length === 0) {
    return a.pre.length === b.pre.length ? 0 : a.pre.length === 0 ? 1 : -1;
  }
  for (let index = 0; index < Math.max(a.pre.length, b.pre.length); index += 1) {
    const x = a.pre[index];
    const y = b.pre[index];
    if (x === undefined || y === undefined) return x === undefined ? -1 : 1;
    if (x === y) continue;
    const xn = /^\d+$/u.test(x);
    const yn = /^\d+$/u.test(y);
    if (xn && yn) return Math.sign(Number(x) - Number(y));
    if (xn !== yn) return xn ? -1 : 1;
    return x < y ? -1 : 1;
  }
  return 0;
}

function validatePublicationSuccessor(previous, next) {
  if (previous.schemaVersion !== MANIFEST_SCHEMA || next.schemaVersion !== MANIFEST_SCHEMA) {
    fail("publication manifest schema mismatch");
  }
  if (previous.releaseTrack !== next.releaseTrack) fail("publication release track mismatch");
  const previousVersions = (previous.releases || []).map((release) => release.version);
  if (previousVersions.length === 0 || next.releases?.length !== 1) {
    fail("publication manifests require release versions");
  }
  const priorHigh = previousVersions.sort(compareSemver).at(-1);
  if (compareSemver(next.releases[0].version, priorHigh) <= 0) {
    fail("publication version must be strictly newer by SemVer");
  }
  const priorRelease = previous.releases.find((release) => release.version === priorHigh);
  const priorDomains = new Map(
    priorRelease.migrationFrontier.domains
      .map((domain) => [domain.domainId, domain]),
  );
  const nextDomains = new Map(
    next.releases[0].migrationFrontier.domains
      .map((domain) => [domain.domainId, domain]),
  );
  for (const [domainId, prior] of priorDomains) {
    const domain = nextDomains.get(domainId);
    if (!domain || domain.targetSchemaVersion < prior.targetSchemaVersion) {
      fail("publication migration frontier must be monotonic");
    }
    if (prior.requiredStepIds.some((stepId, index) =>
      domain.requiredStepIds[index] !== stepId)) {
      fail("publication migration history must be immutable");
    }
  }
  for (const artifact of next.releases[0].artifacts || []) {
    if (artifact.platform === "macos" &&
        (artifact.applicationName !== MACOS_APPLICATION_NAME || artifact.bundleId !== MACOS_BUNDLE_ID)) {
      fail("publication application identity mismatch");
    }
  }
}

function signManifest(document, keys) {
  const payload = Buffer.from(stableStringify(unsignedDocument(document)), "utf8");
  const signatures = [];
  for (const { keyId, privateKey } of keys) {
    const signature = sign(null, payload, privateKey);
    signatures.push({
      keyId,
      algorithm: "Ed25519",
      signature: signature.toString("base64"),
    });
  }
  return { ...document, signatures };
}

function loadEnvPrivateKey(envName, label) {
  const pem = process.env[envName] || "";
  if (pem.trim().length === 0) fail(`${label} signing key (${envName}) is required`);
  return createPrivateKey(pem);
}

function loadBundledPublicKeysDocument() {
  const info = lstatSync(bundledPublicKeysPath, { throwIfNoEntry: false });
  if (!info?.isFile() || info.isSymbolicLink()) fail("bundled public keys document is missing");
  return JSON.parse(readFileSync(bundledPublicKeysPath, "utf8"));
}

function keyIdFromPrivateKey(privateKey, expectedKeyId, document) {
  const raw = Buffer.from(
    createPublicKey(privateKey).export({ type: "spki", format: "der" }),
  ).subarray(-32).toString("base64");
  const keys = document.keys || {};
  for (const [keyId, entry] of Object.entries(keys)) {
    const publicKey = typeof entry === "string" ? entry : entry?.publicKey;
    if (publicKey === raw) {
      if (expectedKeyId && expectedKeyId !== keyId) fail("signing key id does not match the bundled document");
      return keyId;
    }
  }
  fail("signing key does not match the bundled public keys document");
}

function buildManifest(args) {
  const assetsRoot = containedBuildDirectory(args.assets, "update manifest assets");
  const localNames = new Set(exactRegularFiles(assetsRoot));
  const tag = args.tag || "";
  if (!/^[A-Za-z0-9][A-Za-z0-9._+-]{0,126}$/u.test(tag)) fail("invalid release tag");
  const repository = args.repo || "";
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u.test(repository)) fail("invalid release repository");
  const productVersion = JSON.parse(
    readFileSync(path.join(repoRoot, "tools/client-version.json"), "utf8"),
  ).productVersion;
  if (typeof productVersion !== "string" || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(productVersion)) {
    fail("client product version is invalid");
  }
  const minimumSupportedVersion = args["minimum-supported-version"] || "0.0.0";
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(minimumSupportedVersion)) {
    fail("minimum supported version is invalid");
  }
  const releaseTrack = args["release-track"] || "";
  if (releaseTrack !== "nightly" && releaseTrack !== "stable") {
    fail("release track must be explicitly nightly or stable");
  }
  if (releaseTrack === "nightly" && tag !== "nightly") {
    fail("nightly publication must use the fixed nightly prerelease tag");
  }
  if (releaseTrack === "stable" && tag !== `v${productVersion}`) {
    fail("stable publication tag must match the exact product version");
  }
  if (releaseTrack === "stable" && parseSemver(productVersion).pre.length !== 0) {
    fail("stable publication requires a non-prerelease product version");
  }
  const embeddedFrontier = JSON.parse(readFileSync(migrationFrontierPath, "utf8"));
  if (embeddedFrontier.schemaVersion !== "v0.0.1:client-state-migration-frontier-1" ||
      typeof embeddedFrontier.frontierId !== "string" || !Array.isArray(embeddedFrontier.domains)) {
    fail("embedded migration frontier is invalid");
  }
  const migrationFrontier = {
    frontierId: embeddedFrontier.frontierId,
    domains: embeddedFrontier.domains.map((domain) => ({
      domainId: domain.domainId,
      targetSchemaVersion: domain.targetSchemaVersion,
      requiredStepIds: domain.steps.map((step) => step.stepId),
    })),
  };

  const selected = selectedTargetIds(args.targets);
  const artifacts = [];
  for (const meta of selected) {
    if (meta.update.kind !== "signed-http-manifest") continue;
    const packageTargetId = meta.id;
    const topology = CLIENT_RELEASE_TARGETS[packageTargetId];
    const artifactName = topology?.updateArtifact || topology?.files?.[0];
    if (!artifactName || !localNames.has(artifactName)) {
      fail(`selected target ${packageTargetId} artifact is missing from the asset set`);
    }
    const filePath = path.join(assetsRoot, artifactName);
    const info = statSync(filePath);
    if (!info.isFile() || info.size <= 0) fail(`selected target ${packageTargetId} artifact is invalid`);
    const artifact = {
      targetId: meta.runtimeTargetId,
      platform: meta.platform,
      osFamily: meta.platform,
      arch: meta.arch,
      installerStrategy: "app-bundle-replacement",
      url: `https://github.com/${repository}/releases/download/${tag}/${artifactName}`,
      fileName: artifactName,
      size: info.size,
      sha256: `sha256:${sha256Hex(readFileSync(filePath))}`,
    };
    if (meta.platform === "macos") {
      artifact.applicationName = MACOS_APPLICATION_NAME;
      artifact.bundleId = MACOS_BUNDLE_ID;
    }
    artifacts.push(artifact);
  }
  if (artifacts.length === 0) fail("update manifest has no desktop artifacts for the selected targets");

  const publicKeysDocument = loadBundledPublicKeysDocument();
  const offlineRootKeyId = keyIdFromPrivateKey(
    loadEnvPrivateKey("LICO_UPDATE_OFFLINE_ROOT_KEY", "offline root"),
    args["offline-root-key-id"] || "",
    publicKeysDocument,
  );
  const onlineSigningKeyId = keyIdFromPrivateKey(
    loadEnvPrivateKey("LICO_UPDATE_ONLINE_SIGNING_KEY", "online signing"),
    args["online-signing-key-id"] || "",
    publicKeysDocument,
  );
  if (offlineRootKeyId === onlineSigningKeyId) fail("offline root and online signing keys must be distinct");

  const unsigned = {
    schemaVersion: MANIFEST_SCHEMA,
    releaseTrack,
    releaseTrackPolicy: {
      offlineRootKeyId,
      onlineSigningKeyId,
    },
    releases: [
      {
        version: productVersion,
        minimumSupportedVersion,
        classification: "optional",
        releaseNotesUrl: `https://github.com/${repository}/releases/tag/${tag}`,
        migrationNotes: [],
        migrationFrontier,
        artifacts,
      },
    ],
  };
  const manifest = signManifest(unsigned, [
    { keyId: offlineRootKeyId, privateKey: loadEnvPrivateKey("LICO_UPDATE_OFFLINE_ROOT_KEY", "offline root") },
    { keyId: onlineSigningKeyId, privateKey: loadEnvPrivateKey("LICO_UPDATE_ONLINE_SIGNING_KEY", "online signing") },
  ]);
  if (args["previous-manifest"]) {
    const previous = verifyManifest(
      readFileSync(args["previous-manifest"], "utf8"),
      JSON.stringify(publicKeysDocument),
    );
    validatePublicationSuccessor(previous, manifest);
  }
  const manifestText = `${JSON.stringify(manifest, null, 2)}\n`;
  if (Buffer.byteLength(manifestText, "utf8") > MAX_MANIFEST_BYTES) {
    fail("update manifest exceeds the size limit");
  }
  writeFileSync(args.output || path.join(assetsRoot, MANIFEST_NAME), manifestText, {
    encoding: "utf8",
    mode: 0o644,
    flag: "wx",
  });
  if (args["public-keys-output"]) {
    writeFileSync(
      args["public-keys-output"],
      `${JSON.stringify(publicKeysDocument, null, 2)}\n`,
      { encoding: "utf8", mode: 0o644, flag: "wx" },
    );
  }
  return Object.freeze({ ok: true, releaseVersion: productVersion, artifactCount: artifacts.length });
}

function verifyManifest(manifestText, publicKeysText) {
  const manifest = JSON.parse(manifestText);
  if (manifest.schemaVersion !== MANIFEST_SCHEMA) fail("update manifest schema is invalid");
  if (!hasExactKeys(manifest, [
    "schemaVersion",
    "releaseTrack",
    "releaseTrackPolicy",
    "releases",
    "signatures",
  ])) {
    fail("update manifest top-level contract is not closed");
  }
  if (manifest.releaseTrack !== "nightly" && manifest.releaseTrack !== "stable") {
    fail("update manifest release track is invalid");
  }
  for (const release of manifest.releases || []) {
    const frontier = release.migrationFrontier;
    if (!hasExactKeys(frontier, ["frontierId", "domains"]) ||
        typeof frontier.frontierId !== "string" ||
        !Array.isArray(frontier.domains) || frontier.domains.length === 0) {
      fail("update manifest migration frontier is invalid");
    }
    for (const domain of frontier.domains) {
      if (!hasExactKeys(domain, ["domainId", "targetSchemaVersion", "requiredStepIds"])) {
        fail("update manifest migration frontier domain contract is not closed");
      }
    }
  }
  const keys = JSON.parse(publicKeysText).keys || {};
  const payload = Buffer.from(stableStringify(unsignedDocument(manifest)), "utf8");
  const verified = new Set();
  for (const entry of manifest.signatures || []) {
    if (entry.algorithm !== "Ed25519") fail("update manifest signature algorithm is invalid");
    const publicKey = keys[entry.keyId];
    if (!publicKey) fail("update manifest signature key is unknown");
    const raw = Buffer.from(
      typeof publicKey === "string" ? publicKey : publicKey.publicKey,
      "base64",
    );
    if (raw.length !== 32) fail("update manifest public key is invalid");
    const key = createPublicKey({
      key: Buffer.concat([
        Buffer.from("302a300506032b6570032100", "hex"),
        raw,
      ]),
      format: "der",
      type: "spki",
    });
    if (!verify(null, payload, key, Buffer.from(entry.signature, "base64"))) {
      fail("update manifest signature verification failed");
    }
    verified.add(entry.keyId);
  }
  const policy = manifest.releaseTrackPolicy || {};
  if (!verified.has(policy.offlineRootKeyId) || !verified.has(policy.onlineSigningKeyId)) {
    fail("update manifest role signatures are incomplete");
  }
  return manifest;
}

function selfTest() {
  const offline = generateKeyPairSync("ed25519");
  const online = generateKeyPairSync("ed25519");
  const rawPublic = (keyObject) =>
    Buffer.from(keyObject.export({ type: "spki", format: "der" })).subarray(-32).toString("base64");
  const offlineId = "offline-root-self-test";
  const onlineId = "online-signing-self-test";
  const document = {
    schemaVersion: MANIFEST_SCHEMA,
    releaseTrack: "stable",
    releaseTrackPolicy: { offlineRootKeyId: offlineId, onlineSigningKeyId: onlineId },
    releases: [
      {
        version: "1.0.0",
        minimumSupportedVersion: "0.0.0",
        classification: "optional",
        releaseNotesUrl: "https://github.com/LicoLand/LicoUp/releases/tag/v1.0.0",
        migrationNotes: [],
        migrationFrontier: {
          frontierId: "self-test-frontier",
          domains: [{
            domainId: "client-state",
            targetSchemaVersion: 1,
            requiredStepIds: ["client-state.absent-to-1"],
          }],
        },
        artifacts: [
          {
            targetId: "macos-arm64",
            platform: "macos",
            osFamily: "macos",
            arch: "arm64",
            installerStrategy: "app-bundle-replacement",
            url: "https://github.com/LicoLand/LicoUp/releases/download/v1.0.0/LicoUp-macos-arm64-update.zip",
            fileName: "LicoUp-macos-arm64-update.zip",
            size: 4096,
            sha256: `sha256:${"0".repeat(64)}`,
            applicationName: "LicoUp.app",
            bundleId: "land.lico.licoup",
          },
        ],
      },
    ],
  };
  const signed = signManifest(document, [
    { keyId: offlineId, privateKey: offline.privateKey },
    { keyId: onlineId, privateKey: online.privateKey },
  ]);
  const publicKeysText = JSON.stringify({
    keys: {
      [offlineId]: { publicKey: rawPublic(offline.publicKey) },
      [onlineId]: { publicKey: rawPublic(online.publicKey) },
    },
  });
  const manifest = verifyManifest(JSON.stringify(signed), publicKeysText);
  if (manifest.releases.length !== 1 || manifest.releases[0].artifacts.length !== 1) {
    fail("update manifest self-test structure is invalid");
  }
  // Tampering must fail verification.
  const tampered = JSON.parse(JSON.stringify(signed));
  tampered.releases[0].version = "9.9.9-tampered";
  let rejected = false;
  try {
    verifyManifest(JSON.stringify(tampered), publicKeysText);
  } catch {
    rejected = true;
  }
  if (!rejected) fail("update manifest self-test must reject tampering");
  const extendedContract = signManifest({ ...document, eligibilityOverride: true }, [
    { keyId: offlineId, privateKey: offline.privateKey },
    { keyId: onlineId, privateKey: online.privateKey },
  ]);
  rejected = false;
  try {
    verifyManifest(JSON.stringify(extendedContract), publicKeysText);
  } catch {
    rejected = true;
  }
  if (!rejected) fail("update manifest self-test must reject unknown top-level fields");
  const successor = JSON.parse(JSON.stringify(signed));
  successor.releases[0].version = "1.0.1";
  validatePublicationSuccessor(signed, successor);
  const equalVersion = JSON.parse(JSON.stringify(successor));
  equalVersion.releases[0].version = "1.0.0+different-build";
  rejected = false;
  try {
    validatePublicationSuccessor(signed, equalVersion);
  } catch {
    rejected = true;
  }
  if (!rejected) fail("build metadata must not break a SemVer tie");
  const regressedFrontier = JSON.parse(JSON.stringify(successor));
  regressedFrontier.releases[0].migrationFrontier.domains[0].targetSchemaVersion = 0;
  rejected = false;
  try {
    validatePublicationSuccessor(signed, regressedFrontier);
  } catch {
    rejected = true;
  }
  if (!rejected) fail("migration frontier regression must be rejected");
  const rewrittenHistory = JSON.parse(JSON.stringify(successor));
  rewrittenHistory.releases[0].migrationFrontier.domains[0].requiredStepIds[0] =
    "client-state.rewritten";
  rejected = false;
  try {
    validatePublicationSuccessor(signed, rewrittenHistory);
  } catch {
    rejected = true;
  }
  if (!rejected) fail("migration history rewrite must be rejected");
  const removedDomain = JSON.parse(JSON.stringify(successor));
  removedDomain.releases[0].migrationFrontier.domains = [];
  rejected = false;
  try {
    validatePublicationSuccessor(signed, removedDomain);
  } catch {
    rejected = true;
  }
  if (!rejected) fail("migration domain removal must be rejected");
  const changedIdentity = JSON.parse(JSON.stringify(successor));
  changedIdentity.releases[0].artifacts[0].bundleId = "invalid.changed.identity";
  rejected = false;
  try {
    validatePublicationSuccessor(signed, changedIdentity);
  } catch {
    rejected = true;
  }
  if (!rejected) fail("application identity change must be rejected");
  // The bundled document must parse and expose decodable 32-byte keys.
  const bundled = loadBundledPublicKeysDocument();
  const entries = Object.values(bundled.keys || {});
  if (entries.length < 2) fail("bundled public keys document must contain both roles");
  for (const entry of entries) {
    const encoded = typeof entry === "string" ? entry : entry.publicKey;
    if (!/^[A-Za-z0-9+/=]+$/u.test(encoded || "") || Buffer.from(encoded, "base64").length !== 32) {
      fail("bundled public key entry is not a raw Ed25519 key");
    }
  }
  return Object.freeze({ ok: true, schema: MANIFEST_SCHEMA });
}

export function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (args["self-test"] === "true") {
    process.stdout.write(`${JSON.stringify(selfTest())}\n`);
    return;
  }
  process.stdout.write(`${JSON.stringify(buildManifest(args))}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(`client-update-manifest: ${error.message}`);
    process.exitCode = 1;
  }
}
