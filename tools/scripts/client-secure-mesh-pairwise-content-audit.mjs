#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { runCargoTestFilter } from "./lib/cargo-test-filter-runner.mjs";
import { loadSecureClientContract } from "./lib/secure-client-contract.mjs";
import { createSecureClientMeshE2eeRefReportScope } from "./lib/secure-client-mesh-e2ee-ref-report.mjs";
import { loadSecureMeshPairwiseContentAuditConfig } from "./lib/secure-mesh-pairwise-content-audit-config.mjs";
import { optionalReleaseInvocationBinding } from "./lib/release-closure-challenge.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import {
  stableHashFileSnapshot,
  stableReadFile,
} from "./lib/client-release-artifact-digest.mjs";
import { verifyPairwiseReviewSignoff } from "./lib/review-signoff-verifier.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const pairwiseContentAuditConfig = await loadSecureMeshPairwiseContentAuditConfig();
const reportPath = pairwiseContentAuditConfig.reportOutput;
const vectorCorpusPath = pairwiseContentAuditConfig.vectorCorpusOutput;
const reviewSignoffPath = pairwiseContentAuditConfig.reviewSignoffRef;
const reviewAuthoritiesPath = path.join(
  repoRoot,
  "tools/scripts/config/secure-mesh-pairwise-review-authorities.json",
);
const producerPath = fileURLToPath(import.meta.url);
const sourceStateDigest = clientSourceStateDigest(
  repoRoot,
  CANONICAL_CLIENT_SOURCE_ROOTS,
);
const producerSourceBefore = stableHashFileSnapshot(producerPath, {
  maxBytes: 4 * 1024 * 1024,
});
const reviewAuthorities = JSON.parse(stableReadFile(reviewAuthoritiesPath, {
  maxBytes: 1024 * 1024,
}).toString("utf8"));
if (reviewAuthorities?.schemaVersion !==
    "licolite.secure-mesh.pairwise-review-authorities.v1" ||
  !Array.isArray(reviewAuthorities.reviewerKeys) ||
  !Array.isArray(reviewAuthorities.releaseOwnerKeys)) {
  throw new Error("Pairwise review authority config is invalid");
}
const args = new Set(process.argv.slice(2));
const strict = args.has("--strict");
const generateSignoffTemplate = args.has("--generate-signoff-template");

const leakPatterns = Object.freeze([
  ["local_path", /\/Users\/|\/private\/|\/var\/folders\/|[A-Za-z]:\\/u],
  ["bearer", /Bearer\s+(?!\[redacted\])\S+/u],
  ["token", /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u],
  ["private_material", /-----BEGIN|privateKey|sessionKey|rootKey|chainKey|messageKey|"(?:shared_secret|root_key|chain_key|message_key|identity_secret|prekey_secret)"\s*:/u]
]);

const sourceChecks = Object.freeze(pairwiseContentAuditConfig.sourceChecks);
const nativeTestFilters = Object.freeze(pairwiseContentAuditConfig.nativeTestFilters);

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

function functionBody(source, name) {
  const start = source.indexOf(`fn ${name}`);
  if (start < 0) {
    return "";
  }
  const braceStart = source.indexOf("{", start);
  if (braceStart < 0) {
    return "";
  }
  let depth = 0;
  for (let index = braceStart; index < source.length; index += 1) {
    const char = source[index];
    if (char === "{") depth += 1;
    if (char === "}") {
      depth -= 1;
      if (depth === 0) {
        return source.slice(braceStart, index + 1);
      }
    }
  }
  return "";
}

async function evaluateSourceCheck(check) {
  const source = await readText(check.file);
  const scopedSource = check.functionName ? functionBody(source, check.functionName) : source;
  const missingTokens = (check.tokens || []).filter((token) => !scopedSource.includes(token));
  const forbiddenPresent = (check.forbiddenTokens || []).filter((token) => scopedSource.includes(token));
  return {
    id: check.id,
    file: check.file,
    ok: missingTokens.length === 0 && forbiddenPresent.length === 0,
    missingTokens,
    forbiddenPresent
  };
}

function runNativeTest(filter) {
  return runCargoTestFilter({
    repoRoot,
    manifestPath: "crates/lico-client-native/Cargo.toml",
    filter,
    env: {
      ...process.env,
      CARGO_TARGET_DIR: path.join(repoRoot, "build/crates/lico-client-native/target")
    },
    sanitizeError
  });
}

