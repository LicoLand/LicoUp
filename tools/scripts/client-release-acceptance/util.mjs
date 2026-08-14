import { ANDROID_APK_RESOURCE_LIMITS } from "../lib/android-apk-facts.mjs";
import { stableReadFile } from "../lib/client-release-artifact-digest.mjs";
import { maxJsonBytes, maxMacosArchiveBytes } from "./constants.mjs";

export function artifactFileByteLimit(spec) {
  return spec?.artifactKind === "android-apk"
    ? ANDROID_APK_RESOURCE_LIMITS.maxApkBytes
    : spec?.artifactKind === "macos-distribution-archive"
      ? maxMacosArchiveBytes
      : maxJsonBytes;
}

export function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

export function text(value) {
  return String(value || "").trim();
}

export function readJson(filePath) {
  return JSON.parse(stableReadFile(filePath, { maxBytes: maxJsonBytes }).toString("utf8"));
}

export function allPassed(results) {
  return Array.isArray(results) && results.length > 0 && results.every((item) => item?.ok === true);
}

export function result(id, conditions) {
  const blockers = conditions.filter((item) => !item.ok).map((item) => item.blocker);
  return { id, ok: blockers.length === 0, blockers };
}
