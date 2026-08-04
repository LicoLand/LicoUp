export function createFailureCollector() {
  const failures = [];

  function fail(message) {
    failures.push(message);
  }

  function assert(condition, message) {
    if (!condition) {
      fail(message);
    }
  }

  return { assert, fail, failures };
}

export function sameSet(actual, expected) {
  return actual.length === expected.length && expected.every((item) => actual.includes(item));
}

export function moduleSupportsPlatform(moduleConfig, platform) {
  const platforms = Array.isArray(moduleConfig?.platforms) ? moduleConfig.platforms : [];
  return platforms.length === 0 || platforms.includes(platform);
}

export function collectEnumValues(source, enumName) {
  const match = source.match(new RegExp(`enum\\s+${enumName}\\s*\\{(.*?)\\}`, "s"));
  if (!match) {
    return [];
  }
  return match[1]
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean)
    .map((item) => item.split(/\s|\(/)[0]);
}

export function collectRustPubMods(source) {
  return [...source.matchAll(/^pub mod ([A-Za-z0-9_]+);$/gm)]
    .map((match) => match[1])
    .sort();
}

export function lineNumberForToken(source, token) {
  const lines = source.split(/\r?\n/);
  const index = lines.findIndex((line) => line.includes(token));
  return index >= 0 ? index + 1 : 1;
}
