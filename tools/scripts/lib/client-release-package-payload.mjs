// Bounded packaging and reading of an independent package payload.
//
// A payload is the release asset a first-party package is published as: a ZIP
// archive whose `manifest.json` is the package manifest the host already reads
// (`licoup.extension-package.v1`) and whose `package-release.json` is the
// package's own release declaration (identity, version, client compatibility
// and a native converter entry). This module writes that archive byte-wise,
// reads it back within fixed bounds, and knows the one structural rule the
// binary-only requirement needs: an official payload may not carry an
// interpreter entry.
//
// Nothing here reaches the network, and nothing here executes the payload.

import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import path from "node:path";
import { inflateRawSync } from "node:zlib";

export const PACKAGE_PAYLOAD_MANIFEST_NAME = "manifest.json";
export const PACKAGE_PAYLOAD_DECLARATION_NAME = "package-release.json";

export const PACKAGE_PAYLOAD_LIMITS = Object.freeze({
  maxPayloadBytes: 8 * 1024 * 1024,
  maxEntryBytes: 8 * 1024 * 1024,
  maxExpandedBytes: 64 * 1024 * 1024,
  maxEntries: 512,
  maxPathBytes: 512,
  maxDepth: 16,
  maxDeclarationBytes: 256 * 1024,
});

class PackagePayloadError extends Error {
  constructor(code, details = null) {
    super(code);
    this.code = code;
    this.details = details;
  }
}

function fail(code, details = null) {
  throw new PackagePayloadError(code, details);
}

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

export function sha256File(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let index = 0; index < 256; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) {
      value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
    table[index] = value >>> 0;
  }
  return table;
})();

export function crc32(buffer) {
  let value = 0xffffffff;
  for (const byte of buffer) {
    value = CRC_TABLE[(value ^ byte) & 0xff] ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) >>> 0;
}

// A script entry is what makes a package need a language runtime. The rule is
// structural and deliberately conservative: a known script extension, an
// executable bit on a text file whose first two bytes are a shebang, or a
// declared interpreter reference.
const INTERPRETER_SCRIPT_PATTERN =
  /\.(?:py|pyw|rb|pl|php|lua|sh|bash|zsh|ksh|fish|ps1|psm1|bat|cmd|js|mjs|cjs|ts|mts|cts|jsx|tsx|jar|class|wasm)$/u;

export function interpreterScriptEntryName(name) {
  return INTERPRETER_SCRIPT_PATTERN.test(name) ? name : "";
}

export function hasInterpreterShebang(content) {
  return content.length >= 2 && content[0] === 0x23 && content[1] === 0x21;
}

export function portableEntryPath(name) {
  const value = String(name || "");
  if (!value || value.length > PACKAGE_PAYLOAD_LIMITS.maxPathBytes) {
    fail("package_payload_entry_path_invalid");
  }
  if (value.includes("\\") || value.includes("\0") || value.includes(":") ||
    value.startsWith("/") || /^[A-Za-z]:/u.test(value)) {
    fail("package_payload_entry_path_invalid");
  }
  const components = value.split("/");
  if (components.some((component) =>
    !component || component === "." || component === "..")) {
    fail("package_payload_entry_path_invalid");
  }
  if (components.length > PACKAGE_PAYLOAD_LIMITS.maxDepth) {
    fail("package_payload_entry_path_invalid");
  }
  return value;
}

function archiveEntry(name, content, mode) {
  const portable = portableEntryPath(name);
  const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content, "utf8");
  if (bytes.length > PACKAGE_PAYLOAD_LIMITS.maxEntryBytes) {
    fail("package_payload_entry_too_large", { entry: portable });
  }
  return Object.freeze({
    name: portable,
    content: bytes,
    mode: Number.isInteger(mode) ? mode : 0o100644,
  });
}

/**
 * Build a payload archive deterministically: entries sorted by path, stored
 * without compression, and a fixed DOS timestamp. Two runs over the same
 * declared source produce the same bytes, which is what lets the index digest
 * bind the payload before it is published.
 */
