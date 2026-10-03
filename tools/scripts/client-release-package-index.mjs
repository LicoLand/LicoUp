#!/usr/bin/env node

// Produces and verifies the signed first-party package index.
//
// The index is the release document the client reads: one entry per
// independently released package, each carrying the package's own identity,
// version, payload digest, client compatibility list and native converter
// entry. It is authenticated with the same Ed25519 role signatures, the same
// canonical unsigned bytes and the same public-key catalogue shape the client
// update manifest already uses, so one release authority owns both documents.
//
// Subcommands:
//   plan     report the declared package set and the digests it would publish
//   build    write the payload asset and the signed index for a release target
//   fixture  build the same assets from the committed synthetic package with a
//            key pair generated in memory for this run: a disposable trial,
//            never a publication
//   verify   re-verify a signed index against its payloads and key catalogue
//
// The tool never signs with a protected key by itself, never notarizes and
// never publishes: `build` reads the release authority's private keys from the
// environment, and an absent key fails closed before any file is written. It
// reaches no network.

import {
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign,
  verify,
} from "node:crypto";
import {
  copyFileSync,
  lstatSync,
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
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  nativeConverterEntry,
  PACKAGE_PAYLOAD_DECLARATION_NAME,
  PACKAGE_PAYLOAD_LIMITS,
  PACKAGE_PAYLOAD_MANIFEST_NAME,
  PackagePayloadError,
  readPackagePayload,
  readPackageSourceDirectory,
  sha256File,
  sha256Hex,
  writePackagePayload,
} from "./lib/client-release-package-payload.mjs";
import {
  loadClientReleaseTargetCatalog,
  resolveClientReleaseTarget,
} from "./lib/client-release-targets.mjs";

export const PACKAGE_INDEX_SCHEMA = "licomesh.client-release-package-index.v1";
export const PACKAGE_RELEASE_SCHEMA = "licoup.package-release.v1";
export const PACKAGE_SET_SCHEMA = "licomesh.client-release-package-set.v1";
export const PACKAGE_MANIFEST_SCHEMA = "licoup.extension-package.v1";
export const PACKAGE_INDEX_NAME = "LicoUp-package-index.json";
export const PACKAGE_FIXTURE_PUBLIC_KEYS_NAME =
  "LicoUp-package-fixture-public-keys.json";
export const PACKAGE_PAYLOAD_ROLE = "package-payload";
export const PACKAGE_INDEX_ROLE = "package-index";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const buildRoot = path.join(repoRoot, "build");
const defaultPackageSetPath = "tools/client-release-package-set.json";
const defaultPublicKeysPath =
  "crates/licoup-native/resources/client-update-public-keys.json";
const defaultTargetId = "macos-direct-arm64";
const defaultReleaseTrack = "stable";

const MAX_INDEX_BYTES = 1024 * 1024;
const MAX_PACKAGES = 64;
const MAX_COMPARATORS = 8;
const MAX_RANGE_BYTES = 64;
const OFFLINE_ROOT_KEY_ENV = "LICO_PACKAGE_INDEX_OFFLINE_ROOT_KEY";
const ONLINE_SIGNING_KEY_ENV = "LICO_PACKAGE_INDEX_ONLINE_SIGNING_KEY";

const idPattern = /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/u;
const namespacedPattern = /^[a-z][a-z0-9]*(?:[./-][A-Za-z0-9_-]+)+$/u;
// One declared package is published as one payload asset, and the asset's
// release role names that payload rather than the package that happens to be
// first. A role that does not end this way is not a package payload.
const payloadRolePattern = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*-payload$/u;
const semverPattern =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:[0-9A-Za-z-]+\.)*[0-9A-Za-z-]+))?(?:\+[0-9A-Za-z.-]+)?$/u;
const digestPattern = /^sha256:[0-9a-f]{64}$/u;
const selfAssertedFields = Object.freeze([
  "artifactdigest", "contenthash", "granted", "installed", "integrity",
  "sha256", "signedby", "signature", "trusted", "verified",
]);

class ClientPackageIndexError extends Error {
  constructor(code, details = null) {
    super(code);
    this.code = code;
    this.details = details;
  }
}

export function fail(code, details = null) {
  throw new ClientPackageIndexError(code, details);
}

function text(value) {
  return String(value ?? "").trim();
}

export function exactObjectKeys(value, keys) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
}

function requireExactKeys(value, keys, code) {
  if (!exactObjectKeys(value, keys)) fail(code);
}

