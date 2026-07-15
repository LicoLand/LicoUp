import { spawnSync } from "node:child_process";
import {
  closeSync,
  constants,
  existsSync,
  fstatSync,
  lstatSync,
  openSync,
  readSync,
  readdirSync,
} from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import process from "node:process";
import {
  resolveContainedExistingPath,
  sha256File,
  stableHashFileSnapshot,
  stableReadFile,
} from "./client-release-artifact-digest.mjs";
import { minimalReleaseToolEnvironment } from "./release-tool-environment.mjs";

export const ANDROID_APK_RESOURCE_LIMITS = Object.freeze({
  maxApkBytes: 1024 * 1024 * 1024,
  maxEntries: 50_000,
  maxCentralDirectoryBytes: 64 * 1024 * 1024,
  maxEntryMetadataBytes: 256 * 1024,
  maxPathBytes: 4 * 1024,
  maxEntryUncompressedBytes: 1024 * 1024 * 1024,
  maxTotalUncompressedBytes: 4 * 1024 * 1024 * 1024,
  maxNativeLibraryBytes: 256 * 1024 * 1024,
});
const MAX_APK_SIGNING_BLOCK_BYTES = 64 * 1024 * 1024;
const MAX_ANDROID_TOOL_BYTES = 1024 * 1024 * 1024;
const signerIdentityDigestByFacts = new WeakMap();

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function androidSdkRoot(repoRoot) {
  const configured = String(process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT || "").trim();
  if (configured) return configured;
  const propertiesPath = path.join(repoRoot, "apps/desktop/android/local.properties");
  if (!existsSync(propertiesPath)) return "";
  const sdkLine = stableReadFile(propertiesPath, { maxBytes: 1024 * 1024 })
    .toString("utf8")
    .split(/\r?\n/u)
    .find((line) => line.startsWith("sdk.dir="));
  return String(sdkLine || "")
    .slice("sdk.dir=".length)
    .trim()
    .replaceAll("\\\\", "\\")
    .replaceAll("\\:", ":");
}

