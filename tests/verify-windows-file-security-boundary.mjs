import { mkdir, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));

const sensitiveRustFiles = [
  "crates/lico-client-native/src/platform/client_state.rs",
  "crates/lico-client-native/src/domain/conversation_snapshots.rs",
  "crates/lico-client-native/src/platform/file_security.rs",
  "crates/lico-client-native/src/domain/forwarding.rs",
  "crates/lico-client-native/src/platform/local_runtime.rs",
  "crates/lico-client-native/src/platform/process_identity.rs",
  "crates/lico-client-native/src/core/secure_mesh_mls.rs",
  "crates/lico-client-native/src/domain/source_queue.rs",
  "crates/lico-client-native/src/domain/targets.rs"
];

const failures = [];
const helperExpectations = new Map([
  ["crates/lico-client-native/src/platform/client_state.rs", ["atomic_write_private_text", "append_private_line"]],
  ["crates/lico-client-native/src/domain/conversation_snapshots.rs", ["atomic_write_private_text", "harden_private_tree"]],
  ["crates/lico-client-native/src/platform/file_security.rs", ["icacls", "*S-1-3-4:(F)", "*S-1-3-4:(OI)(CI)(F)"]],
  ["crates/lico-client-native/src/domain/forwarding.rs", ["atomic_write_private_text"]],
  ["crates/lico-client-native/src/platform/local_runtime.rs", ["atomic_write_private_text"]],
  ["crates/lico-client-native/src/platform/process_identity.rs", ["atomic_write_private_text"]],
  ["crates/lico-client-native/src/core/secure_mesh_mls.rs", ["harden_private_path"]],
  ["crates/lico-client-native/src/domain/source_queue.rs", ["harden_private_path"]],
  ["crates/lico-client-native/src/domain/targets.rs", ["atomic_write_private_text"]]
]);
const notes = [
  "Sensitive client writes now flow through a shared file_security helper.",
  "Unix private-file writes stay guarded behind #[cfg(unix)] 0600 handling, while Windows applies an explicit owner-only ACL via native icacls owner-rights entries."
];

for (const relativePath of sensitiveRustFiles) {
  const absolutePath = path.join(repoRoot, relativePath);
  const source = readFileSync(absolutePath, "utf8");
  // Unit-test fixtures legitimately exercise chmod on Unix. Restrict this
  // portability check to production code so a distant module-level cfg does
  // not become either a false positive or an accidental blanket exemption.
  const productionSource = source.split(/\n#\[cfg\((?:all\()?test\b/u, 1)[0];

  if (productionSource.includes("std::os::unix::fs::PermissionsExt") && !productionSource.includes("#[cfg(unix)]")) {
    failures.push(`${relativePath} imports PermissionsExt without #[cfg(unix)]`);
  }

  for (const match of productionSource.matchAll(/fs::set_permissions|set_permissions\(/g)) {
    const before = productionSource.slice(Math.max(0, match.index - 320), match.index);
    if (!/#\[cfg\(unix\)\][\s\S]*$/u.test(before) && !before.includes("cfg!(unix)") && !before.includes("permissions.set_mode")) {
      failures.push(`${relativePath} has an unconditional chmod-style permission write near offset ${match.index}`);
    }
  }

  if (productionSource.includes("from_mode(0o600)") && !productionSource.includes("#[cfg(unix)]")) {
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
  console.error("[windows-file-security] report written");
  process.exit(1);
}

console.log("[windows-file-security] boundary verified");
console.log("[windows-file-security] report written");
