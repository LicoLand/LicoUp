import path from "node:path";
import {
  resolveContainedExistingPath,
  sha256File,
} from "../../lib/client-release-artifact-digest.mjs";
import { maxJsonBytes, maxProducerBytes, repoRoot, SHA256 } from "../constants.mjs";
import { requireValue, text } from "../util.mjs";
import { digestBindingStable } from "./stability.mjs";

export function verifyClosureEvidenceDigests(
  config,
  produced,
  artifactContext,
  targetConfig,
) {
  try {
    const buildRoot = path.join(repoRoot, "build");
    const producerRoot = path.join(repoRoot, "tools/scripts");
    for (const receipt of produced.receipts) {
      if (receipt.ok !== true) return false;
      const spec = config.reports[receipt.id];
      const reportPath = resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.ref),
        { expectedKind: "file" },
      );
      const producerPath = resolveContainedExistingPath(
        producerRoot,
        path.join(repoRoot, spec.producer),
        { expectedKind: "file" },
      );
      if (!digestBindingStable(receipt.reportDigest, sha256File(reportPath, {
        maxBytes: maxJsonBytes,
      })) || !digestBindingStable(receipt.sourceDigest, sha256File(producerPath, {
        maxBytes: maxProducerBytes,
      }))) {
        return false;
      }
      for (const dependency of receipt.dependencies || []) {
        const dependencyPath = resolveContainedExistingPath(
          buildRoot,
          path.join(repoRoot, dependency.ref),
          { expectedKind: "file" },
        );
        if (!digestBindingStable(
          dependency.digest,
          sha256File(dependencyPath, { maxBytes: maxJsonBytes }),
        )) return false;
      }
    }

    const canonicalReportPath = resolveContainedExistingPath(
      buildRoot,
      path.join(repoRoot, config.artifactReceipt.ref),
      { expectedKind: "file" },
    );
    const canonicalProducerPath = resolveContainedExistingPath(
      producerRoot,
      path.join(repoRoot, config.artifactReceipt.producer),
      { expectedKind: "file" },
    );
    if (!digestBindingStable(
      artifactContext.receiptReportDigest,
      sha256File(canonicalReportPath, { maxBytes: maxJsonBytes }),
    ) || !digestBindingStable(
      artifactContext.receiptSourceDigest,
      sha256File(canonicalProducerPath, { maxBytes: maxProducerBytes }),
    )) return false;

    for (const receipt of artifactContext.payload.receipts || []) {
      const target = targetConfig.targets?.[receipt.targetId];
      if (!target) return false;
      const evidencePath = resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, target.evidenceRef),
        { expectedKind: "file" },
      );
      const evidenceProducerPath = resolveContainedExistingPath(
        producerRoot,
        path.join(repoRoot, target.evidenceProducer),
        { expectedKind: "file" },
      );
      if (!digestBindingStable(
        receipt.evidenceReportDigest,
        sha256File(evidencePath, { maxBytes: maxJsonBytes }),
      ) || !digestBindingStable(
        receipt.evidenceProducerSourceDigest,
        sha256File(evidenceProducerPath, { maxBytes: maxProducerBytes }),
      )) return false;
      for (const dependency of receipt.dependencies || []) {
        const dependencyPath = resolveContainedExistingPath(
          buildRoot,
          path.join(repoRoot, dependency.ref),
          { expectedKind: "file" },
        );
        if (!digestBindingStable(
          dependency.digest,
          sha256File(dependencyPath, { maxBytes: maxJsonBytes }),
        )) return false;
      }
    }
    return true;
  } catch {
    return false;
  }
}