function findBuildTool(repoRoot, name) {
  const sdkRoot = androidSdkRoot(repoRoot);
  const buildToolsRoot = sdkRoot ? path.join(sdkRoot, "build-tools") : "";
  requireValue(buildToolsRoot && existsSync(buildToolsRoot),
    "Android SDK build tools are unavailable");
  const suffix = process.platform === "win32" ? ".bat" : "";
  const versions = readdirSync(buildToolsRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort((left, right) => right.localeCompare(left, undefined, { numeric: true }));
  const tool = versions
    .map((version) => path.join(buildToolsRoot, version, `${name}${suffix}`))
    .find((candidate) => existsSync(candidate));
  requireValue(tool, `Android SDK ${name} is unavailable`);
  return resolveContainedExistingPath(buildToolsRoot, tool, { expectedKind: "file" });
}

function resolveAndroidAdbTool(repoRoot) {
  const sdkRoot = androidSdkRoot(repoRoot);
  requireValue(sdkRoot, "Android SDK platform tools are unavailable");
  const adbName = process.platform === "win32" ? "adb.exe" : "adb";
  return resolveContainedExistingPath(
    sdkRoot,
    path.join(sdkRoot, "platform-tools", adbName),
    { expectedKind: "file" },
  );
}

function androidJavaEnvironment(requireApprovedToolchain = false) {
  const approvedDarwinJavaHome =
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home";
  const candidates = (requireApprovedToolchain && process.platform === "darwin"
    ? [approvedDarwinJavaHome]
    : [
        process.env.JAVA_HOME,
        process.env.LICO_ANDROID_JAVA_HOME,
        process.platform === "darwin" ? approvedDarwinJavaHome : "",
      ])
    .map((value) => String(value || "").trim()).filter(Boolean);
  const javaHome = candidates.find((candidate) => {
    const javaPath = path.join(
      candidate,
      "bin",
      process.platform === "win32" ? "java.exe" : "java",
    );
    return existsSync(javaPath);
  });
  requireValue(javaHome, "Android APK verification Java runtime is unavailable");
  const javaPath = resolveContainedExistingPath(
    javaHome,
    path.join(javaHome, "bin", process.platform === "win32" ? "java.exe" : "java"),
    { expectedKind: "file" },
  );
  const systemPath = process.platform === "win32"
    ? process.env.PATH || ""
    : "/usr/bin:/bin";
  return {
    javaPath,
    env: minimalReleaseToolEnvironment(process.env, {
      JAVA_HOME: javaHome,
      PATH: `${path.dirname(javaPath)}${path.delimiter}${systemPath}`,
    }),
  };
}

function approvedAndroidToolchain(repoRoot, toolchain) {
  const manifestPath = resolveContainedExistingPath(
    path.join(repoRoot, "tools"),
    path.join(repoRoot, "tools/android-release-toolchain.json"),
    { expectedKind: "file" },
  );
  const manifest = JSON.parse(stableReadFile(manifestPath, {
    maxBytes: 1024 * 1024,
  }).toString("utf8"));
  const hostId = `${process.platform}-${process.arch}`;
  const approval = manifest?.schemaVersion ===
      "licolite.android-release-toolchain-allowlist.v1"
    ? manifest.platforms?.[hostId]
    : null;
  requireValue(approval &&
    approval.buildToolsVersion === path.basename(path.dirname(toolchain.aapt2)),
  "Android release toolchain is not approved for this host");
  const expectedNames = [
    "adb",
    "aapt2",
    "apksigner",
    "apksignerJar",
    "zipalign",
    "java",
  ];
  requireValue(JSON.stringify(Object.keys(approval.digests || {}).sort()) ===
    JSON.stringify([...expectedNames].sort()),
  "Android release toolchain digest allowlist is incomplete");
  for (const name of expectedNames) {
    const expected = String(approval.digests[name] || "");
    requireValue(/^sha256:[a-f0-9]{64}$/u.test(expected) &&
      stableHashFileSnapshot(toolchain[name], {
        maxBytes: MAX_ANDROID_TOOL_BYTES,
      }).digest === expected,
    "Android release toolchain digest is not approved");
  }
  return true;
}

function resolveAndroidToolchain(repoRoot, requireApprovedToolchain) {
  const aapt2 = findBuildTool(repoRoot, "aapt2");
  const apksigner = findBuildTool(repoRoot, "apksigner");
  const zipalign = findBuildTool(repoRoot, "zipalign");
  const java = androidJavaEnvironment(requireApprovedToolchain);
  const buildToolsDirectory = path.dirname(apksigner);
  const toolchain = {
    adb: resolveAndroidAdbTool(repoRoot),
    aapt2,
    apksigner,
    apksignerJar: resolveContainedExistingPath(
      buildToolsDirectory,
      path.join(buildToolsDirectory, "lib/apksigner.jar"),
      { expectedKind: "file" },
    ),
    zipalign,
    java: java.javaPath,
    env: java.env,
  };
  if (requireApprovedToolchain) approvedAndroidToolchain(repoRoot, toolchain);
  return toolchain;
}

export function findAndroidAdbTool(repoRoot, { requireApprovedToolchain = false } = {}) {
  return resolveAndroidToolchain(repoRoot, requireApprovedToolchain).adb;
}

function run(tool, args, repoRoot, env) {
  const result = spawnSync(tool, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 32 * 1024 * 1024,
    timeout: 30_000,
    env,
  });
  requireValue(result.status === 0, "Android APK fact extraction failed");
  return `${String(result.stdout || "")}\n${String(result.stderr || "")}`;
}

function normalizeApkLimits(limits = {}) {
  const merged = { ...ANDROID_APK_RESOURCE_LIMITS, ...limits };
  for (const [name, value] of Object.entries(merged)) {
    requireValue(Number.isSafeInteger(value) && value > 0,
      `Android APK resource limit is invalid: ${name}`);
  }
  requireValue(merged.maxNativeLibraryBytes <= merged.maxEntryUncompressedBytes &&
    merged.maxEntryUncompressedBytes <= merged.maxTotalUncompressedBytes,
  "Android APK resource limits are inconsistent");
  return Object.freeze(merged);
}

