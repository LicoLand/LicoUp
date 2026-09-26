// Development backup: export and import the complete local data root.
//
// The tool does not build archives itself. Only the native owner can establish a
// coherent stopped-writer state and validate the restored application stores, so
// this module marshals the request and reports the owner's typed outcome. A tool
// local copy would be exactly the false "complete backup" the design forbids.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

/** The compiled native CLI. Overridable for an installed or release build. */
export function nativeCliPath() {
  return (
    process.env.LICOUP_NATIVE_CLI ||
    path.join(repoRoot, "build", "crates", "licoup-native", "target", "debug", "licoup-cli")
  );
}

export function isNativeCliAvailable(nativeCli = nativeCliPath()) {
  try {
    return fs.existsSync(nativeCli) && fs.statSync(nativeCli).isFile();
  } catch {
    return false;
  }
}

export const SUPPORTED_ARCHIVE_EXTENSIONS = [".zip", ".tar.gz", ".tgz"];

/** The container is inferred from the archive name, as the design requires. */
export function isSupportedArchiveName(archivePath) {
  const lowered = String(archivePath || "").toLowerCase();
  return SUPPORTED_ARCHIVE_EXTENSIONS.some((extension) => lowered.endsWith(extension));
}

function callNative(args, nativeCli) {
  if (!isNativeCliAvailable(nativeCli)) {
    const error = new Error(
      "backup_native_owner_unavailable: build the native client first " +
        "(node tools/scripts/cargo-client.mjs build -p licoup-native --bin licoup-cli)",
    );
    error.code = "backup_native_owner_unavailable";
    throw error;
  }
  const proc = spawnSync(nativeCli, args, { encoding: "utf8" });
  if (proc.error) {
    throw new Error(`backup_native_owner_failed: ${proc.error.message}`);
  }
  const stdout = (proc.stdout || "").trim();
  let parsed = null;
  if (stdout) {
    try {
      parsed = JSON.parse(stdout);
    } catch {
      parsed = null;
    }
  }
  if (proc.status !== 0) {
    const message = parsed?.error?.message || parsed?.message || (proc.stderr || "").trim();
    const error = new Error(message || `backup_native_owner_failed`);
    error.code = parsed?.error?.code || "backup_native_owner_failed";
    throw error;
  }
  if (!parsed) {
    throw new Error("backup_native_owner_unreadable_response");
  }
  return parsed;
}

/**
 * Export the complete data root into one standard plaintext archive.
 *
 * `writersStopped` is the operator's statement that every writer, including older
 * clients, has stopped. Without it the native owner refuses and nothing is written.
 */
export function exportBackup({ dataRoot, archivePath, writersStopped = false, nativeCli } = {}) {
  if (!dataRoot) throw new Error("backup_data_root_required");
  if (!archivePath) throw new Error("backup_archive_required");
  if (!isSupportedArchiveName(archivePath)) {
    throw new Error(`backup_container_unsupported: ${path.basename(archivePath)}`);
  }
  const args = ["backup", "export", archivePath, "--data-root", dataRoot];
  if (writersStopped) args.push("--writers-stopped");
  return callNative(args, nativeCli || nativeCliPath());
}

/** Restore one archive into a disposable target root; never the active root. */
export function importBackup({ archivePath, targetRoot, nativeCli } = {}) {
  if (!archivePath) throw new Error("backup_archive_required");
  if (!targetRoot) throw new Error("backup_target_root_required");
  if (!isSupportedArchiveName(archivePath)) {
    throw new Error(`backup_container_unsupported: ${path.basename(archivePath)}`);
  }
  return callNative(
    ["backup", "import", archivePath, "--target-root", targetRoot],
    nativeCli || nativeCliPath(),
  );
}
