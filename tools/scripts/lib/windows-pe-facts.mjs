import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readSync,
} from "node:fs";

export const WINDOWS_PE_MACHINE = Object.freeze({
  x64: 0x8664,
  arm64: 0xaa64,
});

const PE_HEADER_READ_LIMIT = 1024 * 1024;

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

export function inspectWindowsPeBytes(bytes) {
  requireValue(Buffer.isBuffer(bytes), "windows_pe_bytes_required");
  requireValue(bytes.length >= 64, "windows_pe_dos_header_truncated");
  requireValue(bytes[0] === 0x4d && bytes[1] === 0x5a, "windows_pe_dos_signature_invalid");
  const peOffset = bytes.readUInt32LE(0x3c);
  requireValue(peOffset >= 64 && peOffset <= bytes.length - 26,
    "windows_pe_header_offset_invalid");
  requireValue(bytes.subarray(peOffset, peOffset + 4).equals(Buffer.from([0x50, 0x45, 0, 0])),
    "windows_pe_signature_invalid");
  const machine = bytes.readUInt16LE(peOffset + 4);
  const architecture = Object.entries(WINDOWS_PE_MACHINE)
    .find(([, value]) => value === machine)?.[0] || "unsupported";
  requireValue(architecture !== "unsupported", "windows_pe_machine_unsupported");
  const optionalHeaderSize = bytes.readUInt16LE(peOffset + 20);
  requireValue(optionalHeaderSize >= 2 && peOffset + 24 + optionalHeaderSize <= bytes.length,
    "windows_pe_optional_header_truncated");
  const optionalHeaderMagic = bytes.readUInt16LE(peOffset + 24);
  requireValue(optionalHeaderMagic === 0x20b, "windows_pe_not_pe32_plus");
  return Object.freeze({
    format: "PE32+",
    architecture,
    machine: `0x${machine.toString(16).padStart(4, "0")}`,
  });
}

export function inspectWindowsPeFile(filePath) {
  const beforePath = lstatSync(filePath, { bigint: true });
  requireValue(beforePath.isFile() && !beforePath.isSymbolicLink(),
    "windows_pe_path_not_regular");
  const descriptor = openSync(filePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  try {
    const before = fstatSync(descriptor, { bigint: true });
    requireValue(before.isFile() && before.dev === beforePath.dev && before.ino === beforePath.ino,
      "windows_pe_path_changed");
    const length = Number(before.size > BigInt(PE_HEADER_READ_LIMIT)
      ? BigInt(PE_HEADER_READ_LIMIT)
      : before.size);
    const bytes = Buffer.alloc(length);
    let offset = 0;
    while (offset < length) {
      const count = readSync(descriptor, bytes, offset, length - offset, offset);
      requireValue(count > 0, "windows_pe_header_read_incomplete");
      offset += count;
    }
    const after = fstatSync(descriptor, { bigint: true });
    const afterPath = lstatSync(filePath, { bigint: true });
    requireValue(before.dev === after.dev && before.ino === after.ino &&
      before.size === after.size && before.mtimeNs === after.mtimeNs &&
      after.dev === afterPath.dev && after.ino === afterPath.ino,
    "windows_pe_file_changed_while_reading");
    return inspectWindowsPeBytes(bytes);
  } finally {
    closeSync(descriptor);
  }
}