function requireZipPathSafe(name, isDirectory, limits) {
  requireValue(name && !name.includes("\\") && !name.includes("\0") &&
    !name.startsWith("/") && !/^[A-Za-z]:/u.test(name),
  "Android APK contains an unsafe ZIP path");
  const pathValue = isDirectory ? name.slice(0, -1) : name;
  requireValue(Buffer.byteLength(pathValue, "utf8") <= limits.maxPathBytes,
    "Android APK ZIP path exceeds its byte bound");
  const components = pathValue.split("/");
  requireValue(pathValue && components.every((component) =>
    component && component !== "." && component !== ".."),
  "Android APK contains an abnormal ZIP path");
}

function readExactly(descriptor, length, position, reason) {
  const buffer = Buffer.allocUnsafe(length);
  let offset = 0;
  while (offset < length) {
    const count = readSync(descriptor, buffer, offset, length - offset, position + offset);
    requireValue(count > 0, reason);
    offset += count;
  }
  return buffer;
}

function findEndOfCentralDirectory(descriptor, fileSize) {
  const tailSize = Math.min(fileSize, 65_557);
  const tailOffset = fileSize - tailSize;
  const tail = readExactly(
    descriptor,
    tailSize,
    tailOffset,
    "Android APK end-of-central-directory read was incomplete",
  );
  for (let index = tail.length - 22; index >= 0; index -= 1) {
    if (tail.readUInt32LE(index) !== 0x06054b50) continue;
    const commentLength = tail.readUInt16LE(index + 20);
    if (index + 22 + commentLength !== tail.length) continue;
    return { record: tail.subarray(index, index + 22), offset: tailOffset + index };
  }
  throw new Error("Android APK central directory is unavailable");
}

