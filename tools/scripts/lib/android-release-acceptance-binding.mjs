import { createHash, randomBytes } from "node:crypto";

import {
  RELEASE_CLOSURE_CHALLENGE_ENV,
  RELEASE_INVOCATION_NONCE_ENV,
  releaseClosureChallengeDigest,
  releaseInvocationNonceDigest,
  requiredReleaseClosureChallenge,
  requiredReleaseInvocationNonce,
  validateReleaseClosureChallenge,
} from "./release-closure-challenge.mjs";

export const ANDROID_RELEASE_ACCEPTANCE_CHANNEL =
  "licomesh.android.release-acceptance.v1";
export const ANDROID_RELEASE_ACCEPTANCE_ACTION =
  "land.lico.licoup.RELEASE_ACCEPTANCE";
export const ANDROID_RELEASE_ACCEPTANCE_RECEIVER =
  "land.lico.licoup/land.lico.licoup.ReleaseAcceptanceReceiver";
export const ANDROID_RELEASE_CLOSURE_CHALLENGE_EXTRA =
  "land.lico.licoup.extra.RELEASE_CLOSURE_CHALLENGE";
export const ANDROID_RELEASE_INVOCATION_NONCE_EXTRA =
  "land.lico.licoup.extra.RELEASE_INVOCATION_NONCE";
export const ANDROID_RELEASE_REQUEST_NONCE_EXTRA =
  "land.lico.licoup.extra.RELEASE_REQUEST_NONCE";
export const ANDROID_RELEASE_REQUEST_SEQUENCE_EXTRA =
  "land.lico.licoup.extra.RELEASE_REQUEST_SEQUENCE";
export const ANDROID_RELEASE_NATIVE_ACTION_EXTRA = "lico_native_action";
export const ANDROID_RELEASE_NATIVE_ACTION_PARAMS_EXTRA = "lico_params_b64";

export function createAndroidReleaseAcceptanceRequest({
  action,
  sequence,
  env = process.env,
  requestNonce = randomBytes(32).toString("base64url"),
}) {
  const normalizedAction = String(action || "");
  requireValue(normalizedAction.length > 0, "Android native action is required");
  requireValue(
    Number.isSafeInteger(sequence) && sequence > 0,
    "Android native-action request sequence is invalid",
  );
  const closureChallenge = requiredReleaseClosureChallenge(env);
  const invocationNonce = requiredReleaseInvocationNonce(env);
  const canonicalRequestNonce = validateReleaseClosureChallenge(requestNonce);
  return Object.freeze({
    action: normalizedAction,
    sequence,
    closureChallenge,
    invocationNonce,
    requestNonce: canonicalRequestNonce,
    closureChallengeDigest: releaseClosureChallengeDigest(closureChallenge),
    invocationNonceDigest: releaseInvocationNonceDigest(invocationNonce),
    requestNonceDigest: releaseClosureChallengeDigest(canonicalRequestNonce),
    actionDigest: `sha256:${createHash("sha256")
      .update(normalizedAction, "utf8")
      .digest("hex")}`,
  });
}

function androidReleaseAcceptanceBindingExtras(binding, includeRequest) {
  const extras = [
    "--es",
    ANDROID_RELEASE_CLOSURE_CHALLENGE_EXTRA,
    binding.closureChallenge,
    "--es",
    ANDROID_RELEASE_INVOCATION_NONCE_EXTRA,
    binding.invocationNonce,
  ];
  if (!includeRequest) return extras;
  extras.push(
    "--es",
    ANDROID_RELEASE_REQUEST_NONCE_EXTRA,
    binding.requestNonce,
    "--el",
    ANDROID_RELEASE_REQUEST_SEQUENCE_EXTRA,
    String(binding.sequence),
  );
  return extras;
}

export function androidReleaseAcceptanceAuthorizationBroadcastArgs({
  closureChallenge,
  invocationNonce,
}) {
  const binding = {
    closureChallenge: validateReleaseClosureChallenge(closureChallenge),
    invocationNonce: validateReleaseClosureChallenge(invocationNonce),
  };
  return [
    "shell",
    "am",
    "broadcast",
    "-a",
    ANDROID_RELEASE_ACCEPTANCE_ACTION,
    "-n",
    ANDROID_RELEASE_ACCEPTANCE_RECEIVER,
    ...androidReleaseAcceptanceBindingExtras(binding, false),
  ];
}

export function androidReleaseAcceptanceRequestBroadcastArgs({
  binding,
  action,
  paramsBase64Url,
}) {
  const normalizedAction = String(action || "");
  const normalizedParams = String(paramsBase64Url || "");
  requireValue(normalizedAction.length > 0, "Android native action is required");
  requireValue(
    normalizedParams.length > 0 && /^[A-Za-z0-9_-]+$/u.test(normalizedParams),
    "Android native-action params are invalid",
  );
  return [
    "shell",
    "am",
    "broadcast",
    "-a",
    ANDROID_RELEASE_ACCEPTANCE_ACTION,
    "-n",
    ANDROID_RELEASE_ACCEPTANCE_RECEIVER,
    "--es",
    ANDROID_RELEASE_NATIVE_ACTION_EXTRA,
    normalizedAction,
    "--es",
    ANDROID_RELEASE_NATIVE_ACTION_PARAMS_EXTRA,
    normalizedParams,
    ...androidReleaseAcceptanceBindingExtras(binding, true),
  ];
}

export function androidReleaseAcceptanceBroadcastAccepted(output) {
  const value = String(output || "");
  return /Broadcast completed:\s*result=-1(?:,|\s|$)/u.test(value) &&
    value.includes("release_acceptance_staged");
}

export function assertAndroidReleaseAcceptanceResultBinding(result, expected) {
  requireValue(result && typeof result === "object",
    "Android native-action result is missing");
  requireValue(
    result.releaseAcceptanceChannel === ANDROID_RELEASE_ACCEPTANCE_CHANNEL,
    "Android release acceptance channel version mismatch",
  );
  for (const field of [
    "closureChallengeDigest",
    "invocationNonceDigest",
    "requestNonceDigest",
    "actionDigest",
  ]) {
    requireValue(
      result[field] === expected[field],
      `Android native-action result ${field} mismatch`,
    );
  }
  requireValue(
    Number(result.sequence) === expected.sequence,
    "Android native-action result sequence mismatch",
  );
  requireValue(
    result.bodyRedacted === true,
    "Android native-action result is not marked redacted",
  );
  return result;
}

export function androidReleaseAcceptanceAuthorizationRequired(result) {
  return String(result?.code || result?.status || "") === "authorization_required";
}

export function androidReleaseAcceptanceAuthorizationApproved(result) {
  return String(result?.code || result?.status || "") === "authorization_approved";
}

export function androidReleaseAcceptanceAuthorizationDenied(result) {
  return String(result?.code || result?.status || "") === "authorization_denied";
}

export function releaseAcceptanceSelfTestEnvironment() {
  return {
    [RELEASE_CLOSURE_CHALLENGE_ENV]: randomBytes(32).toString("base64url"),
    [RELEASE_INVOCATION_NONCE_ENV]: randomBytes(32).toString("base64url"),
  };
}

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}
