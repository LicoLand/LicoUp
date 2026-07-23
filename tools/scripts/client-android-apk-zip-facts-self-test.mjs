#!/usr/bin/env node

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { inspectAndroidApkZipFacts } from "./lib/android-apk-facts.mjs";

const nativePath = "lib/arm64-v8a/liblico_client_native.so";

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

function zipFixture(entries) {
  const localParts = [];
  const centralParts = [];
  let localOffset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, "utf8");
    const content = Buffer.from(entry.content || "", "utf8");
    const method = entry.method ?? 0;
    const crc32 = 0x12345678;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(entry.localMethod ?? method, 8);
    local.writeUInt32LE(crc32, 14);
    local.writeUInt32LE(content.length, 18);
    local.writeUInt32LE(content.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28);
    localParts.push(local, name, content);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(0x0314, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt32LE(crc32, 16);
    central.writeUInt32LE(content.length, 20);
    central.writeUInt32LE(content.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt32LE(((entry.mode ?? 0o100644) << 16) >>> 0, 38);
    central.writeUInt32LE(localOffset, 42);
    centralParts.push(central, name);
    localOffset += local.length + name.length + content.length;
  }
  const centralDirectory = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralDirectory.length, 12);
  end.writeUInt32LE(localOffset, 16);
  return Buffer.concat([...localParts, centralDirectory, end]);
}

function expectRejected(root, name, entries, options = {}) {
  const file = path.join(root, `${name}.apk`);
  writeFileSync(file, zipFixture(entries), { mode: 0o600 });
  let rejected = false;
  try {
    inspectAndroidApkZipFacts(file, options);
  } catch {
    rejected = true;
  }
  requireValue(rejected, `android_zip_self_test_accepted_${name}`);
}

const root = mkdtempSync(path.join(os.tmpdir(), "lico-android-zip-test-"));
try {
  const validPath = path.join(root, "valid.apk");
  writeFileSync(validPath, zipFixture([{
    name: nativePath,
    content: "native-library",
  }]), { mode: 0o600 });
  const valid = inspectAndroidApkZipFacts(validPath);
  requireValue(valid.path === nativePath && valid.regular === true &&
    valid.unique === true && valid.size === 14,
  "android_zip_self_test_valid_fixture_failed");

  expectRejected(root, "duplicate", [
    { name: nativePath, content: "first" },
    { name: nativePath, content: "second" },
  ]);
  expectRejected(root, "traversal", [
    { name: "../outside", content: "bad" },
    { name: nativePath, content: "native" },
  ]);
  expectRejected(root, "backslash", [
    {
      name: ["lib", "arm64-v8a", "liblico_client_native.so"].join(
        String.fromCharCode(92),
      ),
      content: "bad",
    },
    { name: nativePath, content: "native" },
  ]);
  expectRejected(root, "symlink", [{
    name: nativePath,
    content: "target",
    mode: 0o120777,
  }]);
  expectRejected(root, "empty", [{ name: nativePath, content: "" }]);
  expectRejected(root, "compressed", [{
    name: nativePath,
    content: "compressed",
    method: 8,
  }]);
  expectRejected(root, "local_mismatch", [{
    name: nativePath,
    content: "native",
    method: 0,
    localMethod: 8,
  }]);
  expectRejected(root, "missing", [{ name: "lib/arm64-v8a/other.so", content: "other" }]);
  expectRejected(root, "apk_size_bound", [{
    name: nativePath,
    content: "native-library",
  }], { limits: { maxApkBytes: 32 } });
  expectRejected(root, "entry_count_bound", [
    { name: nativePath, content: "native-library" },
    { name: "assets/extra", content: "extra" },
  ], { limits: { maxEntries: 1 } });
  expectRejected(root, "central_directory_bound", [{
    name: nativePath,
    content: "native-library",
  }], { limits: { maxCentralDirectoryBytes: 32 } });
  expectRejected(root, "path_byte_bound", [{
    name: nativePath,
    content: "native-library",
  }], { limits: { maxPathBytes: 16 } });
  expectRejected(root, "native_library_bound", [{
    name: nativePath,
    content: "native-library",
  }], { limits: { maxNativeLibraryBytes: 8 } });
  expectRejected(root, "total_uncompressed_bound", [
    { name: nativePath, content: "native-library" },
    { name: "assets/extra", content: "extra" },
  ], { limits: {
    maxNativeLibraryBytes: 16,
    maxEntryUncompressedBytes: 16,
    maxTotalUncompressedBytes: 16,
  } });

  console.log(JSON.stringify({
    ok: true,
    caseCount: 15,
    privatePathsIncluded: false,
  }));
} finally {
  rmSync(root, { recursive: true, force: true });
}
