import { createHash } from "node:crypto";
import {
  closeSync,
  constants,
  existsSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  openSync,
  readSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  unlinkSync,
  writeSync,
} from "node:fs";
import path from "node:path";

export const DEFAULT_STABLE_READ_MAX_BYTES = 8 * 1024 * 1024;
export const CLIENT_RELEASE_ARTIFACT_TREE_LIMITS = Object.freeze({
  maxEntries: 200_000,
  maxFiles: 150_000,
  maxDirectories: 50_000,
  maxTotalFileBytes: 8 * 1024 * 1024 * 1024,
  maxFileBytes: 2 * 1024 * 1024 * 1024,
  maxPathBytes: 4 * 1024,
  maxSymlinkTargetBytes: 4 * 1024,
  maxDepth: 128,
});
const DEFAULT_STREAM_CHUNK_BYTES = 1024 * 1024;

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function normalizedDeadline(deadlineMs) {
  if (deadlineMs === undefined) return Number.POSITIVE_INFINITY;
  const value = Number(deadlineMs);
  requireValue((Number.isFinite(value) || value === Number.POSITIVE_INFINITY) && value > 0,
    "release artifact deadline is invalid");
  return value;
}

function requireBeforeDeadline(deadlineMs) {
  requireValue(Date.now() <= deadlineMs,
    "release artifact inspection deadline exceeded");
}

function canonicalJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function statIdentity(info) {
  return [
    info.dev,
    info.ino,
    info.mode,
    info.nlink,
    info.uid,
    info.gid,
    info.rdev,
    info.size,
    info.blksize,
    info.blocks,
    info.mtimeNs,
    info.ctimeNs,
    info.birthtimeNs,
  ].map(String).join(":");
}

function sameStableStat(before, after) {
  return statIdentity(before) === statIdentity(after);
}

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function stableLstat(filePath) {
  return lstatSync(filePath, { bigint: true, throwIfNoEntry: false });
}