export function inspectAndroidApkZipFacts(apkPath, { limits: requestedLimits } = {}) {
  const limits = normalizeApkLimits(requestedLimits);
  const descriptor = openSync(
    apkPath,
    constants.O_RDONLY | (constants.O_NOFOLLOW || 0),
  );
  try {
    const before = fstatSync(descriptor, { bigint: true });
    requireValue(before.isFile() && before.size <= BigInt(limits.maxApkBytes),
      "Android APK is not a supported regular ZIP file");
    const fileSize = Number(before.size);
    const eocd = findEndOfCentralDirectory(descriptor, fileSize);
    const diskNumber = eocd.record.readUInt16LE(4);
    const centralDisk = eocd.record.readUInt16LE(6);
    const entriesOnDisk = eocd.record.readUInt16LE(8);
    const entryCount = eocd.record.readUInt16LE(10);
    const centralSize = eocd.record.readUInt32LE(12);
    const centralOffset = eocd.record.readUInt32LE(16);
    requireValue(diskNumber === 0 && centralDisk === 0 &&
      entriesOnDisk === entryCount && entryCount > 0 && entryCount < 0xffff &&
      entryCount <= limits.maxEntries &&
      centralSize !== 0xffffffff && centralOffset !== 0xffffffff &&
      centralSize <= limits.maxCentralDirectoryBytes &&
      centralOffset + centralSize === eocd.offset,
    "Android APK multi-disk or Zip64 layout is unsupported");
    const decoder = new TextDecoder("utf-8", { fatal: true });
    const names = new Set();
    const localHeaderOffsets = new Set();
    const targetPath = "lib/arm64-v8a/liblico_client_native.so";
    let targetEntry = null;
    let cursor = centralOffset;
    let totalUncompressedBytes = 0n;
    for (let index = 0; index < entryCount; index += 1) {
      const header = readExactly(
        descriptor,
        46,
        cursor,
        "Android APK central-directory header was incomplete",
      );
      requireValue(header.readUInt32LE(0) === 0x02014b50,
        "Android APK central-directory entry is invalid");
      const versionMadeBy = header.readUInt16LE(4);
      const flags = header.readUInt16LE(8);
      const compressionMethod = header.readUInt16LE(10);
      const crc32 = header.readUInt32LE(16);
      const compressedSize = header.readUInt32LE(20);
      const uncompressedSize = header.readUInt32LE(24);
      const nameLength = header.readUInt16LE(28);
      const extraLength = header.readUInt16LE(30);
      const commentLength = header.readUInt16LE(32);
      const startingDisk = header.readUInt16LE(34);
      const externalAttributes = header.readUInt32LE(38);
      const localHeaderOffset = header.readUInt32LE(42);
      requireValue(nameLength > 0 && startingDisk === 0 &&
        compressedSize !== 0xffffffff && uncompressedSize !== 0xffffffff &&
        localHeaderOffset !== 0xffffffff,
      "Android APK ZIP entry metadata is unsupported");
      requireValue(uncompressedSize <= limits.maxEntryUncompressedBytes,
        "Android APK ZIP entry exceeds its uncompressed byte bound");
      totalUncompressedBytes += BigInt(uncompressedSize);
      requireValue(totalUncompressedBytes <= BigInt(limits.maxTotalUncompressedBytes),
        "Android APK exceeds its total uncompressed byte bound");
      requireValue(!localHeaderOffsets.has(localHeaderOffset),
        "Android APK contains overlapping ZIP entry headers");
      localHeaderOffsets.add(localHeaderOffset);
      const variableLength = nameLength + extraLength + commentLength;
      requireValue(variableLength <= limits.maxEntryMetadataBytes &&
        nameLength <= limits.maxPathBytes,
      "Android APK ZIP entry metadata exceeds its byte bound");
      const variable = readExactly(
        descriptor,
        variableLength,
        cursor + 46,
        "Android APK central-directory metadata was incomplete",
      );
      let name;
      try {
        name = decoder.decode(variable.subarray(0, nameLength));
      } catch {
        throw new Error("Android APK contains a non-UTF-8 ZIP path");
      }
      const isDirectory = name.endsWith("/");
      requireZipPathSafe(name, isDirectory, limits);
      requireValue(!names.has(name), "Android APK contains a duplicate ZIP entry");
      names.add(name);
      if (name === targetPath) {
        requireValue(!isDirectory && targetEntry === null,
          "Android APK native secure-mesh library is not unique");
        const originSystem = versionMadeBy >>> 8;
        const unixMode = (externalAttributes >>> 16) & 0xffff;
        const fileType = unixMode & 0xf000;
        requireValue(originSystem !== 3 || fileType === 0x8000,
          "Android APK native secure-mesh library is not a regular file");
        requireValue((flags & 0x1) === 0 && (flags & 0x8) === 0 &&
          compressionMethod === 0 && compressedSize > 0 &&
          uncompressedSize === compressedSize &&
          uncompressedSize <= limits.maxNativeLibraryBytes,
        "Android APK native secure-mesh library must be a nonempty stored regular entry");
        targetEntry = {
          path: name,
          flags,
          compressionMethod,
          crc32,
          compressedSize,
          uncompressedSize,
          localHeaderOffset,
        };
      }
      cursor += 46 + variableLength;
      requireValue(cursor <= centralOffset + centralSize,
        "Android APK central directory escaped its declared bounds");
    }
    requireValue(cursor === centralOffset + centralSize && targetEntry !== null,
      "Android APK native secure-mesh library entry is missing");

    const localHeader = readExactly(
      descriptor,
      30,
      targetEntry.localHeaderOffset,
      "Android APK native library local header was incomplete",
    );
    requireValue(localHeader.readUInt32LE(0) === 0x04034b50,
      "Android APK native library local header is invalid");
    const localFlags = localHeader.readUInt16LE(6);
    const localMethod = localHeader.readUInt16LE(8);
    const localCrc32 = localHeader.readUInt32LE(14);
    const localCompressedSize = localHeader.readUInt32LE(18);
    const localUncompressedSize = localHeader.readUInt32LE(22);
    const localNameLength = localHeader.readUInt16LE(26);
    const localExtraLength = localHeader.readUInt16LE(28);
    const localName = decoder.decode(readExactly(
      descriptor,
      localNameLength,
      targetEntry.localHeaderOffset + 30,
      "Android APK native library local name was incomplete",
    ));
    requireValue(localName === targetEntry.path && localFlags === targetEntry.flags &&
      localMethod === targetEntry.compressionMethod &&
      localCrc32 === targetEntry.crc32 &&
      localCompressedSize === targetEntry.compressedSize &&
      localUncompressedSize === targetEntry.uncompressedSize,
    "Android APK native library local and central records disagree");
    const dataOffset = targetEntry.localHeaderOffset + 30 +
      localNameLength + localExtraLength;
    requireValue(dataOffset + targetEntry.compressedSize <= centralOffset,
      "Android APK native library data escaped its local-file bounds");
    const hash = createHash("sha256");
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    let remaining = targetEntry.compressedSize;
    let position = dataOffset;
    while (remaining > 0) {
      const requested = Math.min(remaining, buffer.length);
      const count = readSync(descriptor, buffer, 0, requested, position);
      requireValue(count > 0, "Android APK native library data was incomplete");
      hash.update(buffer.subarray(0, count));
      remaining -= count;
      position += count;
    }
    const after = fstatSync(descriptor, { bigint: true });
    const pathAfter = lstatSync(apkPath, { bigint: true, throwIfNoEntry: false });
    requireValue(before.dev === after.dev && before.ino === after.ino &&
      before.mode === after.mode && before.nlink === after.nlink &&
      before.uid === after.uid && before.gid === after.gid &&
      before.size === after.size && before.mtimeNs === after.mtimeNs &&
      before.ctimeNs === after.ctimeNs && pathAfter?.isFile() === true &&
      pathAfter.isSymbolicLink() === false && pathAfter.dev === after.dev &&
      pathAfter.ino === after.ino,
    "Android APK changed while its ZIP entries were inspected");
    return Object.freeze({
      path: targetEntry.path,
      contentDigest: `sha256:${hash.digest("hex")}`,
      size: targetEntry.uncompressedSize,
      compressedSize: targetEntry.compressedSize,
      crc32: targetEntry.crc32.toString(16).padStart(8, "0"),
      compression: "stored",
      regular: true,
      unique: true,
      zipEntryCount: entryCount,
    });
  } finally {
    closeSync(descriptor);
  }
}

