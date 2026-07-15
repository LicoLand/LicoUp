const ALLOWED_RELEASE_TOOL_ENVIRONMENT = Object.freeze([
  "HOME",
  "USER",
  "LOGNAME",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "TZ",
  "TMPDIR",
  "TMP",
  "TEMP",
  "SystemRoot",
  "ComSpec",
  "PATHEXT",
  "ADB_VENDOR_KEYS",
]);

export function minimalReleaseToolEnvironment(base = process.env, overrides = {}) {
  const environment = {};
  for (const name of ALLOWED_RELEASE_TOOL_ENVIRONMENT) {
    const value = String(base?.[name] || "");
    if (value) environment[name] = value;
  }
  for (const [name, value] of Object.entries(overrides)) {
    if (value !== undefined && value !== null && String(value)) {
      environment[name] = String(value);
    }
  }
  return Object.freeze(environment);
}
