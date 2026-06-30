import { mkdir, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));

const sensitiveRustFiles = [
  "crates/lico-client-native/src/client_state.rs",
  "crates/lico-client-native/src/conversation_snapshots.rs",
  "crates/lico-client-native/src/file_security.rs",
  "crates/lico-client-native/src/forwarding.rs",
  "crates/lico-client-native/src/local_runtime.rs",
  "crates/lico-client-native/src/process_identity.rs",
  "crates/lico-client-native/src/secure_mesh_mls.rs",
  "crates/lico-client-native/src/source_queue.rs",
  "crates/lico-client-native/src/targets.rs"
];

const failures = [];
const helperExpectations = new Map([
  ["crates/lico-client-native/src/client_state.rs", ["atomic_write_private_text", "append_private_line"]],
  ["crates/lico-client-native/src/conversation_snapshots.rs", ["atomic_write_private_text", "harden_private_tree"]],
  ["crates/lico-client-native/src/file_security.rs", ["icacls", "*S-1-3-4:(F)", "*S-1-3-4:(OI)(CI)(F)"]],
  ["crates/lico-client-native/src/forwarding.rs", ["atomic_write_private_text"]],
  ["crates/lico-client-native/src/local_runtime.rs", ["atomic_write_private_text"]],
  ["crates/lico-client-native/src/process_identity.rs", ["atomic_write_private_text"]],
  ["crates/lico-client-native/src/secure_mesh_mls.rs", ["harden_private_path"]],
  ["crates/lico-client-native/src/source_queue.rs", ["harden_private_path"]],
  ["crates/lico-client-native/src/targets.rs", ["atomic_write_private_text"]]
]);
const notes = [
  "Sensitive client writes now flow through a shared file_security helper.",
  "Unix private-file writes stay guarded behind #[cfg(unix)] 0600 handling, while Windows applies an explicit owner-only ACL via native icacls owner-rights entries."
];

for (const relativePath of sensitiveRustFiles) {
  const absolutePath = path.join(repoRoot, relativePath);
  const source = readFileSync(absolutePath, "utf8");

  if (source.includes("std::os::unix::fs::PermissionsExt") && !source.includes("#[cfg(unix)]")) {
    failures.push(`${relativePath} imports PermissionsExt without #[cfg(unix)]`);
  }

  for (const match of source.matchAll(/fs::set_permissions|set_permissions\(/g)) {
    const before = source.slice(Math.max(0, match.index - 140), match.index);
    if (!before.includes("#[cfg(unix)]") && !before.includes("cfg!(unix)") && !before.includes("permissions.set_mode")) {
      failures.push(`${relativePath} has an unconditional chmod-style permission write near offset ${match.index}`);
    }
  }

  if (source.includes("from_mode(0o600)") && !source.includes("#[cfg(unix)]")) {
    failures.push(`${relativePath} references 0600 without an explicit Unix cfg marker`);
  }

  for (const needle of helperExpectations.get(relativePath) ?? []) {
    if (!source.includes(needle)) {
      failures.push(`${relativePath} is missing required file-security marker: ${needle}`);
    }
  }
}

const report = {
  ok: failures.length === 0,
  platform: process.platform,
  checkedAt: new Date().toISOString(),
  checkedFiles: sensitiveRustFiles,
  boundary: {
    windowsAclStatus: "explicit-owner-only-native-dacl-helper",
    targetWindowsAclStatus: "explicit-owner-only-native-dacl-helper",
    unixModeStatus: "0600 guarded by #[cfg(unix)]",
    notes
  },
  failures
};

const reportPath = path.join(repoRoot, "build", "test-reports", "windows-file-security-boundary.json");
await mkdir(path.dirname(reportPath), { recursive: true });
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);

if (failures.length > 0) {
  console.error("[windows-file-security] verifier failed:");
  for (const failure of failures) {
    console.error(`  - ${failure}`);
  }
  console.error(`[windows-file-security] report: ${reportPath}`);
  process.exit(1);
}

console.log("[windows-file-security] boundary verified");
console.log(`[windows-file-security] report: ${reportPath}`);
