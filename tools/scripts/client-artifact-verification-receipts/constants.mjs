import path from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
export const configRef = "tools/scripts/config/client-artifact-verification-receipts.json";
export const configPath = path.join(repoRoot, configRef);
export const producer = "tools/scripts/client-artifact-verification-receipts.mjs";
export const canonicalReportRef = "build/reports/client-artifact-verification-receipts.json";
export const digestPattern = /^sha256:[a-f0-9]{64}$/u;
export const maxJsonBytes = 16 * 1024 * 1024;
export const maxProducerBytes = 16 * 1024 * 1024;
export const maxArtifactFileBytes = 8 * 1024 * 1024 * 1024;
