#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { createHash, createPrivateKey, createPublicKey, verify } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  renameSync,
  rmSync,
  statSync
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import {
  classifyLinuxVmProducerFailure,
  createLinuxVmPackageFailureRecord,
  LinuxEvidenceValidationError,
  linuxEvidencePrivacyRecord,
  linuxVmReceiptWriteFailure,
  linuxVmPackageReceiptSchemaVersion,
  linuxVmPackageReceiptSchema,
  validateLinuxVmPackageReceipt
} from "./lib/secure-mesh-linux-evidence.mjs";
import {
  releaseClosureChallengeDigest,
  releaseInvocationNonceDigest,
  requiredReleaseClosureChallenge,
  requiredReleaseClosureStartedAt,
  requiredReleaseInvocationNonce,
} from "./lib/release-closure-challenge.mjs";
import {
  resolveContainedExistingPath,
  sha256File as stableSha256File,
  stableReadFile,
  stableSnapshotFile,
} from "./lib/client-release-artifact-digest.mjs";
import {
  atomicWriteReportJson,
  SafeReportWriteError,
} from "./lib/safe-report-io.mjs";
import { stopChildProcess } from "./lib/bounded-child-process.mjs";
import {
  inspectLinuxTarGzipArchive,
  LINUX_TAR_RESOURCE_LIMITS,
} from "./lib/linux-tar-resource-bounds.mjs";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

const options = parseArgs(process.argv.slice(2));
const workRoot = mkdtempSync(path.join(os.tmpdir(), "lico-linux-vm-package-receipt-"));
let verificationPhase = "input_validation";
let releaseContext;

try {
  const challenge = requiredReleaseClosureChallenge();
  const invocationNonce = requiredReleaseInvocationNonce();
  const closureStartedAt = requiredReleaseClosureStartedAt();
  releaseContext = Object.freeze({
    closureChallengeDigest: releaseClosureChallengeDigest(challenge),
    invocationNonceDigest: releaseInvocationNonceDigest(invocationNonce),
    closureStartedAtMs: closureStartedAt.milliseconds,
  });
  const report = await runReceipt();
  verificationPhase = "receipt_validation";
  validateLinuxVmPackageReceipt(
    report,
    options.expectedSourceDigest,
    report.productVersion,
    report.buildNumber,
  );
  verificationPhase = "receipt_write";
  writeReport(report);
  console.log(JSON.stringify({
    ok: true,
    artifactKind: report.artifactKind,
    currentSourceArchive: true,
    installReceiptReady: true,
    sessionLaunchReady: true,
    smokeReady: true,
    privacyReady: true
  }, null, 2));
} catch (error) {
  const failure = classifyLinuxVmProducerFailure(verificationPhase, error);
  const failureRecord = createLinuxVmPackageFailureRecord(verificationPhase, failure);
  try {
    writeFailureReceipt(failureRecord);
  } catch {
    // The canonical nonzero exit remains authoritative when even the blocked
    // receipt destination is unsafe or unavailable.
  }
  console.error(JSON.stringify({
    ok: false,
    artifactKind: "linux-vm-installed-client",
    reason: failureRecord.reason,
    phase: failureRecord.phase,
    validationRuleId: failureRecord.validationRuleId,
    failureCategory: failureRecord.failureCategory
  }, null, 2));
  process.exitCode = 1;
} finally {
  rmSync(workRoot, { recursive: true, force: true });
}

