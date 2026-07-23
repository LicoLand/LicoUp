const MAX_DIAGNOSTIC_LENGTH = 1000;
const WINDOWS_SEPARATOR_PATTERN = String.raw`\\`;

export function sanitizePlanDiagnostic(value) {
  const text = value instanceof Error ? value.message : String(value || "");
  return text
    .replace(/-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----[\s\S]*?-----END(?: [A-Z0-9]+)? PRIVATE KEY-----/giu, "[redacted-private-key]")
    .replace(
      new RegExp(
        String.raw`[A-Za-z]:` +
          WINDOWS_SEPARATOR_PATTERN +
          String.raw`(?:Users|Documents and Settings)` +
          WINDOWS_SEPARATOR_PATTERN +
          String.raw`[^\s"',}<>\])]+`,
        "giu",
      ),
      "<local-path>",
    )
    .replace(/\\\\[^\s"',}<>\])]+/giu, "<local-path>")
    .replace(/\/(?:Users|home)\/[^\s"',}<>\])]+/gu, "<local-path>")
    .replace(/\/root(?:\/[^\s"',}<>\])]+)?/gu, "<local-path>")
    .replace(/\/(?:private\/)?(?:tmp|var\/folders)\/[^\s"',}<>\])]+/gu, "<local-temp>")
    .replace(/\bBearer\s+[^\s"',}]+/giu, "Bearer [redacted]")
    .replace(/([?&](?:access_token|api_key|apikey|auth|secret|token)=)[^&\s]+/giu, "$1[redacted]")
    .replace(/\b((?:access[_-]?token|api[_-]?key|authorization|ciphertext|credential|password|private[_-]?key|secret|session[_-]?key|token)=)[^\s&,]+/giu, "$1[redacted]")
    .replace(/("(?:access[_-]?token|api[_-]?key|authorization|ciphertext|credential|password|private[_-]?key|secret|session[_-]?key|token)"\s*:\s*")[^"]*"/giu, "$1[redacted]\"")
    .replace(/\b(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9._-]+|github_pat_[A-Za-z0-9._-]+|sk-(?:proj-)?[A-Za-z0-9._-]+)\b/gu, "[redacted]")
    .slice(0, MAX_DIAGNOSTIC_LENGTH);
}