export function stableStringify(value) {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    return Number.isInteger(value) ? String(value) : JSON.stringify(value);
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(",")}}`;
  }
  fail("package_index_value_unsupported");
}

export function unsignedDocument(document) {
  const copy = { ...document };
  delete copy.signatures;
  return copy;
}

export function canonicalUnsignedBytes(document) {
  return Buffer.from(stableStringify(unsignedDocument(document)), "utf8");
}

function parseSemver(value) {
  const match = semverPattern.exec(text(value));
  if (!match) fail("package_index_version_invalid", { version: text(value) });
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

function comparator(expression, code) {
  const match = /^(>=|<=|>|<|=)?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/u
    .exec(expression);
  if (!match) fail(code);
  return Object.freeze({
    operator: match[1] || "=",
    version: `${match[2]}.${match[3]}.${match[4]}`,
  });
}

export function validateClientCompatibility(value,
  code = "package_index_compatibility_invalid") {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(code);
  const kind = text(value.kind);
  if (kind === "range") {
    requireExactKeys(value, ["kind", "range"], code);
    const range = text(value.range);
    if (!range || range.length > MAX_RANGE_BYTES) fail(code);
    const expressions = range.split(/\s*,\s*|\s+/u).filter(Boolean);
    if (expressions.length === 0 || expressions.length > MAX_COMPARATORS) fail(code);
    return Object.freeze({
      kind,
      range,
      comparators: Object.freeze(expressions.map((entry) => comparator(entry, code))),
    });
  }
  if (kind === "major") {
    requireExactKeys(value, ["kind", "majors"], code);
    if (!Array.isArray(value.majors) || value.majors.length === 0 ||
      value.majors.length > MAX_COMPARATORS ||
      value.majors.some((major) => !Number.isSafeInteger(major) || major < 0) ||
      new Set(value.majors).size !== value.majors.length ||
      value.majors.some((major, index) => index > 0 && major <= value.majors[index - 1])) {
      fail(code);
    }
    return Object.freeze({ kind, majors: Object.freeze([...value.majors]) });
  }
  fail(code);
}

export function publicClientCompatibility(declaration) {
  return declaration.kind === "range"
    ? Object.freeze({ kind: "range", range: declaration.range })
    : Object.freeze({ kind: "major", majors: Object.freeze([...declaration.majors]) });
}

export function clientVersionSatisfies(declaration, clientVersion) {
  const validated = validateClientCompatibility(publicClientCompatibility(declaration));
  const version = text(clientVersion);
  parseSemver(version);
  if (validated.kind === "major") {
    return validated.majors.includes(parseSemver(version).core[0]);
  }
  return validated.comparators.every(({ operator, version: bound }) => {
    const order = compareSemver(version, bound);
    if (operator === "=") return order === 0;
    if (operator === ">") return order > 0;
    if (operator === ">=") return order >= 0;
    if (operator === "<") return order < 0;
    return order <= 0;
  });
}

export function validatePackageManifest(manifest) {
  if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) {
    fail("package_index_manifest_invalid");
  }
  for (const field of selfAssertedFields) {
    if (Object.hasOwn(manifest, field)) fail("package_index_manifest_self_asserted");
  }
  if (text(manifest.schema) !== PACKAGE_MANIFEST_SCHEMA ||
    !namespacedPattern.test(text(manifest.id)) ||
    !semverPattern.test(text(manifest.version)) ||
    !text(manifest.displayName) ||
    !manifest.hostProtocol || typeof manifest.hostProtocol !== "object" ||
    !Number.isSafeInteger(manifest.hostProtocol.major) || manifest.hostProtocol.major < 1 ||
    !Number.isSafeInteger(manifest.hostProtocol.minimumMinor) ||
    manifest.hostProtocol.minimumMinor < 0) {
    fail("package_index_manifest_invalid");
  }
  const runtime = manifest.runtime;
  if (!runtime || typeof runtime !== "object" || text(runtime.mode) !== "process" ||
    !text(runtime.entry) || text(runtime.runtimeRef)) {
    // An official package is a native binary: a declared interpreter reference
    // describes a runtime image, not a package payload.
    fail("package_index_manifest_runtime_not_native");
  }
  if (!Array.isArray(manifest.permissions) ||
    manifest.permissions.some((permission) =>
      !permission || typeof permission !== "object" ||
      !namespacedPattern.test(text(permission.capability)) ||
      !text(permission.scope))) {
    fail("package_index_manifest_invalid");
  }
  return Object.freeze({
    packageId: text(manifest.id),
    packageVersion: text(manifest.version),
    displayName: text(manifest.displayName),
    hostProtocol: Object.freeze({
      major: manifest.hostProtocol.major,
      minimumMinor: manifest.hostProtocol.minimumMinor,
    }),
    runtimeEntry: text(runtime.entry),
  });
}

export function validatePackageRelease(declaration) {
  requireExactKeys(declaration, [
    "schemaVersion", "packageId", "packageVersion", "clientCompatibility", "converter",
  ], "package_index_declaration_invalid");
  if (text(declaration.schemaVersion) !== PACKAGE_RELEASE_SCHEMA ||
    !namespacedPattern.test(text(declaration.packageId)) ||
    !semverPattern.test(text(declaration.packageVersion))) {
    fail("package_index_declaration_invalid");
  }
  const converter = declaration.converter;
  requireExactKeys(converter,
    ["kind", "entry", "sourceFormat", "targetFormat"],
    "package_index_converter_invalid");
  const entry = text(converter.entry);
  if (text(converter.kind) !== "native-executable" || !entry ||
    !entry.includes("/") || entry.startsWith("/") || entry.includes("..") ||
    entry.includes("\\") ||
    !idPattern.test(text(converter.sourceFormat).replaceAll(".", "-")) ||
    !idPattern.test(text(converter.targetFormat).replaceAll(".", "-"))) {
    fail("package_index_converter_invalid");
  }
  return Object.freeze({
    packageId: text(declaration.packageId),
    packageVersion: text(declaration.packageVersion),
    clientCompatibility: validateClientCompatibility(declaration.clientCompatibility),
    converter: Object.freeze({
      kind: text(converter.kind),
      entry,
      sourceFormat: text(converter.sourceFormat),
      targetFormat: text(converter.targetFormat),
    }),
  });
}

function readJsonFile(filePath, code) {
  const info = lstatSync(filePath, { throwIfNoEntry: false });
  if (!info?.isFile() || info.isSymbolicLink() ||
    info.size > PACKAGE_PAYLOAD_LIMITS.maxDeclarationBytes) {
    fail(code);
  }
  try {
    return JSON.parse(readFileSync(filePath, "utf8"));
  } catch {
    fail(code);
  }
}

/**
 * Read the declared package set: every package names the release payload role
 * its own asset is published as, so two packages cannot claim one file and a
 * payload asset cannot appear without a package behind it.
 */
export function loadPackageSet(
  setPath = path.join(repoRoot, defaultPackageSetPath),
  { root = repoRoot } = {},
) {
  const document = readJsonFile(setPath, "package_index_set_invalid");
  requireExactKeys(document, ["schemaVersion", "packages"], "package_index_set_invalid");
  if (text(document.schemaVersion) !== PACKAGE_SET_SCHEMA ||
    !Array.isArray(document.packages) || document.packages.length === 0 ||
    document.packages.length > MAX_PACKAGES) {
    fail("package_index_set_invalid");
  }
  const seen = new Set();
  const seenRoles = new Set();
  const packages = document.packages.map((entry) => {
    requireExactKeys(entry, ["packageId", "payloadRole", "source"], "package_index_set_invalid");
    const packageId = text(entry.packageId);
    const payloadRole = text(entry.payloadRole);
    const source = text(entry.source);
    if (!namespacedPattern.test(packageId) || seen.has(packageId) ||
      !payloadRolePattern.test(payloadRole) || payloadRole === PACKAGE_INDEX_ROLE ||
      seenRoles.has(payloadRole) ||
      !source || path.isAbsolute(source) ||
      source.split("/").some((component) =>
        !component || component === ".." || component === ".")) {
      fail("package_index_set_invalid");
    }
    seen.add(packageId);
    seenRoles.add(payloadRole);
    const absolute = path.resolve(root, source);
    if (!absolute.startsWith(`${root}${path.sep}`)) fail("package_index_set_invalid");
    return Object.freeze({ packageId, payloadRole, source, sourceRoot: absolute });
  });
  return Object.freeze({
    schemaVersion: PACKAGE_SET_SCHEMA,
    packages: Object.freeze(packages),
  });
}

/**
 * Package one declared source directory. Everything the index publishes about
 * the package is read from inside the payload: the host manifest and the
 * package's own release declaration. Both must agree with each other and with
 * the declared identity, so a mislabelled source directory cannot be published.
 */
export function producePackagePayload(declared, {
  expectedPackageId = declared.packageId,
} = {}) {
  const entries = readPackageSourceDirectory(declared.sourceRoot);
  const manifestEntry = entries.find((entry) =>
    entry.name === PACKAGE_PAYLOAD_MANIFEST_NAME);
  const declarationEntry = entries.find((entry) =>
    entry.name === PACKAGE_PAYLOAD_DECLARATION_NAME);
  if (!manifestEntry || !declarationEntry) fail("package_index_source_incomplete");
  let manifestDocument;
  let declarationDocument;
  try {
    manifestDocument = JSON.parse(manifestEntry.content.toString("utf8"));
    declarationDocument = JSON.parse(declarationEntry.content.toString("utf8"));
  } catch {
    fail("package_index_source_incomplete");
  }
  const manifest = validatePackageManifest(manifestDocument);
  const declaration = validatePackageRelease(declarationDocument);
  if (manifest.packageId !== expectedPackageId ||
    declaration.packageId !== expectedPackageId) {
    fail("package_index_package_identity_mismatch");
  }
  if (manifest.packageVersion !== declaration.packageVersion) {
    fail("package_index_package_version_mismatch");
  }
  if (manifest.runtimeEntry !== declaration.converter.entry) {
    fail("package_index_converter_entry_mismatch");
  }
  nativeConverterEntry(entries, declaration.converter.entry);
  const payload = writePackagePayload(entries);
  return Object.freeze({
    manifest,
    declaration,
    payload,
    byteSize: payload.length,
    sha256: `sha256:${sha256Hex(payload)}`,
  });
}

export function indexEntry(produced, fileName) {
  return Object.freeze({
    packageId: produced.manifest.packageId,
    displayName: produced.manifest.displayName,
    packageVersion: produced.manifest.packageVersion,
    hostProtocol: produced.manifest.hostProtocol,
    clientCompatibility: publicClientCompatibility(produced.declaration.clientCompatibility),
    converter: produced.declaration.converter,
    payload: Object.freeze({
      fileName: text(fileName),
      byteSize: produced.byteSize,
      sha256: produced.sha256,
    }),
  });
}

export function buildIndex({
  releaseTrack, packages, offlineRootKeyId, onlineSigningKeyId,
}) {
  if (!["nightly", "stable"].includes(text(releaseTrack))) {
    fail("package_index_release_track_invalid");
  }
  if (!Array.isArray(packages) || packages.length === 0 ||
    packages.length > MAX_PACKAGES) {
    fail("package_index_packages_invalid");
  }
  const sorted = [...packages].sort((left, right) =>
    (left.packageId < right.packageId ? -1 : left.packageId > right.packageId ? 1 : 0));
  if (new Set(sorted.map((entry) => entry.packageId)).size !== sorted.length) {
    fail("package_index_packages_invalid");
  }
  if (!idPattern.test(text(offlineRootKeyId)) ||
    !idPattern.test(text(onlineSigningKeyId)) ||
    offlineRootKeyId === onlineSigningKeyId) {
    fail("package_index_key_policy_invalid");
  }
  return Object.freeze({
    schemaVersion: PACKAGE_INDEX_SCHEMA,
    releaseTrack: text(releaseTrack),
    packages: Object.freeze(sorted),
    signaturePolicy: Object.freeze({
      offlineRootKeyId: text(offlineRootKeyId),
      onlineSigningKeyId: text(onlineSigningKeyId),
    }),
  });
}

export function signIndex(document, keys) {
  if (!Array.isArray(keys) || keys.length === 0) {
    fail("package_index_signing_key_required");
  }
  const payload = canonicalUnsignedBytes(document);
  const signatures = keys.map(({ keyId, privateKey }) => Object.freeze({
    keyId: text(keyId),
    algorithm: "Ed25519",
    signature: sign(null, payload, privateKey).toString("base64"),
  }));
  if (new Set(signatures.map((entry) => entry.keyId)).size !== signatures.length) {
    fail("package_index_key_policy_invalid");
  }
  return Object.freeze({ ...document, signatures: Object.freeze(signatures) });
}

export function parsePublicKeysDocument(document) {
  if (!document || typeof document !== "object" || Array.isArray(document) ||
    !document.keys || typeof document.keys !== "object" ||
    Array.isArray(document.keys)) {
    fail("package_index_public_keys_invalid");
  }
  const keys = {};
  for (const [keyId, entry] of Object.entries(document.keys)) {
    if (!idPattern.test(keyId)) fail("package_index_public_keys_invalid");
    const encoded = typeof entry === "string" ? entry : entry?.publicKey;
    if (typeof encoded !== "string" || !/^[A-Za-z0-9+/=]+$/u.test(encoded) ||
      Buffer.from(encoded, "base64").length !== 32) {
      fail("package_index_public_keys_invalid");
    }
    keys[keyId] = encoded;
  }
  if (Object.keys(keys).length === 0) fail("package_index_public_keys_invalid");
  return Object.freeze(keys);
}

function loadPublicKeysText(publicKeysText) {
  if (typeof publicKeysText !== "string") return publicKeysText;
  try {
    return JSON.parse(publicKeysText);
  } catch {
    fail("package_index_public_keys_invalid");
  }
}

function validateIndexPackage(entry) {
  requireExactKeys(entry, [
    "packageId", "displayName", "packageVersion", "hostProtocol",
    "clientCompatibility", "converter", "payload",
  ], "package_index_package_invalid");
  if (!namespacedPattern.test(text(entry.packageId)) || !text(entry.displayName) ||
    !semverPattern.test(text(entry.packageVersion))) {
    fail("package_index_package_invalid");
  }
  requireExactKeys(entry.hostProtocol, ["major", "minimumMinor"],
    "package_index_package_invalid");
  if (!Number.isSafeInteger(entry.hostProtocol.major) || entry.hostProtocol.major < 1 ||
    !Number.isSafeInteger(entry.hostProtocol.minimumMinor) ||
    entry.hostProtocol.minimumMinor < 0) {
    fail("package_index_package_invalid");
  }
  validateClientCompatibility(entry.clientCompatibility, "package_index_package_invalid");
  requireExactKeys(entry.converter,
    ["kind", "entry", "sourceFormat", "targetFormat"], "package_index_package_invalid");
  if (text(entry.converter.kind) !== "native-executable" ||
    !text(entry.converter.entry)) {
    fail("package_index_package_invalid");
  }
  requireExactKeys(entry.payload, ["fileName", "byteSize", "sha256"],
    "package_index_package_invalid");
  if (!text(entry.payload.fileName) ||
    path.basename(entry.payload.fileName) !== entry.payload.fileName ||
    !Number.isSafeInteger(entry.payload.byteSize) || entry.payload.byteSize <= 0 ||
    !digestPattern.test(text(entry.payload.sha256))) {
    fail("package_index_package_invalid");
  }
  return text(entry.packageId);
}

export function verifyPackageIndex(indexText, publicKeysText) {
  if (typeof indexText !== "string" ||
    Buffer.byteLength(indexText, "utf8") > MAX_INDEX_BYTES) {
    fail("package_index_invalid");
  }
  let document;
  try {
    document = JSON.parse(indexText);
  } catch {
    fail("package_index_invalid");
  }
  requireExactKeys(document, [
    "schemaVersion", "releaseTrack", "packages", "signaturePolicy", "signatures",
  ], "package_index_invalid");
  if (text(document.schemaVersion) !== PACKAGE_INDEX_SCHEMA ||
    !["nightly", "stable"].includes(text(document.releaseTrack)) ||
    !Array.isArray(document.packages) || document.packages.length === 0 ||
    document.packages.length > MAX_PACKAGES) {
    fail("package_index_invalid");
  }
  const packageIds = document.packages.map(validateIndexPackage);
  if (new Set(packageIds).size !== packageIds.length ||
    JSON.stringify(packageIds) !== JSON.stringify([...packageIds].sort())) {
    fail("package_index_package_order_invalid");
  }
  requireExactKeys(document.signaturePolicy,
    ["offlineRootKeyId", "onlineSigningKeyId"], "package_index_invalid");
  const offlineRootKeyId = text(document.signaturePolicy.offlineRootKeyId);
  const onlineSigningKeyId = text(document.signaturePolicy.onlineSigningKeyId);
  if (!offlineRootKeyId || !onlineSigningKeyId ||
    offlineRootKeyId === onlineSigningKeyId) {
    fail("package_index_key_policy_invalid");
  }
  const keys = parsePublicKeysDocument(loadPublicKeysText(publicKeysText));
  if (!Array.isArray(document.signatures) || document.signatures.length === 0) {
    fail("package_index_signature_missing");
  }
  const payload = canonicalUnsignedBytes(document);
  const verified = new Set();
  for (const entry of document.signatures) {
    requireExactKeys(entry, ["keyId", "algorithm", "signature"],
      "package_index_signature_invalid");
    const keyId = text(entry.keyId);
    if (text(entry.algorithm) !== "Ed25519" || !keys[keyId] || verified.has(keyId)) {
      fail("package_index_signature_invalid");
    }
    const key = createPublicKey({
      key: Buffer.concat([
        Buffer.from("302a300506032b6570032100", "hex"),
        Buffer.from(keys[keyId], "base64"),
      ]),
      format: "der",
      type: "spki",
    });
    if (!verify(null, payload, key, Buffer.from(text(entry.signature), "base64"))) {
      fail("package_index_signature_invalid");
    }
    verified.add(keyId);
  }
  if (!verified.has(offlineRootKeyId) || !verified.has(onlineSigningKeyId)) {
    fail("package_index_signature_roles_incomplete");
  }
  return document;
}

function sameCompatibility(left, right) {
  if (left?.kind !== right?.kind) return false;
  return left.kind === "range"
    ? left.range === right.range
    : JSON.stringify(left.majors) === JSON.stringify(right.majors);
}

function sameConverter(left, right) {
  return ["kind", "entry", "sourceFormat", "targetFormat"]
    .every((field) => left?.[field] === right?.[field]);
}

/**
 * Re-read every declared payload and refuse one that is not exactly what the
 * signed index describes, or that is not the native converter package it
 * claims to be.
 */
export function verifyIndexPayloads(document, payloadsRoot) {
  const root = path.resolve(payloadsRoot);
  const rootInfo = lstatSync(root, { throwIfNoEntry: false });
  if (!rootInfo?.isDirectory() || rootInfo.isSymbolicLink() ||
    realpathSync(root) !== root) {
    fail("package_index_payload_root_invalid");
  }
  const verified = [];
  for (const entry of document.packages) {
    const filePath = path.join(root, entry.payload.fileName);
    const info = lstatSync(filePath, { throwIfNoEntry: false });
    if (!info?.isFile() || info.isSymbolicLink() ||
      info.size !== entry.payload.byteSize) {
      fail("package_index_payload_invalid", { packageId: entry.packageId });
    }
    const bytes = readFileSync(filePath);
    if (`sha256:${sha256Hex(bytes)}` !== entry.payload.sha256) {
      fail("package_index_payload_invalid", { packageId: entry.packageId });
    }
    const entries = readPackagePayload(bytes);
    const manifestEntry = entries.find((candidate) =>
      candidate.name === PACKAGE_PAYLOAD_MANIFEST_NAME);
    const declarationEntry = entries.find((candidate) =>
      candidate.name === PACKAGE_PAYLOAD_DECLARATION_NAME);
    if (!manifestEntry || !declarationEntry) {
      fail("package_index_payload_invalid", { packageId: entry.packageId });
    }
    let manifest;
    let declaration;
    try {
      manifest = validatePackageManifest(JSON.parse(manifestEntry.content.toString("utf8")));
      declaration = validatePackageRelease(
        JSON.parse(declarationEntry.content.toString("utf8")),
      );
    } catch {
      fail("package_index_payload_invalid", { packageId: entry.packageId });
    }
    const declaredCompatibility = publicClientCompatibility(declaration.clientCompatibility);
    if (manifest.packageId !== entry.packageId ||
      manifest.packageVersion !== entry.packageVersion ||
      manifest.runtimeEntry !== entry.converter.entry ||
      declaration.packageId !== entry.packageId ||
      declaration.packageVersion !== entry.packageVersion ||
      !sameCompatibility(declaredCompatibility, entry.clientCompatibility) ||
      !sameConverter(declaration.converter, entry.converter)) {
      fail("package_index_payload_self_description_mismatch", {
        packageId: entry.packageId,
      });
    }
    nativeConverterEntry(entries, declaration.converter.entry);
    verified.push(entry.packageId);
  }
  return Object.freeze(verified);
}

function keyIdFromPrivateKey(privateKey, keysDocument) {
  const raw = Buffer.from(
    createPublicKey(privateKey).export({ type: "spki", format: "der" }),
  ).subarray(-32).toString("base64");
  for (const [keyId, entry] of Object.entries(keysDocument.keys || {})) {
    const publicKey = typeof entry === "string" ? entry : entry?.publicKey;
    if (publicKey === raw) return keyId;
  }
  fail("package_index_signing_key_unknown");
}

function loadEnvPrivateKey(envName) {
  const pem = process.env[envName] || "";
  if (pem.trim().length === 0) fail("package_index_signing_key_required");
  return createPrivateKey(pem);
}

function bundledPublicKeysDocument() {
  return readJsonFile(path.join(repoRoot, defaultPublicKeysPath),
    "package_index_public_keys_invalid");
}

function containedOutputRoot(value) {
  const resolved = path.resolve(value);
  const temporaryRoot = realpathSync(os.tmpdir());
  if (resolved === buildRoot || resolved.startsWith(`${buildRoot}${path.sep}`)) {
    return resolved;
  }
  if (resolved === temporaryRoot ||
    resolved.startsWith(`${temporaryRoot}${path.sep}`)) {
    return resolved;
  }
  fail("package_index_output_invalid");
}

/**
 * The release target declares the asset names. One role carries the signed index
 * every package is published in; one role carries each package's own payload, and
 * the role is what the declared set and the release closure agree on.
 */
export function packageRoleNames(target) {
  const payloadRoles = target.artifacts.filter((artifact) =>
    payloadRolePattern.test(artifact.role));
  const indexRoles = target.artifacts.filter((artifact) =>
    artifact.role === PACKAGE_INDEX_ROLE);
  if (payloadRoles.length === 0 || indexRoles.length === 0) {
    fail("package_index_release_role_missing");
  }
  if (indexRoles.length !== 1) {
    fail("package_index_release_role_invalid");
  }
  return Object.freeze({
    indexFile: indexRoles[0].file,
    payloadRoles: Object.freeze(payloadRoles.map((artifact) =>
      Object.freeze({ role: artifact.role, file: artifact.file }))),
  });
}

export function resolvePackageTarget(targetId = defaultTargetId, productVersion) {
  const catalog = loadClientReleaseTargetCatalog();
  const target = catalog.targets.find((candidate) => candidate.id === targetId);
  if (!target) fail("package_index_release_target_unknown");
  const version = productVersion || readJsonFile(
    path.join(repoRoot, "tools/client-version.json"),
    "package_index_version_invalid",
  ).productVersion;
  return resolveClientReleaseTarget(target, version);
}

/**
 * One declared payload role carries exactly one package today, and every declared
 * package names its own role. A role without a package would publish an asset
 * nobody declared, and two packages on one role would collide on one file name, so
 * either mismatch is refused rather than silently ignored.
 */
function resolveDeclaredPackages(set, target) {
  const { indexFile, payloadRoles } = packageRoleNames(target);
  const byRole = new Map(payloadRoles.map((entry) => [entry.role, entry]));
  const packages = set.packages.map((declared) => {
    const role = byRole.get(declared.payloadRole);
    if (!role) fail("package_index_release_role_missing", { role: declared.payloadRole });
    return Object.freeze({
      declared,
      payloadRole: role.role,
      payloadFile: role.file,
    });
  });
  if (byRole.size !== packages.length) fail("package_index_payload_role_count_mismatch");
  return Object.freeze({ indexFile, packages: Object.freeze(packages) });
}

function writeNewFile(filePath, bytes) {
  if (lstatSync(filePath, { throwIfNoEntry: false })) {
    fail("package_index_output_exists", { file: path.basename(filePath) });
  }
  writeFileSync(filePath, bytes, { flag: "wx", mode: 0o644 });
}

// A run either writes its whole declared set or nothing: the target paths are
// checked before the first byte is written, so a refused run cannot leave a
// payload without the index that describes it.
function requireWritableOutputs(outputRoot, names) {
  if (names.some((name) => lstatSync(path.join(outputRoot, name), { throwIfNoEntry: false }))) {
    fail("package_index_output_exists");
  }
}

function writeIndexAssets({ set, target, releaseTrack, keys, outputRoot }) {
  const { indexFile, packages } = resolveDeclaredPackages(set, target);
  const produced = packages.map((entry) => Object.freeze({
    ...entry,
    payload: producePackagePayload(entry.declared),
  }));
  const index = buildIndex({
    releaseTrack,
    packages: produced.map((entry) =>
      indexEntry(entry.payload, entry.payloadFile)),
    offlineRootKeyId: keys[0].keyId,
    onlineSigningKeyId: keys[1].keyId,
  });
  const signed = signIndex(index, keys);
  const indexText = `${JSON.stringify(signed, null, 2)}\n`;
  if (Buffer.byteLength(indexText, "utf8") > MAX_INDEX_BYTES) {
    fail("package_index_too_large");
  }
  mkdirSync(outputRoot, { recursive: true, mode: 0o755 });
  const indexPath = path.join(outputRoot, indexFile);
  requireWritableOutputs(outputRoot,
    [...produced.map((entry) => entry.payloadFile), indexFile]);
  const payloads = produced.map((entry) => {
    const payloadPath = path.join(outputRoot, entry.payloadFile);
    writeNewFile(payloadPath, entry.payload.payload);
    if (`sha256:${sha256File(payloadPath)}` !== entry.payload.sha256) {
      fail("package_index_payload_write_mismatch");
    }
    return Object.freeze({
      packageId: entry.payload.manifest.packageId,
      packageVersion: entry.payload.manifest.packageVersion,
      payloadRole: entry.payloadRole,
      payloadFile: entry.payloadFile,
      payloadPath,
      payloadDigest: entry.payload.sha256,
      payloadByteSize: entry.payload.byteSize,
      source: entry.declared.source,
      clientCompatibility: publicClientCompatibility(
        entry.payload.declaration.clientCompatibility,
      ),
      converterEntry: entry.payload.declaration.converter.entry,
    });
  });
  writeNewFile(indexPath, indexText);
  return Object.freeze({
    indexFile,
    indexPath,
    payloads: Object.freeze(payloads),
    signed,
  });
}

export function planPackageRelease({
  setPath, targetId = defaultTargetId, releaseTrack = defaultReleaseTrack,
} = {}) {
  const set = loadPackageSet(setPath ? path.resolve(repoRoot, setPath) : undefined);
  const target = resolvePackageTarget(targetId);
  const { indexFile, packages } = resolveDeclaredPackages(set, target);
  const produced = packages.map((entry) => Object.freeze({
    ...entry,
    payload: producePackagePayload(entry.declared),
  }));
  return Object.freeze({
    ok: true,
    command: "plan",
    targetId,
    releaseTrack,
    indexFile,
    packages: Object.freeze(produced.map((entry) => Object.freeze({
      packageId: entry.payload.manifest.packageId,
      packageVersion: entry.payload.manifest.packageVersion,
      source: entry.declared.source,
      payloadRole: entry.payloadRole,
      payloadFile: entry.payloadFile,
      payloadByteSize: entry.payload.byteSize,
      payloadDigest: entry.payload.sha256,
      clientCompatibility: publicClientCompatibility(
        entry.payload.declaration.clientCompatibility,
      ),
      converterEntry: entry.payload.declaration.converter.entry,
    }))),
    writesPerformed: false,
    publicationPerformed: false,
    privatePathsIncluded: false,
  });
}

export function buildPackageRelease({
  setPath, outputRoot, targetId = defaultTargetId,
  releaseTrack = defaultReleaseTrack,
} = {}) {
  const set = loadPackageSet(setPath ? path.resolve(repoRoot, setPath) : undefined);
  const target = resolvePackageTarget(targetId);
  const keysDocument = bundledPublicKeysDocument();
  // Both release-authority roles sign the index, and an absent key fails closed
  // before anything is written: this tool defines the handoff, it does not
  // perform the release.
  const offlineRootPrivateKey = loadEnvPrivateKey(OFFLINE_ROOT_KEY_ENV);
  const onlineSigningPrivateKey = loadEnvPrivateKey(ONLINE_SIGNING_KEY_ENV);
  const offlineRootKeyId = keyIdFromPrivateKey(offlineRootPrivateKey, keysDocument);
  const onlineSigningKeyId = keyIdFromPrivateKey(onlineSigningPrivateKey, keysDocument);
  if (offlineRootKeyId === onlineSigningKeyId) {
    fail("package_index_key_policy_invalid");
  }
  const defaultRoot = path.join(
    buildRoot, "apps", "desktop", "release-packages", target.platform,
  );
  const resolvedRoot = containedOutputRoot(outputRoot || defaultRoot);
  const result = writeIndexAssets({
    set,
    target,
    releaseTrack,
    keys: [
      { keyId: offlineRootKeyId, privateKey: offlineRootPrivateKey },
      { keyId: onlineSigningKeyId, privateKey: onlineSigningPrivateKey },
    ],
    outputRoot: resolvedRoot,
  });
  return Object.freeze({
    ok: true,
    command: "build",
    targetId,
    releaseTrack,
    indexPath: path.relative(repoRoot, result.indexPath).split(path.sep).join("/"),
    payloads: Object.freeze(result.payloads.map((entry) => Object.freeze({
      packageId: entry.packageId,
      payloadRole: entry.payloadRole,
      payloadPath: path.relative(repoRoot, entry.payloadPath).split(path.sep).join("/"),
      payloadDigest: entry.payloadDigest,
      payloadByteSize: entry.payloadByteSize,
    }))),
    packageCount: result.signed.packages.length,
    signingKeysFromEnvironment: true,
    publicationPerformed: false,
    privatePathsIncluded: false,
  });
}

/**
 * The disposable local trial: the committed synthetic package, packaged and
 * signed exactly like a release, with a key pair generated in memory for this
 * run. It reads no protected key, writes only inside its output root, and
 * performs no publication.
 */
export function fixturePackageRelease({
  outputRoot, targetId = defaultTargetId, releaseTrack = defaultReleaseTrack,
} = {}) {
  const generate = () => {
    const pair = generateKeyPairSync("ed25519");
    return Object.freeze({
      privateKey: pair.privateKey,
      publicKey: Buffer.from(
        pair.publicKey.export({ type: "spki", format: "der" }),
      ).subarray(-32).toString("base64"),
    });
  };
  const offlineRootKeyId = "fixture-offline-root";
  const onlineSigningKeyId = "fixture-online-signing";
  const offlineRoot = generate();
  const onlineSigning = generate();
  const keys = [
    { keyId: offlineRootKeyId, privateKey: offlineRoot.privateKey },
    { keyId: onlineSigningKeyId, privateKey: onlineSigning.privateKey },
  ];
  const set = loadPackageSet();
  const target = resolvePackageTarget(targetId);
  const resolvedRoot = containedOutputRoot(
    outputRoot || path.join(buildRoot, "client-package-fixture"),
  );
  // The trial claims the whole disposable set or none of it.
  mkdirSync(resolvedRoot, { recursive: true, mode: 0o755 });
  requireWritableOutputs(resolvedRoot, [PACKAGE_FIXTURE_PUBLIC_KEYS_NAME]);
  const result = writeIndexAssets({
    set, target, releaseTrack, keys, outputRoot: resolvedRoot,
  });
  const publicKeysPath = path.join(resolvedRoot, PACKAGE_FIXTURE_PUBLIC_KEYS_NAME);
  writeNewFile(publicKeysPath, `${JSON.stringify({
    keys: {
      [offlineRootKeyId]: { publicKey: offlineRoot.publicKey },
      [onlineSigningKeyId]: { publicKey: onlineSigning.publicKey },
    },
  }, null, 2)}\n`);
  // The trial verifies its own output through the same reader a release uses.
  const verifiedIndex = verifyPackageIndex(
    readFileSync(result.indexPath, "utf8"),
    readFileSync(publicKeysPath, "utf8"),
  );
  const verifiedPackages = verifyIndexPayloads(verifiedIndex, resolvedRoot);
  return Object.freeze({
    ok: true,
    command: "fixture",
    targetId,
    releaseTrack,
    indexPath: path.relative(repoRoot, result.indexPath).split(path.sep).join("/"),
    payloads: Object.freeze(result.payloads.map((entry) => Object.freeze({
      packageId: entry.packageId,
      payloadRole: entry.payloadRole,
      payloadPath: path.relative(repoRoot, entry.payloadPath).split(path.sep).join("/"),
      payloadDigest: entry.payloadDigest,
      payloadByteSize: entry.payloadByteSize,
    }))),
    publicKeysPath: path.relative(repoRoot, publicKeysPath).split(path.sep).join("/"),
    packageIds: verifiedPackages,
    signingKeysGeneratedInMemory: true,
    protectedKeysUsed: false,
    publicationPerformed: false,
    privatePathsIncluded: false,
  });
}

export function verifyPackageRelease({
  indexPath, payloadRoot, publicKeysPath = defaultPublicKeysPath,
} = {}) {
  const resolvedIndex = path.resolve(repoRoot, indexPath || "");
  const document = verifyPackageIndex(
    readFileSync(resolvedIndex, "utf8"),
    readFileSync(path.resolve(repoRoot, publicKeysPath), "utf8"),
  );
  const verifiedPackages = verifyIndexPayloads(
    document,
    path.resolve(repoRoot, payloadRoot || path.dirname(resolvedIndex)),
  );
  return Object.freeze({
    ok: true,
    command: "verify",
    indexFile: path.basename(resolvedIndex),
    packageIds: verifiedPackages,
    signatureRolesVerified: 2,
    publicationPerformed: false,
    privatePathsIncluded: false,
  });
}

function fixtureSourceDirectory() {
  return path.join(repoRoot, "tests", "fixtures", "client_package_release",
    "fixture-native-converter");
}

function selfTestSet(root, overrides = {}) {
  const source = fixtureSourceDirectory();
  const destination = path.join(root, "package");
  for (const relative of [
    "manifest.json", "package-release.json", "bin/licoup-fixture-converter",
  ]) {
    const target = path.join(destination, relative);
    mkdirSync(path.dirname(target), { recursive: true });
    copyFileSync(path.join(source, relative), target);
  }
  for (const [relative, content] of Object.entries(overrides)) {
    const target = path.join(destination, relative);
    mkdirSync(path.dirname(target), { recursive: true });
    writeFileSync(target, content);
  }
  const setPath = path.join(root, "package-set.json");
  writeFileSync(setPath, `${JSON.stringify({
    schemaVersion: PACKAGE_SET_SCHEMA,
    packages: [{
      packageId: "org.licoland.fixture.native-converter",
      source: "package",
      payloadRole: PACKAGE_PAYLOAD_ROLE,
    }],
  }, null, 2)}\n`);
  return Object.freeze({ setPath, sourceRoot: destination });
}

function expectRejected(code, run) {
  try {
    run();
  } catch (error) {
    if (error instanceof ClientPackageIndexError ||
      error instanceof PackagePayloadError) {
      if (error.code === code) return;
      fail("package_index_self_test_unexpected_error", {
        expected: code,
        actual: error.code || "unknown",
      });
    }
    fail("package_index_self_test_unexpected_error", {
      expected: code,
      actual: "unclassified",
    });
  }
  fail("package_index_self_test_accepted", { code });
}

export function selfTest() {
  const root = mkdtempSync(path.join(realpathSync(os.tmpdir()), "lico-package-index-"));
  try {
    // Every declared package packages deterministically and self-describes.
    const set = loadPackageSet();
    const first = set.packages.map((declared) => {
      const produced = producePackagePayload(declared);
      const repeated = producePackagePayload(declared);
      if (produced.sha256 !== repeated.sha256 || !produced.payload.equals(repeated.payload)) {
        fail("package_index_self_test_not_deterministic", { packageId: declared.packageId });
      }
      if (produced.manifest.packageId !== declared.packageId ||
        produced.declaration.packageVersion !== produced.manifest.packageVersion) {
        fail("package_index_self_test_identity_invalid", { packageId: declared.packageId });
      }
      // Each declared role is the role its own asset is published as, and the
      // payload carries the declared native entry and no interpreter.
      if (declared.payloadRole !== PACKAGE_PAYLOAD_ROLE &&
        !payloadRolePattern.test(declared.payloadRole)) {
        fail("package_index_self_test_role_invalid", { packageId: declared.packageId });
      }
      nativeConverterEntry(readPackagePayload(produced.payload),
        produced.declaration.converter.entry);
      return produced;
    });
    const fixtureRange = publicClientCompatibility(first[0].declaration.clientCompatibility);
    if (!clientVersionSatisfies(fixtureRange, "0.3.0") ||
      clientVersionSatisfies(fixtureRange, "1.0.0") ||
      !clientVersionSatisfies({ kind: "major", majors: [1, 2] }, "1.4.0") ||
      clientVersionSatisfies({ kind: "major", majors: [1, 2] }, "0.3.0")) {
      fail("package_index_self_test_compatibility_invalid");
    }

    // The declared set covers every package the tree ships: a package the host
    // installs but the set never names is a package no release publishes, and the
    // tool refuses that state here rather than reporting a complete plan for a
    // partial set. The synthetic fixture is the one declared source outside those
    // directories, so only the missing direction is refused.
    const packageDirectories = ["crates", "components"].flatMap((parent) =>
      readdirSync(path.join(repoRoot, parent), { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => `${parent}/${entry.name}/package`)
        .filter((source) => lstatSync(path.join(repoRoot, source, PACKAGE_PAYLOAD_MANIFEST_NAME),
          { throwIfNoEntry: false })?.isFile()))
      .sort();
    const declaredSources = new Set(set.packages.map((entry) => entry.source));
    const unregistered = packageDirectories.filter((source) => !declaredSources.has(source));
    if (packageDirectories.length === 0 || unregistered.length > 0) {
      fail("package_index_self_test_package_unregistered", { packages: unregistered });
    }

    // A signed index verifies through the shared Ed25519 role mechanism, and
    // tampering or a missing role signature is refused.
    const keyPair = () => generateKeyPairSync("ed25519");
    const offlineRoot = keyPair();
    const onlineSigning = keyPair();
    const offlineRootKeyId = "self-test-offline-root";
    const onlineSigningKeyId = "self-test-online-signing";
    const keys = [
      { keyId: offlineRootKeyId, privateKey: offlineRoot.privateKey },
      { keyId: onlineSigningKeyId, privateKey: onlineSigning.privateKey },
    ];
    const rawPublic = (keyObject) =>
      Buffer.from(keyObject.export({ type: "spki", format: "der" }))
        .subarray(-32).toString("base64");
    const publicKeysText = JSON.stringify({
      keys: {
        [offlineRootKeyId]: { publicKey: rawPublic(offlineRoot.publicKey) },
        [onlineSigningKeyId]: { publicKey: rawPublic(onlineSigning.publicKey) },
      },
    });
    const selfTestAssets = first.map((produced, position) =>
      indexEntry(produced, `LicoUp-package-self-test-${position}.licopkg`));
    const index = signIndex(buildIndex({
      releaseTrack: "stable",
      packages: selfTestAssets,
      offlineRootKeyId,
      onlineSigningKeyId,
    }), keys);
    const verified = verifyPackageIndex(JSON.stringify(index), publicKeysText);
    if (verified.packages.length !== selfTestAssets.length ||
      JSON.stringify(verified.packages.map((entry) => entry.packageId)) !==
        JSON.stringify(selfTestAssets.map((entry) => entry.packageId))) {
      fail("package_index_self_test_index_invalid");
    }
    const tampered = JSON.parse(JSON.stringify(index));
    tampered.packages[0].payload.sha256 = `sha256:${"0".repeat(64)}`;
    expectRejected("package_index_signature_invalid", () =>
      verifyPackageIndex(JSON.stringify(tampered), publicKeysText));
    const extended = JSON.parse(JSON.stringify(index));
    extended.eligibilityOverride = true;
    expectRejected("package_index_invalid", () =>
      verifyPackageIndex(JSON.stringify(extended), publicKeysText));
    const singleRole = JSON.parse(JSON.stringify(index));
    singleRole.signatures = singleRole.signatures.slice(0, 1);
    expectRejected("package_index_signature_roles_incomplete", () =>
      verifyPackageIndex(JSON.stringify(singleRole), publicKeysText));
    const rewrittenRange = JSON.parse(JSON.stringify(index));
    rewrittenRange.packages[0].clientCompatibility.range = ">=0.0.0";
    expectRejected("package_index_signature_invalid", () =>
      verifyPackageIndex(JSON.stringify(rewrittenRange), publicKeysText));
    expectRejected("package_index_key_policy_invalid", () => buildIndex({
      releaseTrack: "stable",
      packages: selfTestAssets,
      offlineRootKeyId: "same-role",
      onlineSigningKeyId: "same-role",
    }));

    // An interpreter-carried or mislabelled package is refused at packaging.
    const fixtureManifest = JSON.parse(readFileSync(
      path.join(fixtureSourceDirectory(), "manifest.json"), "utf8",
    ));
    const interpreterRuntime = selfTestSet(root, {
      "manifest.json": JSON.stringify({
        ...fixtureManifest,
        runtime: {
          mode: "process",
          entry: "bin/licoup-fixture-converter",
          runtimeRef: "python3",
        },
      }, null, 2),
    });
    expectRejected("package_index_manifest_runtime_not_native", () =>
      producePackagePayload(loadPackageSet(interpreterRuntime.setPath, { root }).packages[0]));
    const scriptEntry = selfTestSet(root, { "bin/agent.py": "print('fixture')\n" });
    expectRejected("package_payload_entry_not_native", () =>
      producePackagePayload(loadPackageSet(scriptEntry.setPath, { root }).packages[0]));
    const shebangEntry = selfTestSet(root, {
      "bin/licoup-fixture-converter": "#!/bin/sh\nexec true\n",
    });
    expectRejected("package_payload_converter_not_native", () =>
      producePackagePayload(loadPackageSet(shebangEntry.setPath, { root }).packages[0]));
    const mismatchEntry = selfTestSet(root, {
      "package-release.json": JSON.stringify({
        schemaVersion: PACKAGE_RELEASE_SCHEMA,
        packageId: "org.licoland.fixture.native-converter",
        packageVersion: "1.3.0",
        clientCompatibility: { kind: "range", range: ">=0.2.0, <1.0.0" },
        converter: {
          kind: "native-executable",
          entry: "bin/other-converter",
          sourceFormat: "fixture.agent-session.v1",
          targetFormat: "licoup.conversation.v1",
        },
      }, null, 2),
    });
    expectRejected("package_index_converter_entry_mismatch", () =>
      producePackagePayload(loadPackageSet(mismatchEntry.setPath, { root }).packages[0]));
    const missingEntry = selfTestSet(root, {
      "manifest.json": JSON.stringify({
        ...fixtureManifest,
        runtime: { mode: "process", entry: "bin/missing-converter" },
      }, null, 2),
      "package-release.json": JSON.stringify({
        schemaVersion: PACKAGE_RELEASE_SCHEMA,
        packageId: "org.licoland.fixture.native-converter",
        packageVersion: "1.3.0",
        clientCompatibility: { kind: "range", range: ">=0.2.0, <1.0.0" },
        converter: {
          kind: "native-executable",
          entry: "bin/missing-converter",
          sourceFormat: "fixture.agent-session.v1",
          targetFormat: "licoup.conversation.v1",
        },
      }, null, 2),
    });
    expectRejected("package_payload_converter_entry_missing", () =>
      producePackagePayload(loadPackageSet(missingEntry.setPath, { root }).packages[0]));
    const mismatchedIdentity = selfTestSet(root, {
      "package-release.json": JSON.stringify({
        schemaVersion: PACKAGE_RELEASE_SCHEMA,
        packageId: "org.licoland.fixture.other",
        packageVersion: "1.3.0",
        clientCompatibility: { kind: "major", majors: [1] },
        converter: {
          kind: "native-executable",
          entry: "bin/licoup-fixture-converter",
          sourceFormat: "fixture.agent-session.v1",
          targetFormat: "licoup.conversation.v1",
        },
      }, null, 2),
    });
    expectRejected("package_index_package_identity_mismatch", () =>
      producePackagePayload(
        loadPackageSet(mismatchedIdentity.setPath, { root }).packages[0],
        { expectedPackageId: "org.licoland.fixture.native-converter" },
      ));

    // A payload that is not the one the index describes is refused, and the
    // refusal names the package whose bytes disagree.
    const payloadRoot = path.join(root, "payloads");
    mkdirSync(payloadRoot, { recursive: true });
    const payloadPaths = selfTestAssets.map((entry) =>
      path.join(payloadRoot, entry.payload.fileName));
    for (const [position, entry] of selfTestAssets.entries()) {
      writeFileSync(payloadPaths[position], first[position].payload);
    }
    if (JSON.stringify(verifyIndexPayloads(verified, payloadRoot)) !==
      JSON.stringify(selfTestAssets.map((entry) => entry.packageId))) {
      fail("package_index_self_test_index_invalid");
    }
    const tamperedContent = Buffer.concat([first[0].payload, Buffer.from("tampered")]);
    writeFileSync(payloadPaths[0], tamperedContent);
    expectRejected("package_index_payload_invalid", () =>
      verifyIndexPayloads(verified, payloadRoot));
    writeFileSync(payloadPaths[0], first[0].payload);
    const selfDescribed = JSON.parse(JSON.stringify(verified));
    selfDescribed.packages[0].converter.sourceFormat = "rewritten.format.v9";
    expectRejected("package_index_payload_self_description_mismatch", () =>
      verifyIndexPayloads(selfDescribed, payloadRoot));

    // The bundled release public-key catalogue keeps its shape.
    const bundled = parsePublicKeysDocument(bundledPublicKeysDocument());
    if (Object.keys(bundled).length < 2) {
      fail("package_index_self_test_public_keys_invalid");
    }
    return Object.freeze({ ok: true, schema: PACKAGE_INDEX_SCHEMA });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined) {
      fail("package_index_option_invalid");
    }
    result[flag.slice(2)] = value;
  }
  return result;
}

export function runClientReleasePackageIndex(argv = process.argv.slice(2), {
  emit = (record) => process.stdout.write(`${JSON.stringify(record, null, 2)}\n`),
} = {}) {
  if (argv[0] === "--self-test") {
    if (argv[1] !== undefined && argv[1] !== "true") fail("package_index_option_invalid");
    emit(selfTest());
    return;
  }
  const [command = "", ...rest] = argv;
  const args = parseArgs(rest);
  if (args["self-test"] === "true") {
    emit(selfTest());
    return;
  }
  const targetId = args.target || defaultTargetId;
  const releaseTrack = args.track || defaultReleaseTrack;
  if (command === "plan") {
    emit(planPackageRelease({ setPath: args.set, targetId, releaseTrack }));
    return;
  }
  if (command === "build") {
    emit(buildPackageRelease({
      setPath: args.set,
      outputRoot: args.output,
      targetId,
      releaseTrack,
    }));
    return;
  }
  if (command === "fixture") {
    emit(fixturePackageRelease({ outputRoot: args.output, targetId, releaseTrack }));
    return;
  }
  if (command === "verify") {
    emit(verifyPackageRelease({
      indexPath: args.index,
      payloadRoot: args.payloads,
      publicKeysPath: args["public-keys"] || defaultPublicKeysPath,
    }));
    return;
  }
  fail("package_index_command_invalid");
}

if (process.argv[1] && import.meta.url ===
  pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    runClientReleasePackageIndex();
  } catch (error) {
    const known = error instanceof ClientPackageIndexError ||
      error instanceof PackagePayloadError;
    process.stderr.write(`${JSON.stringify({
      ok: false,
      code: known ? error.code : "package_index_failed",
      ...(known && error.details ? error.details : {}),
      privatePathsIncluded: false,
    })}\n`);
    process.exitCode = 1;
  }
}
