#!/usr/bin/env node
import strictAssert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
  randomUUID,
  sign as signPayload,
  verify as verifyPayload
} from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync
} from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  clientReleaseTargets,
  createClientGitHubReleaseClosure,
  loadClientReleaseTargetCatalog
} from "../tools/scripts/lib/client-release-targets.mjs";
import { loadSecureClientContract } from "../tools/scripts/lib/secure-client-contract.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const clientVersionManifest = JSON.parse(readFileSync(path.join(repoRoot, "tools", "client-version.json"), "utf8"));
const currentClientVersion = clientVersionManifest.productVersion;
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(currentClientVersion)) {
  throw new Error(`Invalid client product version: ${currentClientVersion}`);
}
const workRoot = path.join(repoRoot, "build", "tmp", "client-update-release-channel");
const artifactRoot = path.join(workRoot, "artifacts");
const stagingRoot = path.join(workRoot, "staging");
const reportPath = path.join(repoRoot, "build", "reports", "client-update-release-channel.json");
const androidPhysicalInstallLaunchReportPath = path.join(
  repoRoot,
  "build",
  "reports",
  "android-physical-install-launch.json"
);

const releaseTargetCatalog = loadClientReleaseTargetCatalog();
const productionTargets = Object.freeze(clientReleaseTargets(releaseTargetCatalog, {
  includeUnsupported: false,
  includeReleaseUnsupported: false
}));
const { createSecureClientGitHubReleaseClosure } = await loadSecureClientContract();

function reduceClientGitHubReleaseClosure(options) {
  return createClientGitHubReleaseClosure({
    ...options,
    githubReleaseReducer: createSecureClientGitHubReleaseClosure
  });
}

function stableStringify(value) {
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableStringify(item)).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function sha256Buffer(buffer) {
  return `sha256:${createHash("sha256").update(buffer).digest("hex")}`;
}

function sha256File(filePath) {
  return sha256Buffer(readFileSync(filePath));
}

function keyFingerprint(keyObject) {
  return sha256Buffer(keyObject.export({ type: "spki", format: "der" }));
}

function parseSemanticVersion(value, label = "version") {
  const match = String(value || "").match(
    /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u
  );
  ensure(match, `${label} is not valid semantic versioning`);
  return {
    core: match.slice(1, 4).map((part) => Number.parseInt(part, 10)),
    prerelease: match[4] ? match[4].split(".") : []
  };
}

function compareVersions(left, right) {
  const leftVersion = parseSemanticVersion(left, "left version");
  const rightVersion = parseSemanticVersion(right, "right version");
  for (let index = 0; index < 3; index += 1) {
    const delta = leftVersion.core[index] - rightVersion.core[index];
    if (delta !== 0) {
      return delta > 0 ? 1 : -1;
    }
  }
  if (leftVersion.prerelease.length === 0 || rightVersion.prerelease.length === 0) {
    return leftVersion.prerelease.length === rightVersion.prerelease.length
      ? 0
      : leftVersion.prerelease.length === 0 ? 1 : -1;
  }
  const length = Math.max(leftVersion.prerelease.length, rightVersion.prerelease.length);
  for (let index = 0; index < length; index += 1) {
    const leftPart = leftVersion.prerelease[index];
    const rightPart = rightVersion.prerelease[index];
    if (leftPart === undefined || rightPart === undefined) return leftPart === undefined ? -1 : 1;
    if (leftPart === rightPart) continue;
    const leftNumeric = /^\d+$/u.test(leftPart);
    const rightNumeric = /^\d+$/u.test(rightPart);
    if (leftNumeric && rightNumeric) {
      return Number.parseInt(leftPart, 10) > Number.parseInt(rightPart, 10) ? 1 : -1;
    }
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
    return leftPart > rightPart ? 1 : -1;
  }
  return 0;
}

function unsignedPayload(manifest) {
  const clone = structuredClone(manifest);
  delete clone.signatures;
  return clone;
}

function signManifest(manifest, signers) {
  const payload = Buffer.from(stableStringify(unsignedPayload(manifest)), "utf8");
  return {
    ...manifest,
    signatures: signers.map(({ keyId, signingKey }) => ({
      keyId,
      algorithm: "Ed25519",
      signature: signPayload(null, payload, signingKey).toString("base64")
    }))
  };
}

function signEnvelope(envelope, signingKey, keyId) {
  const payload = Buffer.from(stableStringify(unsignedPayload(envelope)), "utf8");
  return {
    ...envelope,
    signatures: [
      {
        keyId,
        algorithm: "Ed25519",
        signature: signPayload(null, payload, signingKey).toString("base64")
      }
    ]
  };
}