function uint64Number(buffer, offset, label) {
  const value = buffer.readBigUInt64LE(offset);
  requireValue(value <= BigInt(Number.MAX_SAFE_INTEGER), label);
  return Number(value);
}

function lengthPrefixed32(buffer, offset, label) {
  requireValue(offset >= 0 && offset + 4 <= buffer.length, label);
  const length = buffer.readUInt32LE(offset);
  const start = offset + 4;
  const end = start + length;
  requireValue(end >= start && end <= buffer.length, label);
  return { bytes: buffer.subarray(start, end), next: end };
}

function apkSigningBlockLayout(descriptor, fileSize) {
  const eocd = findEndOfCentralDirectory(descriptor, fileSize);
  const centralOffset = eocd.record.readUInt32LE(16);
  requireValue(centralOffset !== 0xffffffff && centralOffset >= 24,
    "Android APK signing block is unavailable");
  const footer = readExactly(
    descriptor,
    24,
    centralOffset - 24,
    "Android APK signing block footer was incomplete",
  );
  const blockSizeWithoutHeader = uint64Number(
    footer,
    0,
    "Android APK signing block is too large",
  );
  requireValue(footer.subarray(8).equals(Buffer.from("APK Sig Block 42", "ascii")) &&
    blockSizeWithoutHeader >= 24 &&
    blockSizeWithoutHeader + 8 <= MAX_APK_SIGNING_BLOCK_BYTES &&
    blockSizeWithoutHeader + 8 <= centralOffset,
  "Android APK signing block is invalid");
  return {
    blockStart: centralOffset - blockSizeWithoutHeader - 8,
    blockSize: blockSizeWithoutHeader + 8,
    centralOffset,
  };
}

