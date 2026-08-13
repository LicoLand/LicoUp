export const MACOS_RELEASE_SIGNER_FINGERPRINT_PATTERN = /^sha256:[a-f0-9]{64}$/u;

export function expectedMacosReleaseSignerFingerprint(environment = process.env) {
  const raw = String(environment.LICO_MACOS_RELEASE_SIGNER_SHA256 || "")
    .trim()
    .toLowerCase();
  const normalized = raw.startsWith("sha256:") ? raw : `sha256:${raw}`;
  if (!MACOS_RELEASE_SIGNER_FINGERPRINT_PATTERN.test(normalized)) {
    throw new Error("audit_release_identity_unstable");
  }
  return normalized;
}