async function buildVectorCorpus() {
  const contentCryptoSource = await readText("crates/lico-client-native/src/core/secure_mesh_crypto.rs");
  const pqxdhSource = await readText("crates/lico-client-native/src/core/secure_mesh_pqxdh.rs");
  const braidSource = await readText("crates/lico-client-native/src/core/secure_mesh_mlkem_braid.rs");
  const pairwiseSource = await readText("crates/lico-client-native/src/core/secure_mesh_pairwise.rs");
  const contentVector = extractContentStableVector(contentCryptoSource);
  const pairwiseVector = extractPairwiseStableVector(pqxdhSource, braidSource, pairwiseSource);
  const corpus = {
    ok: contentVector.ok === true &&
      pairwiseVector.ok === true,
    schemaVersion: "licolite.secure-mesh.pairwise-content-vector-corpus.v1",
    generatedAt: new Date().toISOString(),
    sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    externalCryptographicReviewComplete: false,
    releaseOwnerSignoffComplete: false,
    entries: [
      contentVector,
      pairwiseVector,
      {
        id: "pairwise-ratchet-command-result-coverage",
        kind: "native-test-coverage",
        ok: true,
        redacted: true,
        sourceTests: nativeTestFilters.filter((filter) =>
          filter.includes("pairwise") ||
          filter.includes("mobile_relay") ||
          filter.includes("lifecycle") ||
          filter.includes("payload")
        ),
        coverage: [
          "PQXDH ML-KEM-1024 prekey initialization required",
          "tampered prekey signatures rejected",
          "durable pairwise command/result route",
          "PC/Android/iPhone/CLI/runtime endpoint-kind command/result relay matrix",
          "Sesame-style multi-device fanout with independent pairwise envelopes",
          "server-visible pairwise relay header has an explicit public-field boundary and no payload canaries",
          "wrong-recipient pairwise fanout rejection",
          "ratchet message-key payload codec",
          "pairwise payload open failures do not advance receiver ratchet state",
          "authenticated automatic DH ratchet after remote ratchet",
          "old-chain in-flight recovery after ratchet",
          "stale and replayed relay ACKs do not advance ratchet state",
          "restart-safe pending authenticated ratchet state",
          "revoked session fail-closed for seal and open",
          "bounded skipped-key out-of-order open",
          "oversized skipped-key gaps reject before ratchet state advances",
          "server-substituted peer descriptors and tampered trust records rejected before command execution",
          "mobile FFI raw payload key/body actions are absent",
          "redacted TTL/delete/screenshot/resend/typing/read-receipt/ACK purge service actions",
          "lifecycle service actions seal only inside pairwise or MLS envelopes",
          "MLS product policy bindings for identity, welcome, roster, sender, commit, and one-time KeyPackage",
          "Key Transparency signed checkpoints with anti-equivocation; unsigned hash-chain non-authorizing",
          "ACP protected envelope AAD binding covers session/turn/operation/tool/permission/idempotency/policy fields",
          "ACP plaintext protected-payload relay is blocked as a production path"
        ]
      }
    ],
    reviewGate: {
      independentReviewRequired: true,
      releaseOwnerSignoffRequired: true,
      productionReadyAfterThisCorpus: false
    }
  };
  corpus.corpusDigest = sha256Json({
    schemaVersion: corpus.schemaVersion,
    entries: corpus.entries,
    reviewGate: corpus.reviewGate
  });
  corpus.signoffBinding = signoffBindingForCorpus(corpus);
  return corpus;
}

function extractContentStableVector(source) {
  const body = functionBody(source, "secure_mesh_content_crypto_has_stable_vectors_for_all_payload_kinds");
  const vectorBlocks = [...body.matchAll(/ContentCryptoStableVector\s*\{([\s\S]*?)\n\s*\}/gu)]
    .map((match) => match[1]);
  const vectors = vectorBlocks
    .map((block) => {
      const label = fieldString(block, "label");
      const encryptedHeader = fieldString(block, "encrypted_header");
      const ciphertextSha256 = fieldString(block, "ciphertext_sha256") ||
        (fieldString(block, "ciphertext") ? sha256Text(fieldString(block, "ciphertext")) : "");
      const ciphertextSize = Number(block.match(/ciphertext_size:\s*(\d+)/u)?.[1] || 0);
      return {
        label,
        encryptedHeaderSha256: encryptedHeader ? sha256Text(encryptedHeader) : "",
        ciphertextSha256,
        ciphertextSize,
        vectorDigest: encryptedHeader && ciphertextSha256 && ciphertextSize > 0
          ? sha256Json({ label, encryptedHeader, ciphertextSha256, ciphertextSize })
          : ""
      };
    })
    .filter((vector) => vector.label);
  const labels = new Set(vectors.map((vector) => vector.label).filter(Boolean));
  const requiredLabels = ["command", "result", "error", "file_chunk", "file_manifest"];
  const ok = requiredLabels.every((label) => labels.has(label)) &&
    vectors.every((vector) =>
      Boolean(vector.encryptedHeaderSha256 && vector.ciphertextSha256 && vector.ciphertextSize > 0 && vector.vectorDigest)
    );
  return {
    id: "content-aead-stable-vectors-all-payload-kinds",
    kind: "deterministic-content-crypto-vector",
    ok,
    sourceFile: "crates/lico-client-native/src/core/secure_mesh_crypto.rs",
    sourceTest: "secure_mesh_content_crypto_has_stable_vectors_for_all_payload_kinds",
    cipherSuite: "licolite.secure-payload.v1.chacha20poly1305-hkdfsha256",
    payloadKinds: requiredLabels,
    vectorCount: vectors.length,
    deterministic: true,
    redacted: true,
    rawPlaintextIncluded: false,
    rawContentKeyIncluded: false,
    rawCiphertextIncluded: false,
    vectors,
    vectorDigest: ok ? sha256Json(vectors) : ""
  };
}

