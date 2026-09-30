/**
 * Developer-tool runtime scan (EX-05).
 *
 * The scan names every in-scope string that references a developer-tool
 * executable and classifies each occurrence as an execution site or a
 * non-executing reference. Classification is fail-closed: a literal is an
 * execution site when its statement, a bound program, a wrapper call, an
 * embedded guest script, or a file that executes a variable program can run
 * it. Every execution occurrence is a distinct site with its own ordinal and
 * fingerprint, so one allowlist entry can never authorize a second call site.
 *
 * The scan is a declared-scope static lexical scan, not an exhaustive proof:
 * program names selected from data structures outside the scanned sources
 * cannot be derived statically, and their construction sites are the
 * allowlisted sites that document them.
 */

import path from "node:path";
import { createHash } from "node:crypto";
import {
  lexicalView,
  normalizeSnippet,
  statementAt,
  statementRanges,
} from "./lexical.mjs";
import {
  DEVELOPER_TOOL_ALLOWLIST,
  DEVELOPER_TOOL_NAMES,
  EMBEDDED_SHELL_MARKERS,
  EXECUTION_TOKENS,
  RUNTIME_SOURCE_ROOTS,
} from "./definitions.mjs";

export const MINIMUM_ALLOWLIST_REASON_LENGTH = 12;

/** Quote-aware scan for the matching close of an opening bracket. */
export function findMatching(text, openIndex, open, close) {
  let depth = 0;
  let quote = null;
  let escaped = false;
  for (let index = openIndex; index < text.length; index += 1) {
    const character = text[index];
    if (quote !== null) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === '"' || character === "'" || character === "`") {
      quote = character;
      continue;
    }
    if (character === "/" && text[index + 1] === "/") {
      const newline = text.indexOf("\n", index);
      if (newline < 0) {
        break;
      }
      index = newline;
      continue;
    }
    if (character === "/" && text[index + 1] === "*") {
      const end = text.indexOf("*/", index + 2);
      if (end < 0) {
        break;
      }
      index = end + 1;
      continue;
    }
    if (character === open) {
      depth += 1;
    } else if (character === close) {
      depth -= 1;
      if (depth === 0) {
        return index;
      }
    }
  }
  return -1;
}

/**
 * Remove `#[cfg(test)]` items so inline test modules and fixtures do not count
 * as runtime code. Operates before lexing; iterates because removed blocks
 * cannot contain survivors.
 */
export function stripCfgTestItems(source) {
  let result = source;
  for (let iteration = 0; iteration < 200; iteration += 1) {
    const attribute = result.indexOf("#[cfg(test)]");
    if (attribute < 0) {
      return result;
    }
    const statementStart = result.indexOf(";", attribute);
    const brace = result.indexOf("{", attribute);
    if (brace < 0 || (statementStart >= 0 && statementStart < brace)) {
      result = result.slice(0, attribute) + result.slice(statementStart + 1);
      continue;
    }
    const end = findMatching(result, brace, "{", "}");
    if (end < 0) {
      return result.slice(0, attribute);
    }
    result = result.slice(0, attribute) + result.slice(end + 1);
  }
  return result;
}

function lineStarts(source) {
  const starts = [0];
  for (let index = 0; index < source.length; index += 1) {
    if (source[index] === "\n") {
      starts.push(index + 1);
    }
  }
  return starts;
}

function lineForOffset(starts, offset) {
  let low = 0;
  let high = starts.length - 1;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (starts[middle] <= offset) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return low + 1;
}

function toolInLiteral(literal, tool) {
  if (
    literal === tool ||
    literal.endsWith(`/${tool}`) ||
    literal.endsWith(`\\${tool}`) ||
    literal.includes(`/${tool}/`) ||
    literal.includes(`\\${tool}\\`)
  ) {
    return true;
  }
  // Command-position token: a shell command string such as `node script.js`.
  const escaped = tool.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  return new RegExp(`(?:^|\\s)${escaped}(?:\\s|$)`, "u").test(literal);
}

