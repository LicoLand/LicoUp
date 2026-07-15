#!/usr/bin/env node
import { createHash, createPrivateKey, createPublicKey, sign } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  statSync,
  writeFileSync
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  sha256File as stableSha256File,
  stableReadFile,
} from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import { inspectLinuxTarGzipArchive } from "../../../tools/scripts/lib/linux-tar-resource-bounds.mjs";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const bundleRoot = path.join(workspaceRoot, "build", "apps", "desktop", "bundles", "linux", "release", "bundle");
const distributionRoot = path.join(workspaceRoot, "build", "apps", "desktop", "distribution", "linux-arm64");

function sha256(filePath) {
  return stableSha256File(filePath).slice("sha256:".length);
}

function requiredEnvironment(name) {
  const value = String(process.env[name] || "").trim();
  if (!value) throw new Error(`Linux ARM64 distribution requires protected CI environment field ${name}.`);
  return value;
}

function assertArm64Bundle() {
  if (process.platform !== "linux" || !["arm64", "aarch64"].includes(process.arch)) {
    throw new Error("Linux ARM64 release archives must be produced on a native Linux ARM64 runner.");
  }
  for (const fileName of ["flutter_client", "lico-client"]) {
    const filePath = path.join(bundleRoot, fileName);
    if (!existsSync(filePath) || !statSync(filePath).isFile()) {
      throw new Error(`Linux ARM64 bundle is missing ${fileName}.`);
    }
    const description = execFileSync("/usr/bin/file", ["-b", filePath], { encoding: "utf8" });
    if (!/(?:ARM aarch64|ARM64)/iu.test(description)) {
      throw new Error(`${fileName} is not an ARM64 executable.`);
    }
  }
}

function main() {
  assertArm64Bundle();
  const clientVersion = JSON.parse(stableReadFile(
    path.join(workspaceRoot, "tools", "client-version.json"),
    { maxBytes: 1024 * 1024 },
  ).toString("utf8"));
  if (!String(clientVersion.productVersion || "").trim() ||
    !Number.isInteger(clientVersion.buildNumber) || clientVersion.buildNumber <= 0) {
    throw new Error("Linux client version manifest is invalid.");
  }
  const manifestPath = path.join(bundleRoot, "package-metadata", "lico-client", "packaging-modules.json");
  const manifest = JSON.parse(stableReadFile(manifestPath, {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8"));
  if (manifest.schemaVersion !== "v0.0.1:client-desktop:bundle-manifest-2" ||
    manifest.platform !== "linux" || manifest.mode !== "release") {
    throw new Error("Linux bundle manifest is not a release manifest.");
  }
  if (!/^sha256:[a-f0-9]{64}$/u.test(String(manifest.sourceStateDigest || ""))) {
    throw new Error("Linux bundle manifest is missing its current-source digest binding.");
  }
  if (manifest.configPath !== "apps/desktop/packaging.modules.json" ||
    manifest.packagingConfigDigest !== stableSha256File(path.join(
      workspaceRoot,
      "apps/desktop/packaging.modules.json",
    ), { maxBytes: 2 * 1024 * 1024 })) {
    throw new Error("Linux bundle manifest is missing its canonical packaging policy binding.");
  }
  manifest.architecture = "arm64";
  manifest.productVersion = clientVersion.productVersion;
  manifest.buildNumber = clientVersion.buildNumber;
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  const bundleManifestDigest = sha256(manifestPath);

  mkdirSync(distributionRoot, { recursive: true });
  const archivePath = path.join(distributionRoot, "LicoArc-linux-arm64.tar.gz");
  execFileSync("/usr/bin/tar", ["-czf", archivePath, "-C", path.dirname(bundleRoot), path.basename(bundleRoot)], {
    stdio: "inherit"
  });
  inspectLinuxTarGzipArchive(archivePath);
  const digest = sha256(archivePath);
  writeFileSync(`${archivePath}.sha256`, `${digest}  ${path.basename(archivePath)}\n`, "utf8");
  const signingKeyPath = path.resolve(requiredEnvironment("LICO_LINUX_RELEASE_SIGNING_KEY_PATH"));
  const signingKeyId = requiredEnvironment("LICO_LINUX_RELEASE_SIGNING_KEY_ID");
  if (!existsSync(signingKeyPath)) {
    throw new Error("Linux ARM64 release signing key file is missing.");
  }
  const privateKey = createPrivateKey(stableReadFile(signingKeyPath, {
    maxBytes: 64 * 1024,
  }));
  if (privateKey.asymmetricKeyType !== "ed25519") {
    throw new Error("Linux ARM64 release signing key must be Ed25519.");
  }
  const publicKeyDer = createPublicKey(privateKey).export({
    type: "spki",
    format: "der",
  });
  const signature = sign(null, Buffer.from(digest, "hex"), privateKey).toString("base64");
  const publicKeyFingerprint = createHash("sha256")
    .update(publicKeyDer)
    .digest("hex");
  writeFileSync(`${archivePath}.sig`, `${signature}\n`, "utf8");
  if (sha256(archivePath) !== digest) {
    throw new Error("Linux ARM64 release archive changed while it was signed.");
  }
  writeFileSync(
    path.join(distributionRoot, "manifest.json"),
    `${JSON.stringify({
      schemaVersion: "v0.0.1:client-linux:distribution-1",
      targetId: "linux-glibc-arm64",
      platform: "linux",
      architecture: "arm64",
      mode: "release",
      artifactReady: true,
      nonBlockingDistributionGuidance: {
        channelRequested: false,
        platformChannelReady: false,
        githubReleaseBlocked: false
      },
      productVersion: clientVersion.productVersion,
      buildNumber: clientVersion.buildNumber,
      archive: path.basename(archivePath),
      sha256: digest,
      sourceStateDigest: manifest.sourceStateDigest,
      sourceStateDigestProvenance: manifest.sourceStateDigestProvenance || "git-worktree",
      bundleManifestDigest: `sha256:${bundleManifestDigest}`,
      signature: {
        algorithm: "Ed25519",
        payload: "archive-sha256-digest",
        keyId: signingKeyId,
        publicKeyFingerprint: `sha256:${publicKeyFingerprint}`,
        publicKeySpkiBase64: publicKeyDer.toString("base64"),
        file: `${path.basename(archivePath)}.sig`
      },
      files: readdirSync(bundleRoot).sort()
    }, null, 2)}\n`,
    "utf8"
  );
  console.log(`Linux ARM64 distribution archive ready: ${path.relative(workspaceRoot, archivePath)}`);
}

main();