function updateHashRange(descriptor, hash, start, end) {
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  let position = start;
  while (position < end) {
    const requested = Math.min(buffer.length, end - position);
    const count = readSync(descriptor, buffer, 0, requested, position);
    requireValue(count > 0, "Android APK reproducible payload was incomplete");
    hash.update(buffer.subarray(0, count));
    position += count;
  }
}

export function androidApkReproduciblePayloadFacts(apkPath) {
  const descriptor = openSync(
    apkPath,
    constants.O_RDONLY | (constants.O_NOFOLLOW || 0),
  );
  try {
    const before = fstatSync(descriptor, { bigint: true });
    requireValue(before.isFile() && before.size <= BigInt(ANDROID_APK_RESOURCE_LIMITS.maxApkBytes),
      "Android APK is not a supported regular file");
    const fileSize = Number(before.size);
    const layout = apkSigningBlockLayout(descriptor, fileSize);
    const hash = createHash("sha256");
    hash.update("licolite.android.apk-reproducible-payload.v1\0", "utf8");
    hash.update(`${layout.blockStart}\0${fileSize - layout.centralOffset}\0`, "utf8");
    updateHashRange(descriptor, hash, 0, layout.blockStart);
    updateHashRange(descriptor, hash, layout.centralOffset, fileSize);
    const after = fstatSync(descriptor, { bigint: true });
    const pathAfter = lstatSync(apkPath, { bigint: true, throwIfNoEntry: false });
    requireValue(before.dev === after.dev && before.ino === after.ino &&
      before.size === after.size && before.mtimeNs === after.mtimeNs &&
      before.ctimeNs === after.ctimeNs && pathAfter?.isFile() === true &&
      pathAfter.isSymbolicLink() === false && pathAfter.dev === after.dev &&
      pathAfter.ino === after.ino,
    "Android APK changed while its reproducible payload was inspected");
    return Object.freeze({
      digest: `sha256:${hash.digest("hex")}`,
      signingBlockSize: layout.blockSize,
      unsignedPayloadBytes: layout.blockStart + fileSize - layout.centralOffset,
    });
  } finally {
    closeSync(descriptor);
  }
}

export function androidApkSigningCertificateKeyId(apkPath) {
  const descriptor = openSync(
    apkPath,
    constants.O_RDONLY | (constants.O_NOFOLLOW || 0),
  );
  try {
    const before = fstatSync(descriptor, { bigint: true });
    requireValue(before.isFile() && before.size <= BigInt(ANDROID_APK_RESOURCE_LIMITS.maxApkBytes),
      "Android APK is not a supported regular file");
    const fileSize = Number(before.size);
    const layout = apkSigningBlockLayout(descriptor, fileSize);
    const { blockStart, blockSize, centralOffset } = layout;
    const block = readExactly(
      descriptor,
      blockSize,
      blockStart,
      "Android APK signing block was incomplete",
    );
    const blockSizeWithoutHeader = blockSize - 8;
    requireValue(uint64Number(block, 0, "Android APK signing block is too large") ===
      blockSizeWithoutHeader,
    "Android APK signing block sizes disagree");
    const pairEnd = block.length - 24;
    let cursor = 8;
    let signerValue = null;
    let signerSchemeRank = -1;
    while (cursor < pairEnd) {
      requireValue(cursor + 8 <= pairEnd, "Android APK signing pair is incomplete");
      const pairSize = uint64Number(block, cursor, "Android APK signing pair is too large");
      requireValue(pairSize >= 4 && cursor + 8 + pairSize <= pairEnd,
        "Android APK signing pair is invalid");
      const id = block.readUInt32LE(cursor + 8);
      const rank = id === 0xf05368c0 ? 3 : (id === 0x7109871a ? 2 : -1);
      if (rank > signerSchemeRank) {
        signerSchemeRank = rank;
        signerValue = block.subarray(cursor + 12, cursor + 8 + pairSize);
      }
      cursor += 8 + pairSize;
    }
    requireValue(cursor === pairEnd && signerValue && signerSchemeRank >= 2,
      "Android APK v2 or v3 signer is unavailable");
    const signers = lengthPrefixed32(signerValue, 0,
      "Android APK signer sequence is invalid");
    requireValue(signers.next === signerValue.length,
      "Android APK signer sequence has trailing data");
    const signer = lengthPrefixed32(signers.bytes, 0,
      "Android APK signer is invalid");
    requireValue(signer.next === signers.bytes.length,
      "Android APK must contain exactly one signer");
    const signedData = lengthPrefixed32(signer.bytes, 0,
      "Android APK signed data is invalid");
    const digests = lengthPrefixed32(signedData.bytes, 0,
      "Android APK signed digests are invalid");
    const certificates = lengthPrefixed32(signedData.bytes, digests.next,
      "Android APK signer certificates are invalid");
    const certificate = lengthPrefixed32(certificates.bytes, 0,
      "Android APK signer certificate is invalid");
    requireValue(certificate.next === certificates.bytes.length && certificate.bytes.length > 0,
      "Android APK must contain exactly one signer certificate");
    const after = fstatSync(descriptor, { bigint: true });
    const pathAfter = lstatSync(apkPath, { bigint: true, throwIfNoEntry: false });
    requireValue(before.dev === after.dev && before.ino === after.ino &&
      before.size === after.size && before.mtimeNs === after.mtimeNs &&
      before.ctimeNs === after.ctimeNs && pathAfter?.isFile() === true &&
      pathAfter.isSymbolicLink() === false && pathAfter.dev === after.dev &&
      pathAfter.ino === after.ino,
    "Android APK changed while its signing certificate was inspected");
    return `sha256:${createHash("sha256").update(certificate.bytes).digest("hex")}`;
  } finally {
    closeSync(descriptor);
  }
}