const quotedLiteralPattern = /(["'])((?:\\[\s\S]|[^\\"'\n])*?)\1/gu;

/**
 * Tool occurrences inside string regions only; commented-out text can never
 * produce an occurrence.
 */
export function findToolOccurrences(source, lexed) {
  const starts = lineStarts(source);
  const occurrences = [];
  for (const region of lexed.regions) {
    if (region.kind !== "string") {
      continue;
    }
    const regionText = source.slice(region.start, region.end);
    const regionLineIndex = lineForOffset(starts, region.start) - 1;
    const regionLines = regionText.split("\n");
    for (let lineIndex = 0; lineIndex < regionLines.length; lineIndex += 1) {
      const lineText = regionLines[lineIndex];
      const lineOffset = lineIndex === 0
        ? region.start
        : starts[Math.min(regionLineIndex + lineIndex, starts.length - 1)] ?? region.start;
      for (const match of lineText.matchAll(quotedLiteralPattern)) {
        const content = match[2];
        for (const tool of DEVELOPER_TOOL_NAMES) {
          if (toolInLiteral(content, tool)) {
            occurrences.push({
              tool,
              offset: lineOffset + (match.index ?? 0) + 1,
              line: regionLineIndex + lineIndex + 1,
              literal: content,
              region,
            });
          }
        }
      }
    }
  }
  return occurrences.sort((left, right) => left.offset - right.offset);
}

function collectAliasTokens(masked, language) {
  const aliases = new Set();
  if (language === "dart") {
    for (const match of masked.matchAll(/import\s+['"]dart:io['"]\s+as\s+([A-Za-z_]\w*)/gu)) {
      aliases.add(match[1]);
    }
    return aliases;
  }
  const usePath = /use\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)+)(?:\s+as\s+([A-Za-z_]\w*))?\s*;/gu;
  for (const match of masked.matchAll(usePath)) {
    const segments = match[1].split("::");
    if (!segments.some((segment) => segment === "Command" || segment === "Process")) {
      continue;
    }
    if (match[2]) {
      aliases.add(match[2]);
    }
  }
  for (const match of masked.matchAll(
    /use\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)::\{([^}]*)\}/gu,
  )) {
    const segments = match[1].split("::");
    if (!segments.some((segment) => segment === "Command" || segment === "Process")) {
      continue;
    }
    for (const item of match[2].split(",")) {
      const alias = item.trim().match(/[A-Za-z_]\w*\s+as\s+([A-Za-z_]\w*)/u);
      if (alias) {
        aliases.add(alias[1]);
      }
    }
  }
  return aliases;
}

function executionTokensFor(masked, language) {
  const tokens = [...EXECUTION_TOKENS];
  for (const alias of collectAliasTokens(masked, language)) {
    tokens.push(`${alias}::new(`);
    tokens.push(`${alias}.Process.run(`);
    tokens.push(`${alias}.Process.start(`);
  }
  return tokens;
}

function hasExecutionToken(text, tokens) {
  return tokens.some((token) => text.includes(token));
}

