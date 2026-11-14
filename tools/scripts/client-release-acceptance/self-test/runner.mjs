import path from "node:path";
import process from "node:process";
import {
  loadClientReleaseTargetCatalog,
} from "../../lib/client-release-targets.mjs";
import { CLIENT_GATE_LANES } from "../../client-gate-policy.mjs";
import {
  selectedReleaseBlockingSupportReady,
  validateClientSupportMatrix,
} from "../../client-support-matrix.mjs";
import {
  artifactBindingMapsEqual,
  artifactInputStatesEqual,
} from "../artifacts/selected.mjs";
import {
  digestBindingStable,
  stableProducerSnapshotMatched,
} from "../artifacts/stability.mjs";
import { configPath, repoRoot } from "../constants.mjs";
import { validateProducedReportReceipt } from "../load-reports.mjs";
import { validateReleaseSelectionPreflight } from "../preflight.mjs";
import { assertAcceptancePrivacy } from "../privacy.mjs";
import { reduceClientReleaseAcceptance } from "../reduce.mjs";
import { closureRedactionSeedRefs } from "../refs.mjs";
import { sanitizeArtifactBinding } from "../sanitize-binding.mjs";
import { selectedTargetIds } from "../targets.mjs";
import { readJson, requireValue } from "../util.mjs";

