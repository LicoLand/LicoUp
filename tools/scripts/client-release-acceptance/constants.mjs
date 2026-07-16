import path from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
export const configPath = path.join(repoRoot, "tools/scripts/config/client-release-acceptance.json");
export const outputPath = path.join(repoRoot, "build/reports/client-release-acceptance.json");
export const VERIFIER_REF = "tools/scripts/client-release-acceptance.mjs";
export const SHA256 = /^sha256:[a-f0-9]{64}$/u;
export const maxJsonBytes = 16 * 1024 * 1024;
export const maxProducerBytes = 16 * 1024 * 1024;
export const maxMacosSidecarBytes = 512 * 1024 * 1024;
export const maxMacosArchiveBytes = 8 * 1024 * 1024 * 1024;
