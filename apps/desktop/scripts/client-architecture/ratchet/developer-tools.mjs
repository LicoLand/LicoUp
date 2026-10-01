/**
 * Developer-tool runtime sink scan (EX-05).
 *
 * The metric is defined on process-execution *sinks*, not on tool-name string
 * occurrences: a statement that contains an execution API is one sink, and its
 * reviewed identity is its fingerprint. Every tool that can flow into the sink
 * is attributed through, in order, the sink expression, same-file bindings and
 * identifier chains, cross-file call-site arguments of the enclosing function,
 * and finally file-level tool evidence. A sink whose operands cannot be
 * resolved at all in a source unit that names developer tools is still a
 * relevant sink with the file's attributed tools; it can never silently count
 * as zero. A second sink, a replaced statement or a changed tool set produces a
 * new identity that cannot inherit an existing allowlist entry.
 *
 * The scan is a declared-scope static lexical analysis, not an exhaustive
 * proof: values selected from data structures outside the scanned sources are
 * attributed through file evidence and reviewed as explicit exceptions.
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
  EXECUTION_TOKENS,
  RUNTIME_SOURCE_ROOTS,
} from "./definitions.mjs";

export const MINIMUM_ALLOWLIST_REASON_LENGTH = 12;

const RUNTIME_LAYOUT_SRC = "crate-src";
const RESOLUTION_DEPTH = 6;

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
 * Remove test-only items so fixtures do not count as runtime code. The
 * attribute search runs on the lexical mask, so a commented `#[cfg(test)]`
 * cannot remove following runtime code, and a mixed production/test file keeps
 * its production items. `#[cfg(test)]` items and bare `#[test]` items are
 * removed individually.
 */