export function runSelfTest({ schemaFixture = false } = {}) {
  const selected = [
    { id: "macos-direct-arm64", platform: "macos", arch: "arm64", supported: true, releaseSupported: true }
  ];
  const readyIntegrity = {
    ok: true,
    productVersion: "1.2.3",
    sourceStateDigest: `sha256:${"a".repeat(64)}`,
    sourceStateStable: true,
    artifactInputsStable: true,
    supportMatrixStable: true,
    targetCatalogStable: true,
    policyInputsStable: true,
    closureEvidenceDigestsStable: true,
    closureStartedAt: "2030-01-01T00:00:00.000Z",
    closureChallengeDigest: `sha256:${"9".repeat(64)}`,
    supportMatrixDigest: `sha256:${"8".repeat(64)}`,
    targetCatalogDigest: `sha256:${"7".repeat(64)}`,
    policyBindings: [
      ["acceptance-config", "tools/scripts/config/client-release-acceptance.json", "1"],
      ["target-catalog", "tools/client-release-targets.json", "2"],
      ["receipt-config", "tools/scripts/config/client-artifact-verification-receipts.json", "3"],
      ["client-version", "tools/client-version.json", "4"],
    ].map(([id, ref, digit]) => ({ id, ref, digest: `sha256:${digit.repeat(64)}` })),
    reports: [{
      id: "artifact-receipt",
      ok: true,
      schemaVersion: "licomesh.client-artifact-verification-receipts.v3",
      producer: "tools/scripts/client-artifact-verification-receipts.mjs",
      producerExitCode: 0,
      sourceDigest: `sha256:${"1".repeat(64)}`,
      reportDigest: `sha256:${"2".repeat(64)}`,
      freshnessReady: true,
      closureChallengeBound: true,
      invocationNonceDigest: "",
      dependencies: [],
    }],
  };
  const readyArtifactFor = (targetId, artifactKind, digestDigit) => ({
    targetId,
    productVersion: "1.2.3",
    artifactKind,
    artifactDigest: `sha256:${digestDigit.repeat(64)}`,
    runtimeExecutableDigest: `sha256:${digestDigit.repeat(64)}`,
    artifactEvidenceReportDigest: `sha256:${"d".repeat(64)}`,
    artifactEvidenceInvocationNonceDigest: `sha256:${"e".repeat(64)}`,
    versionReady: true,
    targetReady: true,
    consumerIntegritySignatureReady: false,
    publicVerificationMaterialReady: false,
    consumerVerificationReady: true,
    platformSecurityReady: true,
    consumerIntegritySignatureKind: "platform-local-validation",
    installReceiptReady: true,
    receiptProvenanceReady: true,
    receiptProducer: "tools/scripts/fixture-receipt.mjs",
    receiptSourceDigest: `sha256:${"6".repeat(64)}`,
    receiptReportDigest: `sha256:${"7".repeat(64)}`,
    ready: true
  });
  const readyArtifact = {
    "macos-direct-arm64": readyArtifactFor(
      "macos-direct-arm64",
      "macos-distribution-archive",
      "3",
    ),
  };
  const base = {
    selectedTargets: selected,
    supportMatrixReady: true,
    inputIntegrity: readyIntegrity,
    artifactBindings: readyArtifact
  };
  const externalAndUnselected = reduceClientReleaseAcceptance({ ...base, reports: {} });
  if (schemaFixture) return externalAndUnselected;
  requireValue(externalAndUnselected.githubReleaseReady,
    `macOS selected target must pass on Desktop-owned evidence: ${externalAndUnselected.blockers.join(",")}`);
  const missingSelected = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      "macos-direct-arm64": {
        ...readyArtifact["macos-direct-arm64"],
        platformSecurityReady: false,
        ready: false,
      },
    },
  });
  requireValue(!missingSelected.githubReleaseReady &&
    missingSelected.blockers.some((item) =>
      item.startsWith("selected_platform_security_not_ready:")),
    "selected missing evidence must block");
  const forgedInput = reduceClientReleaseAcceptance({
    ...base,
    inputIntegrity: { ...readyIntegrity, ok: false },
  });
  requireValue(!forgedInput.githubReleaseReady &&
    forgedInput.blockers.includes("release_input_provenance_not_ready"),
    "editable report booleans without current producer provenance must fail closed");
  const missingArtifact = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {},
  });
  requireValue(!missingArtifact.githubReleaseReady &&
    missingArtifact.blockers.some((item) =>
      item.startsWith("selected_target_exact_artifact_not_ready:")),
    "missing exact selected-target artifact must fail closed");
  const unsignedArtifact = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      "macos-direct-arm64": {
        ...readyArtifact["macos-direct-arm64"],
        consumerVerificationReady: false,
        ready: false,
      },
    },
  });
  requireValue(!unsignedArtifact.githubReleaseReady &&
    unsignedArtifact.blockers.some((item) =>
      item.startsWith("selected_target_consumer_verification_not_ready:")),
    "artifact without consumer verification must fail closed");
  const missingReceipt = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      "macos-direct-arm64": {
        ...readyArtifact["macos-direct-arm64"],
        installReceiptReady: false,
        receiptProvenanceReady: false,
        ready: false,
      },
    },
  });
  requireValue(!missingReceipt.githubReleaseReady &&
    missingReceipt.blockers.some((item) =>
      item.startsWith("selected_target_install_receipt_not_ready:")),
    "artifact without exact local install receipt must fail closed");
  const distributionGuidance = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      "macos-direct-arm64": {
        ...readyArtifact["macos-direct-arm64"],
        nonBlockingDistributionStatus: "ready",
      },
    },
  });
  requireValue(distributionGuidance.githubReleaseReady,
    "distribution guidance must not block GitHub release readiness");
  const receiptChallengeDigest = `sha256:${"1".repeat(64)}`;
  const receiptNonceDigest = `sha256:${"2".repeat(64)}`;
  const receiptFixture = {
    payload: {
      schemaVersion: "fixture.v1",
      verifier: "tools/scripts/fixture.mjs",
      closureChallengeDigest: receiptChallengeDigest,
      invocationNonceDigest: receiptNonceDigest,
    },
    spec: { schemaVersion: "fixture.v1", producer: "tools/scripts/fixture.mjs" },
    sourceDigest: `sha256:${"4".repeat(64)}`,
    reportDigest: `sha256:${"5".repeat(64)}`,
    producerExitCode: 0,
    producerStable: true,
    generatedAtMs: 10_001,
    invocationStartedAtMs: 10_000,
    closureStartedAtMs: 10_000,
    expectedClosureChallengeDigest: receiptChallengeDigest,
    expectedInvocationNonceDigest: receiptNonceDigest,
    maxClockSkewMs: 5,
    nowMs: 10_010
  };
  requireValue(validateProducedReportReceipt(receiptFixture).ok,
    "current approved producer receipt must validate");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    payload: { ...receiptFixture.payload, verifier: "tools/scripts/forged.mjs" }
  }).ok, "forged producer identity must fail closed");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    generatedAtMs: 9_000,
  }).ok, "stale producer output must fail closed");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    producerExitCode: 1,
  }).ok, "failed producer must not reuse an old green report");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    producerStable: false,
  }).ok, "mutated producer source must fail closed");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    payload: {
      ...receiptFixture.payload,
      invocationNonceDigest: `sha256:${"3".repeat(64)}`,
    },
  }).ok, "producer output with the wrong invocation nonce must fail closed");
  requireValue(!validateProducedReportReceipt({
    ...receiptFixture,
    reportDigest: "sha256:editable-json"
  }).ok, "invalid report input digest must fail closed");
  requireValue(digestBindingStable(
    `sha256:${"a".repeat(64)}`,
    `sha256:${"a".repeat(64)}`,
  ) && !digestBindingStable(
    `sha256:${"a".repeat(64)}`,
    `sha256:${"b".repeat(64)}`,
  ), "replaced physical evidence digest must fail closed");
  const producerSnapshot = {
    digest: `sha256:${"c".repeat(64)}`,
    device: 1,
    inode: 2,
  };
  requireValue(stableProducerSnapshotMatched(
    producerSnapshot,
    { ...producerSnapshot },
  ) && !stableProducerSnapshotMatched(
    producerSnapshot,
    { ...producerSnapshot, inode: 3 },
  ), "replaced canonical receipt producer must fail closed");
  const artifactBindingFixture = {
    "macos-direct-arm64": sanitizeArtifactBinding({
      targetId: "macos-direct-arm64",
      artifactDigest: `sha256:${"a".repeat(64)}`,
    }),
  };
  requireValue(artifactBindingMapsEqual(
    artifactBindingFixture,
    structuredClone(artifactBindingFixture),
    [{ id: "macos-direct-arm64" }],
  ) && !artifactBindingMapsEqual(
    artifactBindingFixture,
    {
      "macos-direct-arm64": {
        ...artifactBindingFixture["macos-direct-arm64"],
        artifactDigest: `sha256:${"b".repeat(64)}`,
      },
    },
    [{ id: "macos-direct-arm64" }],
  ), "replaced final artifact input must fail closed");
  requireValue(artifactInputStatesEqual(
    { macos: { artifactDigest: `sha256:${"a".repeat(64)}`, manifestDigest: "one" } },
    { macos: { artifactDigest: `sha256:${"a".repeat(64)}`, manifestDigest: "one" } },
  ) && !artifactInputStatesEqual(
    { macos: { artifactDigest: `sha256:${"a".repeat(64)}`, manifestDigest: "one" } },
    { macos: { artifactDigest: `sha256:${"a".repeat(64)}`, manifestDigest: "two" } },
  ), "replaced artifact sidecar input must fail closed");
  let privacyRejected = false;
  try {
    assertAcceptancePrivacy({ fixture: ["", "Users", "fixture", "secret"].join("/") });
  } catch {
    privacyRejected = true;
  }
  requireValue(privacyRejected, "acceptance privacy scan must reject local paths");
  privacyRejected = false;
  try {
    const hostileCertificateDigestKey = ["certificate", "Identity", "Digest"].join("");
    assertAcceptancePrivacy({
      [hostileCertificateDigestKey]: `sha256:${"f".repeat(64)}`,
    });
  } catch {
    privacyRejected = true;
  }
  requireValue(privacyRejected,
    "acceptance privacy scan must reject stable signing identity digests");
  const packageScripts = readJson(path.join(repoRoot, "package.json")).scripts;
  const sourceGate = CLIENT_GATE_LANES.source;
  const releasePolicyGate = CLIENT_GATE_LANES["release-policy"];
  for (const forbidden of [
    "client:verify:secure-mesh-e2ee-evidence:diagnostic",
    "client:verify:secure-mesh-e2ee-evidence",
    "client:verify:secure-mesh-platform-acceptance",
    "client:verify:product-line-security",
    "client:verify:client-release-acceptance:self-test",
  ]) {
    requireValue(
      !sourceGate.includes(forbidden),
      `source policy must not consume release or cross-product evidence: ${forbidden}`,
    );
  }
  requireValue(
    packageScripts["client:verify:secure-mesh-e2ee-evidence"] === undefined,
    "component-owned evidence lanes must not survive in the Desktop workspace",
  );
  requireValue(packageScripts["client:release:macos"]?.includes(
    "client-release-plane.mjs release start",
  ), "macOS publication must be delegated to the release plane");
  requireValue(packageScripts["client:verify:product-line-security"]?.includes(
    "client-release-acceptance.mjs",
  ), "product-line security must retain the full client evidence reducer");
  for (const scriptName of [
    "client:verify:release-artifact-io:self-test",
    "client:verify:release-dependency-receipts:self-test",
    "client:verify:source-state-digest:self-test",
    "client:verify:review-signoff:self-test",
    "client:verify:release-report-schema:self-test",
    "client:verify:macos-nested-code-bounds:self-test",
    "client:verify:package-client:self-test",
    "client:verify:closure-producer-writer:self-test",
    "client:verify:artifact-verification-receipts:self-test",
    "client:verify:client-release-acceptance:self-test",
  ]) {
    requireValue(
      releasePolicyGate.includes(scriptName),
      `release-policy lane must run ${scriptName}`,
    );
  }
  requireValue(!releasePolicyGate.includes(
    "client:verify:release-target-evidence:self-test",
  ), "retired component target evidence must not remain in the release lane");
  const preflightConfig = readJson(configPath);
  const preflightCatalog = loadClientReleaseTargetCatalog();
  const preflightReceiptConfig = readJson(path.join(
    repoRoot,
    "tools/scripts/config/client-artifact-verification-receipts.json",
  ));
  requireValue(validateReleaseSelectionPreflight({
    catalog: preflightCatalog,
    config: preflightConfig,
    receiptConfig: preflightReceiptConfig,
    selectedTargetIds: preflightConfig.releaseTargetAuthority.selectedTargetIds,
  }), "authorized release target preflight failed");
  const mismatchedLineageReceiptConfig = structuredClone(preflightReceiptConfig);
  mismatchedLineageReceiptConfig.targets["macos-direct-arm64"].distributionManifestRef =
    "build/apps/desktop/distribution/macos/retired-manifest.json";
  let mismatchedLineageRejected = false;
  try {
    validateReleaseSelectionPreflight({
      catalog: preflightCatalog,
      config: preflightConfig,
      receiptConfig: mismatchedLineageReceiptConfig,
      selectedTargetIds: ["macos-direct-arm64"],
    });
  } catch {
    mismatchedLineageRejected = true;
  }
  requireValue(mismatchedLineageRejected,
    "mismatched release artifact manifest lineage was accepted");
  const supportMatrixFixture = readJson(path.join(
    repoRoot,
    "tools/client-support-matrix.json",
  ));
  for (const target of supportMatrixFixture.targets) {
    if (target.targetId !== "macos-arm64") continue;
    target.overrides = {
      ...(target.overrides || {}),
      "client-shell": "supported",
      "devices": "supported",
    };
  }
  const validatedSupportMatrix = validateClientSupportMatrix(supportMatrixFixture);
  requireValue(selectedReleaseBlockingSupportReady(
    validatedSupportMatrix,
    ["macos-arm64"],
  ), "selected supported blocking services were rejected");
  supportMatrixFixture.targets.find((target) =>
    target.targetId === "macos-arm64").overrides["devices"] = "preview";
  requireValue(!selectedReleaseBlockingSupportReady(
    validateClientSupportMatrix(supportMatrixFixture),
    ["macos-arm64"],
  ), "selected preview blocking service was accepted");
  const childProofRef =
    "build/reports/consumer-verification-evidence.json";
  requireValue(closureRedactionSeedRefs(
    preflightConfig,
    [{ id: "macos-direct-arm64" }],
    { ok: true, payload: { receipts: [{ dependencies: [{ ref: childProofRef }] }] } },
    preflightReceiptConfig,
  ).includes(childProofRef),
  "selected closure seed refs omitted receipt dependency");
  for (const targetId of ["linux-musl-arm64", "windows-x64"]) {
    let rejected = false;
    try {
      validateReleaseSelectionPreflight({
        catalog: preflightCatalog,
        config: preflightConfig,
        receiptConfig: preflightReceiptConfig,
        selectedTargetIds: [targetId],
      });
    } catch {
      rejected = true;
    }
    requireValue(rejected, `non-authoritative target passed preflight: ${targetId}`);
  }
  let authorityOrderRejected = false;
  try {
    validateReleaseSelectionPreflight({
      catalog: preflightCatalog,
      config: preflightConfig,
      receiptConfig: preflightReceiptConfig,
      selectedTargetIds: ["macos-direct-arm64", "linux-deb-arm64"],
    });
  } catch {
    authorityOrderRejected = true;
  }
  requireValue(authorityOrderRejected,
    "noncanonical release target authority order was accepted");
  const previousTargetSelection = process.env.LICO_CLIENT_RELEASE_TARGETS;
  const previousTargetSelectionPresent = Object.hasOwn(
    process.env,
    "LICO_CLIENT_RELEASE_TARGETS",
  );
  let emptyTokenRejected = false;
  try {
    process.env.LICO_CLIENT_RELEASE_TARGETS = "macos-direct-arm64,";
    selectedTargetIds(
      preflightCatalog,
      preflightConfig.releaseTargetAuthority.selectedTargetIds,
    );
  } catch {
    emptyTokenRejected = true;
  } finally {
    if (previousTargetSelectionPresent) {
      process.env.LICO_CLIENT_RELEASE_TARGETS = previousTargetSelection;
    } else {
      delete process.env.LICO_CLIENT_RELEASE_TARGETS;
    }
  }
  requireValue(emptyTokenRejected, "explicit empty release target token was accepted");
  return { ok: true, caseCount: 30 };
}