export function writePackagePayload(rawEntries) {
  const entries = rawEntries.map((entry) =>
    archiveEntry(entry.name, entry.content, entry.mode))
    .sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0));
  const seen = new Set();
  for (const entry of entries) {
    if (seen.has(entry.name)) fail("package_payload_entry_duplicate", { entry: entry.name });
    seen.add(entry.name);
  }
  const localParts = [];
  const centralParts = [];
  let localOffset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, "utf8");
    const checksum = crc32(entry.content);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(0, 8);
    local.writeUInt16LE(0, 10);
    local.writeUInt16LE(0x0021, 12);
    local.writeUInt32LE(checksum, 14);
    local.writeUInt32LE(entry.content.length, 18);
    local.writeUInt32LE(entry.content.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28);
    localParts.push(local, name, entry.content);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(0x0314, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0x0021, 14);
    central.writeUInt32LE(checksum, 16);
    central.writeUInt32LE(entry.content.length, 20);
    central.writeUInt32LE(entry.content.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt16LE(0, 36);
    central.writeUInt32LE((entry.mode << 16) >>> 0, 38);
    central.writeUInt32LE(localOffset, 42);
    centralParts.push(central, name);
    localOffset += local.length + name.length + entry.content.length;
  }
  const centralDirectory = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralDirectory.length, 12);
  end.writeUInt32LE(localOffset, 16);
  end.writeUInt16LE(0, 20);
  const payload = Buffer.concat([...localParts, centralDirectory, end]);
  if (payload.length > PACKAGE_PAYLOAD_LIMITS.maxPayloadBytes) {
    fail("package_payload_too_large");
  }
  return payload;
}

function endOfCentralDirectory(bytes) {
  const tailSize = Math.min(bytes.length, 65_557);
  const tailOffset = bytes.length - tailSize;
  for (let index = tailSize - 22; index >= 0; index -= 1) {
    if (bytes.readUInt32LE(tailOffset + index) !== 0x06054b50) continue;
    const commentLength = bytes.readUInt16LE(tailOffset + index + 20);
    if (index + 22 + commentLength !== tailSize) continue;
    return {
      entries: bytes.readUInt16LE(tailOffset + index + 10),
      size: bytes.readUInt32LE(tailOffset + index + 12),
      offset: bytes.readUInt32LE(tailOffset + index + 16),
    };
  }
  fail("package_payload_archive_invalid");
}

