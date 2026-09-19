import { spawnSync } from "node:child_process";
import fs from "node:fs";

export const HELPER_PROTOCOL_VERSION = "licoup.migration.helper.v1";

export function isHelperBinaryAvailable(helperBinaryPath) {
  if (!helperBinaryPath) return false;
  try {
    return fs.existsSync(helperBinaryPath) && fs.statSync(helperBinaryPath).isFile();
  } catch {
    return false;
  }
}

export function callHelper(helperBinaryPath, request) {
  if (!isHelperBinaryAvailable(helperBinaryPath)) {
    throw new Error(`Helper binary not found or not executable at: ${helperBinaryPath}`);
  }

  const payload = JSON.stringify({
    protocol: HELPER_PROTOCOL_VERSION,
    ...request,
  });

  const proc = spawnSync(helperBinaryPath, ["migration-helper"], {
    input: payload,
    encoding: "utf8",
    timeout: 30_000,
  });

  if (proc.error) {
    throw new Error(`Helper process error: ${proc.error.message}`);
  }
  if (proc.status !== 0) {
    throw new Error(`Helper exited with code ${proc.status}: ${proc.stderr || proc.stdout}`);
  }

  try {
    return JSON.parse(proc.stdout.trim());
  } catch (err) {
    throw new Error(`Failed to parse helper output as JSON: ${err.message}`);
  }
}
