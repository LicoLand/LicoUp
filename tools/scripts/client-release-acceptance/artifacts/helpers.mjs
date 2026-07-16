import { spawnSync } from "node:child_process";
import path from "node:path";
import { repoRoot } from "../constants.mjs";
import { text } from "../util.mjs";

export function plistValue(appPath, key) {
  const result = spawnSync("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, path.join(appPath, "Contents", "Info.plist")], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
    timeout: 5_000
  });
  return result.status === 0 ? text(result.stdout) : "";
}

export function artifactPlatformVersion(spec, productVersion) {
  if (spec.versionPolicy === "numeric-core") {
    return productVersion.split("-", 1)[0];
  }
  return productVersion;
}
