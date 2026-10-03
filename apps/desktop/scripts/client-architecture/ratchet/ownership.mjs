import { lexicalView } from "./lexical.mjs";

// Split only at the current expression level. Strings/comments are already
// masked; offsets still refer to the original source.
function splitRanges(masked, start, end, separator = ",") {
  const result = [];
  let depth = 0;
  let from = start;
  for (let index = start; index < end; index += 1) {
    if ("([{".includes(masked[index])) depth += 1;
    if (")]}".includes(masked[index])) depth -= 1;
    if (masked[index] === separator && depth === 0) {
      result.push([from, index]);
      from = index + 1;
    }
  }
  result.push([from, end]);
  return result;
}

/** Read the complete declared table, never a subset of matching literal rows. */
export function parseCapabilityOwnership(source, problems = []) {
  const { masked, regions, problems: lexicalProblems } = lexicalView(source, "rust");
  problems.push(...lexicalProblems.map((problem) => `CAPABILITY_OWNERSHIP source: ${problem}`));
  const code = source.split("");
  for (const region of regions.filter((entry) => entry.kind === "comment")) {
    for (let i = region.start; i < region.end; i += 1) code[i] = " ";
  }
  const uncommented = code.join("");
  const modules = [];
  for (const match of masked.matchAll(/\bmod\s+(\w+)\s*\{/gu)) {
    let depth = 1;
    let end = match.index + match[0].length;
    for (; end < masked.length && depth > 0; end += 1) {
      if (masked[end] === "{") depth += 1;
      if (masked[end] === "}") depth -= 1;
    }
    modules.push({ name: match[1], start: match.index, end });
  }
  const constants = new Map();
  for (const match of masked.matchAll(/\bconst\s+(\w+)\s*:\s*([^=]+)=/gu)) {
    const start = match.index + match[0].length;
    const [range] = splitRanges(masked, start, masked.length, ";");
    const scope = modules.filter((entry) => entry.start < match.index && entry.end > match.index)
      .map((entry) => entry.name);
    const key = [...scope, match[1]].join("::");
    if (constants.has(key)) problems.push(`ownership constant ${key} is ambiguous`);
    constants.set(key, { expression: uncommented.slice(...range).trim(), scope, type: match[2] });
  }
  function resolve(expression, scope = [], seen = new Set()) {
    let text = expression.trim();
    if (!/^(?:(?:crate|self|super|[A-Za-z_]\w*)\s*::\s*)*[A-Za-z_]\w*$/u.test(text)) {
      return { text, scope };
    }
    text = text.replace(/\s/gu, "");
    let segments = text.split("::");
    let base = [...scope];
    if (segments[0] === "crate") {
      segments.shift();
      if (segments[0] === "deployment") segments.shift();
      base = [];
    } else if (segments[0] === "self") {
      segments.shift();
    } else {
      while (segments[0] === "super") { base.pop(); segments.shift(); }
    }
    const key = [...base, ...segments].join("::");
    const constant = constants.get(key);
    if (!constant || seen.has(key)) return null;
    return resolve(constant.expression, constant.scope, new Set([...seen, key]));
  }
  function stringValue(expression, scope) {
    const value = resolve(expression, scope)?.text;
    if (!value) return null;
    if (/^"[^"\\]*"$/u.test(value)) return value.slice(1, -1);
    const raw = value.match(/^r(#+)?"([\s\S]*)"\1$/u);
    return raw ? raw[2] : null;
  }
  const table = constants.get("CAPABILITY_OWNERSHIP");
  if (!table) {
    problems.push("CAPABILITY_OWNERSHIP declaration is missing or unsupported");
    return [];
  }
  const resolvedTable = resolve(table.expression, table.scope);
  const expression = resolvedTable?.text;
  if (!expression || !/^&?\s*\[[\s\S]*\]$/u.test(expression)) {
    problems.push("CAPABILITY_OWNERSHIP must resolve to a complete array of ownership rows");
    return [];
  }
  const content = expression.slice(expression.indexOf("[") + 1, -1);
  const mask = lexicalView(content, "rust").masked;
  const entries = splitRanges(mask, 0, mask.length).map((range) => content.slice(...range).trim()).filter(Boolean);
  const declaredCount = table.type.match(/;\s*(\d+)\s*\]/u)?.[1];
  if (declaredCount && Number(declaredCount) !== entries.length) {
    problems.push("CAPABILITY_OWNERSHIP row count does not match its declared array length");
  }
  const rows = [];
  for (const [index, entry] of entries.entries()) {
    const resolvedRow = resolve(entry, resolvedTable.scope);
    const rowExpression = resolvedRow?.text;
    if (!rowExpression?.startsWith("(") || !rowExpression.endsWith(")")) {
      problems.push(`CAPABILITY_OWNERSHIP row ${index + 1} is unsupported`);
      continue;
    }
    const row = rowExpression.slice(1, -1);
    const fields = splitRanges(lexicalView(row, "rust").masked, 0, row.length)
      .map((range) => row.slice(...range).trim()).filter(Boolean);
    const capability = stringValue(fields[0] ?? "", resolvedRow.scope);
    const resolvedOwner = resolve(fields[1] ?? "", resolvedRow.scope);
    const owner = resolvedOwner?.text.match(
      /^(?:[A-Za-z_]\w*\s*::\s*)*PackOwnership\s*::\s*(Core|Optional)\s*\(([\s\S]*)\)$/u,
    );
    if (fields.length !== 2 || !capability || !owner) {
      problems.push(`CAPABILITY_OWNERSHIP row ${index + 1} does not resolve to a capability and owner`);
      continue;
    }
    const raw = owner[2].replace(/,\s*$/u, "").trim();
    const packageId = stringValue(raw, resolvedOwner.scope);
    if (!packageId) problems.push(`capability ${capability} declares ${raw}, which does not resolve to a package id`);
    rows.push({ capability, set: owner[1] === "Core" ? "core" : "optional", package: packageId, raw });
  }
  return rows;
}