export function collectFunctionRanges(masked) {
  const ranges = [];
  const pattern = /\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>{}]*>)?\s*\(/gu;
  for (const match of masked.matchAll(pattern)) {
    const open = masked.indexOf("(", match.index);
    const paramsEnd = findMatching(masked, open, "(", ")");
    if (paramsEnd < 0) {
      continue;
    }
    const between = masked.slice(paramsEnd + 1);
    const braceOffset = between.search(/[;{]/u);
    if (braceOffset < 0 || between[braceOffset] === ";") {
      continue;
    }
    const braceStart = paramsEnd + 1 + braceOffset;
    const bodyEnd = findMatching(masked, braceStart, "{", "}");
    if (bodyEnd < 0) {
      continue;
    }
    ranges.push({
      name: match[1],
      parameters: masked.slice(open + 1, paramsEnd),
      body: masked.slice(braceStart, bodyEnd + 1),
      bodyStart: braceStart,
      bodyEnd,
    });
  }
  return ranges;
}

function callRanges(masked, functionNames) {
  const results = [];
  for (const name of functionNames) {
    const pattern = new RegExp(`\\b${name}\\s*\\(`, "gu");
    for (const match of masked.matchAll(pattern)) {
      const open = match.index + match[0].length - 1;
      const end = findMatching(masked, open, "(", ")");
      if (end < 0) {
        continue;
      }
      results.push({ name, start: open, end });
    }
  }
  return results;
}

function bindingRegions(masked, lexed) {
  const regions = lexed.regions.filter((region) => region.kind === "string");
  const bindings = [];
  const pattern = /\b(?:const|static|let)\s+([A-Za-z_][A-Za-z0-9_]*)[^;=]*=/gu;
  for (const match of masked.matchAll(pattern)) {
    const equalsIndex = match.index + match[0].length - 1;
    let cursor = equalsIndex + 1;
    while (cursor < masked.length && /\s/u.test(masked[cursor])) {
      cursor += 1;
    }
    const region = regions.find((candidate) =>
      candidate.start >= equalsIndex && candidate.start <= cursor);
    if (region) {
      bindings.push({ name: match[1], region });
    }
  }
  return bindings;
}

function regionHasShellMarkers(source, region) {
  const content = source.slice(region.start, region.end);
  return EMBEDDED_SHELL_MARKERS.some((marker) => content.includes(marker));
}

function fileExecutesVariableProgram(masked, tokens) {
  for (const token of tokens) {
    if (!token.endsWith("::new(")) {
      continue;
    }
    const pattern = new RegExp(`${token.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")}\\s*[A-Za-z_]`, "u");
    if (pattern.test(masked)) {
      return true;
    }
  }
  return /\bProcess\.(?:run|start|runSync)\s*\(\s*[A-Za-z_]/u.test(masked);
}

function fingerprintFor(masked, statement, tool, literal) {
  return createHash("sha256")
    .update(`${tool}|${normalizeSnippet(masked.slice(statement.start, statement.end))}|${literal}`)
    .digest("hex")
    .slice(0, 12);
}

/**
 * Classify occurrences for one file.
 *
 * @returns {Array<object>} occurrences with `classification`, `rule`,
 *   `ordinal`, `id`, and `fingerprint`.
 */
export function classifyToolOccurrences({
  source,
  language,
  crossFileWrappers,
}) {
  const lexed = lexicalView(source, language);
  const occurrences = findToolOccurrences(source, lexed);
  if (occurrences.length === 0) {
    return [];
  }
  const tokens = executionTokensFor(lexed.masked, language);
  const ranges = statementRanges(lexed.masked);
  const functionRanges = collectFunctionRanges(lexed.masked);
  const sameFileWrappers = new Set(
    functionRanges
      .filter((range) => range.parameters.trim().length > 0 && hasExecutionToken(range.body, tokens))
      .map((range) => range.name),
  );
  const wrapperNames = new Set([...sameFileWrappers, ...crossFileWrappers]);
  const wrappers = callRanges(lexed.masked, wrapperNames);
  const bindings = bindingRegions(lexed.masked, lexed);
  const executionStatements = ranges.filter((range) =>
    hasExecutionToken(lexed.masked.slice(range.start, range.end), tokens));
  const bindingUsedInExecution = new Set();
  for (const binding of bindings) {
    const pattern = new RegExp(`\\b${binding.name}\\b`, "u");
    if (executionStatements.some((range) => pattern.test(lexed.masked.slice(range.start, range.end)))) {
      bindingUsedInExecution.add(binding.name);
    }
  }
  const dynamicProgram = fileExecutesVariableProgram(lexed.masked, tokens);

  const ordinals = new Map();
  return occurrences.map((occurrence) => {
    const statement = statementAt(ranges, occurrence.offset);
    const statementText = lexed.masked.slice(statement.start, statement.end);
    let classification = "reference";
    let rule = "no-execution-context";
    if (hasExecutionToken(statementText, tokens)) {
      classification = "execution";
      rule = "statement-execution-token";
    }
    if (classification === "reference") {
      const binding = bindings.find((candidate) =>
        occurrence.offset >= candidate.region.start &&
        occurrence.offset < candidate.region.end);
      if (binding && bindingUsedInExecution.has(binding.name)) {
        classification = "execution";
        rule = "bound-program-execution";
      }
    }
    if (classification === "reference" &&
        wrappers.some((wrapper) =>
          occurrence.offset > wrapper.start && occurrence.offset < wrapper.end)) {
      classification = "execution";
      rule = "wrapper-call-argument";
    }
    if (classification === "reference" && regionHasShellMarkers(source, occurrence.region)) {
      classification = "execution";
      rule = "embedded-shell-script";
    }
    if (classification === "reference" && dynamicProgram) {
      classification = "execution";
      rule = "file-executes-variable-program";
    }
    const ordinal = (ordinals.get(occurrence.tool) ?? 0) + 1;
    ordinals.set(occurrence.tool, ordinal);
    return {
      ...occurrence,
      classification,
      rule,
      ordinal,
      fingerprint: fingerprintFor(lexed.masked, statement, occurrence.tool, occurrence.literal),
    };
  });
}

/** Recursively collect runtime sources under the declared roots. */
export async function collectRuntimeSourceFiles(repoRoot, { readdir }) {
  const files = [];
  async function visit(relativeDirectory, extension) {
    const absolute = path.join(repoRoot, relativeDirectory);
    let entries = [];
    try {
      entries = await readdir(absolute, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of [...entries].sort((left, right) => left.name.localeCompare(right.name))) {
      const relativePath = relativeDirectory
        ? `${relativeDirectory}/${entry.name}`
        : entry.name;
      if (entry.isDirectory()) {
        if (["target", "build", "tests", "test", "__pycache__"].includes(entry.name)) {
          continue;
        }
        await visit(relativePath, extension);
      } else if (entry.isFile() && entry.name.endsWith(extension)) {
        if (/^tests?\.(?:rs|dart)$/u.test(entry.name)) {
          continue;
        }
        files.push(relativePath.replaceAll("\\", "/"));
      }
    }
  }
  for (const { root, extension } of RUNTIME_SOURCE_ROOTS) {
    await visit(root, extension);
  }
  return files.sort();
}

function allowlistKey(site) {
  return `${site.file}::${site.tool}::${site.ordinal}`;
}

function validateAllowlist(allowlist) {
  const problems = [];
  const valid = [];
  const seen = new Set();
  for (const entry of allowlist) {
    const label = `${entry.file ?? "<missing-file>"}::${entry.tool ?? "<missing-tool>"}::${
      entry.ordinal ?? "<missing-ordinal>"
    }`;
    if (typeof entry.file !== "string" || entry.file.length === 0 ||
        typeof entry.tool !== "string" || entry.tool.length === 0 ||
        !Number.isInteger(entry.ordinal) || entry.ordinal < 1) {
      problems.push(
        `developer-tool allowlist entry ${label} must declare file, tool and a positive ordinal`,
      );
      continue;
    }
    if (typeof entry.reason !== "string" ||
        entry.reason.trim().length < MINIMUM_ALLOWLIST_REASON_LENGTH) {
      problems.push(
        `developer-tool allowlist entry ${label} needs a meaningful justification, not an empty or placeholder reason`,
      );
      continue;
    }
    if (seen.has(label)) {
      problems.push(`developer-tool allowlist entry ${label} is duplicated`);
      continue;
    }
    seen.add(label);
    valid.push(entry);
  }
  return { problems, valid };
}

/**
 * Scan the runtime sources and return execution sites, allowlist coverage,
 * invalid or stale declarations, and recorded references.
 */
export async function inspectDeveloperToolSites({
  repoRoot,
  readdir,
  readFile,
  allowlist = DEVELOPER_TOOL_ALLOWLIST,
}) {
  const files = await collectRuntimeSourceFiles(repoRoot, { readdir });
  const sources = new Map();
  for (const file of files) {
    let text = "";
    try {
      text = await readFile(path.join(repoRoot, file), "utf8");
    } catch {
      continue;
    }
    const language = file.endsWith(".dart") ? "dart" : "rust";
    const stripped = language === "rust" ? stripCfgTestItems(text) : text;
    if (language === "rust") {
      // External test modules are included by a parent `#[cfg(test)] mod x;`
      // and carry bare `#[test]` items; they are test sources, not runtime.
      const { masked } = lexicalView(stripped, language);
      if (/#\[(?:[A-Za-z_]\w*::)?test\]/u.test(masked)) {
        continue;
      }
    }
    sources.set(file, { language, text: stripped });
  }

  const crossFileWrappers = new Set();
  for (const { language, text } of sources.values()) {
    const lexed = lexicalView(text, language);
    const tokens = executionTokensFor(lexed.masked, language);
    for (const range of collectFunctionRanges(lexed.masked)) {
      if (range.parameters.trim().length > 0 && hasExecutionToken(range.body, tokens)) {
        crossFileWrappers.add(range.name);
      }
    }
  }

  const { problems, valid } = validateAllowlist(allowlist);
  const executionSites = [];
  const references = [];
  for (const [file, { language, text }] of sources) {
    const classified = classifyToolOccurrences({ source: text, language, crossFileWrappers });
    for (const occurrence of classified) {
      const site = {
        id: `${file}::${occurrence.tool}::${occurrence.ordinal}`,
        file,
        tool: occurrence.tool,
        ordinal: occurrence.ordinal,
        line: occurrence.line,
        literal: occurrence.literal,
        rule: occurrence.rule,
        fingerprint: occurrence.fingerprint,
      };
      if (occurrence.classification === "execution") {
        executionSites.push(site);
      } else {
        references.push(site);
      }
    }
  }
  executionSites.sort((left, right) =>
    left.id.localeCompare(right.id, undefined, { numeric: true }));
  references.sort((left, right) =>
    `${left.file}:${left.line}`.localeCompare(`${right.file}:${right.line}`, undefined, { numeric: true }));

  const allowed = new Map(
    valid.map((entry) => [`${entry.file}::${entry.tool}::${entry.ordinal}`, entry]),
  );
  const unallowlisted = executionSites.filter((site) => !allowed.has(allowlistKey(site)));
  const staleAllowlist = [...allowed.keys()]
    .filter((key) => !executionSites.some((site) => allowlistKey(site) === key))
    .sort();

  return {
    executionSites,
    unallowlisted,
    staleAllowlist,
    invalidAllowlist: problems,
    references,
    scannedFiles: files.length,
  };
}
