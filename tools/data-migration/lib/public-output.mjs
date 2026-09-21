import fs from "node:fs";

// The public output boundary for this tool.
//
// Reports and CLI failures carry stable identities — domain ids, schema
// versions, step ids, symbolic codes, and root-relative artifact refs — and
// nothing that describes this machine or this user's documents: no absolute
// paths, no stored values echoed out of an error message, no credential-shaped
// text, no stacks. This mirrors the repository's existing redaction discipline
// (explicit placeholders, raw material kept out of the report) instead of
// adding a framework.
//
// Only the emitted projection is redacted. Internal execution keeps the real
// root, so probing, journals, recovery and the on-disk artifacts still identify
// the root they run against.

export const DATA_ROOT_REF = "<data-root>";
export const PATH_REF = "<path>";
export const CREDENTIAL_REF = "<redacted-credential>";
export const INVALID_JSON_MESSAGE = "invalid JSON document";

const JSON_PARSE_ERROR =
  /Unexpected token|Unexpected end of JSON input|not valid JSON|in JSON at position/iu;
const CREDENTIAL_PATTERN = /(?:sk-|ghp_|github_pat_|AKIA|xox[baprs]-)[A-Za-z0-9_-]{8,}/gu;
const POSIX_PATH_PATTERN = /(?:^|[\s('"=:,\[])((?:\/(?!\/)[^\s'"()[\]:]+)+)/gu;
const WINDOWS_PATH_PATTERN = /(?:^|[\s('"=:,\[])([A-Za-z]:\\(?:[^\\\s'"]+\\)*[^\\\s'"]*)/gu;
const STACK_FRAME_PATTERN = /^[ \t]*at\s+.*$/gmu;

function candidateRoots(dataRoot) {
  const roots = new Set();
  for (const value of [dataRoot, safeRealpath(dataRoot)]) {
    if (typeof value === "string" && value.length > 1) roots.add(value);
  }
  // Longest first: a realpath that contains the given path must win.
  return [...roots].sort((left, right) => right.length - left.length);
}

function safeRealpath(value) {
  try {
    return fs.realpathSync(value);
  } catch {
    return null;
  }
}

function replaceRoots(text, dataRoot) {
  let out = text;
  for (const root of candidateRoots(dataRoot)) {
    out = out.split(root).join(DATA_ROOT_REF);
  }
  return out;
}

/**
 * A message safe to print. Absolute paths become `<data-root>` (when they are
 * under the root the command runs against) or `<path>`; a parse error never
 * repeats the bytes it quoted, because those are the user's document; a stack
 * frame has no place in a report.
 */
export function redactPublicText(value, dataRoot) {
  const text = String(value ?? "");
  let out = replaceRoots(text, dataRoot);
  if (JSON_PARSE_ERROR.test(out)) {
    // Keep the structural sentence (code, domain, what was being read) and drop
    // everything the parser quoted.
    const cut = out.search(/["']/u);
    const prefix = (cut >= 0 ? out.slice(0, cut) : out).replace(/[\s,:;.-]+$/u, "");
    if (prefix.length === 0) return INVALID_JSON_MESSAGE;
    return prefix.includes(INVALID_JSON_MESSAGE)
      ? prefix
      : `${prefix}: ${INVALID_JSON_MESSAGE}`;
  }
  out = out.replace(CREDENTIAL_PATTERN, CREDENTIAL_REF);
  out = out.replace(
    POSIX_PATH_PATTERN,
    (match, pathText) => `${match.slice(0, match.length - pathText.length)}${PATH_REF}`,
  );
  out = out.replace(
    WINDOWS_PATH_PATTERN,
    (match, pathText) => `${match.slice(0, match.length - pathText.length)}${PATH_REF}`,
  );
  out = out.replace(STACK_FRAME_PATTERN, "");
  return out;
}

/** The same projection applied through a report's nested values. */
export function redactPublicValue(value, dataRoot) {
  if (typeof value === "string") return redactPublicText(value, dataRoot);
  if (Array.isArray(value)) return value.map((item) => redactPublicValue(item, dataRoot));
  if (value && typeof value === "object") {
    const projected = {};
    for (const [key, item] of Object.entries(value)) {
      projected[key] = redactPublicValue(item, dataRoot);
    }
    return projected;
  }
  return value;
}

/**
 * A failure as it may be published: a symbolic code, a message carrying the
 * domain/step identity the tool already knows, and never a stack or an echoed
 * input value.
 */
export function publicError(error, dataRoot) {
  const rawMessage =
    typeof error?.message === "string" ? error.message : String(error ?? "");
  const explicitCode =
    typeof error?.code === "string" && /^[A-Za-z][A-Za-z0-9_]*$/u.test(error.code)
      ? error.code
      : null;
  const prefixedCode = /^([a-z][a-z0-9_]*):\s/u.exec(rawMessage)?.[1] ?? null;
  const code = explicitCode ?? prefixedCode ?? "error";
  const message = rawMessage.startsWith(`${code}: `)
    ? rawMessage
    : `${code}: ${rawMessage}`;
  return {
    status: "error",
    code,
    message: redactPublicText(message, dataRoot),
  };
}
