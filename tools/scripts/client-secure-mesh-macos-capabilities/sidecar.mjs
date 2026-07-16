import path from "node:path";
import { resolveContainedExistingPath } from "../lib/client-release-artifact-digest.mjs";
import { run } from "./util.mjs";

export function sidecarSmoke(appPath) {
  const sidecar = resolveContainedExistingPath(
    appPath,
    path.join(appPath, "Contents/MacOS/lico-client"),
    { expectedKind: "file" },
  );
  const result = run(sidecar, [
    "targets",
    "scan",
    "--include-accessible-environments",
    "false",
    "--include-history-model-catalog",
    "false",
  ]);
  if (result.status !== 0) return false;
  try {
    const decoded = JSON.parse(result.stdout);
    return decoded?.ok === true && Array.isArray(decoded.candidates);
  } catch {
    return false;
  }
}