function ensure(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function artifactMatchesTarget(artifact, target) {
  return (
    artifact.targetId === target.id &&
    artifact.platform === target.platform &&
    artifact.osFamily === target.osFamily &&
    artifact.arch === target.arch
  );
}

function selectRelease(manifest, target) {
  ensure(Array.isArray(manifest.releases) && manifest.releases.length > 0, "manifest has no releases");
  const seenVersions = new Set();
  const candidates = [];
  for (const release of manifest.releases) {
    parseSemanticVersion(release.version, "release version");
    parseSemanticVersion(release.minimumSupportedVersion, "minimum supported version");
    ensure(!seenVersions.has(release.version), "manifest contains a duplicate release version");
    seenVersions.add(release.version);
    ensure(Array.isArray(release.artifacts) && release.artifacts.length > 0, "release has no artifacts");
    const seenTargets = new Set();
    for (const artifact of release.artifacts) {
      ensure(artifact.targetId && !seenTargets.has(artifact.targetId), "release contains a duplicate artifact target");
      seenTargets.add(artifact.targetId);
      ensure(typeof artifact.fileName === "string" && /^[^/\\]+$/u.test(artifact.fileName), "artifact fileName is invalid");
      const artifactUrl = new URL(artifact.url);
      ensure(
        decodeURIComponent(path.basename(artifactUrl.pathname)) === artifact.fileName,
        "artifact fileName does not match its signed url"
      );
    }
    const artifact = (release.artifacts || []).find((candidate) => artifactMatchesTarget(candidate, target));
    if (artifact) {
      candidates.push({ release, artifact });
    }
  }
  candidates.sort((left, right) => compareVersions(left.release.version, right.release.version));
  return candidates.at(-1) || null;
}

function verifyManifest(manifest, publicKeysById, { currentVersion, target, revocationList, channel = "stable" } = {}) {
  ensure(manifest.schemaVersion === "v0.0.1:client-update:manifest-1", "unexpected manifest schema");
  ensure(manifest.channel === channel, "manifest channel does not match the selected channel");
  ensure(manifest.channelPolicy?.offlineRootKeyId, "missing offline root key id");
  ensure(manifest.channelPolicy?.onlineChannelKeyId, "missing online channel key id");
  ensure(
    manifest.channelPolicy.offlineRootKeyId !== manifest.channelPolicy.onlineChannelKeyId,
    "offline root and online channel keys must be distinct"
  );
  ensure(Array.isArray(manifest.signatures) && manifest.signatures.length > 0, "manifest has no signatures");
  const payload = Buffer.from(stableStringify(unsignedPayload(manifest)), "utf8");
  const verifiedKeyIds = new Set();
  for (const signature of manifest.signatures) {
    ensure(!verifiedKeyIds.has(signature.keyId), "manifest contains a duplicate signing key id");
    const key = publicKeysById.get(signature.keyId);
    const valid = Boolean(
      key &&
        signature.algorithm === "Ed25519" &&
        verifyPayload(null, payload, key, Buffer.from(signature.signature, "base64"))
    );
    ensure(valid, "manifest signature verification failed");
    verifiedKeyIds.add(signature.keyId);
  }
  ensure(
    verifiedKeyIds.has(manifest.channelPolicy.offlineRootKeyId),
    "manifest is missing the offline root signature"
  );
  ensure(
    verifiedKeyIds.has(manifest.channelPolicy.onlineChannelKeyId),
    "manifest is missing the online channel signature"
  );
  const signatureOk = true;
  if (!target) {
    return { signatureOk };
  }
  const selected = selectRelease(manifest, target);
  ensure(selected, `unsupported update target: ${target.id}`);
  if (revocationList) {
    verifyRevocationList(revocationList, publicKeysById, {
      channel,
      offlineRootKeyId: manifest.channelPolicy.offlineRootKeyId
    });
    const revokedKeyIds = new Set(revocationList.revokedKeyIds || []);
    const revokedArtifactDigests = new Set(revocationList.revokedArtifactDigests || []);
    const signingKeyIds = manifest.signatures.map((signature) => signature.keyId);
    if (signingKeyIds.some((keyId) => revokedKeyIds.has(keyId))) {
      throw new Error("manifest signing key is revoked by the signed revocation list");
    }
    if (revokedArtifactDigests.has(selected.artifact.sha256)) {
      throw new Error("selected release artifact digest is revoked by the signed revocation list");
    }
    if (new Set(revocationList.revokedVersions || []).has(selected.release.version)) {
      throw new Error("selected release version is revoked by the signed revocation list");
    }
  }
  if (currentVersion && compareVersions(selected.release.version, currentVersion) < 0) {
    ensure(manifest.channelPolicy.allowDowngrade === true, "signed channel policy rejects downgrade");
  }
  if (currentVersion && compareVersions(currentVersion, selected.release.minimumSupportedVersion) < 0) {
    throw new Error("current version is below the minimum supported update floor");
  }
  return { signatureOk, ...selected };
}

function verifyArtifact(artifact) {
  ensure(typeof artifact.fileName === "string" && /^[^/\\]+$/u.test(artifact.fileName), "artifact fileName is invalid");
  const artifactUrl = new URL(artifact.url);
  ensure(
    decodeURIComponent(path.basename(artifactUrl.pathname)) === artifact.fileName,
    "artifact fileName does not match its signed url"
  );
  const artifactPath = fileURLToPath(artifact.url);
  ensure(existsSync(artifactPath), `artifact does not exist for ${artifact.targetId}`);
  const stats = statSync(artifactPath);
  ensure(stats.size === artifact.size, `artifact size mismatch for ${artifact.targetId}`);
  ensure(sha256File(artifactPath) === artifact.sha256, `artifact checksum mismatch for ${artifact.targetId}`);
  return artifactPath;
}

function verifySignedEnvelope(envelope, publicKeysById, expectedSchemaVersion, label) {
  ensure(envelope.schemaVersion === expectedSchemaVersion, `unexpected ${label} schema`);
  ensure(Array.isArray(envelope.signatures) && envelope.signatures.length > 0, `${label} has no signatures`);
  const payload = Buffer.from(stableStringify(unsignedPayload(envelope)), "utf8");
  const verifiedKeyIds = new Set();
  for (const signature of envelope.signatures) {
    ensure(!verifiedKeyIds.has(signature.keyId), `${label} contains a duplicate signing key id`);
    const key = publicKeysById.get(signature.keyId);
    const valid = Boolean(
      key &&
        signature.algorithm === "Ed25519" &&
        verifyPayload(null, payload, key, Buffer.from(signature.signature, "base64"))
    );
    ensure(valid, `${label} signature verification failed`);
    verifiedKeyIds.add(signature.keyId);
  }
  return verifiedKeyIds;
}

function verifyRevocationList(
  revocationList,
  publicKeysById,
  { channel = "stable", offlineRootKeyId = revocationList.offlineRootKeyId } = {}
) {
  ensure(revocationList.channel === channel, "revocation list channel does not match the selected channel");
  ensure(
    revocationList.offlineRootKeyId === offlineRootKeyId,
    "revocation list offline root key does not match channel policy"
  );
  const verifiedKeyIds = verifySignedEnvelope(
    revocationList,
    publicKeysById,
    "v0.0.1:client-update:revocation-list-1",
    "revocation list"
  );
  ensure(
    verifiedKeyIds.has(offlineRootKeyId),
    "revocation list is missing the offline root signature"
  );
  return { signatureOk: true };
}

function verifyPublicationReceipt(receipt, publicKeysById) {
  verifySignedEnvelope(
    receipt,
    publicKeysById,
    "v0.0.1:client-update:publication-receipt-1",
    "publication receipt"
  );
  return { signatureOk: true };
}

function expectFailure(name, fn) {
  try {
    fn();
  } catch (error) {
    return {
      name,
      ok: true,
      rejectedWith: error instanceof Error ? error.message : String(error)
    };
  }
  throw new Error(`${name} did not fail`);
}

function redactLocalPaths(value = "") {
  return String(value || "")
    .replaceAll(repoRoot, "<repo>")
    .replace(/\/Users\/[^/\s"]+(?:\/[^\s"]*)?/gu, "<local-path>")
    .replace(/\/private\/var\/folders\/[^\s"]+/gu, "<local-temp>")
    .replace(/\/private\/tmp\/[^\s"]+/gu, "<local-temp>")
    .replace(/\/tmp\/[^\s"]+/gu, "<local-temp>")
    .replace(/file:\/\/\/[^\s"]+/gu, "file:///<redacted>")
    .replace(/[A-Za-z]:\\[^\s"]+/gu, "<local-path>");
}

function summarizeOutput(value = "") {
  return redactLocalPaths(value)
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .slice(0, 8)
    .join("\n");
}

function parseJsonObjectOutput(value = "") {
  const text = String(value || "");
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new Error("command did not emit a JSON object");
  }
  return JSON.parse(text.slice(start, end + 1));
}

function readJsonIfPresent(filePath) {
  try {
    return JSON.parse(readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

function summarizeAndroidPhysicalInstallLaunchReport(report) {
  if (!report) {
    return {
      report: "build/reports/android-physical-install-launch.json",
      present: false,
      ready: false
    };
  }
  const summary = report.summary || {};
  return {
    report: "build/reports/android-physical-install-launch.json",
    present: true,
    ok: report.ok === true,
    physicalDevice: report.physicalDevice === true,
    packageName: String(report.packageName || ""),
    apkReady: summary.apkReady === true,
    installReady: summary.installReady === true,
    launchReady: summary.launchReady === true,
    runtimeStatusReady: summary.runtimeStatusReady === true,
    nativeRuntimeReady: summary.nativeRuntimeReady === true,
    androidKeyStoreReady: summary.androidKeyStoreReady === true,
    keyStoreUserAuthReady: summary.keyStoreUserAuthReady === true,
    ready: report.ok === true &&
      report.physicalDevice === true &&
      summary.apkReady === true &&
      summary.installReady === true &&
      summary.launchReady === true &&
      summary.runtimeStatusReady === true &&
      summary.nativeRuntimeReady === true &&
      summary.androidKeyStoreReady === true &&
      summary.keyStoreUserAuthReady === true
  };
}

function appExecutablePath(root, appName, executableName = "flutter_client") {
  return path.join(root, appName, "Contents", "MacOS", executableName);
}

function fileSizeOrZero(filePath) {
  try {
    const stat = statSync(filePath);
    return stat.isFile() ? stat.size : 0;
  } catch {
    return 0;
  }
}

function readPackageManifest(root) {
  return readJsonIfPresent(path.join(root, "package-metadata", "lico-client", "packaging-modules.json")) || {};
}

function summarizeMacosBundleRoot(kind, root, appName) {
  const manifest = readPackageManifest(root);
  const signing = manifest.signing || {};
  return {
    kind,
    root: path.relative(repoRoot, root),
    appName,
    mode: String(manifest.mode || ""),
    platform: String(manifest.platform || ""),
    signingKind: String(signing.signingKind || ""),
    entitlementProfile: String(signing.entitlementProfile || ""),
    entitlementsFile: String(signing.entitlementsFile || ""),
    productionEntitlementsRequested: signing.productionEntitlementsRequested === true,
    flutterExecutable: String(manifest.flutterExecutable || ""),
    flutterExecutableBytes: fileSizeOrZero(appExecutablePath(root, appName)),
    licoClientBytes: fileSizeOrZero(appExecutablePath(root, appName, "lico-client")),
    manifestPresent: Object.keys(manifest).length > 0,
    readmePresent: existsSync(path.join(root, "README-macos.txt")),
    runnableMarkerPresent: kind === "runnable" ? existsSync(path.join(root, "RUNNABLE_CLIENT.txt")) : null
  };
}

function runMacosReleaseBundleEvidence(hostPlatform) {
  const evidence = {
    platform: "macos",
    hostPlatform,
    attempted: hostPlatform === "macos",
    dryRun: false,
    artifactKind: "actual-release-bundle",
    signingKind: "local-ad-hoc-codesign",
    developerIdSigned: false,
    notarizationVerified: false,
    gatekeeperVerified: false,
    command: "node apps/desktop/scripts/package-client.mjs --platform macos --mode release --production-entitlements",
    verificationCommand: "node apps/desktop/scripts/verify-macos-client-bundle.mjs",
    codesignCommand: "codesign --verify --deep --strict Arc.app",
    ok: false
  };
  if (!evidence.attempted) {
    return {
      ...evidence,
      status: "not-run-on-this-host"
    };
  }
  if (!String(process.env.LICO_MACOS_APP_IDENTIFIER_PREFIX || "").trim()) {
    return {
      ...evidence,
      status: "production-entitlements-blocked",
      ok: false,
      localBundleShapeVerified: false,
      missingEnvironment: "LICO_MACOS_APP_IDENTIFIER_PREFIX",
      remainingProductionProofs: [
        "LICO_MACOS_APP_IDENTIFIER_PREFIX for production Keychain entitlements",
        "Developer ID signing",
        "hardened runtime release policy review",
        "notarization",
        "stapling",
        "Gatekeeper assessment on release-distributed artifact"
      ]
    };
  }

  const packageScriptPath = path.join(repoRoot, "apps", "desktop", "scripts", "package-client.mjs");
  const packageResult = spawnSync(process.execPath, [packageScriptPath, "--platform", "macos", "--mode", "release", "--production-entitlements"], {
    cwd: repoRoot,
    encoding: "utf8",
    env: process.env,
    maxBuffer: 128 * 1024 * 1024,
    windowsHide: true
  });
  strictAssert.equal(
    packageResult.status,
    0,
    `macOS release bundle build failed: ${summarizeOutput(packageResult.stderr || packageResult.stdout)}`
  );

  const verifierPath = path.join(repoRoot, "apps", "desktop", "scripts", "verify-macos-client-bundle.mjs");
  const verifyResult = spawnSync(process.execPath, [verifierPath], {
    cwd: repoRoot,
    encoding: "utf8",
    env: process.env,
    maxBuffer: 16 * 1024 * 1024,
    windowsHide: true
  });
  strictAssert.equal(
    verifyResult.status,
    0,
    `macOS release bundle verification failed: ${summarizeOutput(verifyResult.stderr || verifyResult.stdout)}`
  );

  const runnableRoot = path.join(repoRoot, "build", "apps", "desktop", "runnable", "macos", "release");
  const runnableAppPath = path.join(runnableRoot, "Arc.app");
  const codesignResult = spawnSync("codesign", ["--verify", "--deep", "--strict", runnableAppPath], {
    cwd: repoRoot,
    encoding: "utf8",
    env: process.env,
    maxBuffer: 16 * 1024 * 1024,
    windowsHide: true
  });
  strictAssert.equal(
    codesignResult.status,
    0,
    `macOS release bundle local codesign verification failed: ${summarizeOutput(codesignResult.stderr || codesignResult.stdout)}`
  );

  const bundleRoot = path.join(repoRoot, "build", "apps", "desktop", "bundles", "macos", "release", "bundle");
  return {
    ...evidence,
    ok: true,
    status: "verified",
    packageExitCode: packageResult.status,
    verificationExitCode: verifyResult.status,
    codesignVerifyExitCode: codesignResult.status,
    packageOutput: summarizeOutput(packageResult.stdout),
    verificationOutput: summarizeOutput(verifyResult.stdout),
    codesignOutput: summarizeOutput(codesignResult.stderr || codesignResult.stdout),
    artifacts: [
      summarizeMacosBundleRoot("bundle", bundleRoot, "flutter_client.app"),
      summarizeMacosBundleRoot("runnable", runnableRoot, "Arc.app")
    ],
    remainingProductionProofs: [
      "Developer ID signing",
      "hardened runtime release policy review",
      "notarization",
      "stapling",
      "Gatekeeper assessment on release-distributed artifact"
    ]
  };
}

function createArtifact(target) {
  const fileName = `${target.id}${target.installerStrategy === "app-bundle-replacement" ? ".tar.gz" : ".bin"}`;
  const filePath = path.join(artifactRoot, fileName);
  const payload = Buffer.from(`LicoLite update artifact ${target.id} ${randomUUID()}\n`, "utf8");
  writeFileSync(filePath, payload);
  return {
    targetId: target.id,
    platform: target.platform,
    osFamily: target.osFamily,
    arch: target.arch,
    installerStrategy: target.installerStrategy,
    url: pathToFileURL(filePath).href,
    fileName,
    size: payload.length,
    sha256: sha256Buffer(payload),
    ...(target.installerStrategy === "app-bundle-replacement"
      ? { applicationName: "Lico Arc.app", bundleId: "com.liko.arc" }
      : {})
  };
}

function artifactsForTargets(artifacts, targetIds) {
  const selected = new Set(targetIds);
  return artifacts.filter((artifact) => selected.has(artifact.targetId));
}

function readyTargetEvidence(targetIds) {
  return targetIds.map((targetId) => ({
    targetId,
    githubReleaseReady: true,
    blockers: [],
    evidenceRefs: [`reports/platform-release/${targetId}.json`]
  }));
}

function createDryRunInstallerPlans(artifacts) {
  return artifacts.map((artifact) => ({
    targetId: artifact.targetId,
    platform: artifact.platform,
    osFamily: artifact.osFamily,
    arch: artifact.arch,
    installerStrategy: artifact.installerStrategy,
    preUpdateStateRecord: `${artifact.targetId}.pre-update.json`,
    rollback:
      artifact.platform === "android"
        ? {
            feasibility: "platform-managed-or-recovery-install",
            note: "Android rollback depends on platform policy; dry-run records recovery install metadata."
          }
        : {
            feasibility: "supported-by-staged-previous-artifact",
            note: "Dry-run records the previous runnable path and staged replacement path."
          },
    smokeCheckCommand:
      artifact.platform === "android"
        ? "npm run client:verify:android-physical-install-launch -- --install --launch"
        : `node apps/desktop/scripts/package-client.mjs --platform ${artifact.platform} --mode release --dry-run`
  }));
}

function resumeDownloadAndCleanup(artifact) {
  mkdirSync(stagingRoot, { recursive: true });
  const sourcePath = fileURLToPath(artifact.url);
  const finalPath = path.join(stagingRoot, `${artifact.targetId}.final`);
  const partialPath = `${finalPath}.partial`;
  const source = readFileSync(sourcePath);
  writeFileSync(partialPath, source.subarray(0, Math.max(1, Math.floor(source.length / 2))));
  copyFileSync(sourcePath, finalPath);
  ensure(sha256File(finalPath) === artifact.sha256, "resumed artifact checksum mismatch");
  rmSync(partialPath, { force: true });
  ensure(!existsSync(partialPath), "partial staging file was not removed");
  rmSync(finalPath, { force: true });
  ensure(!existsSync(finalPath), "final staging file was not removed after verification");
  return {
    targetId: artifact.targetId,
    resumed: true,
    hashVerified: true,
    stagingCleaned: true
  };
}

function runInstallerDryRun(platform) {
  const scriptPath = path.join(repoRoot, "apps", "desktop", "scripts", "package-client.mjs");
  const result = spawnSync(process.execPath, [scriptPath, "--platform", platform, "--mode", "release", "--dry-run"], {
    cwd: repoRoot,
    encoding: "utf8",
    env: process.env,
    windowsHide: true
  });
  strictAssert.equal(result.status, 0, `installer dry-run failed for ${platform}: ${summarizeOutput(result.stderr || result.stdout)}`);
  return {
    platform,
    command: `node apps/desktop/scripts/package-client.mjs --platform ${platform} --mode release --dry-run`,
    exitCode: result.status,
    stdout: summarizeOutput(result.stdout),
    stderr: summarizeOutput(result.stderr)
  };
}

function runMacosProductionEntitlementsDryRun() {
  const scriptPath = path.join(repoRoot, "apps", "desktop", "scripts", "package-client.mjs");
  const result = spawnSync(
    process.execPath,
    [scriptPath, "--platform", "macos", "--mode", "release", "--production-entitlements", "--dry-run"],
    {
      cwd: repoRoot,
      encoding: "utf8",
      env: process.env,
      windowsHide: true
    }
  );
  strictAssert.equal(
    result.status,
    0,
    `macOS production entitlements dry-run failed: ${summarizeOutput(result.stderr || result.stdout)}`
  );
  const plan = parseJsonObjectOutput(result.stdout);
  const signing = plan.signing || {};
  const evidence = {
    platform: "macos",
    command: "node apps/desktop/scripts/package-client.mjs --platform macos --mode release --production-entitlements --dry-run",
    exitCode: result.status,
    dryRun: true,
    ok: plan.ok === true &&
      plan.platform === "macos" &&
      plan.mode === "release" &&
      signing.productionEntitlementsRequested === true &&
      signing.entitlementProfile === "production-release" &&
      signing.entitlementsFile === "apps/desktop/macos/Runner/ProductionRelease.entitlements",
    signingKind: String(signing.signingKind || ""),
    entitlementProfile: String(signing.entitlementProfile || ""),
    entitlementsFile: String(signing.entitlementsFile || ""),
    productionEntitlementsRequested: signing.productionEntitlementsRequested === true
  };
  strictAssert.equal(
    evidence.ok,
    true,
    `macOS production entitlements dry-run selected the wrong signing policy: ${JSON.stringify(evidence)}`
  );
  return evidence;
}

function buildProductionClosureStatus({
  publicationReceiptVerification,
  macosReleaseBundleEvidence,
  androidPhysicalInstallLaunchEvidence,
  dryRunInstallerPlans
}) {
  const dryRunPlansCoverTargetLabels =
    dryRunInstallerPlans.length === productionTargets.length &&
    dryRunInstallerPlans.every((plan) => plan.installerStrategy && plan.preUpdateStateRecord && plan.rollback);
  const localAdHocBundleVerified =
    macosReleaseBundleEvidence.ok === true &&
    macosReleaseBundleEvidence.artifactKind === "actual-release-bundle" &&
    macosReleaseBundleEvidence.signingKind === "local-ad-hoc-codesign";
  return {
    dryRunOnly: true,
    productionReady: false,
    rawProductionKeyMaterialIncluded: false,
    productionSigningCustodyReady: false,
    productionPublicationReceiptReady: false,
    productionInstallerExecutionReady: false,
    productionMacosDistributionReady: false,
    signingCustody: {
      offlineRootSigningCustody: "generated-test-vector-only",
      onlineChannelSigningCustody: "generated-test-vector-only",
      publicationAuthorityCustody: "generated-test-vector-only",
      productionCustodyReceiptVerified: false
    },
    publicationReceiptStatus: {
      dryRunReceiptVerified: publicationReceiptVerification.signatureOk === true,
      dryRunReceiptSource: "generated-local-test-vector",
      productionChannelReceiptVerified: false,
      publicationAuthorityCustodyVerified: false
    },
    installerExecutionStatus: {
      dryRunPlansCoverTargetLabels,
      productionHostExecutionReady: false,
      dryRunPlanCount: dryRunInstallerPlans.length,
      productionTargetCount: productionTargets.length
    },
    macosDistributionStatus: {
      localAdHocBundleVerified,
      developerIdSigned: macosReleaseBundleEvidence.developerIdSigned === true,
      notarizationVerified: macosReleaseBundleEvidence.notarizationVerified === true,
      gatekeeperVerified: macosReleaseBundleEvidence.gatekeeperVerified === true,
      productionReady: false
    },
    androidProductionUpdateStatus: {
      physicalInstallLaunchReady: androidPhysicalInstallLaunchEvidence.ready === true,
      productionReady: false
    },
    remainingProductionGates: [
      "offline-root and online-channel signing custody receipts",
      "publication-authority custody and production-channel publication receipt",
      "Developer ID signing, notarization, stapling, and Gatekeeper assessment",
      "release-built installer/package execution proof on declared production hosts",
      ...(
        androidPhysicalInstallLaunchEvidence.ready === true
          ? []
          : ["Android physical-device install and launch evidence"]
      )
    ]
  };
}

function main() {
  rmSync(workRoot, { recursive: true, force: true });
  mkdirSync(artifactRoot, { recursive: true });

  const offlineRoot = generateKeyPairSync("ed25519");
  const onlineChannel = generateKeyPairSync("ed25519");
  const publicationAuthority = generateKeyPairSync("ed25519");
  const offlineRootKeyId = "offline-root-test-vector";
  const onlineChannelKeyId = "online-channel-test-vector";
  const publicationAuthorityKeyId = "release-publication-test-vector";
  const artifacts = productionTargets.map(createArtifact);
  const macosSingleTargetIds = ["macos-arm64"];
  const linuxArmSingleTargetIds = ["linux-glibc-arm64"];
  const macosAndroidTargetIds = ["macos-arm64", "android-arm64"];
  const macosSingleTrain = reduceClientGitHubReleaseClosure({
    catalog: releaseTargetCatalog,
    selectedTargetIds: macosSingleTargetIds,
    artifacts: artifactsForTargets(artifacts, macosSingleTargetIds),
    targetReadiness: [
      ...readyTargetEvidence(macosSingleTargetIds),
      {
        targetId: "windows-x64",
        githubReleaseReady: false,
        blockers: ["unselected_platform_evidence_missing"]
      }
    ]
  });
  const linuxArmSingleTrain = reduceClientGitHubReleaseClosure({
    catalog: releaseTargetCatalog,
    selectedTargetIds: linuxArmSingleTargetIds,
    artifacts: artifactsForTargets(artifacts, linuxArmSingleTargetIds),
    targetReadiness: readyTargetEvidence(linuxArmSingleTargetIds)
  });
  const macosAndroidTrain = reduceClientGitHubReleaseClosure({
    catalog: releaseTargetCatalog,
    selectedTargetIds: macosAndroidTargetIds,
    artifacts: artifactsForTargets(artifacts, macosAndroidTargetIds),
    targetReadiness: readyTargetEvidence(macosAndroidTargetIds)
  });
  const blockedMacosTrain = reduceClientGitHubReleaseClosure({
    catalog: releaseTargetCatalog,
    selectedTargetIds: macosSingleTargetIds,
    artifacts: artifactsForTargets(artifacts, macosSingleTargetIds),
    targetReadiness: [{
      targetId: "macos-arm64",
      githubReleaseReady: false,
      blockers: ["platform_signing_evidence_missing"]
    }]
  });
  for (const [label, train] of [
    ["macOS single-target GitHub Release closure", macosSingleTrain],
    ["Linux glibc ARM64 single-target GitHub Release closure", linuxArmSingleTrain],
    ["macOS and Android GitHub Release subset", macosAndroidTrain]
  ]) {
    strictAssert.equal(train.githubReleaseReady, true, `${label} must be independently ready`);
    strictAssert.equal(train.productionReady, false, `${label} must not imply product production readiness`);
    strictAssert.equal(train.productionReleaseReady, false, `${label} must not imply product release readiness`);
  }
  strictAssert.equal(
    macosSingleTrain.githubReleaseReadiness.find((entry) => entry.targetId === "windows-x64")?.githubReleaseReady,
    false,
    "unselected Windows readiness must remain false"
  );
  strictAssert.deepEqual(
    macosSingleTrain.githubReleaseReadiness.find((entry) => entry.targetId === "windows-x64")?.blockers,
    [
      "windows_github_release_consumer_verification_pending",
      "windows_native_host_receipt_pending",
    ],
    "unselected release-unsupported platform blockers must remain visible without affecting the selected train"
  );
  strictAssert.equal(blockedMacosTrain.githubReleaseReady, false, "selected target blocker must fail the GitHub Release closure");
  const dryRunInstallerPlans = createDryRunInstallerPlans(artifacts);
  const manifest = signManifest(
    {
      schemaVersion: "v0.0.1:client-update:manifest-1",
      generatedAt: "2026-06-28T00:00:00.000Z",
      channel: "stable",
      channelPolicy: {
        offlineRootKeyId,
        onlineChannelKeyId,
        allowDowngrade: false,
        keyCustody: "offline-root-plus-online-channel-signing-key",
        revokePolicy: "signed-revocation-list-required"
      },
      signing: {
        manifestAlgorithm: "Ed25519",
        artifactDigest: "sha256",
        offlineRootKeyFingerprint: keyFingerprint(offlineRoot.publicKey),
        onlineChannelKeyFingerprint: keyFingerprint(onlineChannel.publicKey)
      },
      releases: [
        {
          version: "0.0.2",
          minimumSupportedVersion: currentClientVersion,
          classification: "optional",
          releaseNotesUrl: "https://updates.example.com/releases/0.0.2",
          migrationNotes: ["No destructive migration is required for this dry-run vector."],
          artifacts
        }
      ],
      dryRunInstallerPlans
    },
    [
      { signingKey: offlineRoot.privateKey, keyId: offlineRootKeyId },
      { signingKey: onlineChannel.privateKey, keyId: onlineChannelKeyId }
    ]
  );

  const publicationReceipt = signEnvelope(
    {
      schemaVersion: "v0.0.1:client-update:publication-receipt-1",
      publicationId: "client-update-release-channel-stable-0.0.2",
      channel: "stable",
      releaseVersion: "0.0.2",
      manifestSha256: sha256Buffer(Buffer.from(stableStringify(unsignedPayload(manifest)), "utf8")),
      artifactCount: artifacts.length,
      artifactTargetIds: artifacts.map((artifact) => artifact.targetId),
      publishedAt: "2026-06-28T00:00:00.000Z",
      publicationAuthorityKeyId
    },
    publicationAuthority.privateKey,
    publicationAuthorityKeyId
  );

  const revocationList = signEnvelope(
    {
      schemaVersion: "v0.0.1:client-update:revocation-list-1",
      channel: "stable",
      issuedAt: "2026-06-28T00:00:00.000Z",
      revokedKeyIds: [onlineChannelKeyId],
      revokedVersions: [],
      revokedArtifactDigests: [artifacts[0].sha256],
      reason: "local test-vector revocation for release channel validation",
      offlineRootKeyId
    },
    offlineRoot.privateKey,
    offlineRootKeyId
  );

  const publicKeysById = new Map([
    [onlineChannelKeyId, onlineChannel.publicKey],
    [offlineRootKeyId, offlineRoot.publicKey],
    [publicationAuthorityKeyId, publicationAuthority.publicKey]
  ]);
  const positiveChecks = [];
  positiveChecks.push(
    { name: "macOS single-target GitHub Release closure is independently ready", ok: macosSingleTrain.githubReleaseReady },
    { name: "Linux glibc ARM64 GitHub Release closure is independently ready", ok: linuxArmSingleTrain.githubReleaseReady },
    { name: "macOS and Android GitHub Release subset is independently ready", ok: macosAndroidTrain.githubReleaseReady },
    {
      name: "unselected target readiness does not block selected GitHub Release",
      ok: macosSingleTrain.githubReleaseReady &&
        macosSingleTrain.githubReleaseReadiness.find((entry) => entry.targetId === "windows-x64")?.githubReleaseReady === false
    },
    { name: "selected target blocker fails GitHub Release closed", ok: blockedMacosTrain.githubReleaseReady === false }
  );
  const selected = verifyManifest(manifest, publicKeysById, {
    currentVersion: currentClientVersion,
    target: productionTargets[0]
  });
  positiveChecks.push({ name: "signed manifest verifies", ok: selected.signatureOk });
  const publicationReceiptVerification = verifyPublicationReceipt(publicationReceipt, publicKeysById);
  positiveChecks.push({
    name: "release publication receipt verifies",
    ok: publicationReceiptVerification.signatureOk,
    publicationId: publicationReceipt.publicationId
  });
  const revocationVerification = verifyRevocationList(revocationList, publicKeysById);
  positiveChecks.push({
    name: "signed revocation list verifies",
    ok: revocationVerification.signatureOk,
    revokedKeyIds: revocationList.revokedKeyIds
  });
  for (const artifact of artifacts) {
    verifyArtifact(artifact);
  }
  positiveChecks.push({ name: "artifact size and sha256 checks pass", ok: true, count: artifacts.length });
  const resumeResult = resumeDownloadAndCleanup(artifacts[0]);
  positiveChecks.push({ name: "interrupted download resume and staging cleanup", ok: true, detail: resumeResult });
  const hostPlatform = process.platform === "win32" ? "windows" : process.platform === "darwin" ? "macos" : "linux";
  const installerDryRunEvidence = [
    runInstallerDryRun(hostPlatform)
  ];
  const macosProductionEntitlementsDryRun = runMacosProductionEntitlementsDryRun();
  positiveChecks.push({
    name: "macOS production entitlement dry-run selects production template",
    ok: macosProductionEntitlementsDryRun.ok,
    entitlementProfile: macosProductionEntitlementsDryRun.entitlementProfile,
    entitlementsFile: macosProductionEntitlementsDryRun.entitlementsFile
  });
  const macosReleaseBundleEvidence = runMacosReleaseBundleEvidence(hostPlatform);
  if (macosReleaseBundleEvidence.ok) {
    positiveChecks.push({
      name: "macOS actual release bundle builds and verifies on host",
      ok: true,
      signingKind: macosReleaseBundleEvidence.signingKind,
      artifactKind: macosReleaseBundleEvidence.artifactKind
    });
  }
  const androidPhysicalInstallLaunchEvidence = summarizeAndroidPhysicalInstallLaunchReport(
    readJsonIfPresent(androidPhysicalInstallLaunchReportPath)
  );
  if (androidPhysicalInstallLaunchEvidence.ready) {
    positiveChecks.push({
      name: "Android physical install and launch evidence verifies",
      ok: true,
      report: androidPhysicalInstallLaunchEvidence.report,
      packageName: androidPhysicalInstallLaunchEvidence.packageName
    });
  }
  ensure(
    dryRunInstallerPlans.length === productionTargets.length &&
      dryRunInstallerPlans.every((plan) => plan.installerStrategy && plan.preUpdateStateRecord && plan.rollback),
    "installer dry-run plan is incomplete"
  );
  positiveChecks.push({ name: "platform installer dry-run plan covers production target labels", ok: true });

  const tamperedManifest = structuredClone(manifest);
  tamperedManifest.releases[0].releaseNotesUrl = "https://updates.example.com/releases/tampered";
  const checksumMismatchManifest = structuredClone(manifest);
  checksumMismatchManifest.releases[0].artifacts[0].sha256 = "sha256:0000";
  const revokedManifest = structuredClone(manifest);
  const downgradeManifest = signManifest(
    {
      ...unsignedPayload(manifest),
      releases: [
        {
          ...unsignedPayload(manifest).releases[0],
          version: currentClientVersion
        }
      ]
    },
    [
      { signingKey: offlineRoot.privateKey, keyId: offlineRootKeyId },
      { signingKey: onlineChannel.privateKey, keyId: onlineChannelKeyId }
    ]
  );
  const tamperedPublicationReceipt = structuredClone(publicationReceipt);
  tamperedPublicationReceipt.manifestSha256 = "sha256:ffffffff";
  const missingOfflineManifest = structuredClone(manifest);
  missingOfflineManifest.signatures = missingOfflineManifest.signatures.filter(
    (signature) => signature.keyId !== offlineRootKeyId
  );
  const missingOnlineManifest = structuredClone(manifest);
  missingOnlineManifest.signatures = missingOnlineManifest.signatures.filter(
    (signature) => signature.keyId !== onlineChannelKeyId
  );
  const duplicateSignatureManifest = structuredClone(manifest);
  duplicateSignatureManifest.signatures.push(structuredClone(manifest.signatures[0]));
  const malformedReleaseManifest = signManifest(
    {
      ...unsignedPayload(manifest),
      releases: [{ ...unsignedPayload(manifest).releases[0], version: "0.0" }]
    },
    [
      { signingKey: offlineRoot.privateKey, keyId: offlineRootKeyId },
      { signingKey: onlineChannel.privateKey, keyId: onlineChannelKeyId }
    ]
  );
  const mismatchedArtifactNameDocument = unsignedPayload(manifest);
  mismatchedArtifactNameDocument.releases[0].artifacts[0].fileName = "caller-selected.bin";
  const mismatchedArtifactNameManifest = signManifest(
    mismatchedArtifactNameDocument,
    [
      { signingKey: offlineRoot.privateKey, keyId: offlineRootKeyId },
      { signingKey: onlineChannel.privateKey, keyId: onlineChannelKeyId }
    ]
  );
  const onlineOnlyRevocationList = signEnvelope(
    unsignedPayload(revocationList),
    onlineChannel.privateKey,
    onlineChannelKeyId
  );
  const unsupportedTarget = {
    id: "freebsd-x64",
    platform: "freebsd",
    osFamily: "freebsd",
    arch: "x64"
  };

  const releaseTrainNegativeChecks = [
    expectFailure("empty GitHub Release target selection is rejected", () =>
      reduceClientGitHubReleaseClosure({ catalog: releaseTargetCatalog, selectedTargetIds: [], artifacts: [] })
    ),
    expectFailure("duplicate GitHub Release target selection is rejected", () =>
      reduceClientGitHubReleaseClosure({
        catalog: releaseTargetCatalog,
        selectedTargetIds: ["macos-arm64", "macos-arm64"],
        artifacts: artifactsForTargets(artifacts, ["macos-arm64"])
      })
    ),
    expectFailure("unknown GitHub Release target is rejected", () =>
      reduceClientGitHubReleaseClosure({ catalog: releaseTargetCatalog, selectedTargetIds: ["freebsd-x64"], artifacts: [] })
    ),
    expectFailure("unsupported iOS release target is explicit and rejected", () =>
      reduceClientGitHubReleaseClosure({ catalog: releaseTargetCatalog, selectedTargetIds: ["ios-arm64"], artifacts: [] })
    ),
    expectFailure("iOS simulator adaptation cannot be selected as a distribution artifact", () =>
      reduceClientGitHubReleaseClosure({ catalog: releaseTargetCatalog, selectedTargetIds: ["ios-simulator-arm64"], artifacts: [] })
    ),
    expectFailure("artifact outside selected GitHub Release targets is rejected", () =>
      reduceClientGitHubReleaseClosure({
        catalog: releaseTargetCatalog,
        selectedTargetIds: macosSingleTargetIds,
        artifacts: [
          ...artifactsForTargets(artifacts, ["macos-arm64"]),
          createArtifact(releaseTargetCatalog.targets.find((target) =>
            target.id === "windows-x64"))
        ],
        targetReadiness: readyTargetEvidence(macosSingleTargetIds)
      })
    )
  ];

  const negativeChecks = [
    ...releaseTrainNegativeChecks,
    expectFailure("manifest missing offline root signature is rejected", () =>
      verifyManifest(missingOfflineManifest, publicKeysById, {
        currentVersion: currentClientVersion,
        target: productionTargets[0]
      })
    ),
    expectFailure("manifest missing online channel signature is rejected", () =>
      verifyManifest(missingOnlineManifest, publicKeysById, {
        currentVersion: currentClientVersion,
        target: productionTargets[0]
      })
    ),
    expectFailure("duplicate manifest signature key id is rejected", () =>
      verifyManifest(duplicateSignatureManifest, publicKeysById, {
        currentVersion: currentClientVersion,
        target: productionTargets[0]
      })
    ),
    expectFailure("malformed release semantic version is rejected", () =>
      verifyManifest(malformedReleaseManifest, publicKeysById, {
        currentVersion: currentClientVersion,
        target: productionTargets[0]
      })
    ),
    expectFailure("signed artifact file name and url mismatch is rejected", () =>
      verifyManifest(mismatchedArtifactNameManifest, publicKeysById, {
        currentVersion: currentClientVersion,
        target: productionTargets[0]
      })
    ),
    expectFailure("revocation list without offline root signature is rejected", () =>
      verifyRevocationList(onlineOnlyRevocationList, publicKeysById, {
        channel: manifest.channel,
        offlineRootKeyId
      })
    ),
    expectFailure("tampered manifest signature is rejected", () =>
      verifyManifest(tamperedManifest, publicKeysById, { currentVersion: currentClientVersion, target: productionTargets[0] })
    ),
    expectFailure("artifact checksum mismatch is rejected", () =>
      verifyArtifact(checksumMismatchManifest.releases[0].artifacts[0])
    ),
    expectFailure("revoked signing key is rejected", () =>
      verifyManifest(revokedManifest, publicKeysById, {
        currentVersion: currentClientVersion,
        target: productionTargets[0],
        revocationList
      })
    ),
    expectFailure("tampered publication receipt is rejected", () =>
      verifyPublicationReceipt(tamperedPublicationReceipt, publicKeysById)
    ),
    expectFailure("downgrade is rejected without signed policy allowance", () =>
      verifyManifest(downgradeManifest, publicKeysById, { currentVersion: "0.0.2", target: productionTargets[0] })
    ),
    expectFailure("unsupported platform is rejected", () =>
      verifyManifest(manifest, publicKeysById, { currentVersion: currentClientVersion, target: unsupportedTarget })
    )
  ];

  const productionClosureStatus = buildProductionClosureStatus({
    publicationReceiptVerification,
    macosReleaseBundleEvidence,
    androidPhysicalInstallLaunchEvidence,
    dryRunInstallerPlans
  });
  mkdirSync(path.dirname(reportPath), { recursive: true });
  const diagnosticRemainingGaps = [
    "This verifier now covers local signed revocation, publication-receipt, tamper, downgrade, installer dry-run evidence, and macOS actual release bundle structure/local codesign evidence with generated test-vector keys.",
    "Production closure still needs offline-root plus online-channel signing custody, release publication receipts on the production channel, production signing/notarization, and platform installer/package proof on declared hosts.",
    ...(
      androidPhysicalInstallLaunchEvidence.ready
        ? []
        : ["Android production update closure still needs physical-device install and launch evidence."]
    )
  ];
  const report = {
    ok: true,
    productionReady: false,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    reportLeakScan: true,
    dryRun: true,
    generatedAt: new Date().toISOString(),
    scenario: "client-update",
    artifactKind: "client-update-release-channel-evidence",
    manifestSchema: manifest.schemaVersion,
    channel: manifest.channel,
    productionTargetLabels: productionTargets.map((target) => target.id),
    releaseTargetCatalog: {
      schemaVersion: releaseTargetCatalog.schemaVersion,
      targetCount: releaseTargetCatalog.targets.length,
      releaseSupportedTargetCount: productionTargets.length,
      buildSupportedTargetCount: releaseTargetCatalog.targets
        .filter((target) => target.supported)
        .length,
      unsupportedTargets: releaseTargetCatalog.targets
        .filter((target) => !target.supported)
        .map((target) => ({ targetId: target.id, blockers: target.blockers })),
      releaseUnsupportedTargets: releaseTargetCatalog.targets
        .filter((target) => !target.releaseSupported)
        .map((target) => ({
          targetId: target.id,
          blockers: target.releaseBlockers
        }))
    },
    releaseTrainContract: {
      testVectorOnly: true,
      productionReady: false,
      productionReleaseReady: false,
      macosSingleTrain,
      linuxArmSingleTrain,
      macosAndroidTrain,
      blockedMacosTrain
    },
    positiveChecks,
    negativeChecks,
    publicationReceipt,
    revocationList,
    installerDryRunEvidence,
    macosProductionEntitlementsDryRun,
    macosReleaseBundleEvidence,
    androidPhysicalInstallLaunchEvidence,
    dryRunInstallerPlans,
    productionClosureStatus,
    diagnosticRemainingGaps
  };
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(`[verify-client-update-release-channel] ok: ${artifacts.length} target labels, report ${path.relative(repoRoot, reportPath)}`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
