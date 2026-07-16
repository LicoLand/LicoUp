import { physicalReleaseApkReady } from "./apk/inspect.mjs";
import { successfulAdbInstall } from "./operations/install.mjs";
import {
  normalizeLaunchComponent,
  parseAmStartResult,
} from "./operations/launch.mjs";
import { assertNoLeak } from "./privacy/leak-scan.mjs";
import {
  selectRuntimeStatusOutput,
  validateRuntimeStatus,
} from "./runtime/status.mjs";

export function runSelfTest() {
  const releaseApk = {
    mode: "release",
    debuggable: false,
    signingKind: "local-install-keystore",
  };
  if (!physicalReleaseApkReady(releaseApk) ||
    physicalReleaseApkReady({ ...releaseApk, debuggable: true }) ||
    physicalReleaseApkReady({ ...releaseApk, signingKind: "local-debug" })) {
    throw new Error("android_release_apk_policy_self_test_failed");
  }
  if (!successfulAdbInstall({ ok: true, stdout: "Success\n" }) ||
    successfulAdbInstall({ ok: true, stdout: "Failure [test]\n" }) ||
    successfulAdbInstall({ ok: false, stdout: "Success\n" })) {
    throw new Error("android_install_result_self_test_failed");
  }
  const component = "com.liko.arc/com.liko.arc.MainActivity";
  if (!parseAmStartResult(`Status: ok\nActivity: ${component}\n`, component).ready ||
    parseAmStartResult(`Status: ok\nActivity: com.liko.arc/.Other\n`, component).ready ||
    parseAmStartResult(`Status: timeout\nActivity: ${component}\n`, component).ready) {
    throw new Error("android_launch_result_self_test_failed");
  }
  const same = selectRuntimeStatusOutput("{\"ok\":true}", "{\"ok\":true}");
  const conflict = selectRuntimeStatusOutput("{\"ok\":true}", "{\"ok\":false}");
  if (!same.ok || conflict.ok || conflict.source !== "conflicting-runtime-status") {
    throw new Error("android_runtime_status_conflict_self_test_failed");
  }
  const unprovenRuntime = validateRuntimeStatus({}, "closure", "invocation");
  if (unprovenRuntime.ok ||
    !unprovenRuntime.missing.includes("freshOneShotAuthorizationPolicy") ||
    unprovenRuntime.freshOneShotAuthorizationPolicyReady) {
    throw new Error("android_unproven_one_shot_authorization_must_block");
  }
  if (normalizeLaunchComponent("com.liko.arc/.MainActivity") !== component ||
    normalizeLaunchComponent("com.other/.MainActivity") === component) {
    throw new Error("android_launch_component_self_test_failed");
  }
  let stableIdentityRejected = false;
  try {
    const hostileCertificateDigestKey = ["certificate", "Identity", "Digest"].join("");
    assertNoLeak(
      { [hostileCertificateDigestKey]: `sha256:${"a".repeat(64)}` },
      "Android privacy self-test",
    );
  } catch {
    stableIdentityRejected = true;
  }
  if (!stableIdentityRejected) {
    throw new Error("android_stable_signing_identity_privacy_self_test_failed");
  }
  return { ok: true, mode: "self-test", caseCount: 13, privatePathsIncluded: false };
}
