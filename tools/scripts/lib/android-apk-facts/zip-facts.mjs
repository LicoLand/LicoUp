import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { ANDROID_APK_RESOURCE_LIMITS } from "./limits.mjs";
import { requireValue } from "./require.mjs";

export function normalizeApkLimits(limits = {}) {
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


export function requireZipPathSafe(name, isDirectory, limits) {
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


export function readExactly(descriptor, length, position, reason) {
  const buffer = Buffer.allocUnsafe(length);
  let offset = 0;
  while (offset < length) {
    const count = readSync(descriptor, buffer, offset, length - offset, position + offset);
    requireValue(count > 0, reason);
    offset += count;
  }
  return buffer;
}


export function findEndOfCentralDirectory(descriptor, fileSize) {
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
