import path from "node:path";
import process from "node:process";
import {
  selectClientReleaseTargets,
  validateClientReleaseTargetCatalog,
} from "../lib/client-release-targets.mjs";
import {
  resolveContainedExistingPath,
  stableHashFileSnapshot,
} from "../lib/client-release-artifact-digest.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "../lib/client-source-state-digest.mjs";
import {
  captureLicoArcBadTowerCandidateBinding,
  LICOARC_BADTOWER_CANDIDATE_BINDING_KEY,
  licoArcBadTowerCandidateSnapshotsMatch,
} from "../lib/licoarc-badtower-candidate-binding.mjs";
import {
  createReleaseClosureChallenge,
  releaseClosureChallengeDigest,
} from "../lib/release-closure-challenge.mjs";
import {
  atomicWriteReportJson,
  removeContainedReportIfExists,
} from "../lib/safe-report-io.mjs";
import {
  captureSourceBoundJsonPolicy,
  publicPolicyBindings,
  sourceBoundPolicySnapshotsStable,
} from "../lib/source-bound-policy-snapshot.mjs";
import { materializeArtifactReceipts } from "./artifacts/materialize.mjs";
import {
  artifactBindingMapsEqual,
  artifactInputStatesEqual,
  captureSelectedArtifactInputState,
  verifySelectedArtifacts,
} from "./artifacts/selected.mjs";
import { verifyClosureEvidenceDigests } from "./artifacts/digests.mjs";
import { stableProducerSnapshotMatched } from "./artifacts/stability.mjs";
import { parseReleaseAcceptanceArgs } from "./cli.mjs";
import { configPath, outputPath, repoRoot } from "./constants.mjs";
import { runAndLoadApprovedReports } from "./load-reports.mjs";
import { validateReleaseSelectionPreflight } from "./preflight.mjs";
import { assertAcceptancePrivacy } from "./privacy.mjs";
import { reduceClientReleaseAcceptance } from "./reduce.mjs";
import { runSelfTest } from "./self-test/runner.mjs";
import { runSupportMatrixCheck } from "./support-matrix.mjs";
import { selectedTargetIds } from "./targets.mjs";
import { requireValue, text } from "./util.mjs";
import { validateConfig } from "./validate-config.mjs";
import { validateAcceptanceReport } from "./validate-report.mjs";

