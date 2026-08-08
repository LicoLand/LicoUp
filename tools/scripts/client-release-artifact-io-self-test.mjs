#!/usr/bin/env node

import {
  appendFileSync,
  chmodSync,
  closeSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  artifactTreeContentDigest,
  artifactTreeDigest,
  resolveContainedExistingPath,
  sha256File,
  stableReadFileSnapshot,
  stableSnapshotFile,
} from "./lib/client-release-artifact-digest.mjs";
import {
  atomicWriteReportJson,
  resolveSafeReportPath,
  SAFE_REPORT_WRITE_STAGES,
  SafeReportWriteError,
} from "./lib/safe-report-io.mjs";
import {
  captureSourceBoundJsonPolicy,
  sourceBoundPolicySnapshotStable,
} from "./lib/source-bound-policy-snapshot.mjs";

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

function expectRejected(code, operation) {
  let rejected = false;
  try {
    operation();
  } catch {
    rejected = true;
  }
  requireValue(rejected, code);
}

const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "lico-artifact-io-test-"));

try {
  const artifact = path.join(temporaryRoot, "artifact");
  const nested = path.join(artifact, "nested");
  mkdirSync(nested, { recursive: true });
  writeFileSync(path.join(nested, "payload.bin"), "payload", { mode: 0o600 });
  symlinkSync("nested/payload.bin", path.join(artifact, "contained-link"));
  const containedDigest = artifactTreeDigest(artifact);
  requireValue(/^sha256:[a-f0-9]{64}$/u.test(containedDigest),
    "contained_relative_symlink_was_not_hashed");

  symlinkSync("artifact", path.join(temporaryRoot, "artifact-root-link"));
  expectRejected("top_level_artifact_symlink_accepted", () =>
    artifactTreeDigest(path.join(temporaryRoot, "artifact-root-link")));

  writeFileSync(path.join(temporaryRoot, "outside.bin"), "outside", { mode: 0o600 });
  symlinkSync("../outside.bin", path.join(artifact, "escaping-link"));
  expectRejected("escaping_relative_symlink_accepted", () => artifactTreeDigest(artifact));
  unlinkSync(path.join(artifact, "escaping-link"));

  symlinkSync(path.join(temporaryRoot, "outside.bin"), path.join(artifact, "absolute-link"));
  expectRejected("absolute_symlink_accepted", () => artifactTreeDigest(artifact));
  unlinkSync(path.join(artifact, "absolute-link"));

  expectRejected("canonical_path_symlink_accepted", () =>
    resolveContainedExistingPath(temporaryRoot, path.join(artifact, "contained-link"), {
      expectedKind: "file",
    }));

  const mutableFile = path.join(temporaryRoot, "mutable.bin");
  writeFileSync(mutableFile, "before", { mode: 0o600 });
  expectRejected("file_mutation_during_read_accepted", () =>
    stableReadFileSnapshot(mutableFile, {
      afterOpen: () => appendFileSync(mutableFile, "after"),
    }));

  const swappedFile = path.join(temporaryRoot, "swapped.bin");
  const swappedBackup = path.join(temporaryRoot, "swapped-backup.bin");
  writeFileSync(swappedFile, "original", { mode: 0o600 });
  expectRejected("file_path_swap_during_read_accepted", () =>
    stableReadFileSnapshot(swappedFile, {
      afterOpen: () => {
        renameSync(swappedFile, swappedBackup);
        writeFileSync(swappedFile, "replacement", { mode: 0o600 });
      },
    }));

  const mutableTree = path.join(temporaryRoot, "mutable-tree");
  mkdirSync(mutableTree);
  writeFileSync(path.join(mutableTree, "first"), "one", { mode: 0o600 });
  expectRejected("directory_mutation_during_hash_accepted", () =>
    artifactTreeDigest(mutableTree, {
      onDirectoryRead: (directory, relative) => {
        if (relative === "") {
          writeFileSync(path.join(directory, "second"), "two", { mode: 0o600 });
        }
      },
    }));

  const modeTree = path.join(temporaryRoot, "mode-tree");
  mkdirSync(modeTree, { mode: 0o700 });
  const modeFile = path.join(modeTree, "executable");
  writeFileSync(modeFile, "mode", { mode: 0o700 });
  const executableDigest = artifactTreeDigest(modeTree);
  chmodSync(modeFile, 0o600);
  requireValue(artifactTreeDigest(modeTree) !== executableDigest,
    "chmod_only_tree_mutation_was_not_hashed");
  chmodSync(modeFile, 0o622);
  expectRejected("shared_writable_tree_entry_accepted", () =>
    artifactTreeDigest(modeTree));

  const emptyDirectoryTree = path.join(temporaryRoot, "empty-directory-tree");
  mkdirSync(path.join(emptyDirectoryTree, "empty-a"), { recursive: true });
  const emptyDirectoryDigest = artifactTreeDigest(emptyDirectoryTree);
  mkdirSync(path.join(emptyDirectoryTree, "empty-b"));
  requireValue(artifactTreeDigest(emptyDirectoryTree) !== emptyDirectoryDigest,
    "empty_directory_tree_mutation_was_not_hashed");
  mkdirSync(path.join(emptyDirectoryTree, "empty-a", "deep"));

  expectRejected("tree_directory_count_bound_ignored", () =>
    artifactTreeDigest(emptyDirectoryTree, {
      limits: { maxEntries: 3, maxDirectories: 1, maxFiles: 1 },
    }));
  expectRejected("tree_depth_bound_ignored", () =>
    artifactTreeDigest(emptyDirectoryTree, { limits: { maxDepth: 1 } }));

  const boundedTree = path.join(temporaryRoot, "bounded-tree");
  mkdirSync(boundedTree);
  writeFileSync(path.join(boundedTree, "one"), "12345", { mode: 0o600 });
  writeFileSync(path.join(boundedTree, "two"), "67890", { mode: 0o600 });
  expectRejected("tree_single_file_byte_bound_ignored", () =>
    artifactTreeDigest(boundedTree, {
      limits: { maxFileBytes: 4, maxTotalFileBytes: 16 },
    }));
  expectRejected("tree_total_file_byte_bound_ignored", () =>
    artifactTreeDigest(boundedTree, {
      limits: { maxFileBytes: 8, maxTotalFileBytes: 8 },
    }));

  const externalHardlinkSource = path.join(temporaryRoot, "hardlink-source");
  writeFileSync(externalHardlinkSource, "hardlink", { mode: 0o600 });
  const externalHardlinkTree = path.join(temporaryRoot, "external-hardlink-tree");
  mkdirSync(externalHardlinkTree);
  linkSync(externalHardlinkSource, path.join(externalHardlinkTree, "linked"));
  expectRejected("external_hardlink_tree_entry_accepted", () =>
    artifactTreeDigest(externalHardlinkTree));
  const externalHardlinkContentDigest = artifactTreeContentDigest(
    externalHardlinkTree,
    { allowExternalHardlinks: true },
  );
  requireValue(/^sha256:[a-f0-9]{64}$/u.test(externalHardlinkContentDigest),
    "external_hardlink_content_identity_rejected");

  const internalHardlinkTree = path.join(temporaryRoot, "internal-hardlink-tree");
  mkdirSync(internalHardlinkTree);
  const internalHardlinkFirst = path.join(internalHardlinkTree, "first");
  writeFileSync(internalHardlinkFirst, "hardlink", { mode: 0o600 });
  linkSync(internalHardlinkFirst, path.join(internalHardlinkTree, "second"));
  requireValue(/^sha256:[a-f0-9]{64}$/u.test(artifactTreeDigest(internalHardlinkTree)),
    "internal_hardlink_tree_rejected");
  const contentIdentityBeforeModeChange = artifactTreeContentDigest(internalHardlinkTree);
  chmodSync(internalHardlinkFirst, 0o700);
  requireValue(artifactTreeContentDigest(internalHardlinkTree) ===
    contentIdentityBeforeModeChange, "content_identity_included_install_metadata");
  writeFileSync(internalHardlinkFirst, "changed", { mode: 0o700 });
  requireValue(artifactTreeContentDigest(internalHardlinkTree) !==
    contentIdentityBeforeModeChange, "content_identity_ignored_file_mutation");

  const snapshotDirectory = path.join(temporaryRoot, "snapshots");
  mkdirSync(snapshotDirectory);
  const stableSource = path.join(temporaryRoot, "stable-source.bin");
  writeFileSync(stableSource, "stable", { mode: 0o600 });
  const snapshot = stableSnapshotFile(stableSource, snapshotDirectory, "snapshot.bin");
  requireValue(readFileSync(snapshot, "utf8") === "stable",
    "stable_snapshot_copy_failed");
  expectRejected("existing_snapshot_target_accepted", () =>
    stableSnapshotFile(stableSource, snapshotDirectory, "snapshot.bin"));

  const oversizedMetadata = path.join(temporaryRoot, "oversized-metadata.json");
  writeFileSync(oversizedMetadata, JSON.stringify({ value: "x".repeat(2048) }), {
    mode: 0o600,
  });
  expectRejected("oversized_stable_report_read_accepted", () =>
    stableReadFileSnapshot(oversizedMetadata, { maxBytes: 1024 }));

  const largeSource = path.join(temporaryRoot, "large-artifact.bin");
  const largeDescriptor = openSync(largeSource, "wx", 0o600);
  try {
    const chunk = Buffer.alloc(1024 * 1024, 0x5a);
    for (let index = 0; index < 20; index += 1) {
      requireValue(writeSync(largeDescriptor, chunk) === chunk.length,
        "large_artifact_fixture_write_failed");
    }
  } finally {
    closeSync(largeDescriptor);
  }
  expectRejected("large_artifact_unbounded_buffer_read_accepted", () =>
    stableReadFileSnapshot(largeSource));
  const largeDigest = sha256File(largeSource, { chunkBytes: 64 * 1024 });
  const largeSnapshot = stableSnapshotFile(
    largeSource,
    snapshotDirectory,
    "large-snapshot.bin",
  );
  requireValue(sha256File(largeSnapshot, { chunkBytes: 128 * 1024 }) === largeDigest,
    "large_artifact_chunked_snapshot_failed");

  const reportRoot = path.join(temporaryRoot, "reports");
  mkdirSync(reportRoot);
  expectRejected("report_path_traversal_accepted", () =>
    atomicWriteReportJson(reportRoot, "../escaped.json", { ok: true }));
  expectRejected("normalized_report_path_traversal_accepted", () =>
    atomicWriteReportJson(reportRoot, "nested/../inside.json", { ok: true }));

  const outsideDirectory = path.join(temporaryRoot, "outside-directory");
  mkdirSync(outsideDirectory);
  symlinkSync("../outside-directory", path.join(reportRoot, "linked-directory"));
  expectRejected("report_directory_symlink_accepted", () =>
    atomicWriteReportJson(reportRoot, "linked-directory/report.json", { ok: true }));

  const outsideReport = path.join(temporaryRoot, "outside-report.json");
  writeFileSync(outsideReport, "{}", { mode: 0o600 });
  symlinkSync("../outside-report.json", path.join(reportRoot, "linked-report.json"));
  expectRejected("report_file_symlink_accepted", () =>
    atomicWriteReportJson(reportRoot, "linked-report.json", { ok: true }));

  symlinkSync("reports", path.join(temporaryRoot, "report-root-link"));
  expectRejected("report_root_symlink_accepted", () =>
    resolveSafeReportPath(path.join(temporaryRoot, "report-root-link"), "report.json"));
  expectRejected("oversized_report_json_accepted", () =>
    atomicWriteReportJson(
      reportRoot,
      "oversized-report.json",
      { value: "x".repeat(128) },
      { maxBytes: 32 },
    ));
  expectRejected("report_json_bound_above_global_limit_accepted", () =>
    atomicWriteReportJson(
      reportRoot,
      "invalid-bound-report.json",
      { ok: true },
      { maxBytes: Number.MAX_SAFE_INTEGER },
    ));

  const swapReportRoot = path.join(temporaryRoot, "swap-reports");
  const swapParent = path.join(swapReportRoot, "nested");
  const swappedParent = path.join(swapReportRoot, "nested-original");
  const swapOutside = path.join(temporaryRoot, "swap-outside");
  mkdirSync(swapParent, { recursive: true });
  mkdirSync(swapOutside);
  expectRejected("report_parent_symlink_swap_accepted", () =>
    atomicWriteReportJson(
      swapReportRoot,
      "nested/report.json",
      { ok: true },
      {
        beforePublish: () => {
          renameSync(swapParent, swappedParent);
          symlinkSync("../swap-outside", swapParent);
        },
      },
    ));

  const validReportPath = atomicWriteReportJson(reportRoot, "nested/report.json", {
    ok: true,
    publicationReady: false,
  });
  const validReport = JSON.parse(readFileSync(validReportPath, "utf8"));
  requireValue(validReport.ok === true && validReport.publicationReady === false,
    "atomic_report_publication_failed");

  for (const stage of SAFE_REPORT_WRITE_STAGES) {
    let failure;
    try {
      atomicWriteReportJson(
        reportRoot,
        `fault-${stage}.json`,
        { ok: true, privateDynamicValueIncluded: false },
        {
          faultInjector: (currentStage) => {
            if (currentStage === stage) {
              throw new Error(["private", "dynamic", "fault"].join("-"));
            }
          },
        },
      );
    } catch (error) {
      failure = error;
    }
    requireValue(failure instanceof SafeReportWriteError &&
      failure.stage === stage &&
      failure.message === "Safe report write failed" &&
      JSON.stringify({ name: failure.name, stage: failure.stage })
        .includes("dynamic") === false,
    `safe_report_fault_stage_not_closed:${stage}`);
  }

  const policyRoot = path.join(temporaryRoot, "policies");
  mkdirSync(policyRoot);
  const policyPath = path.join(policyRoot, "release.json");
  writeFileSync(policyPath, JSON.stringify({ authority: "canonical" }), {
    mode: 0o600,
  });
  const policy = captureSourceBoundJsonPolicy({
    allowedRoot: policyRoot,
    filePath: policyPath,
    id: "release-policy",
    ref: "policies/release.json",
  });
  requireValue(sourceBoundPolicySnapshotStable(policy),
    "stable_policy_snapshot_rejected");
  const policyOriginal = path.join(policyRoot, "release-original.json");
  renameSync(policyPath, policyOriginal);
  writeFileSync(policyPath, JSON.stringify({ authority: "swapped" }), {
    mode: 0o600,
  });
  expectRejected("policy_swap_window_accepted", () => {
    requireValue(sourceBoundPolicySnapshotStable(policy),
      "policy_swap_window_rejected");
  });

  console.log(JSON.stringify({
    ok: true,
    caseCount: 31 + SAFE_REPORT_WRITE_STAGES.length,
    policyReadBeforeAfterBound: true,
    policySwapWindowRejected: true,
    safeReportWriteStageCount: SAFE_REPORT_WRITE_STAGES.length,
    dynamicFaultValuesIncluded: false,
    privatePathsIncluded: false,
  }));
} finally {
  rmSync(temporaryRoot, { recursive: true, force: true });
}