export function inspectAndroidApkFacts(
  repoRoot,
  apkPath,
  { requireApprovedToolchain = false } = {},
) {
  const digestBefore = sha256File(apkPath, {
    maxBytes: ANDROID_APK_RESOURCE_LIMITS.maxApkBytes,
  });
  const nativeSecureMeshLibrary = inspectAndroidApkZipFacts(apkPath);
  const toolchain = resolveAndroidToolchain(repoRoot, requireApprovedToolchain);
  const { aapt2, apksigner, zipalign } = toolchain;
  const toolPaths = [
    aapt2,
    apksigner,
    toolchain.apksignerJar,
    zipalign,
    toolchain.java,
  ];
  const toolsBefore = toolPaths.map((tool) => stableHashFileSnapshot(tool, {
    maxBytes: MAX_ANDROID_TOOL_BYTES,
  }));
  const badging = run(aapt2, ["dump", "badging", apkPath], repoRoot, toolchain.env);
  const signature = run(
    apksigner,
    ["verify", "--verbose", "--print-certs", "--Werr", apkPath],
    repoRoot,
    toolchain.env,
  );
  run(zipalign, ["-c", "-P", "16", "-v", "4", apkPath], repoRoot, toolchain.env);
  const toolsAfter = toolPaths.map((tool) => stableHashFileSnapshot(tool, {
    maxBytes: MAX_ANDROID_TOOL_BYTES,
  }));
  requireValue(toolsBefore.every((before, index) =>
    before.digest === toolsAfter[index].digest &&
      before.device === toolsAfter[index].device &&
      before.inode === toolsAfter[index].inode),
  "Android APK verification toolchain changed during fact extraction");
  const digestAfter = sha256File(apkPath, {
    maxBytes: ANDROID_APK_RESOURCE_LIMITS.maxApkBytes,
  });
  requireValue(digestBefore === digestAfter, "Android APK changed during fact extraction");
  const packageMatch = badging.match(
    /package:\s+name='([^']+)'\s+versionCode='([^']+)'\s+versionName='([^']*)'/u,
  );
  requireValue(packageMatch, "Android APK package facts are unavailable");
  const signerCount = Number(signature.match(/Number of signers:\s*(\d+)/iu)?.[1] || 0);
  requireValue(signerCount === 1,
    "Android APK must contain exactly one signer");
  const signerDigests = [...signature.matchAll(
    /(?:Signer #\d+|V[1-4] Signer):\s*certificate SHA-256 digest:\s*([0-9a-f]{64})/giu,
  )].map((match) => match[1].toLowerCase());
  const uniqueSignerDigests = [...new Set(signerDigests)];
  requireValue(uniqueSignerDigests.length === 1,
    "Android APK must contain exactly one signing identity");
  const signerDigest = uniqueSignerDigests[0];
  requireValue(/^[a-f0-9]{64}$/u.test(signerDigest),
    "Android APK signer certificate digest is unavailable");
  const nativeCodeLine = badging.split(/\r?\n/u)
    .find((line) => line.startsWith("native-code:")) || "";
  const abis = [...nativeCodeLine.matchAll(/'([^']+)'/gu)]
    .map((match) => match[1])
    .sort();
  requireValue(abis.length > 0, "Android APK native ABI facts are unavailable");
  const launchableActivity = badging.match(
    /launchable-activity:\s+name='([^']+)'/u,
  )?.[1] || "";
  requireValue(launchableActivity, "Android APK launchable activity is unavailable");
  const versionCode = String(packageMatch[2]);
  requireValue(/^\d+$/u.test(versionCode) && BigInt(versionCode) > 0n,
    "Android APK versionCode is invalid");
  const signatureSchemes = [...signature.matchAll(
    /Verified using v([1-4]) scheme[^:]*:\s*(true|false)/giu,
  )].filter((match) => match[2].toLowerCase() === "true")
    .map((match) => `v${match[1]}`)
    .sort();
  requireValue(signatureSchemes.some((scheme) => ["v2", "v3", "v4"].includes(scheme)),
    "Android APK lacks a modern signature scheme");
  const facts = Object.freeze({
    artifactDigest: digestBefore,
    packageName: packageMatch[1],
    versionCode,
    versionName: packageMatch[3],
    debuggable: /(?:^|\n)application-debuggable(?:\r?\n|$)/u.test(badging),
    abis: Object.freeze(abis),
    launchableActivity,
    signerCount,
    signatureSchemes: Object.freeze(signatureSchemes),
    zipAligned: true,
    nativeSecureMeshLibrary,
  });
  signerIdentityDigestByFacts.set(facts, `sha256:${signerDigest}`);
  return facts;
}

