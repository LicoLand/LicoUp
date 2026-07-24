import path from "node:path";
import { fileURLToPath } from "node:url";
import { CANONICAL_CLIENT_SOURCE_ROOTS } from "../lib/client-source-state-digest.mjs";
import { loadSecureMeshPhysicalEvidenceConfig } from "../lib/secure-mesh-physical-evidence-config.mjs";

export const repoRoot = path.resolve(
  fileURLToPath(new URL("../../..", import.meta.url)),
);
export const VERIFIER_PATH = "tools/scripts/client-android-physical-install-launch.mjs";
export const defaultPackageName = "land.lico.licoup";
export const runtimeStatusRelativePath = "files/secure-mesh/android-runtime-status.json";
export const ANDROID_AUTHENTICATED_PAIRWISE_RUNTIME_STATUS =
  "authenticated_pairwise_runtime_bound_to_selected_custody";
export const SHA256_DIGEST = /^sha256:[a-f0-9]{64}$/u;
export const clientSourceRoots = CANONICAL_CLIENT_SOURCE_ROOTS;

const physicalEvidenceConfig = await loadSecureMeshPhysicalEvidenceConfig();
export const reportPath = physicalEvidenceConfig.linkedReports.androidInstallLaunch;
