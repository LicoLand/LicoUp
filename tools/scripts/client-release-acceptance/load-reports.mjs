import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import {
  releaseClosureEnvironment,
  releaseInvocationEnvironment,
  releaseInvocationNonceDigest,
  createReleaseInvocationNonce,
} from "../lib/release-closure-challenge.mjs";
import {
  resolveContainedExistingPath,
  sha256Buffer,
  stableHashFileSnapshot,
  stableReadFileSnapshot,
} from "../lib/client-release-artifact-digest.mjs";
import {
  licoArcBadTowerAcceptanceProducer,
  licoArcBadTowerAcceptanceReportValid,
  licoArcBadTowerAcceptanceSchemaVersion,
} from "../lib/licoarc-badtower-acceptance-report.mjs";
import { repoRoot, maxJsonBytes, maxProducerBytes, SHA256 } from "./constants.mjs";
import { reportDependenciesReady, reportDependencyReceipts } from "./report-deps.mjs";
import {
  buildRelativeRef,
  closureRedactionSeedRefs,
  reportSelectedForTargets,
} from "./refs.mjs";
import { requireValue, text, readJson } from "./util.mjs";

export function runAndLoadApprovedReports(
  config,
  selectedTargets,
  artifactContext,
  closureStartedAtMs,
  closureChallenge,
  receiptConfig,
) {
  const reports = {};
  const receipts = [];
  const invocationNonceDigests = new Set();
  const selectedTargetIdSet = new Set(selectedTargets.map((target) => target.id));
  const closureReportRefs = closureRedactionSeedRefs(
    config,
    selectedTargets,
    artifactContext,
    receiptConfig,
  );
  const expectedClosureChallengeDigest =
    releaseClosureChallengeDigest(closureChallenge);
  const buildRoot = path.join(repoRoot, "build");
  const producerRoot = path.join(repoRoot, "tools/scripts");
  for (const id of config.reportOrder) {
    const spec = config.reports[id];
    if (!reportSelectedForTargets(spec, selectedTargetIdSet)) continue;
    const sourcePath = path.join(repoRoot, spec.producer);
    const reportRef = buildRelativeRef(spec.ref);
    const reportPath = path.join(buildRoot, reportRef);
    let sourceDigest = "";
    let payload = {};
    let reportDigest = "";
    let generatedAtMs = Number.NaN;
    let invocationStartedAtMs = Number.NaN;
    let producerExitCode = -1;
    let producerStable = false;
    let dependencies = [];
    const invocationNonce = createReleaseInvocationNonce();
    const expectedInvocationNonceDigest =
      releaseInvocationNonceDigest(invocationNonce);
    requireValue(SHA256.test(expectedInvocationNonceDigest),
      "client release producer invocation nonce digest is missing");
    requireValue(!invocationNonceDigests.has(expectedInvocationNonceDigest),
      "client release producer invocation nonce was reused");
    invocationNonceDigests.add(expectedInvocationNonceDigest);
    try {
      const safeSourcePath = resolveContainedExistingPath(producerRoot, sourcePath, {
        expectedKind: "file",
      });
      const sourceBefore = stableHashFileSnapshot(safeSourcePath, {
        maxBytes: maxProducerBytes,
      });
      sourceDigest = sourceBefore.digest;
      invocationStartedAtMs = Date.now();
      removeContainedReportIfExists(buildRoot, reportRef);
      const selectedClosureRefs = [...new Set([
        ...closureReportRefs,
        ...receipts.filter((receipt) => receipt.ok).map((receipt) =>
          config.reports[receipt.id]?.ref),
        ...receipts.filter((receipt) => receipt.ok).flatMap((receipt) =>
          (receipt.dependencies || []).map((dependency) => dependency.ref)),
        ...(Array.isArray(spec.redactionRefs) ? spec.redactionRefs : []),
      ].map(text).filter(Boolean))];
      const command = spawnSync(process.execPath, [
        safeSourcePath,
        ...(Array.isArray(spec.args) ? spec.args.map(String) : []),
      ], {
        cwd: repoRoot,
        env: {
          ...process.env,
          ...releaseClosureEnvironment(
            closureChallenge,
            new Date(closureStartedAtMs),
          ),
          ...releaseInvocationEnvironment(invocationNonce),
          LICO_CLIENT_RELEASE_SELECTED_TARGETS:
            [...selectedTargetIdSet].join(","),
          ...(id === "redaction" ? {
            LICO_CLIENT_RELEASE_CLOSURE_REPORT_REFS_JSON:
              JSON.stringify(selectedClosureRefs),
            LICO_SECURE_MESH_REDACTION_RUN_ID:
              expectedInvocationNonceDigest,
          } : {}),
        },
        encoding: "utf8",
        stdio: "pipe",
        maxBuffer: 16 * 1024 * 1024,
        timeout: Number(spec.timeoutMs || 900_000)
      });
      producerExitCode = Number.isInteger(command.status) ? command.status : -1;
      const sourceAfter = stableHashFileSnapshot(safeSourcePath, {
        maxBytes: maxProducerBytes,
      });
      producerStable = sourceBefore.digest === sourceAfter.digest &&
        sourceBefore.device === sourceAfter.device &&
        sourceBefore.inode === sourceAfter.inode;
      if (producerExitCode === 0) {
        const safeReportPath = resolveContainedExistingPath(buildRoot, reportPath, {
          expectedKind: "file",
        });
        const reportSnapshot = stableReadFileSnapshot(safeReportPath, {
          maxBytes: maxJsonBytes,
        });
        payload = JSON.parse(reportSnapshot.bytes.toString("utf8"));
        reportDigest = sha256Buffer(reportSnapshot.bytes);
        const directFreshOutput = directLicoArcBadTowerOutput(payload, spec);
        generatedAtMs = directFreshOutput
          ? reportSnapshot.mtimeMs
          : Date.parse(String(payload.generatedAt || payload.checkedAt || ""));
        dependencies = reportDependencyReceipts(id, payload, buildRoot);
      }
    } catch {
      payload = {};
    }
    const validation = validateProducedReportReceipt({
      payload,
      spec,
      sourceDigest,
      reportDigest,
      producerExitCode,
      producerStable,
      generatedAtMs,
      invocationStartedAtMs,
      closureStartedAtMs,
      expectedClosureChallengeDigest,
      expectedInvocationNonceDigest,
      maxClockSkewMs: Number(config.maxClockSkewMs || 0),
      nowMs: Date.now(),
      dependenciesReady: reportDependenciesReady(id, dependencies),
      directFreshOutput: directLicoArcBadTowerOutput(payload, spec),
    });
    reports[id] = validation.ok ? payload : {};
    receipts.push({
      id,
      ok: validation.ok,
      schemaVersion: text(payload.schemaVersion || spec.schemaVersion),
      producer: validation.producerMatched ? spec.producer : "producer-mismatch",
      producerExitCode,
      sourceDigest,
      reportDigest,
      freshnessReady: validation.freshnessReady,
      closureChallengeBound: validation.closureChallengeBound,
      invocationNonceDigest: expectedInvocationNonceDigest,
      dependencies,
    });
    if (validation.ok) {
      closureReportRefs.push(spec.ref);
      if (Array.isArray(spec.redactionRefs)) {
        closureReportRefs.push(...spec.redactionRefs);
      }
    }
  }
  return {
    reports,
    receipts,
    ok: receipts.length > 0 && receipts.every((item) => item.ok)
  };
}