export function stripTestItems(source) {
  let result = source;
  for (let iteration = 0; iteration < 500; iteration += 1) {
    const view = lexicalView(result, "rust");
    const attribute = /#\[(?:cfg\(test\)|(?:[A-Za-z_]\w*::)?test)\]/u.exec(view.masked);
    if (!attribute) {
      return result;
    }
    const start = attribute.index;
    const semicolon = view.masked.indexOf(";", start);
    const brace = view.masked.indexOf("{", start);
    if (brace < 0 || (semicolon >= 0 && semicolon < brace)) {
      result = result.slice(0, start) + result.slice(semicolon + 1);
      continue;
    }
    const end = findMatching(view.masked, brace, "{", "}");
    if (end < 0) {
      return result.slice(0, start);
    }
    result = result.slice(0, start) + result.slice(end + 1);
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

function escapePattern(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
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
  const escaped = escapePattern(tool);
  return new RegExp(`(?:^|\\s)${escaped}(?:\\s|$)`, "u").test(literal);
}

const quotedLiteralPattern = /(["'])((?:\\[\s\S]|[^\\"'\n])*?)\1/gu;

/** Tools named inside the string literals of a text slice (audit helper). */
export function toolsInText(text) {
  const found = new Set();
  for (const match of text.matchAll(quotedLiteralPattern)) {
    for (const tool of DEVELOPER_TOOL_NAMES) {
      if (toolInLiteral(match[2], tool)) {
        found.add(tool);
      }
    }
  }
  return found;
}

/**
 * Tools named as commands or path segments in raw script content, so a
 * multiline guest script without inner quotes still attributes its runtimes.
 */
export function toolsInContent(content) {
  const found = new Set();
  for (const line of content.split(/\r?\n/u)) {
    for (const tool of DEVELOPER_TOOL_NAMES) {
      const escaped = escapePattern(tool);
      const commandPosition = new RegExp(
        `(?:^|;|&&|\\|\\||\\$\\()\\s*(?:[\\w.-]+/)*${escaped}(?:\\s|$)`,
        "u",
      );
      const pathSegment = new RegExp(`[/\\\\]${escaped}(?=$|[/\\\\"'\\s])`, "u");
      if (commandPosition.test(line) || pathSegment.test(line)) {
        found.add(tool);
      }
    }
  }
  return found;
}

function toolsInRange(source, regions, start, end) {
  const found = new Set();
  for (const region of regions) {
    if (region.kind !== "string" || region.start >= end || region.end <= start) {
      continue;
    }
    const content = source.slice(region.start, region.end);
    for (const tool of toolsInText(content)) {
      found.add(tool);
    }
    for (const tool of toolsInContent(content)) {
      found.add(tool);
    }
  }
  return found;
}

function hasExecutionToken(text) {
  return EXECUTION_TOKENS.some((token) => text.includes(token));
}

/** Recursively collect runtime sources under the declared roots. */
export async function collectRuntimeSourceFiles(repoRoot, { readdir }) {
  const files = [];
  const problems = [];
  async function visit(relativeDirectory, extension, { includeSelf = false } = {}) {
    let entries = [];
    try {
      entries = await readdir(path.join(repoRoot, relativeDirectory), { withFileTypes: true });
    } catch (error) {
      if (error?.code !== "ENOENT") {
        problems.push(
          `${relativeDirectory} cannot be read: ${error?.code ?? error?.message ?? "unknown"}`,
        );
      }
      return;
    }
    for (const entry of [...entries].sort((left, right) => left.name.localeCompare(right.name))) {
      const relativePath = `${relativeDirectory}/${entry.name}`;
      if (entry.isDirectory()) {
        if (["target", "build", "tests", "test", "__pycache__"].includes(entry.name)) {
          continue;
        }
        await visit(relativePath, extension, { includeSelf: true });
      } else if (includeSelf && entry.isFile() && entry.name.endsWith(extension)) {
        if (/^tests?\.(?:rs|dart)$/u.test(entry.name)) {
          continue;
        }
        files.push(relativePath.replaceAll("\\", "/"));
      }
    }
  }
  for (const { root, extension, layout } of RUNTIME_SOURCE_ROOTS) {
    if (layout === RUNTIME_LAYOUT_SRC) {
      let entries = [];
      try {
        entries = await readdir(path.join(repoRoot, root), { withFileTypes: true });
      } catch (error) {
        if (error?.code !== "ENOENT") {
          problems.push(
            `${root} cannot be read: ${error?.code ?? error?.message ?? "unknown"}`,
          );
        }
        continue;
      }
      for (const entry of [...entries].sort((left, right) => left.name.localeCompare(right.name))) {
        if (entry.isDirectory()) {
          await visit(`${root}/${entry.name}/src`, extension, { includeSelf: true });
        }
      }
      continue;
    }
    await visit(root, extension, { includeSelf: true });
  }
  return { files: files.sort(), problems };
}

function collectFunctionRanges(masked) {
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
      parameters: masked
        .slice(open + 1, paramsEnd)
        .split(",")
        .map((parameter) => parameter.trim().match(/([A-Za-z_]\w*)\s*:/u)?.[1])
        .filter(Boolean),
      bodyStart: braceStart,
      bodyEnd,
    });
  }
  return ranges;
}

function enclosingFunction(ranges, offset) {
  return ranges.find((range) => offset >= range.bodyStart && offset <= range.bodyEnd) ?? null;
}

function bindingAssignments(masked, ranges) {
  const bindings = new Map();
  const pattern = /\b(?:const|static|let)\s+(?:mut\s+)?([A-Za-z_]\w*)[^;=]*=/gu;
  for (const match of masked.matchAll(pattern)) {
    const statement = statementAt(ranges, match.index);
    const list = bindings.get(match[1]) ?? [];
    list.push(statement);
    bindings.set(match[1], list);
  }
  return bindings;
}

function callSitesByName(sources) {
  const sites = new Map();
  for (const [file, { masked }] of sources) {
    for (const match of masked.matchAll(/\b([A-Za-z_]\w*)\s*\(/gu)) {
      const name = match[1];
      if (["fn", "if", "for", "while", "match", "return", "let", "const", "static"].includes(name)) {
        continue;
      }
      const open = match.index + match[0].length - 1;
      const end = findMatching(masked, open, "(", ")");
      if (end < 0) {
        continue;
      }
      const list = sites.get(name) ?? [];
      list.push({ file, start: open + 1, end });
      sites.set(name, list);
    }
  }
  return sites;
}

const identifierDenylist = new Set([
  "let", "mut", "const", "static", "fn", "if", "for", "in", "match", "return",
  "Some", "None", "Ok", "Err", "true", "false", "str", "String", "self", "Self",
  "use", "pub", "async", "await", "move", "ref", "as", "where", "impl", "trait",
]);

function nestedIdentifiers(masked, start, end) {
  const identifiers = new Set();
  for (const match of masked.slice(start, end).matchAll(/\b([A-Za-z_]\w*)\b/gu)) {
    if (!identifierDenylist.has(match[1])) {
      identifiers.add(match[1]);
    }
  }
  return identifiers;
}

function sinkContinuationStatements(masked, ranges, statement) {
  const text = masked.slice(statement.start, statement.end);
  const binding = text.match(/\b(?:const|static|let)\s+(?:mut\s+)?([A-Za-z_]\w*)[^;=]*=/u)?.[1];
  if (!binding) {
    return [];
  }
  const pattern = new RegExp(`\\b${binding}\\b`, "u");
  return ranges.filter((range) =>
    range.start > statement.end && pattern.test(masked.slice(range.start, range.end)));
}

function runnerArgumentIdentifiers(masked, range) {
  const identifiers = [];
  for (const match of masked.slice(range.start, range.end)
    .matchAll(/&mut\s+([A-Za-z_]\w*)|\(\s*&?([A-Za-z_]\w*)\s*,/gu)) {
    identifiers.push(match[1] ?? match[2]);
  }
  return identifiers.filter(Boolean);
}

function resolveIdentifierTools({
  identifier,
  sources,
  file,
  index,
  callSites,
  depth,
  visited,
}) {
  if (depth > RESOLUTION_DEPTH) {
    return new Set();
  }
  const key = `${file}::${identifier}`;
  if (visited.has(key)) {
    return new Set();
  }
  visited.add(key);
  const tools = new Set();
  const { source, regions } = sources.get(file);
  const entry = index.get(file);
  for (const statement of entry.bindings.get(identifier) ?? []) {
    for (const tool of toolsInRange(source, regions, statement.start, statement.end)) {
      tools.add(tool);
    }
    for (const inner of nestedIdentifiers(
      sources.get(file).masked,
      statement.start,
      statement.end,
    )) {
      if (inner === identifier) {
        continue;
      }
      for (const tool of resolveIdentifierTools({
        identifier: inner,
        sources,
        file,
        index,
        callSites,
        depth: depth + 1,
        visited,
      })) {
        tools.add(tool);
      }
    }
  }
  return tools;
}

/**
 * Attribute developer tools to one sink statement.
 */
function sinkTools({
  file,
  sinkRange,
  sources,
  index,
  callSites,
}) {
  const { source, regions, masked } = sources.get(file);
  const tools = new Set();
  for (const tool of toolsInRange(source, regions, sinkRange.start, sinkRange.end)) {
    tools.add(tool);
  }
  const entry = index.get(file);
  const functionRange = enclosingFunction(entry.functions, sinkRange.start);
  const identifiers = nestedIdentifiers(masked, sinkRange.start, sinkRange.end);
  for (const identifier of runnerArgumentIdentifiers(masked, sinkRange)) {
    identifiers.add(identifier);
    for (const statement of entry.bindings.get(identifier) ?? []) {
      for (const tool of toolsInRange(source, regions, statement.start, statement.end)) {
        tools.add(tool);
      }
      for (const continuation of sinkContinuationStatements(masked, entry.statements, statement)) {
        for (const tool of toolsInRange(source, regions, continuation.start, continuation.end)) {
          tools.add(tool);
        }
      }
    }
  }
  for (const identifier of identifiers) {
    for (const tool of resolveIdentifierTools({
      identifier,
      sources,
      file,
      index,
      callSites,
      depth: 0,
      visited: new Set(),
    })) {
      tools.add(tool);
    }
    if (functionRange && functionRange.parameters.includes(identifier)) {
      for (const site of callSites.get(functionRange.name) ?? []) {
        const siteSource = sources.get(site.file);
        for (const tool of toolsInRange(siteSource.source, siteSource.regions, site.start, site.end)) {
          tools.add(tool);
        }
        for (const nested of nestedIdentifiers(siteSource.masked, site.start, site.end)) {
          for (const tool of resolveIdentifierTools({
            identifier: nested,
            sources,
            file: site.file,
            index,
            callSites,
            depth: 0,
            visited: new Set(),
          })) {
            tools.add(tool);
          }
        }
      }
    }
  }
  return tools;
}

function fileEvidenceTools(file, sources) {
  const { source, regions } = sources.get(file);
  return toolsInRange(source, regions, 0, source.length);
}

function fingerprintFor(file, source, range) {
  const statement = normalizeSnippet(source.slice(range.start, range.end));
  return createHash("sha256").update(`${file}|${statement}`).digest("hex").slice(0, 12);
}

/**
 * Scan runtime sources for developer-tool execution sinks.
 */
export async function inspectDeveloperToolSites({
  repoRoot,
  readdir,
  readFile,
  allowlist = DEVELOPER_TOOL_ALLOWLIST,
}) {
  const collected = await collectRuntimeSourceFiles(repoRoot, { readdir });
  const problems = [...collected.problems];
  const sources = new Map();
  for (const file of collected.files) {
    let raw = "";
    try {
      raw = await readFile(path.join(repoRoot, file), "utf8");
    } catch (error) {
      problems.push(`${file} cannot be read: ${error?.code ?? error?.message ?? "unknown"}`);
      continue;
    }
    const language = file.endsWith(".dart") ? "dart" : "rust";
    const source = language === "rust" ? stripTestItems(raw) : raw;
    const lexed = lexicalView(source, language);
    sources.set(file, { language, source, masked: lexed.masked, regions: lexed.regions });
  }

  const index = new Map();
  for (const [file, { masked }] of sources) {
    const statements = statementRanges(masked);
    index.set(file, {
      statements,
      functions: collectFunctionRanges(masked),
      bindings: bindingAssignments(masked, statements),
    });
  }
  const callSites = callSitesByName(sources);

  const relevantSinks = [];
  const references = [];
  let scannedSinkStatements = 0;
  for (const [file, { source, masked, regions }] of sources) {
    const { statements } = index.get(file);
    const starts = lineStarts(source);
    const rangedRanges = statements.map((range) => ({
      ...range,
      masked: masked.slice(range.start, range.end),
    }));
    const fileTools = fileEvidenceTools(file, sources);
    for (const range of rangedRanges) {
      if (!hasExecutionToken(range.masked)) {
        continue;
      }
      scannedSinkStatements += 1;
      const tools = sinkTools({ file, sinkRange: range, sources, index, callSites });
      if (tools.size === 0) {
        for (const tool of fileTools) {
          tools.add(tool);
        }
      }
      if (tools.size === 0) {
        continue;
      }
      relevantSinks.push({
        file,
        fingerprint: fingerprintFor(file, source, range),
        tools: [...tools].sort(),
        line: lineForOffset(starts, range.start),
        statement: normalizeSnippet(source.slice(range.start, range.end)).slice(0, 200),
      });
    }
    for (const region of regions) {
      if (region.kind !== "string") {
        continue;
      }
      const regionText = source.slice(region.start, region.end);
      const regionLine = lineForOffset(starts, region.start);
      for (const match of regionText.matchAll(quotedLiteralPattern)) {
        for (const tool of DEVELOPER_TOOL_NAMES) {
          if (toolInLiteral(match[2], tool)) {
            references.push({
              file,
              tool,
              line: regionLine + (regionText.slice(0, match.index ?? 0).match(/\n/gu)?.length ?? 0),
              literal: match[2],
            });
          }
        }
      }
    }
  }

  const duplicates = new Map();
  for (const sink of relevantSinks) {
    const count = (duplicates.get(sink.fingerprint) ?? 0) + 1;
    duplicates.set(sink.fingerprint, count);
    sink.sink = count === 1 ? sink.fingerprint : `${sink.fingerprint}#${count}`;
    delete sink.fingerprint;
    sink.id = `${sink.file}::${sink.sink}`;
  }
  relevantSinks.sort((left, right) => left.id.localeCompare(right.id));

  const siteIds = relevantSinks.flatMap((sink) =>
    sink.tools.map((tool) => `${sink.id}::${tool}`));

  const { problems: allowlistProblems, valid } = validateAllowlist(allowlist);
  problems.push(...allowlistProblems);
  const allowedBySink = new Map(valid.map((entry) => [`${entry.file}::${entry.sink}`, entry]));
  const unallowlisted = [];
  for (const sink of relevantSinks) {
    const entry = allowedBySink.get(sink.id);
    if (!entry || sink.tools.some((tool) => !entry.tools.includes(tool))) {
      unallowlisted.push(sink);
    }
  }
  const staleAllowlist = [...allowedBySink.keys()]
    .filter((key) => !relevantSinks.some((sink) => sink.id === key))
    .sort();

  return {
    executionSites: relevantSinks,
    siteIds: siteIds.sort(),
    unallowlisted,
    staleAllowlist,
    invalidAllowlist: allowlistProblems,
    references,
    scannedFiles: sources.size,
    scannedSinkStatements,
    problems,
  };
}

function validateAllowlist(allowlist) {
  const problems = [];
  const valid = [];
  const seen = new Set();
  for (const entry of allowlist) {
    const label = `${entry.file ?? "<missing-file>"}::${entry.sink ?? "<missing-sink>"}`;
    if (typeof entry.file !== "string" || entry.file.length === 0 ||
        typeof entry.sink !== "string" || entry.sink.length === 0) {
      problems.push(`developer-tool allowlist entry ${label} must declare file and sink identity`);
      continue;
    }
    if (!Array.isArray(entry.tools) || entry.tools.length === 0 ||
        entry.tools.some((tool) => typeof tool !== "string" || tool.length === 0)) {
      problems.push(`developer-tool allowlist entry ${label} must declare the attributed tools`);
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
