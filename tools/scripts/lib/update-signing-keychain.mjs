import { spawnSync } from "node:child_process";
import { createPrivateKey } from "node:crypto";

export const UPDATE_SIGNING_KEYCHAIN_SERVICES = Object.freeze({
  offlineRoot: "land.lico.licoup.release-update.offline-root",
  onlineSigning: "land.lico.licoup.release-update.online-signing",
});

function privateKeyFromKeychain(service) {
  const result = spawnSync("/usr/bin/security", [
    "find-generic-password", "-s", service, "-w",
  ], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 120_000,
    maxBuffer: 32 * 1024,
  });
  const value = String(result.stdout || "").trim();
  if (result.error || result.status !== 0 || !/^[A-Za-z0-9+/=]{1,16384}$/u.test(value)) {
    throw new Error("update_signing_keychain_unavailable");
  }
  try {
    return createPrivateKey({
      key: Buffer.from(value, "base64"), format: "der", type: "pkcs8",
    }).export({ format: "pem", type: "pkcs8" }).toString();
  } catch {
    throw new Error("update_signing_keychain_unavailable");
  }
}

export function updateSigningKeyEnvironment(baseEnvironment = process.env) {
  return {
    ...baseEnvironment,
    LICO_UPDATE_OFFLINE_ROOT_KEY: privateKeyFromKeychain(
      UPDATE_SIGNING_KEYCHAIN_SERVICES.offlineRoot),
    LICO_UPDATE_ONLINE_SIGNING_KEY: privateKeyFromKeychain(
      UPDATE_SIGNING_KEYCHAIN_SERVICES.onlineSigning),
  };
}