function extractPairwiseStableVector(pqxdhSource, braidSource, pairwiseSource) {
  const pqxdhBody = functionBody(
    pqxdhSource,
    "pqxdh_schedule_is_deterministic_domain_separated_and_context_bound",
  );
  const braidBody = functionBody(braidSource, "authenticator_known_answer");
  const tripleRatchetBody = functionBody(
    pairwiseSource,
    "secure_mesh_pairwise_triple_ratchet_combines_ec_and_sparse_pq_messages",
  );
  const pqxdhVectors = [
    ["ec-secret", /hex\(first\.ec_secret\(\)\),\s*"([a-f0-9]{64})"/u],
    ["scka-secret", /hex\(first\.scka_secret\(\)\),\s*"([a-f0-9]{64})"/u],
    [
      "associated-data",
      /hex\(&libcrux_sha3::sha256\(first\.associated_data\(\)\)\),\s*"([a-f0-9]{64})"/u,
    ],
  ].map(([label, pattern]) => redactedKnownAnswer(label, pqxdhBody, pattern));
  const braidVectors = [
    ["authenticator-root", /hex\(auth\.root_key\.as_slice\(\)\),\s*"([a-f0-9]{64})"/u],
    ["authenticator-mac", /hex\(auth\.mac_key\.as_slice\(\)\),\s*"([a-f0-9]{64})"/u],
    [
      "header-mac",
      /hex\(&auth\.mac_header\(1,\s*&header\)\.unwrap\(\)\),\s*"([a-f0-9]{64})"/u,
    ],
  ].map(([label, pattern]) => redactedKnownAnswer(label, braidBody, pattern));
  const parameterSizes = {
    headerBytes: numericConstant(braidSource, "ML_KEM_BRAID_HEADER_BYTES"),
    encapsulationKeyBytes: numericConstant(braidSource, "ML_KEM_BRAID_EK_BYTES"),
    ciphertext1Bytes: numericConstant(braidSource, "ML_KEM_BRAID_CT1_BYTES"),
    ciphertext2Bytes: numericConstant(braidSource, "ML_KEM_BRAID_CT2_BYTES"),
    transitionCount: numericConstant(braidSource, "ML_KEM_BRAID_TRANSITION_COUNT"),
  };
  const cipherSuite = String(
    pairwiseSource.match(/SECURE_MESH_PAIRWISE_CIPHER_SUITE:\s*&str\s*=\s*"([^"]+)"/u)?.[1] || "",
  );
  const tripleRatchetIntegrationCovered = [
    "seal_message_with_nonce",
    "sparse_pq_header.message_number",
    "rotate_sending_ratchet_with_secret",
    "open_message",
  ].every((token) => tripleRatchetBody.includes(token));
  const expectedParameterSizes = {
    headerBytes: 64,
    encapsulationKeyBytes: 1536,
    ciphertext1Bytes: 1408,
    ciphertext2Bytes: 160,
    transitionCount: 13,
  };
  const ok = pqxdhVectors.every((vector) => vector.expectedValueSha256.startsWith("sha256:")) &&
    braidVectors.every((vector) => vector.expectedValueSha256.startsWith("sha256:")) &&
    JSON.stringify(parameterSizes) === JSON.stringify(expectedParameterSizes) &&
    cipherSuite ===
      "licolite.pqxdh-triple-ratchet.v1.x25519-ed25519-mlkem1024-hkdfsha256-chacha20poly1305" &&
    tripleRatchetIntegrationCovered;
  return {
    id: "pairwise-pqxdh-mlkem1024-triple-ratchet-stable-vectors",
    kind: "deterministic-pairwise-pqxdh-mlkem1024-triple-ratchet-vector",
    ok,
    sourceFiles: [
      "crates/lico-client-native/src/core/secure_mesh_pqxdh.rs",
      "crates/lico-client-native/src/core/secure_mesh_mlkem_braid.rs",
      "crates/lico-client-native/src/core/secure_mesh_pairwise.rs",
    ],
    sourceTests: [
      "pqxdh_schedule_is_deterministic_domain_separated_and_context_bound",
      "authenticator_known_answer",
      "secure_mesh_pairwise_triple_ratchet_combines_ec_and_sparse_pq_messages",
    ],
    cipherSuite,
    parameterSet: "ML-KEM-1024",
    parameterSizes,
    deterministic: true,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    pqxdhVectorCount: pqxdhVectors.length,
    braidVectorCount: braidVectors.length,
    tripleRatchetIntegrationCovered,
    pqxdhVectors,
    braidVectors,
    vectorDigest: ok
      ? sha256Json({ cipherSuite, parameterSizes, pqxdhVectors, braidVectors })
      : "",
  };
}

function redactedKnownAnswer(label, body, pattern) {
  const expectedValue = String(body.match(pattern)?.[1] || "");
  return {
    label,
    expectedValueSha256: expectedValue ? sha256Text(expectedValue) : "",
  };
}

function numericConstant(source, name) {
  const raw = String(
    source.match(new RegExp(`const ${name}: usize = ([0-9_]+);`, "u"))?.[1] || "0",
  );
  return Number(raw.replaceAll("_", ""));
}

function fieldString(source, fieldName) {
  return source.match(new RegExp(`${fieldName}:\\s*"([^"]+)"`, "u"))?.[1] || "";
}