export function assertAndroidApkFactsEqual(expected, actual) {
  return assertAndroidApkFactsMatch(expected, actual, true);
}

export function assertAndroidApkPayloadFactsEqual(expected, actual) {
  return assertAndroidApkFactsMatch(expected, actual, false);
}

function assertAndroidApkFactsMatch(expected, actual, compareArtifactDigest) {
  for (const field of [
    ...(compareArtifactDigest ? ["artifactDigest"] : []),
    "packageName",
    "versionCode",
    "versionName",
    "debuggable",
    "launchableActivity",
    "signerCount",
    "zipAligned",
  ]) {
    requireValue(expected?.[field] === actual?.[field],
      "Android APK installed facts do not match the source artifact");
  }
  requireValue(
    signerIdentityDigestByFacts.has(expected) &&
      signerIdentityDigestByFacts.get(expected) === signerIdentityDigestByFacts.get(actual),
    "Android APK installed signing identity does not match the source artifact",
  );
  requireValue(JSON.stringify(expected?.abis) === JSON.stringify(actual?.abis),
    "Android APK installed ABI facts do not match the source artifact");
  requireValue(JSON.stringify(expected?.signatureSchemes) ===
    JSON.stringify(actual?.signatureSchemes),
  "Android APK signature schemes do not match the source artifact");
  requireValue(JSON.stringify(expected?.nativeSecureMeshLibrary) ===
    JSON.stringify(actual?.nativeSecureMeshLibrary),
  "Android APK native secure-mesh library facts do not match the source artifact");
  return true;
}

export function androidApkSignerIdentityKeyId(facts) {
  const digest = signerIdentityDigestByFacts.get(facts);
  requireValue(/^sha256:[a-f0-9]{64}$/u.test(String(digest || "")),
    "Android APK signer certificate digest is unavailable");
  return digest;
}
