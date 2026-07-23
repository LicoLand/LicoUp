import { generateKeyPairSync, sign } from "node:crypto";
import path from "node:path";
import process from "node:process";
import {
  loadClientReleaseTargetCatalog,
} from "../../lib/client-release-targets.mjs";
import {
  sha256Buffer,
  stableReadFile,
} from "../../lib/client-release-artifact-digest.mjs";
import {
  selectedReleaseBlockingSupportReady,
  validateClientSupportMatrix,
} from "../../client-support-matrix.mjs";
import {
  SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION,
} from "../../lib/secure-mesh-trust-ux-reducer.mjs";
import { verifyLinuxArchiveDigestSignature } from "../artifacts/linux-signature.mjs";
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
import { readJson, requireValue, text } from "../util.mjs";
import {
  selfTestAndroidTrustEvidence,
  selfTestReleaseCliReport,
  selfTestReports,
  selfTestTrustReport,
} from "./fixtures.mjs";

export function runSelfTest({ schemaFixture = false } = {}) {
  const selected = [
    { id: "macos-arm64", platform: "macos", arch: "arm64", supported: true, releaseSupported: true },
    { id: "android-arm64", platform: "android", arch: "arm64", supported: true, releaseSupported: true }
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
      id: "linuxCli",
      ok: true,
      schemaVersion: "licomesh.secure-mesh.release-cli-proof-report.v1",
      producer: "tools/scripts/client-secure-mesh-release-cli-proof.mjs",
      producerExitCode: 0,
      sourceDigest: `sha256:${"1".repeat(64)}`,
      reportDigest: `sha256:${"2".repeat(64)}`,
      freshnessReady: true,
      closureChallengeBound: true,
      invocationNonceDigest: `sha256:${"3".repeat(64)}`,
      dependencies: [],
    }]
  };
  const readyArtifactFor = (targetId, artifactKind, digestDigit) => ({
    targetId,
    productVersion: "1.2.3",
    artifactKind,
    artifactDigest: `sha256:${digestDigit.repeat(64)}`,
    runtimeExecutableDigest: `sha256:${digestDigit.repeat(64)}`,
    artifactEvidenceReportDigest: targetId === "android-arm64"
      ? `sha256:${"b".repeat(64)}`
      : `sha256:${"d".repeat(64)}`,
    artifactEvidenceInvocationNonceDigest: targetId === "android-arm64"
      ? `sha256:${"c".repeat(64)}`
      : `sha256:${"e".repeat(64)}`,
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
    "macos-arm64": readyArtifactFor(
      "macos-arm64",
      "macos-distribution-archive",
      "3",
    ),
    "android-arm64": readyArtifactFor("android-arm64", "android-apk", "8")
  };
  const base = {
    selectedTargets: selected,
    supportMatrixReady: true,
    inputIntegrity: readyIntegrity,
    artifactBindings: readyArtifact
  };
  const externalAndUnselected = reduceClientReleaseAcceptance({ ...base, reports: selfTestReports() });
  if (schemaFixture) return externalAndUnselected;
  requireValue(externalAndUnselected.githubReleaseReady,
    `macOS and Android selected targets must pass without iOS or external evidence: ${externalAndUnselected.blockers.join(",")}`);
  const productTrustMissing = reduceClientReleaseAcceptance({
    ...base,
    reports: selfTestReports({ productTrustUxReady: false })
  });
  requireValue(!productTrustMissing.githubReleaseReady && productTrustMissing.blockers.includes("client_product_trust_ux_not_ready"), "missing product trust UX must fail closed");
  const unsupportedSchema = reduceClientReleaseAcceptance({
    ...base,
    reports: selfTestReports({ trustSchemaVersion: "licomesh.secure-mesh.trust-ux-report.unsupported" })
  });
  requireValue(!unsupportedSchema.githubReleaseReady && unsupportedSchema.blockers.includes("client_trust_v2_contract_not_ready"), "unsupported Trust UX schema must fail closed");
  const unknownAuthority = reduceClientReleaseAcceptance({
    ...base,
    reports: selfTestReports({ includeUnknownAuthorityField: true })
  });
  requireValue(!unknownAuthority.githubReleaseReady && unknownAuthority.blockers.includes("client_trust_v2_contract_not_ready"), "unknown trust authority field must fail closed");
  const missingSelected = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      ...readyArtifact,
      "macos-arm64": {
        ...readyArtifact["macos-arm64"],
        platformSecurityReady: false,
        ready: false,
      },
    },
    reports: selfTestReports(),
  });
  requireValue(!missingSelected.githubReleaseReady && missingSelected.blockers.some((item) => item.startsWith("selected_platform_security_not_ready:")), "selected missing evidence must block");
  const plaintext = reduceClientReleaseAcceptance({ ...base, reports: selfTestReports({ plaintextReady: false }) });
  requireValue(!plaintext.githubReleaseReady && plaintext.blockers.some((item) => item.includes("plaintext")), "mock relay plaintext observation must fail closed");
  const tamper = reduceClientReleaseAcceptance({ ...base, reports: selfTestReports({ tamperReady: false }) });
  requireValue(!tamper.githubReleaseReady && tamper.blockers.includes("encrypted_relay_header_tamper_not_rejected"), "mock relay tamper must fail closed");
  const legacyMetadataReports = selfTestReports();
  delete legacyMetadataReports.pairwise.metadataResistanceEvidence;
  const legacyMetadata = reduceClientReleaseAcceptance({
    ...base,
    reports: legacyMetadataReports,
  });
  requireValue(!legacyMetadata.githubReleaseReady && legacyMetadata.blockers.includes(
    "canonical_wire_residual_metadata_topology_evidence_not_ready",
  ), "legacy metadata-resistance boolean without complete wire evidence must fail closed");
  const unsignedReview = reduceClientReleaseAcceptance({
    ...base,
    reports: selfTestReports({ reviewSignoffReady: false }),
  });
  requireValue(!unsignedReview.githubReleaseReady &&
    unsignedReview.blockers.includes("independent_cryptographic_review_signature_not_ready") &&
    unsignedReview.blockers.includes("independent_reviewer_signature_invalid") &&
    unsignedReview.blockers.includes("release_owner_signature_invalid"),
  "boolean-only independent audit signoff must fail closed");
  const ambiguousCustody = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      ...readyArtifact,
      "macos-arm64": {
        ...readyArtifact["macos-arm64"],
        platformSecurityReady: false,
        ready: false,
      },
    },
    reports: selfTestReports(),
  });
  requireValue(!ambiguousCustody.githubReleaseReady && ambiguousCustody.blockers.some((item) => item.startsWith("selected_platform_security_not_ready:")), "missing exact adaptive custody evidence must fail closed");
  const forgedInput = reduceClientReleaseAcceptance({
    ...base,
    inputIntegrity: { ...readyIntegrity, ok: false },
    reports: selfTestReports()
  });
  requireValue(!forgedInput.githubReleaseReady && forgedInput.blockers.includes("release_input_provenance_not_ready"), "editable report booleans without current producer provenance must fail closed");
  const missingArtifact = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {},
    reports: selfTestReports()
  });
  requireValue(!missingArtifact.githubReleaseReady && missingArtifact.blockers.some((item) => item.startsWith("selected_target_exact_artifact_not_ready:")), "missing exact selected-target artifact must fail closed");
  const unsignedArtifact = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      ...readyArtifact,
      "macos-arm64": { ...readyArtifact["macos-arm64"], consumerVerificationReady: false, ready: false }
    },
    reports: selfTestReports()
  });
  requireValue(!unsignedArtifact.githubReleaseReady && unsignedArtifact.blockers.some((item) => item.startsWith("selected_target_consumer_verification_not_ready:")), "artifact without consumer verification must fail closed");
  const missingReceipt = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      ...readyArtifact,
      "macos-arm64": { ...readyArtifact["macos-arm64"], installReceiptReady: false, receiptProvenanceReady: false, ready: false }
    },
    reports: selfTestReports()
  });
  requireValue(!missingReceipt.githubReleaseReady && missingReceipt.blockers.some((item) => item.startsWith("selected_target_install_receipt_not_ready:")), "artifact without exact local install receipt must fail closed");
  const distributionGuidance = reduceClientReleaseAcceptance({
    ...base,
    artifactBindings: {
      ...readyArtifact,
      "macos-arm64": {
        ...readyArtifact["macos-arm64"],
        nonBlockingDistributionStatus: "ready",
      },
    },
    reports: selfTestReports(),
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
  requireValue(validateProducedReportReceipt(receiptFixture).ok, "current approved producer receipt must validate");
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
    "macos-arm64": sanitizeArtifactBinding({
      targetId: "macos-arm64",
      artifactDigest: `sha256:${"a".repeat(64)}`,
    }),
  };
  requireValue(artifactBindingMapsEqual(
    artifactBindingFixture,
    structuredClone(artifactBindingFixture),
    [{ id: "macos-arm64" }],
  ) && !artifactBindingMapsEqual(
    artifactBindingFixture,
    {
      "macos-arm64": {
        ...artifactBindingFixture["macos-arm64"],
        artifactDigest: `sha256:${"b".repeat(64)}`,
      },
    },
    [{ id: "macos-arm64" }],
  ), "replaced final artifact input must fail closed");
  requireValue(artifactInputStatesEqual(
    { linux: { artifactDigest: `sha256:${"a".repeat(64)}`, signatureDigest: "one" } },
    { linux: { artifactDigest: `sha256:${"a".repeat(64)}`, signatureDigest: "one" } },
  ) && !artifactInputStatesEqual(
    { linux: { artifactDigest: `sha256:${"a".repeat(64)}`, signatureDigest: "one" } },
    { linux: { artifactDigest: `sha256:${"a".repeat(64)}`, signatureDigest: "two" } },
  ), "replaced artifact sidecar input must fail closed");
  const { publicKey: linuxPublicKey, privateKey: linuxPrivateKey } =
    generateKeyPairSync("ed25519");
  const linuxPublicKeyDer = linuxPublicKey.export({ type: "spki", format: "der" });
  const linuxArtifactDigest = `sha256:${"d".repeat(64)}`;
  const linuxSignature = sign(
    null,
    Buffer.from(linuxArtifactDigest.slice("sha256:".length), "hex"),
    linuxPrivateKey,
  );
  const linuxDistribution = {
    signature: {
      publicKeySpkiBase64: linuxPublicKeyDer.toString("base64"),
      publicKeyFingerprint: sha256Buffer(linuxPublicKeyDer),
    },
  };
  requireValue(verifyLinuxArchiveDigestSignature(
    linuxDistribution,
    linuxSignature,
    linuxArtifactDigest,
  ) && !verifyLinuxArchiveDigestSignature(
    linuxDistribution,
    linuxSignature,
    `sha256:${"e".repeat(64)}`,
  ), "Linux archive signature direct verification must fail closed");
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
  const defaultVerifySource = stableReadFile(
    path.join(repoRoot, "tools/run-client-verify.mjs"),
    { maxBytes: 2 * 1024 * 1024 },
  ).toString("utf8");
  const packageScripts = readJson(path.join(repoRoot, "package.json")).scripts;
  requireValue(defaultVerifySource.includes("client:verify:secure-mesh-e2ee-evidence:diagnostic"), "default verification must retain the cross-product diagnostic");
  requireValue(!defaultVerifySource.includes('["npm", ["run", "client:verify:secure-mesh-e2ee-evidence"]]'), "default verification must not run strict A10 acceptance");
  requireValue(defaultVerifySource.includes(
    "client:verify:client-release-acceptance:self-test",
  ), "default verification must run the side-effect-free client release acceptance self-test");
  requireValue(!defaultVerifySource.includes(
    '["npm", ["run", "client:verify:client-release-acceptance"]]',
  ), "default verification must not run the side-effecting client release reducer");
  requireValue(packageScripts["client:verify:github-release"]?.includes(
    "client-github-release-acceptance.mjs",
  ), "explicit GitHub release must run the artifact-only GitHub reducer");
  requireValue(packageScripts["client:verify:product-line-security"]?.includes(
    "client-release-acceptance.mjs",
  ), "product-line security must retain the full client evidence reducer");
  for (const scriptName of [
    "client:verify:release-artifact-io:self-test",
    "client:verify:release-dependency-receipts:self-test",
    "client:verify:source-state-digest:self-test",
    "client:verify:linux-tar-resource-bounds:self-test",
    "client:verify:android-apk-zip-facts:self-test",
    "client:verify:android-release-toolchain:self-test",
    "client:verify:macos-distribution:self-test",
    "client:verify:review-signoff:self-test",
    "client:verify:release-target-evidence:self-test",
    "client:verify:release-report-schema:self-test",
    "client:verify:macos-nested-code-bounds:self-test",
    "client:verify:package-client:self-test",
    "client:native:smoke:policy:self-test",
    "client:verify:closure-producer-writer:self-test",
  ]) {
    requireValue(defaultVerifySource.includes(scriptName),
    `default verification must run ${scriptName}`);
  }
  requireValue(packageScripts["client:verify:secure-mesh-platform-acceptance"]?.includes("client:verify:secure-mesh-e2ee-evidence"), "strict Secure Mesh platform acceptance must remain explicitly callable");
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
  mismatchedLineageReceiptConfig.targets["linux-glibc-arm64"].distributionManifestRef =
    "build/apps/desktop/distribution/linux-arm64/retired-manifest.json";
  let mismatchedLineageRejected = false;
  try {
    validateReleaseSelectionPreflight({
      catalog: preflightCatalog,
      config: preflightConfig,
      receiptConfig: mismatchedLineageReceiptConfig,
      selectedTargetIds: ["linux-glibc-arm64"],
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
    if (!["macos-arm64", "android-arm64", "linux-glibc-arm64"].includes(
      target.targetId,
    )) continue;
    target.overrides = {
      ...(target.overrides || {}),
      "client-shell": "supported",
      "secure-mesh-pairwise": "supported",
    };
  }
  const validatedSupportMatrix = validateClientSupportMatrix(supportMatrixFixture);
  requireValue(selectedReleaseBlockingSupportReady(
    validatedSupportMatrix,
    ["macos-arm64", "android-arm64", "linux-glibc-arm64"],
  ), "selected supported blocking services were rejected");
  supportMatrixFixture.targets.find((target) =>
    target.targetId === "android-arm64").overrides["secure-mesh-pairwise"] = "preview";
  requireValue(!selectedReleaseBlockingSupportReady(
    validateClientSupportMatrix(supportMatrixFixture),
    ["macos-arm64", "android-arm64", "linux-glibc-arm64"],
  ), "selected preview blocking service was accepted");
  const childProofRef =
    "build/reports/secure-mesh-macos-keychain-user-presence-proof.json";
  requireValue(closureRedactionSeedRefs(
    preflightConfig,
    [{ id: "macos-arm64" }],
    { ok: true, payload: { receipts: [{ dependencies: [{ ref: childProofRef }] }] } },
    preflightReceiptConfig,
  ).includes(childProofRef),
  "selected closure redaction omitted macOS child proof dependency");
  for (const targetId of ["macos-x64", "linux-musl-arm64", "windows-x64"]) {
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
      selectedTargetIds: [...preflightConfig.releaseTargetAuthority.selectedTargetIds]
        .reverse(),
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
    process.env.LICO_CLIENT_RELEASE_TARGETS = "macos-arm64,";
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
  return { ok: true, caseCount: 43 };
}