function sha256Text(value) {
  return `sha256:${crypto.createHash("sha256").update(String(value), "utf8").digest("hex")}`;
}

function sha256Json(value) {
  return sha256Text(JSON.stringify(value));
}

function assertStableAuditSource() {
  const producerAfter = stableHashFileSnapshot(producerPath, {
    maxBytes: 4 * 1024 * 1024,
  });
  if (producerAfter.digest !== producerSourceBefore.digest ||
    producerAfter.device !== producerSourceBefore.device ||
    producerAfter.inode !== producerSourceBefore.inode ||
    clientSourceStateDigest(repoRoot, CANONICAL_CLIENT_SOURCE_ROOTS) !==
      sourceStateDigest) {
    throw new Error("Pairwise audit source changed during verification");
  }
}

function signoffBindingForCorpus(corpus) {
  const entryIds = corpus.entries.map((entry) => String(entry.id || ""));
  return {
    schemaVersion: "licolite.secure-mesh.pairwise-content-review-signoff-binding.v2",
    corpusSchemaVersion: corpus.schemaVersion,
    corpusDigest: corpus.corpusDigest,
    corpusEntryCount: corpus.entries.length,
    corpusEntryIdsDigest: sha256Json(entryIds),
    sourceCheckCount: sourceChecks.length,
    sourceCheckIdsDigest: sha256Json(sourceChecks.map((check) => check.id)),
    nativeTestFilterCount: nativeTestFilters.length,
    nativeTestFiltersDigest: sha256Json(nativeTestFilters),
    sourceStateDigest,
    producerSourceDigest: producerSourceBefore.digest,
  };
}

function vectorCorpusSnapshotRefForCorpus(corpus) {
  const digest = String(corpus.corpusDigest || "").replace(/^sha256:/u, "");
  const suffix = /^[a-f0-9]{64}$/u.test(digest) ? digest.slice(0, 16) : "unknown-digest";
  const parsed = path.posix.parse(vectorCorpusPath.replaceAll("\\", "/"));
  return `${parsed.dir}/${parsed.name}-${suffix}${parsed.ext}`;
}

function safeReportRef(value) {
  const ref = String(value || "").trim().replaceAll("\\", "/");
  if (!ref ||
    !ref.endsWith(".json") ||
    ref.startsWith("/") ||
    ref.startsWith("file:") ||
    /^https?:\/\//iu.test(ref) ||
    ref.split("/").includes("..") ||
    !(ref.startsWith("build/reports/") || ref.startsWith("build/client-cli-vm/"))) {
    return "";
  }
  return ref;
}

async function loadVectorCorpusSnapshot(relativePath) {
  const ref = safeReportRef(relativePath);
  if (!ref) {
    return {
      report: "",
      present: false,
      ok: false,
      corpusDigest: "",
      recomputedCorpusDigestMatched: false,
      failureSummary: "vector corpus snapshot ref is missing or unsafe"
    };
  }
  try {
    const payload = JSON.parse(await readText(ref));
    assertNoLeak(payload, "secure mesh pairwise/content vector corpus snapshot");
    const recomputedCorpusDigest = sha256Json({
      schemaVersion: payload.schemaVersion,
      entries: Array.isArray(payload.entries) ? payload.entries : [],
      reviewGate: payload.reviewGate || {}
    });
    const ok = payload.schemaVersion === "licolite.secure-mesh.pairwise-content-vector-corpus.v1" &&
      payload.redacted === true &&
      payload.rawPrivateMaterialIncluded === false &&
      payload.rawPlaintextIncluded === false &&
      payload.rawPublicWireBytesIncluded === false &&
      payload.signoffBinding?.corpusDigest === payload.corpusDigest &&
      recomputedCorpusDigest === payload.corpusDigest;
    return {
      report: ref,
      present: true,
      ok,
      schemaVersion: String(payload.schemaVersion || ""),
      redacted: payload.redacted === true,
      corpusDigest: String(payload.corpusDigest || ""),
      signoffBindingCorpusDigest: String(payload.signoffBinding?.corpusDigest || ""),
      recomputedCorpusDigest,
      recomputedCorpusDigestMatched: recomputedCorpusDigest === payload.corpusDigest,
      failureSummary: ok ? "" : "vector corpus snapshot is missing required digest-bound fields"
    };
  } catch (error) {
    return {
      report: ref,
      present: false,
      ok: false,
      corpusDigest: "",
      recomputedCorpusDigestMatched: false,
      failureSummary: sanitizeError(error)
    };
  }
}

