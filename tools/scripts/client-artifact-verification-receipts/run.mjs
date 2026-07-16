import path from "node:path";
import process from "node:process";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "../lib/client-source-state-digest.mjs";
import { resolveContainedExistingPath } from "../lib/client-release-artifact-digest.mjs";
import {
  createReleaseClosureChallenge,
  releaseClosureChallengeDigest,
  requiredReleaseClosureChallenge,
  requiredReleaseClosureStartedAt,
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
import { parseArgs, selectedTargetIds } from "./cli.mjs";
import {
  canonicalReportRef,
  configPath,
  configRef,
  repoRoot,
} from "./constants.mjs";
import { ReceiptValidationError } from "./errors.mjs";
import { buildRelativeRef, invokeAndLoadTargetInput } from "./invoke/target-input.mjs";
import { buildCanonicalReceiptReport } from "./receipt/build.mjs";
import { runSelfTest } from "./self-test/runner.mjs";
import { readJson, requireValue, text } from "./util.mjs";
import { validateConfig } from "./validate-config.mjs";

export function runArtifactVerificationReceiptsCli(argv = process.argv.slice(2)) {
  try {
    const selfTestRequested = argv.includes("--self-test");
    const schemaFixtureRequested = argv.includes("--schema-fixture");
    if (!selfTestRequested && !schemaFixtureRequested) {
      removeContainedReportIfExists(
        path.join(repoRoot, "build"),
        buildRelativeRef(canonicalReportRef),
      );
    }
    const options = parseArgs(argv);
    const safeConfigPath = resolveContainedExistingPath(
      path.join(repoRoot, "tools/scripts/config"),
      configPath,
      { expectedKind: "file" },
    );
    if (options.selfTest) {
      const config = validateConfig(readJson(safeConfigPath));
      console.log(JSON.stringify(runSelfTest(config)));
      return;
    }
    if (options.schemaFixture) {
      const config = validateConfig(readJson(safeConfigPath));
      console.log(JSON.stringify(runSelfTest(config, { schemaFixture: true })));
      return;
    }
    const sourceStateDigest = clientSourceStateDigest(
      repoRoot,
      CANONICAL_CLIENT_SOURCE_ROOTS,
    );
    const policySnapshots = [
      captureSourceBoundJsonPolicy({
        allowedRoot: path.join(repoRoot, "tools/scripts/config"),
        filePath: safeConfigPath,
        id: "receipt-config",
        ref: configRef,
      }),
      captureSourceBoundJsonPolicy({
        allowedRoot: path.join(repoRoot, "tools"),
        filePath: path.join(repoRoot, "tools/client-version.json"),
        id: "client-version",
        ref: "tools/client-version.json",
      }),
    ];
    const config = validateConfig(policySnapshots[0].payload);
    const reportRef = canonicalReportRef;
    const relativeReportRef = buildRelativeRef(reportRef);
    const targets = selectedTargetIds(options, config);
    const clientVersion = policySnapshots[1].payload;
    const productVersion = text(clientVersion.productVersion);
    const buildNumber = clientVersion.buildNumber;
    const inheritedChallenge = text(process.env.LICO_CLIENT_RELEASE_CLOSURE_CHALLENGE);
    const closureChallenge = inheritedChallenge
      ? requiredReleaseClosureChallenge()
      : createReleaseClosureChallenge();
    const inheritedStartedAt = text(process.env.LICO_CLIENT_RELEASE_CLOSURE_STARTED_AT);
    const closureStartedAt = inheritedStartedAt
      ? new Date(requiredReleaseClosureStartedAt().milliseconds)
      : new Date();
    const closureChallengeDigest = releaseClosureChallengeDigest(closureChallenge);
    const targetInputs = Object.fromEntries(targets.map((targetId) => [
      targetId,
      invokeAndLoadTargetInput(
        config.targets[targetId],
        closureChallenge,
        closureStartedAt,
        { sourceStateDigest, productVersion, buildNumber },
      ),
    ]));
    requireValue(sourceBoundPolicySnapshotsStable(policySnapshots),
      "receipt_policy_changed_during_closure");
    requireValue(clientSourceStateDigest(repoRoot, config.sourceRoots) === sourceStateDigest,
      "receipt_source_changed_during_closure");
    const report = buildCanonicalReceiptReport({
      config,
      selectedTargetIds: targets,
      productVersion,
      buildNumber,
      sourceStateDigest,
      targetInputs,
      closureChallengeDigest,
      closureStartedAtMs: closureStartedAt.getTime(),
      policyBindings: publicPolicyBindings(policySnapshots),
    });
    atomicWriteReportJson(path.join(repoRoot, "build"), relativeReportRef, report);
    console.log(JSON.stringify({
      ok: report.ok,
      selectedTargetIds: report.selectedTargetIds,
      receiptCount: report.receipts.length,
      readyCount: report.receipts.filter((receipt) => receipt.ready).length,
      report: reportRef,
      privatePathsIncluded: false,
    }));
    if (!report.ok) process.exitCode = 1;
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      reason: error instanceof ReceiptValidationError
        ? error.code
        : "artifact_receipt_reducer_failed",
      privatePathsIncluded: false,
    }));
    process.exitCode = 1;
  }
}