async function runReceipt() {
  assert(process.platform === "linux", "Linux VM package receipt requires Linux");
  assert(["arm64", "aarch64"].includes(process.arch), "Linux VM package receipt requires ARM64");
  const archive = requiredFile(options.archive, "Linux archive");
  const distributionManifestPath = requiredFile(
    options.distributionManifest,
    "Linux distribution manifest"
  );
  const signaturePath = requiredFile(`${archive}.sig`, "Linux archive signature");
  const validationKeyPath = requiredFile(
    process.env.LICO_LINUX_RELEASE_SIGNING_KEY_PATH,
    "Linux VM validation signing key"
  );
  const distribution = JSON.parse(stableReadFile(distributionManifestPath, {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8"));
  const versionManifestPath = resolveContainedExistingPath(
    repoRoot,
    path.join(repoRoot, "tools/client-version.json"),
    { expectedKind: "file" },
  );
  const versionManifest = JSON.parse(stableReadFile(versionManifestPath, {
    maxBytes: 1024 * 1024,
  }).toString("utf8"));
  assert(String(versionManifest.productVersion || "").trim() !== "" &&
    Number.isInteger(versionManifest.buildNumber) && versionManifest.buildNumber > 0,
  "Linux client version manifest is invalid");
  verificationPhase = "archive_binding";
  const stableArchive = stableSnapshotFile(
    archive,
    workRoot,
    "release-archive.tar.gz",
    { maxBytes: LINUX_TAR_RESOURCE_LIMITS.maxCompressedBytes },
  );
  const archiveDigest = stableSha256File(stableArchive);
  assert(distribution.targetId === "linux-glibc-arm64", "Linux distribution target is invalid");
  assert(distribution.archive === path.basename(archive), "Linux distribution archive binding is invalid");
  assert(distribution.sha256 === archiveDigest.slice("sha256:".length),
    "Linux distribution archive digest is invalid");
  assert(distribution.sourceStateDigest === options.expectedSourceDigest,
    "Linux archive source-state digest is stale");
  assert(distribution.productVersion === versionManifest.productVersion &&
    distribution.buildNumber === versionManifest.buildNumber,
  "Linux distribution version binding is invalid");
  assert(distribution.signature?.algorithm === "Ed25519" &&
    distribution.signature?.payload === "archive-sha256-digest" &&
    statSync(signaturePath).size > 0,
    "Linux archive signature is incomplete");
  assert(distribution.signature?.keyId === "linux-vm-acceptance",
    "Linux VM archive does not carry the validation-only signature marker");
  assert(distribution.signature?.file === path.basename(signaturePath),
    "Linux VM archive signature file binding is invalid");
  const privateKey = createPrivateKey(stableReadFile(validationKeyPath, {
    maxBytes: 64 * 1024,
  }));
  assert(privateKey.asymmetricKeyType === "ed25519",
    "Linux VM validation signing key is not Ed25519");
  const publicKey = createPublicKey(privateKey);
  const publicKeyDer = publicKey.export({ type: "spki", format: "der" });
  const publicKeyFingerprint = `sha256:${createHash("sha256")
    .update(publicKeyDer)
    .digest("hex")}`;
  const declaredPublicKeyDer = decodeCanonicalBase64(
    distribution.signature?.publicKeySpkiBase64,
    "Linux archive public verification key",
  );
  assert(declaredPublicKeyDer.equals(publicKeyDer),
    "Linux archive public verification key does not match the validation key");
  const signature = Buffer.from(stableReadFile(signaturePath, {
    maxBytes: 16 * 1024,
  }).toString("utf8").trim(), "base64");
  assert(signature.length === 64 && verify(
    null,
    Buffer.from(archiveDigest.slice("sha256:".length), "hex"),
    publicKey,
    signature,
  ),
    "Linux VM archive signature verification failed");
  assert(distribution.signature?.publicKeyFingerprint === publicKeyFingerprint,
    "Linux VM archive signature fingerprint is invalid");

  const archiveEntries = inspectLinuxTarGzipArchive(stableArchive).entries;
  verificationPhase = "archive_install";
  assert(archiveEntries.length > 0, "Linux archive is empty");
  assert(
    archiveEntries.every((entry) =>
      entry === "bundle" || entry.startsWith("bundle/") || entry === "bundle/"
    ),
    "Linux archive layout escaped the bundle root"
  );
  const extractRoot = path.join(workRoot, "extract");
  const installRoot = path.join(workRoot, "installed");
  mkdirSync(extractRoot, { recursive: true });
  mkdirSync(installRoot, { recursive: true });
  run("/usr/bin/tar", ["-xzf", stableArchive, "-C", extractRoot], {
    timeout: LINUX_TAR_RESOURCE_LIMITS.extractTimeoutMs,
  });
  const extractedBundle = path.join(extractRoot, "bundle");
  const installedBundle = path.join(installRoot, "client");
  assert(existsSync(extractedBundle), "Linux archive did not contain a bundle");
  renameSync(extractedBundle, installedBundle);

  const flutterClient = requiredFile(path.join(installedBundle, "flutter_client"),
    "installed Linux desktop executable");
  const nativeClient = requiredFile(path.join(installedBundle, "lico-client"),
    "installed Linux native sidecar");
  const bundleManifestPath = requiredFile(
    path.join(installedBundle, "package-metadata", "lico-client", "packaging-modules.json"),
    "installed Linux bundle manifest"
  );
  const bundleManifest = JSON.parse(stableReadFile(bundleManifestPath, {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8"));
  const bundleManifestDigest = sha256File(bundleManifestPath);
  const canonicalPackagingConfigDigest = stableSha256File(path.join(
    repoRoot,
    "apps/desktop/packaging.modules.json",
  ), { maxBytes: 2 * 1024 * 1024 });
  assert(bundleManifest.schemaVersion ===
    "v0.0.1:client-desktop:bundle-manifest-2" &&
    bundleManifest.platform === "linux" && bundleManifest.mode === "release",
    "Installed Linux bundle manifest target is invalid");
  assert(bundleManifest.architecture === "arm64", "Installed Linux bundle architecture is invalid");
  assert(bundleManifest.sourceStateDigest === options.expectedSourceDigest,
    "Installed Linux bundle source-state digest is stale");
  assert(bundleManifest.configPath === "apps/desktop/packaging.modules.json" &&
    bundleManifest.packagingConfigDigest === canonicalPackagingConfigDigest,
  "Installed Linux bundle packaging policy binding is invalid");
  assert(bundleManifest.productVersion === versionManifest.productVersion &&
    bundleManifest.buildNumber === versionManifest.buildNumber,
  "Installed Linux bundle version binding is invalid");
  assert(distribution.bundleManifestDigest === bundleManifestDigest,
    "Linux distribution bundle-manifest digest is invalid");
  assert(existsSync(path.join(installedBundle, "data", "flutter_assets")),
    "Installed Linux bundle is missing Flutter assets");
  assert(existsSync(path.join(installedBundle, "lib")),
    "Installed Linux bundle is missing runtime libraries");
  assertArm64Executable(flutterClient);
  assertArm64Executable(nativeClient);

  verificationPhase = "cli_smoke";
  const smokeState = path.join(workRoot, "smoke-state");
  mkdirSync(smokeState, { recursive: true });
  const targetScan = runJson(nativeClient, [
    "targets",
    "scan",
    "--include-accessible-environments",
    "false",
    "--include-history-model-catalog",
    "false",
  ], {
    ...process.env,
    LICO_PORTABLE_DIR: smokeState
  });
  assertTargetScan(targetScan);
  const secureMeshStatus = runJson(nativeClient, ["secure-mesh", "status"], {
    ...process.env,
    LICO_PORTABLE_DIR: smokeState
  });
  const capabilityReport = secureMeshStatus.capabilityReport;
  verificationPhase = "gui_session";
  const gui = await runGuiSession(flutterClient, installedBundle, smokeState);

  const sourceBinding = {
    sourceStateDigest: options.expectedSourceDigest,
    sourceStateDigestProvenance: String(
      bundleManifest.sourceStateDigestProvenance || distribution.sourceStateDigestProvenance || ""
    ),
    archiveDigest,
    bundleManifestDigest,
    nativeClientDigest: stableSha256File(nativeClient, { maxBytes: 512 * 1024 * 1024 }),
    stale: false
  };
  return {
    schema: linuxVmPackageReceiptSchema,
    schemaVersion: linuxVmPackageReceiptSchemaVersion,
    ok: true,
    producer: "linux-vm-package-receipt",
    generatedAt: new Date().toISOString(),
    closureChallengeDigest: releaseContext.closureChallengeDigest,
    invocationNonceDigest: releaseContext.invocationNonceDigest,
    productVersion: versionManifest.productVersion,
    buildNumber: versionManifest.buildNumber,
    artifactKind: "linux-vm-installed-client",
    target: "ubuntu-linux-arm64",
    redacted: true,
    reportLeakScan: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    sourceBinding,
    package: {
      format: "tar.gz",
      layoutClasses: [
        "desktop_executable",
        "native_sidecar",
        "flutter_assets",
        "package_metadata"
      ],
      executableCount: 2,
      signaturePresent: true,
      validationSignature: true,
      signatureVerified: true,
      archiveDigestVerified: true,
      bundleManifestDigestVerified: true,
      installedFromArchive: true
    },
    session: {
      kind: "x11_virtual_display",
      clientStarted: gui.clientStarted,
      visibleWindow: gui.visibleWindow,
      interactionSmoke: gui.interactionSmoke,
      boundedShutdown: gui.boundedShutdown
    },
    smoke: {
      cliTargetScan: true,
      guiSession: true,
      exactCapabilitySchema: true
    },
    capabilityReport,
    privacy: linuxEvidencePrivacyRecord(),
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      publicDownloadStatus: "not-configured",
      updateChannelStatus: "not-configured",
      rollbackChannelStatus: "not-configured",
    },
    summary: {
      currentSourceArchive: true,
      installReceiptReady: true,
      sessionLaunchReady: true,
      smokeReady: true,
      privacyReady: true
    }
  };
}

function assertArm64Executable(file) {
  const result = spawnSync("file", ["-b", file], { encoding: "utf8" });
  assert(result.status === 0 && /(?:ARM aarch64|ARM64)/iu.test(String(result.stdout || "")),
    "Installed Linux executable is not ARM64");
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    ...options
  });
  assert(result.status === 0, "Linux VM package command failed");
  return result;
}

function runJson(command, args, env) {
  const result = run(command, args, { env });
  try {
    return JSON.parse(String(result.stdout || ""));
  } catch {
    throw new Error("Linux VM package command returned invalid JSON");
  }
}

function assertTargetScan(scan) {
  assert(scan?.ok === true && Array.isArray(scan.candidates), "Linux CLI target scan failed");
  const targets = new Set(scan.candidates.map((candidate) => candidate?.target).filter(Boolean));
  for (const target of ["openclaw", "codex", "opencode"]) {
    assert(targets.has(target), "Linux CLI target scan omitted a required adapter");
  }
}

async function runGuiSession(flutterClient, installedBundle, portableRoot) {
  for (const tool of ["Xvfb", "xdotool"]) {
    const check = spawnSync("bash", ["-lc", `command -v ${tool}`], { encoding: "utf8" });
    assert(check.status === 0, "Linux GUI session tool is unavailable");
  }
  const display = `:${200 + (process.pid % 500)}`;
  const env = {
    ...process.env,
    DISPLAY: display,
    GDK_BACKEND: "x11",
    GDK_GL: "software",
    LIBGL_ALWAYS_SOFTWARE: "1",
    NO_AT_BRIDGE: "1",
    LICO_PORTABLE_DIR: portableRoot
  };
  const xvfb = spawn("Xvfb", [
    display,
    "-screen",
    "0",
    "1280x800x24",
    "-ac",
    "+extension",
    "GLX",
    "+render",
    "-noreset",
    "-nolisten",
    "tcp"
  ], { stdio: "ignore" });
  let app;
  let stderrBytes = 0;
  let stderrOverflow = false;
  try {
    verificationPhase = "gui_display";
    await waitFor(() => {
      assert(xvfb.exitCode === null, "Linux virtual display exited before readiness");
      const probe = spawnSync("xdotool", ["getdisplaygeometry"], {
        env,
        stdio: "ignore"
      });
      return probe.status === 0;
    }, 5_000, "virtual display readiness");
    verificationPhase = "gui_process";
    app = spawn(flutterClient, ["--enable-software-rendering"], {
      cwd: installedBundle,
      env,
      stdio: ["ignore", "ignore", "pipe"]
    });
    app.stderr.on("data", (chunk) => {
      stderrBytes = Math.min(64 * 1024 + 1, stderrBytes + Buffer.byteLength(chunk));
      if (stderrBytes > 64 * 1024) {
        stderrOverflow = true;
        app.kill("SIGTERM");
      }
    });
    verificationPhase = "gui_window";
    const windowId = await waitFor(() => {
      assert(app.exitCode === null, "Installed Linux desktop client exited before readiness");
      const search = spawnSync("xdotool", [
        "search",
        "--onlyvisible",
        "--pid",
        String(app.pid),
        "--name",
        ".*"
      ], {
        env,
        encoding: "utf8"
      });
      return search.status === 0
        ? String(search.stdout || "").trim().split(/\s+/u).find(Boolean) || ""
        : "";
    }, 30_000, "installed Linux desktop window");
    verificationPhase = "gui_interaction";
    const interaction = spawnSync("xdotool", ["key", "--window", windowId, "Tab"], {
      env,
      stdio: "ignore"
    });
    assert(interaction.status === 0 && app.exitCode === null,
      "Installed Linux desktop interaction smoke failed");
    verificationPhase = "gui_shutdown";
    const boundedShutdown = await stopChildProcess(app, { gracefulTimeoutMs: 5_000 });
    app = null;
    assert(boundedShutdown, "Installed Linux desktop client did not stop within the bound");
    verificationPhase = "gui_stderr";
    assert(stderrOverflow === false && stderrBytes <= 64 * 1024,
      "Installed Linux desktop stderr exceeded the bounded buffer");
    return {
      clientStarted: true,
      visibleWindow: true,
      interactionSmoke: true,
      boundedShutdown
    };
  } finally {
    if (app) await stopChildProcess(app, { gracefulTimeoutMs: 2_000 });
    await stopChildProcess(xvfb, { gracefulTimeoutMs: 2_000 });
  }
}

async function waitFor(probe, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = probe();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 125));
  }
  throw new Error(`${label} timed out`);
}