function reviewSignoffTemplateForCorpus(corpus, checkedAt, vectorCorpusSnapshotRef) {
  const binding = corpus.signoffBinding;
  return {
    schemaVersion: "licolite.secure-mesh.pairwise-content-review-signoff.v2",
    templateSchemaVersion: "licolite.secure-mesh.pairwise-content-review-signoff-template.v2",
    sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    generatedBy: "tools/scripts/client-secure-mesh-pairwise-content-audit.mjs",
    generatedAt: checkedAt,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    vectorCorpusReport: vectorCorpusPath,
    vectorCorpusSnapshotReport: vectorCorpusSnapshotRef,
    corpusSchemaVersion: binding.corpusSchemaVersion,
    corpusDigest: binding.corpusDigest,
    corpusEntryCount: binding.corpusEntryCount,
    corpusEntryIdsDigest: binding.corpusEntryIdsDigest,
    sourceCheckCount: binding.sourceCheckCount,
    sourceCheckIdsDigest: binding.sourceCheckIdsDigest,
    nativeTestFilterCount: binding.nativeTestFilterCount,
    nativeTestFiltersDigest: binding.nativeTestFiltersDigest,
    sourceStateDigest: binding.sourceStateDigest,
    producerSourceDigest: binding.producerSourceDigest,
    independentCryptographicReviewComplete: null,
    releaseOwnerSignoffComplete: null,
    releaseDecision: null,
    productionReadyClaimed: false,
    reviewer: {
      authority: null,
      keyId: null,
      signedAt: null,
      signatureBase64: null
    },
    releaseOwner: {
      authority: null,
      keyId: null,
      signedAt: null,
      signatureBase64: null
    },
    instructions: [
      "Do not change digest, count, schema, source-of-truth, or redaction fields.",
      "The independent reviewer may set independentCryptographicReviewComplete to true only after reviewing the generated vector corpus and source/test coverage represented by these digests.",
      "The release owner may set releaseOwnerSignoffComplete to true and releaseDecision to approved_for_release_gate only after accepting the independent review.",
      "productionReadyClaimed must remain false; platform secret-store and physical-device gates are separate release blockers."
    ]
  };
}

async function loadReviewSignoffArtifact(relativePath, corpus) {
  const binding = corpus.signoffBinding;
  try {
    const payload = JSON.parse(await readText(relativePath));
    const vectorCorpusSnapshot = await loadVectorCorpusSnapshot(payload?.vectorCorpusSnapshotReport);
    const templateSnapshotDigestMatched =
      vectorCorpusSnapshot.ok === true &&
      payload?.corpusDigest === vectorCorpusSnapshot.corpusDigest;
    const templatePresent =
      payload?.templateSchemaVersion === "licolite.secure-mesh.pairwise-content-review-signoff-template.v2";
    const templateCompleted =
      payload?.independentCryptographicReviewComplete === true ||
      payload?.releaseOwnerSignoffComplete === true ||
      String(payload?.releaseDecision || "").trim() !== "";
    if (templatePresent && !templateCompleted) {
      return {
        report: relativePath,
        present: false,
        templatePresent: true,
        templateDigestMatched: payload?.corpusDigest === binding.corpusDigest,
        templateSnapshotPresent: vectorCorpusSnapshot.present === true,
        templateSnapshotDigestMatched,
        vectorCorpusSnapshot,
        ok: false,
        schemaVersion: String(payload?.schemaVersion || ""),
        redacted: payload?.redacted === true,
        rawPrivateMaterialIncluded: payload?.rawPrivateMaterialIncluded === true,
        rawPlaintextIncluded: payload?.rawPlaintextIncluded === true,
        rawPublicWireBytesIncluded: payload?.rawPublicWireBytesIncluded === true,
        corpusDigestMatched: false,
        corpusEntryIdsDigestMatched: false,
        sourceCheckIdsDigestMatched: false,
        nativeTestFiltersDigestMatched: false,
        independentCryptographicReviewComplete: false,
        releaseOwnerSignoffComplete: false,
        releaseDecision: "",
        productionReadyClaimed: false,
        reviewerSignatureVerified: false,
        releaseOwnerSignatureVerified: false,
        authoritiesDistinct: false,
        missingOrMismatchedFields: [],
        failureSummary: "pairwise/content review signoff template is present but not completed"
      };
    }
    const missingOrMismatchedFields = [];
    const expected = {
      schemaVersion: "licolite.secure-mesh.pairwise-content-review-signoff.v2",
      sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
      redacted: true,
      rawPrivateMaterialIncluded: false,
      rawPlaintextIncluded: false,
      rawPublicWireBytesIncluded: false,
      corpusSchemaVersion: binding.corpusSchemaVersion,
      corpusDigest: binding.corpusDigest,
      corpusEntryCount: binding.corpusEntryCount,
      corpusEntryIdsDigest: binding.corpusEntryIdsDigest,
      sourceCheckCount: binding.sourceCheckCount,
      sourceCheckIdsDigest: binding.sourceCheckIdsDigest,
      nativeTestFilterCount: binding.nativeTestFilterCount,
      nativeTestFiltersDigest: binding.nativeTestFiltersDigest,
      sourceStateDigest: binding.sourceStateDigest,
      producerSourceDigest: binding.producerSourceDigest,
      independentCryptographicReviewComplete: true,
      releaseOwnerSignoffComplete: true,
      releaseDecision: "approved_for_release_gate",
      productionReadyClaimed: false
    };
    for (const [field, value] of Object.entries(expected)) {
      if (payload?.[field] !== value) {
        missingOrMismatchedFields.push(field);
      }
    }
    const signatureVerification = verifyPairwiseReviewSignoff({
      binding,
      signoff: payload,
      authorities: reviewAuthorities,
    });
    const ok = missingOrMismatchedFields.length === 0 &&
      signatureVerification.ready === true;
    return {
      report: relativePath,
      present: true,
      templatePresent,
      templateDigestMatched: templatePresent
        ? payload?.corpusDigest === binding.corpusDigest
        : false,
      templateSnapshotPresent: vectorCorpusSnapshot.present === true,
      templateSnapshotDigestMatched,
      vectorCorpusSnapshot,
      ok,
      schemaVersion: String(payload?.schemaVersion || ""),
      redacted: payload?.redacted === true,
      rawPrivateMaterialIncluded: payload?.rawPrivateMaterialIncluded === true,
      rawPlaintextIncluded: payload?.rawPlaintextIncluded === true,
      rawPublicWireBytesIncluded: payload?.rawPublicWireBytesIncluded === true,
      corpusDigestMatched: payload?.corpusDigest === binding.corpusDigest,
      corpusEntryIdsDigestMatched: payload?.corpusEntryIdsDigest === binding.corpusEntryIdsDigest,
      sourceCheckIdsDigestMatched: payload?.sourceCheckIdsDigest === binding.sourceCheckIdsDigest,
      nativeTestFiltersDigestMatched: payload?.nativeTestFiltersDigest === binding.nativeTestFiltersDigest,
      independentCryptographicReviewComplete:
        payload?.independentCryptographicReviewComplete === true,
      releaseOwnerSignoffComplete: payload?.releaseOwnerSignoffComplete === true,
      releaseDecision: String(payload?.releaseDecision || ""),
      productionReadyClaimed: payload?.productionReadyClaimed === true,
      reviewerSignatureVerified:
        signatureVerification.reviewerSignatureVerified === true,
      releaseOwnerSignatureVerified:
        signatureVerification.releaseOwnerSignatureVerified === true,
      authoritiesDistinct: signatureVerification.authoritiesDistinct === true,
      sourceStateDigestBound: signatureVerification.sourceStateDigestBound === true,
      producerSourceDigestBound:
        signatureVerification.producerSourceDigestBound === true,
      missingOrMismatchedFields,
      failureSummary: ok
        ? ""
        : "pairwise/content review signoff is missing required digest-bound fields"
    };
  } catch (error) {
    return {
      report: relativePath,
      present: false,
      templatePresent: false,
      templateDigestMatched: false,
      templateSnapshotPresent: false,
      templateSnapshotDigestMatched: false,
      vectorCorpusSnapshot: {
        present: false,
        ok: false,
        failureSummary: "not loaded"
      },
      ok: false,
      schemaVersion: "",
      redacted: false,
      rawPrivateMaterialIncluded: false,
      rawPlaintextIncluded: false,
      rawPublicWireBytesIncluded: false,
      corpusDigestMatched: false,
      corpusEntryIdsDigestMatched: false,
      sourceCheckIdsDigestMatched: false,
      nativeTestFiltersDigestMatched: false,
      independentCryptographicReviewComplete: false,
      releaseOwnerSignoffComplete: false,
      releaseDecision: "",
      productionReadyClaimed: false,
      reviewerSignatureVerified: false,
      releaseOwnerSignatureVerified: false,
      authoritiesDistinct: false,
      sourceStateDigestBound: false,
      producerSourceDigestBound: false,
      missingOrMismatchedFields: [],
      failureSummary: sanitizeError(error)
    };
  }
}

