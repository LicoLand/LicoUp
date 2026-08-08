export function stableUniquePaths(paths) {
  return Array.from(new Set(paths.map((item) => String(item || "")).filter(Boolean))).sort();
}

export function missingFieldPaths(checks) {
  return stableUniquePaths(
    checks
      .filter(([, ready]) => ready !== true)
      .map(([field]) => field),
  );
}

export function hasOwn(object, field) {
  return Object.prototype.hasOwnProperty.call(object, field);
}

export function stringList(value) {
  return Array.isArray(value)
    ? value.map((item) => String(item || "").trim()).filter(Boolean).sort()
    : [];
}

export function objectContainsAnyKeyOrValue(value, forbidden) {
  if (Array.isArray(value)) {
    return value.some((item) => objectContainsAnyKeyOrValue(item, forbidden));
  }
  if (value && typeof value === "object") {
    return Object.entries(value).some(([key, item]) =>
      forbidden.has(key) || objectContainsAnyKeyOrValue(item, forbidden)
    );
  }
  return forbidden.has(String(value || ""));
}
