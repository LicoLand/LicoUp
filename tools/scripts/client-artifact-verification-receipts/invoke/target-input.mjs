import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import {
  artifactTreeDigest,
  resolveContainedExistingPath,
  sha256Buffer,
  sha256File,
  stableHashFileSnapshot,
  stableReadFileSnapshot,
} from "../../lib/client-release-artifact-digest.mjs";
import {
  createReleaseInvocationNonce,
  releaseClosureEnvironment,
  releaseInvocationEnvironment,
  releaseInvocationNonceDigest,
} from "../../lib/release-closure-challenge.mjs";
import { removeContainedReportIfExists } from "../../lib/safe-report-io.mjs";
import {
  maxArtifactFileBytes,
  maxJsonBytes,
  maxProducerBytes,
  repoRoot,
} from "../constants.mjs";
import { requireValue, text } from "../util.mjs";
import { distributionLineageReady } from "./lineage.mjs";

export function buildRelativeRef(ref) {
  const normalized = text(ref).replaceAll("\\", "/");
  requireValue(normalized.startsWith("build/") && !normalized.includes("../"),
    "receipt_build_ref_invalid");
  return normalized.slice("build/".length);
}

export function invokeAndLoadTargetInput(
  spec,
  closureChallenge,
  closureStartedAt,
  { sourceStateDigest, productVersion, buildNumber },
) {
  const buildRoot = path.join(repoRoot, "build");
  const toolsRoot = path.join(repoRoot, "tools/scripts");
  const artifactPath = path.join(repoRoot, spec.artifactRef);
  const evidenceRef = buildRelativeRef(spec.evidenceRef);
  const evidencePath = path.join(buildRoot, evidenceRef);
  const producerPath = path.join(repoRoot, spec.evidenceProducer);
  const invocationScript = path.join(repoRoot, spec.evidenceInvocation.script);
  const input = {
    payload: {},
    artifactDigest: "",
    artifactManifestDigest: "",
    artifactLineageReady: false,
    evidenceArtifactDigest: "",
    evidenceProducerSourceDigest: "",
    evidenceReportDigest: "",
    invocationStartedAtMs: Number.NaN,
    invocationExitCode: -1,
    expectedInvocationNonceDigest: "",
    producerStable: false,
  };
  const invocationNonce = createReleaseInvocationNonce();
  input.expectedInvocationNonceDigest = releaseInvocationNonceDigest(invocationNonce);
  try {
    removeContainedReportIfExists(buildRoot, evidenceRef);
    const safeProducerPath = resolveContainedExistingPath(
      toolsRoot,
      producerPath,
      { expectedKind: "file" },
    );
    const safeInvocationScript = resolveContainedExistingPath(
      toolsRoot,
      invocationScript,
      { expectedKind: "file" },
    );
    const producerBefore = stableHashFileSnapshot(safeProducerPath, {
      maxBytes: maxProducerBytes,
    });
    const invocationBefore = stableHashFileSnapshot(safeInvocationScript, {
      maxBytes: maxProducerBytes,
    });
    input.invocationStartedAtMs = Date.now();
    const invocationArgs = spec.evidenceInvocation.args.map((arg) => {
      const replacements = {
        "{artifactRef}": spec.artifactRef,
        "{distributionManifestRef}": spec.distributionManifestRef,
        "{evidenceRef}": spec.evidenceRef,
        "{sourceStateDigest}": sourceStateDigest,
      };
      const value = replacements[arg] ?? String(arg);
      requireValue(!value.includes("{"), "receipt_evidence_argument_unresolved");
      return value;
    });
    const command = spawnSync(process.execPath, [
      safeInvocationScript,
      ...invocationArgs,
    ], {
      cwd: repoRoot,
      env: {
        ...process.env,
        ...releaseClosureEnvironment(closureChallenge, closureStartedAt),
        ...releaseInvocationEnvironment(invocationNonce),
        ...(spec.platform === "linux" ? {
          LICO_LINUX_VM_REPORT_ROOT: path.dirname(evidencePath),
        } : {}),
      },
      encoding: "utf8",
      stdio: "pipe",
      maxBuffer: 16 * 1024 * 1024,
      timeout: spec.evidenceInvocation.timeoutMs,
    });
    input.invocationExitCode = Number.isInteger(command.status) ? command.status : -1;
    const producerAfter = stableHashFileSnapshot(safeProducerPath, {
      maxBytes: maxProducerBytes,
    });
    const invocationAfter = stableHashFileSnapshot(safeInvocationScript, {
      maxBytes: maxProducerBytes,
    });
    input.producerStable = producerBefore.digest === producerAfter.digest &&
      producerBefore.device === producerAfter.device &&
      producerBefore.inode === producerAfter.inode &&
      invocationBefore.digest === invocationAfter.digest &&
      invocationBefore.device === invocationAfter.device &&
      invocationBefore.inode === invocationAfter.inode;
    input.evidenceProducerSourceDigest = producerBefore.digest;
    if (input.invocationExitCode !== 0) return input;
    const safeEvidencePath = resolveContainedExistingPath(buildRoot, evidencePath, {
      expectedKind: "file",
    });
    const evidenceSnapshot = stableReadFileSnapshot(safeEvidencePath, {
      maxBytes: maxJsonBytes,
    });
    input.payload = JSON.parse(evidenceSnapshot.bytes.toString("utf8"));
    input.evidenceReportDigest = sha256Buffer(evidenceSnapshot.bytes);
    if (existsSync(artifactPath)) {
      const safeArtifact = resolveContainedExistingPath(buildRoot, artifactPath, {
        expectedKind: spec.artifactDigestKind === "tree" ? "directory" : "file",
      });
      input.artifactDigest = spec.artifactDigestKind === "tree"
        ? artifactTreeDigest(safeArtifact)
        : sha256File(safeArtifact, { maxBytes: maxArtifactFileBytes });
    }
    if (text(spec.evidenceArtifactRef)) {
      const evidenceArtifactPath = path.join(repoRoot, spec.evidenceArtifactRef);
      const safeEvidenceArtifact = resolveContainedExistingPath(
        buildRoot,
        evidenceArtifactPath,
        {
          expectedKind: spec.evidenceArtifactDigestKind === "tree"
            ? "directory"
            : "file",
        },
      );
      input.evidenceArtifactDigest = spec.evidenceArtifactDigestKind === "tree"
        ? artifactTreeDigest(safeEvidenceArtifact)
        : sha256File(safeEvidenceArtifact, { maxBytes: maxArtifactFileBytes });
    }
    if (text(spec.distributionManifestRef)) {
      const manifestPath = resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.distributionManifestRef),
        { expectedKind: "file" },
      );
      const manifestSnapshot = stableReadFileSnapshot(manifestPath, {
        maxBytes: maxJsonBytes,
      });
      const manifest = JSON.parse(manifestSnapshot.bytes.toString("utf8"));
      input.artifactManifestDigest = sha256Buffer(manifestSnapshot.bytes);
      input.artifactLineageReady = distributionLineageReady(spec, manifest, {
        artifactPath,
        artifactDigest: input.artifactDigest,
        evidenceArtifactDigest: input.evidenceArtifactDigest,
        sourceStateDigest,
        productVersion,
        buildNumber,
      });
    }
  } catch {
    return input;
  }
  return input;
}
