import fs from "node:fs";
import path from "node:path";

export const MAX_JSON_BYTES = 16 * 1024 * 1024;

export function ensureDirectorySync(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true, mode: 0o700 });
  }
}

export function writeJsonAtomicSync(filePath, value, mode = 0o600) {
  const dir = path.dirname(filePath);
  ensureDirectorySync(dir);
  const serialized = JSON.stringify(value, null, 2) + "\n";
  if (Buffer.byteLength(serialized, "utf8") > MAX_JSON_BYTES) {
    throw new Error(`Payload exceeds maximum JSON bytes (${MAX_JSON_BYTES}): ${filePath}`);
  }
  const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  // Write, flush, then rename. The rename is atomic, so a reader sees the old
  // document or the new one; the fsync before it is what keeps a crash from
  // leaving the new name over bytes that never reached the disk.
  const descriptor = fs.openSync(tempPath, "wx", mode);
  try {
    fs.writeFileSync(descriptor, serialized, "utf8");
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.renameSync(tempPath, filePath);
  // Best effort: the directory entry itself. Not every platform permits a
  // directory fsync, and failing to flush it does not undo the atomic rename —
  // it only means the entry's power-loss durability is not claimed.
  try {
    const directory = fs.openSync(dir, "r");
    try {
      fs.fsyncSync(directory);
    } finally {
      fs.closeSync(directory);
    }
  } catch {
    // Directory fsync is unavailable here; the rename already happened.
  }
}

export function readJsonSync(filePath) {
  if (!fs.existsSync(filePath)) {
    return null;
  }
  const raw = fs.readFileSync(filePath, "utf8");
  if (!raw.trim()) {
    return null;
  }
  return JSON.parse(raw);
}

export function removeFileSync(filePath) {
  try {
    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
    }
  } catch (err) {
    if (err.code !== "ENOENT") throw err;
  }
}

export function isRegularFileSync(filePath) {
  try {
    const stat = fs.lstatSync(filePath);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

export function isDirectorySync(dirPath) {
  try {
    const stat = fs.lstatSync(dirPath);
    return stat.isDirectory() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}