function sha256File(file) {
  return stableSha256File(file);
}

function requiredFile(value, label) {
  const resolved = path.resolve(String(value || ""));
  const info = value && existsSync(resolved)
    ? lstatSync(resolved, { throwIfNoEntry: false })
    : undefined;
  assert(info?.isFile() === true && info.isSymbolicLink() === false,
    `${label} is missing or unsafe`);
  return resolved;
}

function decodeCanonicalBase64(value, label) {
  const encoded = String(value || "").trim();
  assert(encoded.length > 0 && encoded.length <= 16 * 1024 &&
    /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(encoded),
  `${label} is not canonical base64`);
  const bytes = Buffer.from(encoded, "base64");
  assert(bytes.length > 0 && bytes.toString("base64") === encoded,
    `${label} is not canonical base64`);
  return bytes;
}

function writeReport(report) {
  let destination;
  try {
    destination = safeReportDestination();
  } catch {
    throw new LinuxEvidenceValidationError(
      "linux_vm_receipt_write_destination_invalid",
      "producer",
    );
  }
  try {
    JSON.stringify(report);
  } catch {
    throw new LinuxEvidenceValidationError(
      "linux_vm_receipt_write_payload_not_serializable",
      "producer",
    );
  }
  try {
    atomicWriteReportJson(destination.root, destination.ref, report);
  } catch (error) {
    if (error instanceof SafeReportWriteError) {
      throw linuxVmReceiptWriteFailure(error.stage);
    }
    throw new LinuxEvidenceValidationError(
      "linux_vm_receipt_write_atomic_publish_failed",
      "producer",
    );
  }
}

