export const ANDROID_RELEASE_BUILD_PARAMETERS = Object.freeze({
  flutterMode: "release",
  targetPlatform: "android-arm64",
  entrypoint: "lib/main.dart",
  splitPerAbi: false,
  obfuscate: false,
  pubResolution: "locked-offline-preflight",
});

export function validateAndroidReleaseBuildRequest({
  mode,
  passthrough = [],
  targetPlatformEnvironment = "",
} = {}) {
  if (mode !== "release") return true;
  if (!Array.isArray(passthrough) || passthrough.length !== 0) {
    throw new Error("android_release_noncanonical_argument");
  }
  const configuredTarget = String(targetPlatformEnvironment || "").trim();
  if (configuredTarget &&
    configuredTarget !== ANDROID_RELEASE_BUILD_PARAMETERS.targetPlatform) {
    throw new Error("android_release_target_override_rejected");
  }
  return true;
}

export function androidReleaseBuildParametersReady(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    JSON.stringify(value) === JSON.stringify(ANDROID_RELEASE_BUILD_PARAMETERS);
}