export function runClientReleaseAcceptanceCli(argv = process.argv.slice(2)) {
  const parsed = parseReleaseAcceptanceArgs(argv);
  const { args } = parsed;
  try {
    if (parsed.selfTest) {
      requireValue(args.size === 1, "client release self-test arguments are invalid");
      console.log(JSON.stringify(runSelfTest()));
      return;
    }
    if (parsed.schemaFixture) {
      requireValue(args.size === 1, "client release schema fixture arguments are invalid");
      console.log(JSON.stringify(runSelfTest({ schemaFixture: true })));
      return;
    }
    removeContainedReportIfExists(
      path.join(repoRoot, "build"),
      path.relative(path.join(repoRoot, "build"), outputPath),
    );
    requireValue(args.size === 0, "client release acceptance arguments are invalid");
    const sourceStateDigest = clientSourceStateDigest(
      repoRoot,
      CANONICAL_CLIENT_SOURCE_ROOTS,
    );
    const stationCandidateBefore =
      captureLicoArcBadTowerCandidateBinding({
        clientCandidateDigest: sourceStateDigest,
      });
    const safeConfigPath = resolveContainedExistingPath(
      path.join(repoRoot, "tools/scripts/config"),
      configPath,
      { expectedKind: "file" },
    );
    const targetCatalogPath = resolveContainedExistingPath(
      path.join(repoRoot, "tools"),
      path.join(repoRoot, "tools/client-release-targets.json"),
      { expectedKind: "file" },
    );
    const receiptConfigPath = resolveContainedExistingPath(
      path.join(repoRoot, "tools/scripts/config"),
      path.join(
        repoRoot,
        "tools/scripts/config/client-artifact-verification-receipts.json",
      ),
      { expectedKind: "file" },
    );
    const clientVersionPath = resolveContainedExistingPath(
      path.join(repoRoot, "tools"),
      path.join(repoRoot, "tools/client-version.json"),
      { expectedKind: "file" },
    );
    const policySnapshots = [
      captureSourceBoundJsonPolicy({
        allowedRoot: path.join(repoRoot, "tools/scripts/config"),
        filePath: safeConfigPath,
        id: "acceptance-config",
        ref: "tools/scripts/config/client-release-acceptance.json",
      }),
      captureSourceBoundJsonPolicy({
        allowedRoot: path.join(repoRoot, "tools"),
        filePath: targetCatalogPath,
        id: "target-catalog",
        ref: "tools/client-release-targets.json",
      }),
      captureSourceBoundJsonPolicy({
        allowedRoot: path.join(repoRoot, "tools/scripts/config"),
        filePath: receiptConfigPath,
        id: "receipt-config",
        ref: "tools/scripts/config/client-artifact-verification-receipts.json",
      }),
      captureSourceBoundJsonPolicy({
        allowedRoot: path.join(repoRoot, "tools"),
        filePath: clientVersionPath,
        id: "client-version",
        ref: "tools/client-version.json",
      }),
    ];
    const policyBindings = publicPolicyBindings(policySnapshots);
    const config = policySnapshots[0].payload;
    validateConfig(config);
    const targetCatalogBefore = policySnapshots[1];
    const catalog = validateClientReleaseTargetCatalog(policySnapshots[1].payload);
    const requestedTargetIds = selectedTargetIds(
      catalog,
      config.releaseTargetAuthority.selectedTargetIds,
    );
    const receiptConfig = policySnapshots[2].payload;
    validateReleaseSelectionPreflight({
      catalog,
      config,
      receiptConfig,
      selectedTargetIds: requestedTargetIds,
    });
    const selectedTargets = selectClientReleaseTargets(catalog, requestedTargetIds);
    const clientVersion = policySnapshots[3].payload;
    const productVersion = text(clientVersion.productVersion);
    requireValue(productVersion && Number.isInteger(clientVersion.buildNumber) &&
      clientVersion.buildNumber > 0, "client version manifest is invalid");
    const closureStartedAtMs = Date.now();
    const closureChallenge = createReleaseClosureChallenge();
    const receiptPolicyBindings = policyBindings.filter((binding) =>
      ["receipt-config", "client-version"].includes(binding.id));
    const artifactReceiptContext = materializeArtifactReceipts(
      config,
      selectedTargets,
      productVersion,
      clientVersion.buildNumber,
      sourceStateDigest,
      closureStartedAtMs,
      closureChallenge,
      receiptPolicyBindings,
    );
    const produced = runAndLoadApprovedReports(
      config,
      selectedTargets,
      artifactReceiptContext,
      closureStartedAtMs,
      closureChallenge,
      receiptConfig,
    );
    const initialArtifactInputState = captureSelectedArtifactInputState(
      config,
      selectedTargets,
    );
    const initialArtifactBindings = verifySelectedArtifacts(
      config,
      selectedTargets,
      clientVersion,
      artifactReceiptContext,
    );
    const supportMatrix = runSupportMatrixCheck(requestedTargetIds);
    const closureEvidenceDigestsStable = verifyClosureEvidenceDigests(
      config,
      produced,
      artifactReceiptContext,
      receiptConfig,
    );
    const selectedArtifactBindings = verifySelectedArtifacts(
      config,
      selectedTargets,
      clientVersion,
      artifactReceiptContext,
    );
    const finalArtifactInputState = captureSelectedArtifactInputState(
      config,
      selectedTargets,
    );
    const artifactInputsStable = artifactBindingMapsEqual(
      initialArtifactBindings,
      selectedArtifactBindings,
      selectedTargets,
    ) && artifactInputStatesEqual(
      initialArtifactInputState,
      finalArtifactInputState,
    );
    const supportMatrixStable = supportMatrix.ready === true &&
      supportMatrix.snapshots.every((entry) => stableProducerSnapshotMatched(
        entry.snapshot,
        stableHashFileSnapshot(entry.path, { maxBytes: 4 * 1024 * 1024 }),
      ));
    const targetCatalogAfter = stableHashFileSnapshot(targetCatalogPath, {
      maxBytes: 4 * 1024 * 1024,
    });
    const targetCatalogStable = stableProducerSnapshotMatched(
      targetCatalogBefore,
      targetCatalogAfter,
    );
    const policyInputsStable = sourceBoundPolicySnapshotsStable(policySnapshots);
    const sourceStateStable =
      clientSourceStateDigest(repoRoot, config.sourceRoots) === sourceStateDigest;
    const stationCandidateAfter =
      captureLicoArcBadTowerCandidateBinding({
        clientCandidateDigest: sourceStateDigest,
      });
    const candidateInputsStable =
      licoArcBadTowerCandidateSnapshotsMatch(
        stationCandidateBefore,
        stationCandidateAfter,
      );
    const artifactBindings = {
      ...selectedArtifactBindings,
      [LICOARC_BADTOWER_CANDIDATE_BINDING_KEY]:
        stationCandidateAfter.bindings,
    };
    const inputIntegrity = {
      ok: produced.ok && artifactReceiptContext.ok === true &&
        closureEvidenceDigestsStable && artifactInputsStable && sourceStateStable &&
        supportMatrixStable && targetCatalogStable && policyInputsStable &&
        candidateInputsStable,
      productVersion,
      sourceStateDigest,
      sourceStateStable,
      artifactInputsStable,
      candidateInputsStable,
      supportMatrixStable,
      targetCatalogStable,
      policyInputsStable,
      closureEvidenceDigestsStable,
      closureStartedAt: new Date(closureStartedAtMs).toISOString(),
      closureChallengeDigest: releaseClosureChallengeDigest(closureChallenge),
      supportMatrixDigest: supportMatrix.snapshot.digest,
      targetCatalogDigest: targetCatalogBefore.digest,
      policyBindings,
      reports: produced.receipts,
    };
    const report = reduceClientReleaseAcceptance({
      selectedTargets,
      supportMatrixReady: supportMatrixStable,
      reports: produced.reports,
      inputIntegrity,
      artifactBindings,
    });
    validateAcceptanceReport(report);
    assertAcceptancePrivacy(report);
    atomicWriteReportJson(
      path.join(repoRoot, "build"),
      path.relative(path.join(repoRoot, "build"), outputPath),
      report,
    );
    console.log(JSON.stringify({
      ok: report.ok,
      githubReleaseReady: report.githubReleaseReady,
      selectedTargetIds: report.selectedTargetIds,
      blockerCount: report.blockers.length,
      report: path.relative(repoRoot, outputPath),
    }));
    if (!report.ok) process.exitCode = 1;
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      error: args.has("--self-test")
        ? text(error instanceof Error ? error.message : error).slice(0, 240)
        : "client_release_acceptance_failed",
    }));
    process.exitCode = 1;
  }
}
