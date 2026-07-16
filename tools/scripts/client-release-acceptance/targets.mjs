import { requireValue, text } from "./util.mjs";

export function inferHostTargetId(catalog) {
  const platform = process.platform === "darwin" ? "macos" : process.platform === "win32" ? "windows" : process.platform;
  const arch = process.arch === "x64" ? "x64" : process.arch === "arm64" ? "arm64" : process.arch;
  if (platform === "linux") {
    const glibcVersion = text(process.report?.getReport?.()?.header?.glibcVersionRuntime);
    requireValue(glibcVersion,
      "Linux libc is ambiguous; set LICO_CLIENT_RELEASE_TARGETS explicitly");
  }
  const match = catalog.targets.find((target) =>
    target.platform === platform && target.arch === arch &&
    target.releaseSupported === true);
  requireValue(match, `no release-supported client target matches the current host (${platform}/${arch})`);
  return match.id;
}

export function selectedTargetIds(catalog, authorityIds) {
  const explicit = Object.hasOwn(process.env, "LICO_CLIENT_RELEASE_TARGETS");
  const requested = explicit
    ? String(process.env.LICO_CLIENT_RELEASE_TARGETS).split(",").map(text)
    : [inferHostTargetId(catalog)];
  requireValue(requested.every(Boolean),
    "release target selection contains an empty token");
  requireValue(new Set(requested).size === requested.length,
    "release target selection contains duplicates");
  const requestedSet = new Set(requested);
  const normalized = authorityIds.filter((id) => requestedSet.has(id));
  requireValue(normalized.length === requested.length,
    "release target selection is outside authority");
  return normalized;
}
