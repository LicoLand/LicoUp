#!/usr/bin/env node
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import {
  pairwiseReviewStatementBytes,
  reviewSignatureDigest,
  verifyPairwiseReviewSignoff,
} from "./lib/review-signoff-verifier.mjs";

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function keyRecord(authority, keyId, publicKey) {
  const bytes = publicKey.export({ type: "spki", format: "der" });
  return {
    authority,
    keyId,
    publicKeySpkiBase64: bytes.toString("base64"),
    publicKeyFingerprint:
      `sha256:${createHash("sha256").update(bytes).digest("hex")}`,
  };
}

const reviewerKeys = generateKeyPairSync("ed25519");
const ownerKeys = generateKeyPairSync("ed25519");
const binding = {
  schemaVersion: "licomesh.secure-mesh.pairwise-content-review-signoff-binding.v2",
  corpusSchemaVersion: "licomesh.secure-mesh.pairwise-content-vector-corpus.v1",
  corpusDigest: `sha256:${"1".repeat(64)}`,
  corpusEntryCount: 3,
  corpusEntryIdsDigest: `sha256:${"2".repeat(64)}`,
  sourceCheckCount: 7,
  sourceCheckIdsDigest: `sha256:${"3".repeat(64)}`,
  nativeTestFilterCount: 11,
  nativeTestFiltersDigest: `sha256:${"4".repeat(64)}`,
  sourceStateDigest: `sha256:${"5".repeat(64)}`,
  producerSourceDigest: `sha256:${"6".repeat(64)}`,
};
const signoff = {
  schemaVersion: "licomesh.secure-mesh.pairwise-content-review-signoff.v2",
  sourceOfTruth: "self-test-authority",
  independentCryptographicReviewComplete: true,
  releaseOwnerSignoffComplete: true,
  releaseDecision: "approved_for_release_gate",
  productionReadyClaimed: false,
  reviewer: {
    authority: "independent-review-board",
    keyId: "reviewer-self-test",
    signedAt: "2030-01-01T00:00:00.000Z",
    signatureBase64: "",
  },
  releaseOwner: {
    authority: "release-owner-board",
    keyId: "owner-self-test",
    signedAt: "2030-01-01T00:01:00.000Z",
    signatureBase64: "",
  },
};
signoff.reviewer.signatureBase64 = sign(
  null,
  pairwiseReviewStatementBytes({
    binding,
    signoff,
    role: "independent-reviewer",
    signer: signoff.reviewer,
  }),
  reviewerKeys.privateKey,
).toString("base64");
signoff.releaseOwner.signatureBase64 = sign(
  null,
  pairwiseReviewStatementBytes({
    binding,
    signoff,
    role: "release-owner",
    signer: signoff.releaseOwner,
    reviewerSignatureDigest: reviewSignatureDigest(
      signoff.reviewer.signatureBase64,
    ),
  }),
  ownerKeys.privateKey,
).toString("base64");
const authorities = {
  reviewerKeys: [keyRecord(
    signoff.reviewer.authority,
    signoff.reviewer.keyId,
    reviewerKeys.publicKey,
  )],
  releaseOwnerKeys: [keyRecord(
    signoff.releaseOwner.authority,
    signoff.releaseOwner.keyId,
    ownerKeys.publicKey,
  )],
};

requireValue(verifyPairwiseReviewSignoff({ binding, signoff, authorities }).ready,
  "valid independent review and owner signatures must pass");
requireValue(!verifyPairwiseReviewSignoff({
  binding: { ...binding, sourceStateDigest: `sha256:${"7".repeat(64)}` },
  signoff,
  authorities,
}).ready, "source-state substitution must fail");
requireValue(!verifyPairwiseReviewSignoff({
  binding,
  signoff: { ...signoff, releaseDecision: "rejected" },
  authorities,
}).ready, "decision substitution must fail");
requireValue(!verifyPairwiseReviewSignoff({
  binding,
  signoff: {
    ...signoff,
    reviewer: { ...signoff.reviewer, signatureBase64: "" },
  },
  authorities,
}).ready, "boolean-only review artifact must fail");
requireValue(!verifyPairwiseReviewSignoff({
  binding,
  signoff,
  authorities: {
    reviewerKeys: authorities.reviewerKeys,
    releaseOwnerKeys: authorities.reviewerKeys,
  },
}).ready, "reviewer and owner authority reuse must fail");
requireValue(!verifyPairwiseReviewSignoff({
  binding,
  signoff,
  authorities: { reviewerKeys: [], releaseOwnerKeys: [] },
}).ready, "untrusted signing keys must fail");

console.log(JSON.stringify({ ok: true, caseCount: 6 }));