export function sha256Buffer(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function stableOpenRead(filePath) {
  return openSync(filePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
}

function validateStableOpenedPath(filePath, descriptorInfo) {
  const pathAfter = stableLstat(filePath);
  requireValue(pathAfter?.isFile() === true &&
    pathAfter.isSymbolicLink() === false &&
    pathAfter.dev === descriptorInfo.dev && pathAfter.ino === descriptorInfo.ino,
  "release artifact file path changed while reading");
}

function validateChunkBytes(value) {
  const chunkBytes = Number(value || DEFAULT_STREAM_CHUNK_BYTES);
  requireValue(Number.isInteger(chunkBytes) && chunkBytes >= 4096 &&
    chunkBytes <= 16 * 1024 * 1024,
  "release artifact stream chunk size is invalid");
  return chunkBytes;
}

export function stableReadFileSnapshot(filePath, {
  afterOpen,
  maxBytes = DEFAULT_STABLE_READ_MAX_BYTES,
} = {}) {
  requireValue(Number.isInteger(maxBytes) && maxBytes >= 0,
    "stable file read maximum size is invalid");
  const descriptor = openSync(
    filePath,
    constants.O_RDONLY | (constants.O_NOFOLLOW || 0),
  );
  try {
    const before = fstatSync(descriptor, { bigint: true });
    requireValue(before.isFile(), "release artifact path is not a regular file");
    requireValue(before.size <= BigInt(maxBytes),
      "stable file read exceeds its maximum size");
    if (typeof afterOpen === "function") afterOpen(filePath);
    const expectedSize = Number(before.size);
    const bytes = Buffer.allocUnsafe(expectedSize);
    let offset = 0;
    while (offset < expectedSize) {
      const count = readSync(descriptor, bytes, offset, expectedSize - offset, null);
      if (count === 0) break;
      offset += count;
    }
    const after = fstatSync(descriptor, { bigint: true });
    requireValue(sameStableStat(before, after), "release artifact file changed while reading");
    requireValue(offset === expectedSize, "release artifact file read was incomplete");
    validateStableOpenedPath(filePath, after);
    return Object.freeze({
      bytes,
      mtimeMs: Number(after.mtimeMs),
      size: Number(after.size),
      device: String(after.dev),
      inode: String(after.ino),
    });
  } finally {
    closeSync(descriptor);
  }
}

export function stableReadFile(filePath, options = {}) {
  return stableReadFileSnapshot(filePath, options).bytes;
}

export function stableHashFileSnapshot(filePath, {
  afterOpen,
  chunkBytes: requestedChunkBytes,
  maxBytes: requestedMaxBytes,
  deadlineMs: requestedDeadlineMs,
} = {}) {
  const chunkBytes = validateChunkBytes(requestedChunkBytes);
  const maxBytes = requestedMaxBytes === undefined
    ? Number.MAX_SAFE_INTEGER
    : Number(requestedMaxBytes);
  requireValue(Number.isSafeInteger(maxBytes) && maxBytes >= 0,
    "release artifact hash byte bound is invalid");
  const deadlineMs = normalizedDeadline(requestedDeadlineMs);
  requireBeforeDeadline(deadlineMs);
  const descriptor = stableOpenRead(filePath);
  try {
    const before = fstatSync(descriptor, { bigint: true });
    requireValue(before.isFile(), "release artifact path is not a regular file");
    requireValue(before.size <= BigInt(maxBytes),
      "release artifact file exceeds its hash byte bound");
    if (typeof afterOpen === "function") afterOpen(filePath);
    const hash = createHash("sha256");
    const buffer = Buffer.allocUnsafe(chunkBytes);
    let remaining = before.size;
    let bytesRead = 0n;
    while (remaining > 0n) {
      requireBeforeDeadline(deadlineMs);
      const requested = Number(remaining > BigInt(chunkBytes)
        ? BigInt(chunkBytes)
        : remaining);
      const count = readSync(descriptor, buffer, 0, requested, null);
      requireValue(count > 0, "release artifact file hash was incomplete");
      hash.update(buffer.subarray(0, count));
      bytesRead += BigInt(count);
      remaining -= BigInt(count);
    }
    const after = fstatSync(descriptor, { bigint: true });
    requireValue(bytesRead === before.size && sameStableStat(before, after),
      "release artifact file changed while hashing");
    validateStableOpenedPath(filePath, after);
    return Object.freeze({
      digest: `sha256:${hash.digest("hex")}`,
      size: Number(after.size),
      mtimeMs: Number(after.mtimeMs),
      device: String(after.dev),
      inode: String(after.ino),
    });
  } finally {
    closeSync(descriptor);
  }
}

export function sha256File(filePath, options = {}) {
  return stableHashFileSnapshot(filePath, options).digest;
}

export function stableSnapshotFile(
  sourcePath,
  snapshotDirectory,
  snapshotName,
  { maxBytes: requestedMaxBytes } = {},
) {
  const maxBytes = requestedMaxBytes === undefined
    ? Number.MAX_SAFE_INTEGER
    : Number(requestedMaxBytes);
  requireValue(Number.isSafeInteger(maxBytes) && maxBytes >= 0,
    "stable snapshot byte bound is invalid");
  const directory = path.resolve(snapshotDirectory);
  const directoryInfo = stableLstat(directory);
  requireValue(directoryInfo?.isDirectory() === true &&
    directoryInfo.isSymbolicLink() === false,
  "stable snapshot directory is not safe");
  const target = path.resolve(directory, String(snapshotName || ""));
  requireValue(path.dirname(target) === directory && path.basename(target) === snapshotName,
    "stable snapshot name is invalid");
  requireValue(!existsSync(target), "stable snapshot target already exists");
  const sourceDescriptor = stableOpenRead(sourcePath);
  let targetDescriptor;
  try {
    const sourceBefore = fstatSync(sourceDescriptor, { bigint: true });
    requireValue(sourceBefore.isFile() &&
      sourceBefore.size <= BigInt(maxBytes),
    "stable snapshot source is not a supported regular file");
    targetDescriptor = openSync(
      target,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL |
        (constants.O_NOFOLLOW || 0),
      0o600,
    );
    const buffer = Buffer.allocUnsafe(DEFAULT_STREAM_CHUNK_BYTES);
    const sourceHash = createHash("sha256");
    let remaining = sourceBefore.size;
    while (remaining > 0n) {
      const requested = Number(remaining > BigInt(buffer.length)
        ? BigInt(buffer.length)
        : remaining);
      const count = readSync(sourceDescriptor, buffer, 0, requested, null);
      requireValue(count > 0, "stable snapshot source read was incomplete");
      sourceHash.update(buffer.subarray(0, count));
      let written = 0;
      while (written < count) {
        const writeCount = writeSync(
          targetDescriptor,
          buffer,
          written,
          count - written,
          null,
        );
        requireValue(writeCount > 0, "stable snapshot target write was incomplete");
        written += writeCount;
      }
      remaining -= BigInt(count);
    }
    fsyncSync(targetDescriptor);
    const targetBeforeClose = fstatSync(targetDescriptor, { bigint: true });
    requireValue(targetBeforeClose.isFile() && targetBeforeClose.size === sourceBefore.size,
      "stable snapshot target size is invalid");
    closeSync(targetDescriptor);
    targetDescriptor = undefined;
    const sourceAfter = fstatSync(sourceDescriptor, { bigint: true });
    requireValue(sameStableStat(sourceBefore, sourceAfter),
      "stable snapshot source changed while copying");
    validateStableOpenedPath(sourcePath, sourceAfter);
    const sourceDigest = `sha256:${sourceHash.digest("hex")}`;
    requireValue(sha256File(target, { maxBytes }) === sourceDigest,
      "stable snapshot does not match its source");
    const directoryAfter = stableLstat(directory);
    requireValue(directoryAfter?.isDirectory() === true &&
      directoryAfter.isSymbolicLink() === false &&
      directoryAfter.dev === directoryInfo.dev && directoryAfter.ino === directoryInfo.ino,
    "stable snapshot directory changed while copying");
    return target;
  } catch (error) {
    if (targetDescriptor !== undefined) closeSync(targetDescriptor);
    if (existsSync(target)) {
      const targetInfo = stableLstat(target);
      if (targetInfo?.isFile() === true && targetInfo.isSymbolicLink() === false) {
        unlinkSync(target);
      }
    }
    throw error;
  } finally {
    closeSync(sourceDescriptor);
  }
}

export function resolveContainedExistingPath(allowedRoot, candidatePath, {
  expectedKind = "any",
} = {}) {
  const rootPath = path.resolve(allowedRoot);
  const rootInfo = stableLstat(rootPath);
  requireValue(rootInfo?.isDirectory() === true && rootInfo.isSymbolicLink() === false,
    "allowed path root is not a stable directory");
  const rootReal = realpathSync(rootPath);
  const candidate = path.resolve(candidatePath);
  requireValue(isWithin(rootPath, candidate), "path escapes its allowed root");
  const relative = path.relative(rootPath, candidate);
  let current = rootPath;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const info = stableLstat(current);
    requireValue(info !== undefined, "required contained path is missing");
    requireValue(info.isSymbolicLink() === false, "contained path traverses a symbolic link");
  }
  const candidateReal = realpathSync(candidate);
  requireValue(isWithin(rootReal, candidateReal), "contained path resolves outside its allowed root");
  const finalInfo = stableLstat(candidate);
  requireValue(finalInfo !== undefined && finalInfo.isSymbolicLink() === false,
    "contained path is not stable");
  if (expectedKind === "file") {
    requireValue(finalInfo.isFile(), "contained path is not a regular file");
  } else if (expectedKind === "directory") {
    requireValue(finalInfo.isDirectory(), "contained path is not a directory");
  }
  return candidateReal;
}

function normalizeTreeLimits(limits = {}) {
  const merged = { ...CLIENT_RELEASE_ARTIFACT_TREE_LIMITS, ...limits };
  for (const [name, value] of Object.entries(merged)) {
    requireValue(Number.isSafeInteger(value) && value > 0,
      `release artifact tree limit is invalid: ${name}`);
  }
  requireValue(merged.maxFiles <= merged.maxEntries &&
    merged.maxDirectories <= merged.maxEntries &&
    merged.maxFileBytes <= merged.maxTotalFileBytes,
  "release artifact tree limits are inconsistent");
  return Object.freeze(merged);
}

function treeEntryMetadata(info, expectedUid, relative, limits) {
  const pathBytes = Buffer.byteLength(relative || ".", "utf8");
  const depth = relative ? relative.split("/").length : 0;
  const mode = Number(info.mode & 0o7777n);
  requireValue(pathBytes <= limits.maxPathBytes,
    "release artifact entry path exceeds its byte bound");
  requireValue(depth <= limits.maxDepth,
    "release artifact entry exceeds its depth bound");
  requireValue(Number(info.uid) === expectedUid,
    "release artifact entry is not owned by the release user");
  requireValue((mode & 0o7000) === 0,
    "release artifact entry uses privileged permission bits");
  if (!info.isSymbolicLink()) {
    requireValue((mode & 0o022) === 0,
      "release artifact entry is group- or world-writable");
  }
  return {
    mode: mode.toString(8).padStart(4, "0"),
    owner: Number(info.uid),
    group: Number(info.gid),
    depth,
  };
}

export function artifactTreeDigest(artifactPath, {
  onDirectoryRead,
  limits: requestedLimits,
  expectedUid: requestedExpectedUid,
  deadlineMs: requestedDeadlineMs,
} = {}) {
  return artifactTreeSnapshot(artifactPath, {
    onDirectoryRead,
    limits: requestedLimits,
    expectedUid: requestedExpectedUid,
    deadlineMs: requestedDeadlineMs,
  }).digest;
}

export function artifactTreeContentDigest(artifactPath, {
  onDirectoryRead,
  limits: requestedLimits,
  expectedUid: requestedExpectedUid,
  deadlineMs: requestedDeadlineMs,
  allowExternalHardlinks = false,
} = {}) {
  const snapshot = artifactTreeSnapshot(artifactPath, {
    onDirectoryRead,
    limits: requestedLimits,
    expectedUid: requestedExpectedUid,
    deadlineMs: requestedDeadlineMs,
    allowExternalHardlinks,
  });
  const contentRecords = snapshot.entries.map((entry) => {
    if (entry.kind === "file") {
      return {
        kind: entry.kind,
        path: entry.path,
        size: entry.size,
        digest: entry.digest,
      };
    }
    if (entry.kind === "symlink") {
      return { kind: entry.kind, path: entry.path, target: entry.target };
    }
    return { kind: entry.kind, path: entry.path };
  });
  return sha256Buffer(Buffer.from(canonicalJson(contentRecords), "utf8"));
}

export function artifactTreeSnapshot(artifactPath, {
  onDirectoryRead,
  limits: requestedLimits,
  expectedUid: requestedExpectedUid,
  deadlineMs: requestedDeadlineMs,
  allowExternalHardlinks = false,
} = {}) {
  const deadlineMs = normalizedDeadline(requestedDeadlineMs);
  requireBeforeDeadline(deadlineMs);
  const top = stableLstat(artifactPath);
  requireValue(top !== undefined && top.isDirectory(), "release artifact root is not a directory");
  requireValue(top.isSymbolicLink() === false, "release artifact root must not be a symbolic link");
  const root = realpathSync(artifactPath);
  const records = [];
  const limits = normalizeTreeLimits(requestedLimits);
  const expectedUid = requestedExpectedUid === undefined
    ? (typeof process.geteuid === "function" ? process.geteuid() : Number(top.uid))
    : Number(requestedExpectedUid);
  requireValue(Number.isSafeInteger(expectedUid) && expectedUid >= 0,
    "release artifact expected owner is invalid");
  let entryCount = 0;
  let fileCount = 0;
  let directoryCount = 0;
  let totalFileBytes = 0n;
  const hardlinkGroups = new Map();

  function visit(current, relative) {
    requireBeforeDeadline(deadlineMs);
    const infoBefore = stableLstat(current);
    requireValue(infoBefore !== undefined, "release artifact entry disappeared");
    entryCount += 1;
    requireValue(entryCount <= limits.maxEntries,
      "release artifact tree exceeds its entry-count bound");
    const metadata = treeEntryMetadata(infoBefore, expectedUid, relative, limits);
    if (infoBefore.isSymbolicLink()) {
      requireValue(relative !== "", "release artifact root must not be a symbolic link");
      const targetBefore = readlinkSync(current);
      requireValue(Buffer.byteLength(targetBefore, "utf8") <=
        limits.maxSymlinkTargetBytes,
      "release artifact symlink target exceeds its byte bound");
      requireValue(infoBefore.nlink === 1n,
        "release artifact symlink has unsupported hard links");
      requireValue(!path.isAbsolute(targetBefore), "release artifact contains an absolute symlink");
      const resolvedTargetBefore = realpathSync(current);
      requireValue(isWithin(root, resolvedTargetBefore),
        "release artifact symlink resolves outside the artifact root");
      const targetAfter = readlinkSync(current);
      const infoAfter = stableLstat(current);
      const resolvedTargetAfter = realpathSync(current);
      requireValue(infoAfter?.isSymbolicLink() === true && targetBefore === targetAfter &&
        sameStableStat(infoBefore, infoAfter) && resolvedTargetBefore === resolvedTargetAfter,
      "release artifact symlink changed while reading");
      records.push({
        kind: "symlink",
        path: relative,
        target: targetBefore,
        ...metadata,
      });
      return;
    }
    if (infoBefore.isDirectory()) {
      directoryCount += 1;
      requireValue(directoryCount <= limits.maxDirectories,
        "release artifact tree exceeds its directory-count bound");
      const namesBefore = readdirSync(current).sort();
      if (typeof onDirectoryRead === "function") onDirectoryRead(current, relative);
      for (const name of namesBefore) {
        visit(path.join(current, name), relative ? `${relative}/${name}` : name);
      }
      const namesAfter = readdirSync(current).sort();
      const infoAfter = stableLstat(current);
      requireValue(infoAfter?.isDirectory() === true &&
        sameStableStat(infoBefore, infoAfter) &&
        JSON.stringify(namesBefore) === JSON.stringify(namesAfter),
      "release artifact directory changed while reading");
      records.push({
        kind: "directory",
        path: relative,
        childCount: namesBefore.length,
        ...metadata,
      });
      return;
    }
    requireValue(infoBefore.isFile(), "release artifact contains an unsupported filesystem entry");
    fileCount += 1;
    requireValue(fileCount <= limits.maxFiles,
      "release artifact tree exceeds its file-count bound");
    requireValue(infoBefore.size <= BigInt(limits.maxFileBytes),
      "release artifact file exceeds its byte bound");
    totalFileBytes += infoBefore.size;
    requireValue(totalFileBytes <= BigInt(limits.maxTotalFileBytes),
      "release artifact tree exceeds its total file-byte bound");
    const snapshot = stableHashFileSnapshot(current, {
      maxBytes: limits.maxFileBytes,
      deadlineMs,
    });
    const infoAfter = stableLstat(current);
    requireValue(infoAfter?.isFile() === true && sameStableStat(infoBefore, infoAfter),
      "release artifact file changed during tree hashing");
    const inodeKey = `${infoBefore.dev}:${infoBefore.ino}`;
    const hardlinkGroup = hardlinkGroups.get(inodeKey) || {
      firstPath: relative,
      expectedLinks: Number(infoBefore.nlink),
      observedLinks: 0,
    };
    requireValue(hardlinkGroup.expectedLinks === Number(infoBefore.nlink),
      "release artifact hard-link metadata changed");
    hardlinkGroup.observedLinks += 1;
    hardlinkGroups.set(inodeKey, hardlinkGroup);
    records.push({
      kind: "file",
      path: relative,
      size: snapshot.size,
      digest: snapshot.digest,
      hardlinkGroup: hardlinkGroup.firstPath,
      linkCount: Number(infoBefore.nlink),
      ...metadata,
    });
  }

  visit(root, "");
  const topAfter = stableLstat(artifactPath);
  requireValue(topAfter?.isDirectory() === true && topAfter.isSymbolicLink() === false &&
    sameStableStat(top, topAfter), "release artifact root changed while hashing");
  if (!allowExternalHardlinks) {
    for (const group of hardlinkGroups.values()) {
      requireValue(group.expectedLinks === group.observedLinks,
        "release artifact file has a hard link outside the artifact tree");
    }
  }
  return Object.freeze({
    digest: sha256Buffer(Buffer.from(canonicalJson(records), "utf8")),
    root,
    limits,
    deadlineMs,
    metrics: Object.freeze({
      entryCount,
      fileCount,
      directoryCount,
      totalFileBytes: Number(totalFileBytes),
    }),
    entries: Object.freeze(records.map((record) => Object.freeze({ ...record }))),
  });
}