function assertNoLeak(value, label) {
  const text = JSON.stringify(value);
  for (const [kind, pattern] of leakPatterns) {
    if (pattern.test(text)) {
      throw new Error(
        `${label} contains sensitive data: ${kind} at ${findLeakPath(value, pattern)}`
      );
    }
  }
}

function findLeakPath(value, pattern, pathPrefix = "$") {
  if (typeof value === "string") {
    pattern.lastIndex = 0;
    return pattern.test(value) ? pathPrefix : "<unknown>";
  }
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const found = findLeakPath(value[index], pattern, `${pathPrefix}[${index}]`);
      if (found !== "<unknown>") return found;
    }
    return "<unknown>";
  }
  if (value && typeof value === "object") {
    for (const [key, nested] of Object.entries(value)) {
      pattern.lastIndex = 0;
      if (!pattern.test(JSON.stringify({ [key]: nested }))) continue;
      const found = findLeakPath(nested, pattern, `${pathPrefix}.${key}`);
      return found !== "<unknown>" ? found : `${pathPrefix}.${key}`;
    }
  }
  return "<unknown>";
}

function sanitizeError(error) {
  return String(error instanceof Error ? error.message : error)
    .replace(/\/Users\/[^\s"')\]]+/gu, "<local-path>")
    .replace(/\/home\/[^\s"')\]]+/gu, "<local-path>")
    .replace(/\/private\/[^\s"')\]]+/gu, "<local-path>")
    .replace(/\/var\/folders\/[^\s"')\]]+/gu, "<local-path>")
    .replace(/[A-Za-z]:\\[^\s"')\]]+/gu, "<local-path>")
    .replace(/\/Users\//gu, "<local-path>/")
    .replace(/\/private\//gu, "<local-path>/")
    .replace(/\/var\/folders\//gu, "<local-path>/")
    .replace(/Bearer\s+\S+/gu, "Bearer [redacted]")
    .replace(/\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]+\b/gu, "[redacted]")
    .slice(0, 1200);
}

const contract = await loadSecureClientContract();
const {
  SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
  SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS,
  SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH
} = contract;
const blocker = SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.find((item) => item === "pairwise/content crypto audit");
if (!blocker) {
  throw new Error("Client-pinned Secure Client Mesh contract does not define pairwise/content crypto audit blocker");
}

const sourceResults = [];
for (const check of sourceChecks) {
  sourceResults.push(await evaluateSourceCheck(check));
}

const nativeResults = nativeTestFilters.map(runNativeTest);
const vectorCorpus = await buildVectorCorpus();
const checkedAt = new Date().toISOString();
if (generateSignoffTemplate) {
  const vectorCorpusSnapshotPath = vectorCorpusSnapshotRefForCorpus(vectorCorpus);
  const template = reviewSignoffTemplateForCorpus(vectorCorpus, checkedAt, vectorCorpusSnapshotPath);
  assertNoLeak(template, "secure mesh pairwise/content review signoff template");
  assertNoLeak(vectorCorpus, "secure mesh pairwise/content vector corpus report");
  assertStableAuditSource();
  atomicWriteReportJson(
    path.join(repoRoot, "build"),
    vectorCorpusPath.replace(/^build\//u, ""),
    vectorCorpus,
  );
  atomicWriteReportJson(
    path.join(repoRoot, "build"),
    vectorCorpusSnapshotPath.replace(/^build\//u, ""),
    vectorCorpus,
  );
  atomicWriteReportJson(
    path.join(repoRoot, "build"),
    reviewSignoffPath.replace(/^build\//u, ""),
    template,
  );
  console.log(JSON.stringify({
    ok: true,
    report: reviewSignoffPath,
    vectorCorpusReport: vectorCorpusPath,
    vectorCorpusSnapshotReport: vectorCorpusSnapshotPath,
    templateWritten: true,
    corpusDigest: template.corpusDigest,
    sourceCheckCount: template.sourceCheckCount,
    nativeTestFilterCount: template.nativeTestFilterCount,
    productionReadyClaimed: false
  }, null, 2));
  process.exit(0);
}
const reviewSignoff = await loadReviewSignoffArtifact(reviewSignoffPath, vectorCorpus);
const reviewSignoffReady = reviewSignoff.ok === true &&
  reviewSignoff.independentCryptographicReviewComplete === true &&
  reviewSignoff.releaseOwnerSignoffComplete === true &&
  reviewSignoff.reviewerSignatureVerified === true &&
  reviewSignoff.releaseOwnerSignatureVerified === true &&
  reviewSignoff.authoritiesDistinct === true &&
  reviewSignoff.sourceStateDigestBound === true &&
  reviewSignoff.producerSourceDigestBound === true &&
  reviewSignoff.productionReadyClaimed !== true;
vectorCorpus.externalCryptographicReviewComplete = reviewSignoffReady;
vectorCorpus.releaseOwnerSignoffComplete = reviewSignoffReady;
const metadataResistanceSourceIds = new Set([
  "content-payload-bucket-padding-is-bounded-and-authenticated",
  "pairwise-relay-header-uses-double-ratchet-header-encryption"
]);
const metadataResistanceTestFilters = new Set([
  "secure_mesh_content_crypto_bucket_padding_hides_length_and_round_trips_boundaries",
  "secure_mesh_content_crypto_rejects_invalid_padding_and_oversized_bucket",
  "secure_mesh_pairwise_encrypted_relay_header_hides_ratchet_structure_and_rejects_tamper",
  "secure_mesh_pairwise_encrypted_headers_preserve_old_chain_envelope_out_of_order"
]);
const metadataResistanceReady = sourceResults
  .filter((result) => metadataResistanceSourceIds.has(result.id))
  .length === metadataResistanceSourceIds.size &&
  sourceResults
    .filter((result) => metadataResistanceSourceIds.has(result.id))
    .every((result) => result.ok === true) &&
  nativeResults
    .filter((result) => metadataResistanceTestFilters.has(result.id))
    .length === metadataResistanceTestFilters.size &&
  nativeResults
    .filter((result) => metadataResistanceTestFilters.has(result.id))
    .every((result) => result.ok === true);
const ok = sourceResults.every((check) => check.ok) &&
  nativeResults.every((check) => check.ok) &&
  vectorCorpus.ok;
const productionReady = false;
const clientRuntimeScopeEvidence = await createSecureClientMeshE2eeRefReportScope({
  contract,
  reportRef: reportPath,
  blocker,
  checkedAt,
});
const report = {
  ok,
  schemaVersion: "licolite.secure-mesh.pairwise-content-audit-report.v1",
  evidenceRefSchemaVersion: SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
  verifier: "tools/scripts/client-secure-mesh-pairwise-content-audit.mjs",
  generatedBy: "tools/scripts/client-secure-mesh-pairwise-content-audit.mjs",
  generatedAt: checkedAt,
  ...optionalReleaseInvocationBinding(),
  checkedAt,
  sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
  blocker,
  diagnosticStatus: "incomplete",
  productionReady,
  releaseReady: false,
  evidenceKind: "redacted-static-native-test-and-vector-corpus-evidence",
  redacted: true,
  rawPrivateMaterialIncluded: false,
  rawPlaintextIncluded: false,
  rawPublicWireBytesIncluded: false,
  reportLeakScan: true,
  ...clientRuntimeScopeEvidence,
  contractBinding: {
    sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    canonicalBlocker: blocker,
    canonicalBlockerCount: SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.length
  },
  pairwiseContentAuditConfig: {
    ref: pairwiseContentAuditConfig.configRef,
    schemaVersion: pairwiseContentAuditConfig.schemaVersion,
    sourceCheckCount: sourceChecks.length,
    nativeTestFilterCount: nativeTestFilters.length,
    reviewSignoffRefSource: pairwiseContentAuditConfig.reviewSignoffRefSource,
    reviewSignoffEnvKey: pairwiseContentAuditConfig.reviewSignoffEnvKey ? "[configured]" : ""
  },
  sourceResults,
  nativeResults,
  vectorCorpus: {
    report: vectorCorpusPath,
    schemaVersion: vectorCorpus.schemaVersion,
    ok: vectorCorpus.ok,
    redacted: vectorCorpus.redacted,
    rawPrivateMaterialIncluded: vectorCorpus.rawPrivateMaterialIncluded,
    rawPlaintextIncluded: vectorCorpus.rawPlaintextIncluded,
    rawPublicWireBytesIncluded: vectorCorpus.rawPublicWireBytesIncluded,
    entryCount: vectorCorpus.entries.length,
    corpusDigest: vectorCorpus.corpusDigest,
    signoffBinding: vectorCorpus.signoffBinding,
    externalCryptographicReviewComplete: vectorCorpus.externalCryptographicReviewComplete,
    releaseOwnerSignoffComplete: vectorCorpus.releaseOwnerSignoffComplete
  },
  reviewSignoff,
  summary: {
    verificationPassed: ok,
    metadataResistanceReady,
    sourceCheckCount: sourceResults.length,
    nativeTestCount: nativeResults.length,
    vectorCorpusGenerated: vectorCorpus.ok,
    vectorCorpusReport: vectorCorpusPath,
    vectorCorpusEntryCount: vectorCorpus.entries.length,
    reviewSignoffReport: reviewSignoffPath,
    reviewSignoffPresent: reviewSignoff.present === true,
    reviewSignoffTemplatePresent: reviewSignoff.templatePresent === true,
    reviewSignoffTemplateDigestMatched: reviewSignoff.templateDigestMatched === true,
    reviewSignoffTemplateSnapshotPresent:
      reviewSignoff.templateSnapshotPresent === true,
    reviewSignoffTemplateSnapshotDigestMatched:
      reviewSignoff.templateSnapshotDigestMatched === true,
    reviewSignoffReady,
    reviewerSignatureVerified: reviewSignoff.reviewerSignatureVerified === true,
    releaseOwnerSignatureVerified:
      reviewSignoff.releaseOwnerSignatureVerified === true,
    reviewAuthoritiesDistinct: reviewSignoff.authoritiesDistinct === true,
    reviewSourceStateDigestBound: reviewSignoff.sourceStateDigestBound === true,
    reviewProducerSourceDigestBound:
      reviewSignoff.producerSourceDigestBound === true,
    corpusDigestMatchedBySignoff: reviewSignoff.corpusDigestMatched === true,
    nativeTestFiltersDigestMatchedBySignoff:
      reviewSignoff.nativeTestFiltersDigestMatched === true,
    sourceCheckIdsDigestMatchedBySignoff:
      reviewSignoff.sourceCheckIdsDigestMatched === true,
    externalCryptographicReviewComplete:
      reviewSignoff.independentCryptographicReviewComplete === true,
    releaseOwnerSignoffComplete: reviewSignoff.releaseOwnerSignoffComplete === true,
    productionReady,
    releaseReady: false,
    reportLeakScan: true,
    remainingGates: [
      ...(reviewSignoffReady
        ? []
        : [
            "independent pairwise/content cryptographic review",
            "release-owner signoff of the generated redacted vector corpus"
          ]),
      "production platform secret-store binding",
      "physical multi-device command/result/file matrix"
    ]
  }
};

assertNoLeak(report, "secure mesh pairwise/content audit report");
assertNoLeak(vectorCorpus, "secure mesh pairwise/content vector corpus report");
assertStableAuditSource();
atomicWriteReportJson(
  path.join(repoRoot, "build"),
  vectorCorpusPath.replace(/^build\//u, ""),
  vectorCorpus,
);
atomicWriteReportJson(
  path.join(repoRoot, "build"),
  reportPath.replace(/^build\//u, ""),
  report,
);

console.log(JSON.stringify({
  ok,
  report: reportPath,
  blocker: report.blocker,
  diagnosticStatus: report.diagnosticStatus,
  productionReady,
  sourceCheckCount: sourceResults.length,
  nativeTestCount: nativeResults.length,
  vectorCorpusGenerated: report.summary.vectorCorpusGenerated,
  metadataResistanceReady: report.summary.metadataResistanceReady,
  remainingGateCount: report.summary.remainingGates.length
}, null, 2));

if (!ok || (strict && productionReady !== true)) {
  process.exitCode = 1;
}