/** Read a payload archive within fixed bounds and verify every entry checksum. */
export function readPackagePayload(bytes, limits = {}) {
  const bounds = { ...PACKAGE_PAYLOAD_LIMITS, ...limits };
  if (!Buffer.isBuffer(bytes) || bytes.length === 0 ||
    bytes.length > bounds.maxPayloadBytes) {
    fail("package_payload_archive_invalid");
  }
  const end = endOfCentralDirectory(bytes);
  if (end.entries === 0 || end.entries > bounds.maxEntries ||
    end.offset + end.size > bytes.length) {
    fail("package_payload_archive_invalid");
  }
  const entries = [];
  const seen = new Set();
  const folded = new Set();
  let expanded = 0;
  let cursor = end.offset;
  for (let index = 0; index < end.entries; index += 1) {
    if (cursor + 46 > bytes.length || bytes.readUInt32LE(cursor) !== 0x02014b50) {
      fail("package_payload_archive_invalid");
    }
    const flags = bytes.readUInt16LE(cursor + 8);
    const method = bytes.readUInt16LE(cursor + 10);
    const checksum = bytes.readUInt32LE(cursor + 16);
    const compressedSize = bytes.readUInt32LE(cursor + 20);
    const size = bytes.readUInt32LE(cursor + 24);
    const nameLength = bytes.readUInt16LE(cursor + 28);
    const extraLength = bytes.readUInt16LE(cursor + 30);
    const commentLength = bytes.readUInt16LE(cursor + 32);
    const mode = bytes.readUInt32LE(cursor + 38) >>> 16;
    const localOffset = bytes.readUInt32LE(cursor + 42);
    if (flags & 0x1) fail("package_payload_archive_encrypted");
    if (mode & 0o170000 && (mode & 0o170000) !== 0o100000) {
      fail("package_payload_entry_type_unsupported");
    }
    const name = portableEntryPath(
      bytes.subarray(cursor + 46, cursor + 46 + nameLength).toString("utf8"),
    );
    if (seen.has(name) || folded.has(name.toLowerCase())) {
      fail("package_payload_entry_duplicate", { entry: name });
    }
    seen.add(name);
    folded.add(name.toLowerCase());
    if (size > bounds.maxEntryBytes) {
      fail("package_payload_entry_too_large", { entry: name });
    }
    expanded += size;
    if (expanded > bounds.maxExpandedBytes) fail("package_payload_expanded_too_large");
    if (localOffset + 30 > bytes.length || bytes.readUInt32LE(localOffset) !== 0x04034b50) {
      fail("package_payload_archive_invalid");
    }
    const localNameLength = bytes.readUInt16LE(localOffset + 26);
    const localExtraLength = bytes.readUInt16LE(localOffset + 28);
    const bodyStart = localOffset + 30 + localNameLength + localExtraLength;
    if (bodyStart + compressedSize > bytes.length) fail("package_payload_archive_invalid");
    const body = bytes.subarray(bodyStart, bodyStart + compressedSize);
    let content;
    if (method === 0) {
      content = Buffer.from(body);
    } else if (method === 8) {
      try {
        content = inflateRawSync(body, { maxOutputLength: bounds.maxEntryBytes });
      } catch {
        fail("package_payload_entry_unreadable", { entry: name });
      }
    } else {
      fail("package_payload_compression_unsupported", { entry: name });
    }
    if (content.length !== size || crc32(content) !== checksum) {
      fail("package_payload_entry_checksum_invalid", { entry: name });
    }
    entries.push(Object.freeze({
      name,
      mode: mode & 0o777,
      byteSize: size,
      content,
    }));
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  return Object.freeze(entries);
}

/** Read the declared converter entry and refuse interpreter-carried payloads. */
export function nativeConverterEntry(entries, entryName) {
  const entry = entries.find((candidate) => candidate.name === entryName);
  if (!entry) fail("package_payload_converter_entry_missing", { entry: entryName });
  const scripted = interpreterScriptEntryName(entry.name);
  if (scripted) fail("package_payload_converter_not_native", { entry: scripted });
  if (hasInterpreterShebang(entry.content)) {
    fail("package_payload_converter_not_native", { entry: entry.name });
  }
  if ((entry.mode & 0o111) === 0) {
    fail("package_payload_converter_not_executable", { entry: entry.name });
  }
  for (const candidate of entries) {
    const name = interpreterScriptEntryName(candidate.name);
    if (name) fail("package_payload_entry_not_native", { entry: name });
    if (hasInterpreterShebang(candidate.content)) {
      fail("package_payload_entry_not_native", { entry: candidate.name });
    }
  }
  return entry;
}

/**
 * Read one package source directory: regular files only, bounded, sorted. The
 * caller owns the directory layout, so the entry names are the directory's own
 * relative paths.
 */
export function readPackageSourceDirectory(sourceRoot, limits = {}) {
  const bounds = { ...PACKAGE_PAYLOAD_LIMITS, ...limits };
  const absolute = path.resolve(sourceRoot);
  const rootInfo = lstatSync(absolute, { throwIfNoEntry: false });
  if (!rootInfo?.isDirectory() || rootInfo.isSymbolicLink() ||
    realpathSync(absolute) !== absolute) {
    fail("package_payload_source_invalid");
  }
  const entries = [];
  const walk = (directory, prefix) => {
    const names = readdirSync(directory, { withFileTypes: true })
      .map((entry) => entry.name)
      .sort();
    for (const name of names) {
      const filePath = path.join(directory, name);
      const info = lstatSync(filePath);
      const relative = prefix ? `${prefix}/${name}` : name;
      if (info.isSymbolicLink()) fail("package_payload_source_symlink", { entry: relative });
      if (info.isDirectory()) {
        walk(filePath, relative);
        continue;
      }
      if (!info.isFile()) fail("package_payload_source_invalid", { entry: relative });
      if (info.size > bounds.maxEntryBytes) {
        fail("package_payload_entry_too_large", { entry: relative });
      }
      entries.push({
        name: portableEntryPath(relative),
        content: readFileSync(filePath),
        mode: (info.mode & 0o111) === 0 ? 0o100644 : 0o100755,
      });
    }
  };
  walk(absolute, "");
  if (entries.length === 0 || entries.length > bounds.maxEntries) {
    fail("package_payload_source_invalid");
  }
  return Object.freeze(entries.map((entry) => Object.freeze(entry)));
}

export { PackagePayloadError };
