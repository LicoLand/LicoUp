import path from "node:path";
import { stableReadFile } from "../lib/client-release-artifact-digest.mjs";
import { repoRoot } from "./constants.mjs";
import { parseJson } from "./util/json.mjs";

export function clientVersionManifest() {
  const manifest = parseJson(stableReadFile(
    path.join(repoRoot, "tools", "client-version.json"),
  ).toString("utf8"));
  if (!Number.isInteger(manifest.buildNumber) || manifest.buildNumber <= 0) {
    throw new Error("Client build number is invalid");
  }
  return manifest;
}

export function clientProductVersion() {
  const manifest = clientVersionManifest();
  const productVersion = String(manifest.productVersion || "").trim();
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(productVersion)) {
    throw new Error("Client product version is invalid");
  }
  return productVersion;
}
