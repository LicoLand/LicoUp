import { chmodSync, mkdirSync } from "node:fs";
import path from "node:path";

import { packageClientRuntime } from "../cli-policy.mjs";
import { runPackageProcess } from "../process-runner.mjs";
import { cargoTargetDir } from "./native.mjs";

export function buildSwiftSidecars(selected, options) {
  if (
    options.platform !== "macos" ||
    options.skipNativeBuild ||
    options.dryRun
  ) {
    return;
  }
  for (const moduleConfig of selected.filter(
    (item) => item.packaging === "swift-sidecar",
  )) {
    const source = path.join(
      packageClientRuntime.workspaceRoot,
      moduleConfig.swiftSource || "",
    );
    const artifactName = moduleConfig.artifactName || moduleConfig.id;
    const target = path.join(
      cargoTargetDir(options.mode, options),
      artifactName,
    );
    mkdirSync(path.dirname(target), { recursive: true });
    runPackageProcess(
      "xcrun",
      ["swiftc", "-parse-as-library", "-O", "-o", target, source],
      {
        failureCode: "swift_sidecar_build_failed",
        stage: "swift-build",
      },
    );
    chmodSync(target, 0o755);
  }
}
