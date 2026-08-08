export function sanitizeError(error) {
  return String(error instanceof Error ? error.message : error)
    .replace(/adb\s+-s\s+\S+/gu, "adb -s [redacted]")
    .replace(/\/Users\/[^/\s"]+/gu, "<user-home>")
    .replace(/\/private\/var\/folders\/[^\s"]+/gu, "<local-temp>")
    .replace(/\/sdcard\/[^\s"]+/gu, "<android-external-path>")
    .replace(/\/data\/data\/[^\s"]+/gu, "<android-private-path>")
    .replace(/[A-Za-z]:\\[^\s"]+/gu, "<local-path>")
    .replace(/Bearer\s+\S+/gu, "Bearer [redacted]")
    .replace(/\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]+\b/gu, "[redacted]")
    .replace(/android-physical-plaintext-canary-[0-9a-fA-F-]+/gu, "android-physical-plaintext-canary-[redacted]")
    .replace(/android-lifecycle-private-[0-9a-fA-F-]+/gu, "android-lifecycle-private-[redacted]")
    .replace(/YW5kcm9pZC1waHlzaWNhbC1wbGFpbnRleHQtY2FuYXJ5[A-Za-z0-9+/_=-]*/gu, "android-physical-plaintext-canary:[redacted]")
    .replace(/616e64726f69642d706879736963616c2d706c61696e746578742d63616e617279[0-9a-fA-F]*/gu, "android-physical-plaintext-canary:[redacted]")
    .slice(0, 1200);
}
