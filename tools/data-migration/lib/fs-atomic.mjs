import fs from "node:fs";
import fsp from "node:fs/promises";
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
  fs.writeFileSync(tempPath, serialized, { encoding: "utf8", mode });
  fs.renameSync(tempPath, filePath);
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
