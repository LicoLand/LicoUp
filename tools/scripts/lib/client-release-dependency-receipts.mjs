import path from "node:path";
import {
  resolveContainedExistingPath,
  sha256Buffer,
  sha256File,
  stableReadFileSnapshot,
} from "./client-release-artifact-digest.mjs";
import { verifyPairwiseReviewSignoff } from "./review-signoff-verifier.mjs";

const MAX_DEPENDENCY_BYTES = 16 * 1024 * 1024;

function safeBuildRef(ref) {
  const normalized = String(ref || "").trim();
  if (!normalized.startsWith("build/") || normalized.includes("\\") ||
    normalized.includes("\0") || normalized.split("/").some((component) =>
      !component || component === "." || component === "..")) {
    throw new Error("release_dependency_ref_invalid");
  }
  return normalized;
}

export function captureReleaseDependencyReceipts(buildRoot, dependencies) {
  const ids = new Set();
  const refs = new Set();
  return dependencies.map(({ id, ref }) => {
    const normalizedId = String(id || "").trim();
    const normalizedRef = safeBuildRef(ref);
    if (!normalizedId || ids.has(normalizedId) || refs.has(normalizedRef)) {
      throw new Error("release_dependency_identity_invalid");
    }
    ids.add(normalizedId);
    refs.add(normalizedRef);
    const candidate = path.join(buildRoot, normalizedRef.slice("build/".length));
    const safe = resolveContainedExistingPath(buildRoot, candidate, {
      expectedKind: "file",
    });
    return {
      id: normalizedId,
      ref: normalizedRef,
      digest: sha256File(safe, { maxBytes: MAX_DEPENDENCY_BYTES }),
    };
  });
}

export function releaseDependencyReceiptsStable(buildRoot, dependencies) {
  try {
    return dependencies.length > 0 && dependencies.every((dependency) => {
      const current = captureReleaseDependencyReceipts(buildRoot, [{
        id: dependency.id,
        ref: dependency.ref,
      }])[0];
      return current.digest === dependency.digest;
    });
  } catch {
    return false;
  }
}

export function pairwiseAuditDependencyReceipts(buildRoot, report) {
  const corpusRef = report?.vectorCorpus?.report;
  const signoffRef = report?.reviewSignoff?.report;
  const snapshotRef = report?.reviewSignoff?.vectorCorpusSnapshot?.report;
  if (corpusRef !==
      "build/reports/secure-mesh-pairwise-content-vector-corpus.json" ||
    signoffRef !==
      "build/reports/secure-mesh-pairwise-content-review-signoff.json" ||
    !/^build\/reports\/secure-mesh-pairwise-content-vector-corpus-[a-f0-9]{16}\.json$/u
      .test(String(snapshotRef || ""))) {
    throw new Error("pairwise_release_dependencies_invalid");
  }
  const readDependency = (id, ref) => {
    const normalizedRef = safeBuildRef(ref);
    const safe = resolveContainedExistingPath(
      buildRoot,
      path.join(buildRoot, normalizedRef.slice("build/".length)),
      { expectedKind: "file" },
    );
    const snapshot = stableReadFileSnapshot(safe, {
      maxBytes: MAX_DEPENDENCY_BYTES,
    });
    return {
      receipt: { id, ref: normalizedRef, digest: sha256Buffer(snapshot.bytes) },
      payload: JSON.parse(snapshot.bytes.toString("utf8")),
    };
  };
  const corpus = readDependency("pairwise-vector-corpus", corpusRef);
  const signoff = readDependency("pairwise-review-signoff", signoffRef);
  const snapshot = readDependency(
    "pairwise-vector-corpus-snapshot",
    snapshotRef,
  );
  const binding = report?.vectorCorpus?.signoffBinding;
  const bindingJson = JSON.stringify(binding);
  if (corpus.payload?.schemaVersion !== report?.vectorCorpus?.schemaVersion ||
    corpus.payload?.corpusDigest !== report?.vectorCorpus?.corpusDigest ||
    JSON.stringify(corpus.payload?.signoffBinding) !== bindingJson ||
    snapshot.payload?.schemaVersion !== corpus.payload?.schemaVersion ||
    snapshot.payload?.corpusDigest !== corpus.payload?.corpusDigest ||
    JSON.stringify(snapshot.payload?.signoffBinding) !== bindingJson ||
    signoff.payload?.vectorCorpusReport !== corpusRef ||
    signoff.payload?.vectorCorpusSnapshotReport !== snapshotRef) {
    throw new Error("pairwise_release_dependency_binding_mismatch");
  }
  for (const field of [
    "corpusSchemaVersion",
    "corpusDigest",
    "corpusEntryCount",
    "corpusEntryIdsDigest",
    "sourceCheckCount",
    "sourceCheckIdsDigest",
    "nativeTestFilterCount",
    "nativeTestFiltersDigest",
    "sourceStateDigest",
    "producerSourceDigest",
  ]) {
    if (signoff.payload?.[field] !== binding?.[field]) {
      throw new Error("pairwise_release_signoff_binding_mismatch");
    }
  }
  const repoRoot = path.dirname(buildRoot);
  const authoritiesPath = resolveContainedExistingPath(
    path.join(repoRoot, "tools/scripts/config"),
    path.join(
      repoRoot,
      "tools/scripts/config/secure-mesh-pairwise-review-authorities.json",
    ),
    { expectedKind: "file" },
  );
  const authorities = JSON.parse(stableReadFileSnapshot(authoritiesPath, {
    maxBytes: 2 * 1024 * 1024,
  }).bytes.toString("utf8"));
  const verification = verifyPairwiseReviewSignoff({
    binding,
    signoff: signoff.payload,
    authorities,
  });
  if (verification.ready !== true || report?.reviewSignoff?.ok !== true ||
    report?.summary?.reviewSignoffReady !== true ||
    report?.summary?.reviewerSignatureVerified !== true ||
    report?.summary?.releaseOwnerSignatureVerified !== true) {
    throw new Error("pairwise_release_signoff_not_verified");
  }
  return [corpus.receipt, signoff.receipt, snapshot.receipt];
}
