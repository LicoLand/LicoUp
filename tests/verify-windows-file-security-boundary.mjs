import { mkdir, writeFile } from "node:fs/promises";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));

function rustSourceBundle(relativeRoot) {
  const found = [];
  function walk(relativeDirectory) {
    for (const entry of readdirSync(path.join(repoRoot, relativeDirectory), {
      withFileTypes: true,
    })) {
      const relativePath = path.posix.join(relativeDirectory, entry.name);
      if (entry.isDirectory()) {
        walk(relativePath);
      } else if (entry.isFile() && entry.name.endsWith(".rs")) {
        found.push(relativePath);
      }
    }
  }
  walk(relativeRoot);
  return found.sort();
}

const conversationSnapshotSourceFiles = [
  "crates/licoup-native/src/domain/conversation_snapshots.rs",
  ...rustSourceBundle("crates/licoup-native/src/domain/conversation/snapshots"),
];
const targetSourceFiles = [
  "crates/licoup-native/src/domain/targets.rs",
  ...rustSourceBundle("crates/licoup-native/src/domain/targets")
    .filter((ref) => !ref.endsWith("/tests.rs") && !ref.includes("/tests/")),
];
const clientStateSourceFiles = [
  "crates/licoup-native/src/platform/client_state.rs",
  ...rustSourceBundle("crates/licoup-native/src/platform/client_state")
    .filter((ref) => !ref.includes("/tests/")),
];
const fileSecuritySourceFiles = [
  "crates/licoup-native/src/platform/file_security.rs",
  ...rustSourceBundle("crates/licoup-native/src/platform/file_security")
    .filter((ref) => !ref.includes("/tests/")),
];
const fileSecurityFacadeSource = readFileSync(
  path.join(repoRoot, "crates/licoup-native/src/platform/file_security.rs"),
  "utf8",
);
const unixHardeningModuleGuarded =
  /#\[cfg\(unix\)\]\s*mod unix_hardening;/u.test(fileSecurityFacadeSource);
const secureMeshMlsSourceFiles = [
  "crates/licoup-native/src/core/secure_mesh_mls.rs",
  ...rustSourceBundle("crates/licoup-native/src/core/secure_mesh_mls"),
];

const sensitiveRustFiles = [
  ...clientStateSourceFiles,
  ...conversationSnapshotSourceFiles,
  ...fileSecuritySourceFiles,
  ...secureMeshMlsSourceFiles,
  "crates/licoup-native/src/platform/secure_mesh_mls_store.rs",
  ...targetSourceFiles,
];

const failures = [];
const helperExpectations = new Map([
  ["crates/licoup-native/src/platform/client_state/serialization.rs", ["atomic_write_private_text"]],
  ["crates/licoup-native/src/platform/client_state/activity.rs", ["append_private_line"]],
  ["crates/licoup-native/src/domain/conversation/snapshots/mod.rs", ["atomic_write_private_text"]],
  ["crates/licoup-native/src/platform/file_security/windows_acl.rs", ["icacls", "*S-1-3-4:(F)", "*S-1-3-4:(OI)(CI)(F)"]],
  ["crates/licoup-native/src/platform/secure_mesh_mls_store.rs", ["harden_private_path"]],
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
  const unixModule = productionSource.trimStart().startsWith("#![cfg(unix)]") ||
    (relativePath.endsWith("/file_security/unix_hardening.rs") &&
      unixHardeningModuleGuarded);

  if (productionSource.includes("std::os::unix::fs::PermissionsExt") &&
      !unixModule &&
      !productionSource.includes("#[cfg(unix)]")) {
    failures.push(`${relativePath} imports PermissionsExt without #[cfg(unix)]`);
  }

  for (const match of productionSource.matchAll(/fs::set_permissions|set_permissions\(/g)) {
    const before = productionSource.slice(Math.max(0, match.index - 320), match.index);
    if (!unixModule &&
        !/#\[cfg\(unix\)\][\s\S]*$/u.test(before) &&
        !before.includes("cfg!(unix)") &&
        !before.includes("permissions.set_mode")) {
      failures.push(`${relativePath} has an unconditional chmod-style permission write near offset ${match.index}`);
    }
  }

  if (productionSource.includes("from_mode(0o600)") &&
      !unixModule &&
      !productionSource.includes("#[cfg(unix)]")) {
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
