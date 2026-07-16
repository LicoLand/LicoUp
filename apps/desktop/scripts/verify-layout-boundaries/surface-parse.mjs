import { matchingDelimiter } from "./dart-source.mjs";
import { fail } from "./errors.mjs";
import { normalizeRelative } from "./paths.mjs";

export function parseSurfaceIdentities(source, relativePath) {
  const declaration = /\benum\s+LayoutRuntimeSurface\s*\{([^}]*)\}/su.exec(
    source,
  );
  if (!declaration) {
    fail("layout_surface_contract_missing", relativePath);
  }
  const identities = new Set();
  for (const candidate of declaration[1].split(";", 1)[0].split(",")) {
    const identity = candidate
      .replace(/\/\*[\s\S]*?\*\//gu, "")
      .replace(/\/\/.*$/gmu, "")
      .trim();
    if (!identity) {
      continue;
    }
    if (!/^[a-z][A-Za-z0-9_]*$/u.test(identity)) {
      fail("layout_surface_contract_invalid", relativePath);
    }
    if (identities.has(identity)) {
      fail("layout_surface_identity_duplicate", relativePath);
    }
    identities.add(identity);
  }
  if (identities.size === 0) {
    fail("layout_surface_contract_missing", relativePath);
  }
  return identities;
}

export function parseDefinitionBundleSymbols(source, relativePath) {
  const groups = [];
  const expression = /\bLayoutDefinition\s*\(/gu;
  for (const match of source.matchAll(expression)) {
    const openParenthesis = source.indexOf("(", match.index);
    const closeParenthesis = matchingDelimiter(
      source,
      openParenthesis,
      "(",
      ")",
      "layout_composition_definition_unclosed",
      relativePath,
    );
    const body = source.slice(openParenthesis + 1, closeParenthesis);
    const openBracket = body.search(/\[/u);
    if (openBracket < 0) {
      fail("layout_composition_definition_invalid", relativePath);
    }
    const closeBracket = matchingDelimiter(
      body,
      openBracket,
      "[",
      "]",
      "layout_composition_bundle_list_unclosed",
      relativePath,
    );
    if (body.slice(closeBracket + 1).replace(/[,\s]/gu, "")) {
      fail("layout_composition_definition_invalid", relativePath);
    }
    const symbols = body
      .slice(openBracket + 1, closeBracket)
      .split(",")
      .map((value) => value.replace(/\/\*[\s\S]*?\*\//gu, "").trim())
      .filter(Boolean);
    if (
      symbols.length === 0 ||
      symbols.some((symbol) => !/^[A-Za-z_]\w*$/u.test(symbol))
    ) {
      fail("layout_composition_bundle_list_invalid", relativePath);
    }
    groups.push(symbols);
  }
  if (groups.length === 0) {
    fail("layout_composition_definition_missing", relativePath);
  }
  return groups;
}

export function uniqueMatch(source, expression, code, relativePath) {
  const matches = new Set();
  for (const match of source.matchAll(expression)) {
    matches.add(match[1]);
  }
  if (matches.size !== 1) {
    fail(code, relativePath);
  }
  return [...matches][0];
}

export function profileSurfaceFromPath(relativePath, profileSourceRoot) {
  const prefix = `${normalizeRelative(profileSourceRoot)}/`;
  if (!relativePath.startsWith(prefix)) {
    return null;
  }
  const [profile, surface, ...remainder] = relativePath
    .slice(prefix.length)
    .split("/");
  if (!profile || !surface || remainder.length === 0) {
    return null;
  }
  return { profile, surface };
}