function writeFailureReceipt(failureRecord) {
  if (!options.report) return;
  const { root, ref } = safeReportDestination();
  atomicWriteReportJson(root, ref, failureRecord);
}

function safeReportDestination() {
  const rootValue = String(process.env.LICO_LINUX_VM_REPORT_ROOT || "").trim();
  assert(rootValue, "Linux VM report root is missing");
  const root = path.resolve(rootValue);
  const target = path.resolve(requiredOption("report"));
  const relative = path.relative(root, target);
  assert(relative && !relative.startsWith("..") && !path.isAbsolute(relative),
    "Linux VM report path escapes its allowed root");
  return { root, ref: relative };
}

function requiredOption(name) {
  const value = String(options[name] || "").trim();
  assert(value, `Linux VM package receipt requires --${name.replace(/[A-Z]/g, (letter) =>
    `-${letter.toLowerCase()}`)}`);
  return value;
}

function parseArgs(args) {
  const parsed = {};
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (!arg.startsWith("--")) throw new Error("Unknown Linux VM package receipt argument");
    const [rawKey, inline] = arg.slice(2).split("=", 2);
    const key = rawKey.replace(/-([a-z])/gu, (_, letter) => letter.toUpperCase());
    parsed[key] = inline ?? args[index + 1] ?? "";
    if (inline === undefined) index += 1;
  }
  requiredOptionFrom(parsed, "archive");
  requiredOptionFrom(parsed, "distributionManifest");
  requiredOptionFrom(parsed, "expectedSourceDigest");
  requiredOptionFrom(parsed, "report");
  assert(/^sha256:[a-f0-9]{64}$/u.test(parsed.expectedSourceDigest),
    "Linux VM package receipt source digest is invalid");
  return parsed;
}

function requiredOptionFrom(parsed, name) {
  if (!String(parsed[name] || "").trim()) {
    throw new Error("Linux VM package receipt option is missing");
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