export function validateProducedReportReceipt({
  payload,
  spec,
  sourceDigest,
  reportDigest,
  producerExitCode,
  producerStable,
  generatedAtMs,
  invocationStartedAtMs,
  closureStartedAtMs,
  expectedClosureChallengeDigest,
  expectedInvocationNonceDigest,
  maxClockSkewMs,
  nowMs,
  dependenciesReady = true,
  directFreshOutput = false,
}) {
  const directAcceptance =
    directFreshOutput === true &&
    directLicoArcBadTowerOutput(payload, spec);
  const producer = directAcceptance
    ? spec.producer
    : text(payload?.verifier || payload?.generatedBy);
  const producerMatched = producer === spec.producer;
  const closureChallengeBound = directAcceptance ||
    payload?.closureChallengeDigest === expectedClosureChallengeDigest;
  const invocationNonceBound = directAcceptance ||
    payload?.invocationNonceDigest === expectedInvocationNonceDigest;
  const freshnessReady = Number.isFinite(generatedAtMs) &&
    Number.isFinite(invocationStartedAtMs) &&
    invocationStartedAtMs >= closureStartedAtMs - maxClockSkewMs &&
    generatedAtMs >= invocationStartedAtMs - maxClockSkewMs &&
    generatedAtMs >= closureStartedAtMs - maxClockSkewMs &&
    generatedAtMs <= nowMs + maxClockSkewMs;
  const ok = producerExitCode === 0 && producerStable === true &&
    payload?.schemaVersion === spec.schemaVersion &&
    producerMatched &&
    closureChallengeBound && invocationNonceBound &&
    SHA256.test(sourceDigest) &&
    SHA256.test(reportDigest) &&
    freshnessReady && dependenciesReady === true;
  return {
    ok,
    producerMatched,
    freshnessReady,
    closureChallengeBound,
    invocationNonceBound,
  };
}

function directLicoArcBadTowerOutput(payload, spec) {
  return spec?.schemaVersion === licoArcBadTowerAcceptanceSchemaVersion &&
    spec?.producer === licoArcBadTowerAcceptanceProducer &&
    licoArcBadTowerAcceptanceReportValid(payload);
}
