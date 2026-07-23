import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { ANDROID_APK_RESOURCE_LIMITS, MAX_APK_SIGNING_BLOCK_BYTES } from "./limits.mjs";
import { requireValue } from "./require.mjs";
import { findEndOfCentralDirectory, readExactly } from "./zip-facts.mjs";

export function uint64Number(buffer, offset, label) {
  const value = buffer.readBigUInt64LE(offset);
  requireValue(value <= BigInt(Number.MAX_SAFE_INTEGER), label);
  return Number(value);
}


export function lengthPrefixed32(buffer, offset, label) {
  requireValue(offset >= 0 && offset + 4 <= buffer.length, label);
  const length = buffer.readUInt32LE(offset);
  const start = offset + 4;
  const end = start + length;
  requireValue(end >= start && end <= buffer.length, label);
  return { bytes: buffer.subarray(start, end), next: end };
}


export function apkSigningBlockLayout(descriptor, fileSize) {
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


export function updateHashRange(descriptor, hash, start, end) {
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
    hash.update("licomesh.android.apk-reproducible-payload.v1\0", "utf8");
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
