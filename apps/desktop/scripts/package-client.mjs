import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { publicPackageFailure } from "./package-client/cli-policy.mjs";
import { packageClient } from "./package-client/orchestrator.mjs";

export { validateReleaseBuildPolicy } from "./package-client/cli-policy.mjs";
export { validatePackagingConfig } from "./package-client/config-codec.mjs";
export {
  assertReleaseSourceDigestStable,
  diffReleaseSourceManifests,
  packageSourceStateBinding,
} from "./package-client/portable-manifest.mjs";
export { packageClient } from "./package-client/orchestrator.mjs";

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "")) {
  try {
    packageClient();
  } catch (error) {
    console.error(JSON.stringify(publicPackageFailure(error)));
    process.exitCode = 1;
  }
}
