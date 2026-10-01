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
 * proof: file evidence may attribute an otherwise unresolved operand, but a
 * known process target with no such evidence is a refusal, not zero debt. No
 * external Agent protocol is executed or inspected to turn unknown into safe.
 */

import path from "node:path";
import { createHash } from "node:crypto";
import { createTargetAttribution } from "./target-attribution.mjs";
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
  KERNEL_HOST_CRATE,
  OPTIONAL_CAPABILITY_CRATES,
} from "./definitions.mjs";

export const MINIMUM_ALLOWLIST_REASON_LENGTH = 12;

const RUNTIME_LAYOUT_SRC = "crate-src";
const RESOLUTION_DEPTH = 6;

function nonRuntimeLibraries(manifests) {
  const records = [...manifests.values()];
  const declaredOwners = new Set([KERNEL_HOST_CRATE,
    ...Object.values(OPTIONAL_CAPABILITY_CRATES).flatMap((owner) => owner.crates)]);
  return records.flatMap((record) => {
    if (record.publish !== false || record.bins.length || declaredOwners.has(record.name) ||
        !record.libraryTypes?.length || record.libraryTypes.some((kind) => !["lib", "rlib"].includes(kind))) return [];
    const incoming = records.flatMap((owner) => owner.deps
      .filter((dependency) => dependency.localName === record.name)
      .map((dependency) => ({ from: owner.path, kind: dependency.kind })));
    if (!incoming.length || incoming.some((edge) => edge.kind !== "dev-dependencies")) return [];
    return [{ name: record.name, path: record.path, incoming,
      reason: "Private library with no binary/dynamic artifact and only dev-dependencies consumers; outside the declared installed-runtime scope." }];
  });
}

/** Match delimiters in an already lexical-masked source (lifetimes stay code). */
export function findMatching(text, openIndex, open, close) {
  let depth = 0;
  for (let index = openIndex; index < text.length; index += 1) {
    const character = text[index];
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
  const result = source.split("");
  const { masked } = lexicalView(source, "rust");
  let removedThrough = 0;
  function productionCfg(expression) {
    const text = expression.trim();
    if (text === "test") return false;
    const operator = text.match(/^(all|any|not)\s*\(([\s\S]*)\)$/u);
    if (!operator) return null;
    let depth = 0;
    const parts = [];
    let start = 0;
    for (let index = 0; index <= operator[2].length; index += 1) {
      const token = operator[2][index];
      if (token === "(") depth += 1;
      if (token === ")") depth -= 1;
      if ((token === "," && depth === 0) || index === operator[2].length) {
        const part = operator[2].slice(start, index).trim();
        if (part) parts.push(productionCfg(part));
        start = index + 1;
      }
    }
    if (operator[1] === "not") return parts.length === 1 && parts[0] !== null ? !parts[0] : null;
    if (operator[1] === "all") return parts.includes(false) ? false : parts.every((part) => part === true) ? true : null;
    return parts.includes(true) ? true : parts.every((part) => part === false) ? false : null;
  }
  for (const attribute of masked.matchAll(/#\s*\[/gu)) {
    const start = attribute.index;
    if (start < removedThrough) continue;
    const attributeEnd = findMatching(masked, start + attribute[0].length - 1, "[", "]");
    const text = masked.slice(start + attribute[0].length, attributeEnd).trim();
    const cfg = text.match(/^cfg\s*\(([\s\S]*)\)$/u);
    if (!(cfg && productionCfg(cfg[1]) === false) && !/^(?:\w+\s*::\s*)?test(?:\s*\([^]*\))?$/u.test(text)) continue;
    const semicolon = masked.indexOf(";", attributeEnd + 1);
    const brace = masked.indexOf("{", attributeEnd + 1);
    if (brace < 0 || (semicolon >= 0 && semicolon < brace)) {
      removedThrough = semicolon < 0 ? source.length : semicolon + 1;
    } else {
      const end = findMatching(masked, brace, "{", "}");
      removedThrough = end < 0 ? source.length : end + 1;
    }
    for (let index = start; index < removedThrough; index += 1) {
      if (source[index] !== "\n") result[index] = " ";
    }
  }
  return result.join("");
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
  const escaped = escapePattern(tool);
  const executable = `${escaped}(?:\\.(?:exe|cmd|bat))?`;
  const segment = new RegExp(`^${executable}$`, "iu");
  if (literal.replaceAll("\\", "/").split("/").some((part) => segment.test(part))) return true;
  return new RegExp(`(?:^|\\s)${executable}(?:\\s|$)`, "iu").test(literal);
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

function hasExecutionToken(text, aliases = []) {
  if (new RegExp(`\\b(?:Command|${aliases.map(escapePattern).join("|") || "Command"})\\s*::\\s*(?:new|spawn|output|status)\\b|\\bProcess\\s*\\.\\s*(?:run|runSync|start)\\b`, "u").test(text)) return true;
  return [...EXECUTION_TOKENS, ...aliases.map((alias) => `${alias}::new(`)]
    .some((token) => new RegExp(escapePattern(token).replaceAll("::", "\\s*::\\s*")
      .replaceAll("\\.", "\\.\\s*").replaceAll("\\(", "\\s*\\("), "u").test(text));
}

/** Recursively collect runtime sources under the declared roots. */
export async function collectRuntimeSourceFiles(repoRoot, { readdir }) {
  const files = [];
  const problems = [];
  async function visit(relativeDirectory, extension, { includeSelf = false, required = false } = {}) {
    let entries = [];
    try {
      entries = await readdir(path.join(repoRoot, relativeDirectory), { withFileTypes: true });
    } catch (error) {
      if (required || error?.code !== "ENOENT") {
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
        await visit(relativePath, extension, { includeSelf: true, required: true });
      } else if (includeSelf && entry.isFile() && entry.name.endsWith(extension)) {
        if (/^tests?\.(?:rs|dart)$/u.test(entry.name)) {
          continue;
        }
        files.push(relativePath.replaceAll("\\", "/"));
      } else if (entry.isSymbolicLink()) {
        problems.push(`${relativePath} is a symbolic link; runtime source scope is unresolved`);
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
          const directory = `${root}/${entry.name}`;
          try {
            const children = await readdir(path.join(repoRoot, directory), { withFileTypes: true });
            if (children.some((child) => child.name === "src")) {
              await visit(`${directory}/src`, extension, { includeSelf: true, required: true });
            }
          } catch (error) {
            problems.push(`${directory} cannot be read: ${error?.code ?? "unknown"}`);
          }
        } else if (entry.isSymbolicLink()) {
          problems.push(`${root}/${entry.name} is a symbolic link; runtime source scope is unresolved`);
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
  const snippet = source.slice(range.start, range.end);
  const literals = lexicalView(snippet, file.endsWith(".dart") ? "dart" : "rust").regions
    .filter((region) => region.kind === "string");
  let previous = 0;
  let statement = "";
  for (const literal of literals) {
    statement += snippet.slice(previous, literal.start).replace(/\s+/gu, " ");
    statement += snippet.slice(literal.start, literal.end);
    previous = literal.end;
  }
  statement = (statement + snippet.slice(previous).replace(/\s+/gu, " ")).trim();
  return createHash("sha256").update(`${file}|${statement}`).digest("hex").slice(0, 12);
}

function processTargetAttribution(file, range, sources, aliases, resolver, visited = new Set()) {
  if (visited.has(range.start)) return resolver.unknown("recursive Command binding");
  visited.add(range.start);
  const { source, masked } = sources.get(file);
  const entry = resolver.model(file);
  const text = masked.slice(range.start, range.end);
  const commandTypes = ["Command", ...aliases].map(escapePattern).join("|");
  const constructors = new RegExp(`\\b((?:\\w+\\s*::\\s*)*(?:${commandTypes}))\\s*::\\s*new\\s*\\(|\\b((?:\\w+\\s*\\.\\s*)?Process)\\s*\\.\\s*(?:run|runSync|start)\\s*\\(`, "gu");
  const observations = [];
  for (const match of text.matchAll(constructors)) {
    const api = resolver.api(file, match[1] ?? match[2]);
    const start = range.start + match.index + match[0].length;
    const close = findMatching(masked, start - 1, "(", ")");
    const [target] = resolver.parts(masked, start, close);
    if (api.startsWith("non-process:")) {
      observations.push({ ...resolver.known([], resolver.reference(file, start, api)), api, offset: start });
      continue;
    }
    const result = close < 0 ? resolver.unknown("unclosed process constructor") : resolver.resolve(file, ...target);
    if (api.startsWith("unresolved-api:")) result.reasons.push(api);
    const observation = { ...result, api, offset: range.start + match.index };
    observations.push(observation);
    if (result.targets.some((value) => /^(?:sh|bash|zsh|cmd(?:\.exe)?|powershell(?:\.exe)?|pwsh|env|sandbox-exec)$/u.test(path.posix.basename(value)))) {
      const binding = entry.bindings.find((entry) => entry.expression[0] <= start && start < entry.expression[1]);
      const boundary = binding ? Math.min(...binding.scopes.map((scope) => scope.end)) : range.end;
      const argumentText = masked.slice(close + 1, Math.max(range.end, boundary));
      const operands = [];
      for (const argument of argumentText.matchAll(/\.\s*args?\s*\(/gu)) {
        const open = close + 1 + argument.index + argument[0].length - 1;
        const end = findMatching(masked, open, "(", ")");
        const operand = source.slice(open + 1, end).trim();
        const array = operand.startsWith("[") ? masked.indexOf("[", open + 1) : -1;
        const values = array >= 0 ? resolver.parts(masked, array + 1, end - 1) : [[open + 1, end]];
        for (const value of values) {
          if (!source.slice(...value).trim()) continue;
          const guest = resolver.resolve(file, ...value);
          operands.push(guest);
        }
      }
      if (/\bProcess\b/u.test(text)) {
        const args = resolver.parts(masked, start, close)[1];
        if (args) {
          const open = masked.indexOf("[", args[0]);
          if (open >= args[0] && open < args[1]) {
            for (const value of resolver.parts(masked, open + 1, findMatching(masked, open, "[", "]"))) {
              if (source.slice(...value).trim()) operands.push(resolver.resolve(file, ...value));
            }
          } else operands.push(resolver.unknown("dynamic shell argument vector"));
        }
      }
      for (const target of [...result.targets].filter((value) => /^(?:sh|bash|zsh|cmd(?:\.exe)?|powershell(?:\.exe)?|pwsh|env|sandbox-exec)$/u.test(path.posix.basename(value)))) {
        const executable = path.posix.basename(target).replace(/\.exe$/u, "");
        let selected = false;
        for (let index = 0; index < operands.length; index += 1) {
          const operand = operands[index];
          const value = operand.reasons.length === 0 && operand.targets.length === 1 ? operand.targets[0] : null;
          if (executable === "sandbox-exec" && ["-p", "-f", "-D"].includes(value)) { index += 1; continue; }
          if (["sh", "bash", "zsh"].includes(executable) && value?.startsWith("-") && !value.includes("c")) continue;
          if (["powershell", "pwsh"].includes(executable) && ["-NoProfile", "-NonInteractive"].includes(value)) continue;
          if (["powershell", "pwsh"].includes(executable) && value === "-ExecutionPolicy") { index += 1; continue; }
          const inlineScript = (["sh", "bash", "zsh"].includes(executable) && value?.startsWith("-") && value.includes("c")) || ["-Command", "/c"].includes(value);
          const scriptFile = value === "-File";
          const guest = inlineScript || scriptFile ? operands[++index] : operand;
          if (!guest) observation.reasons.push("launcher omits its guest target");
          else {
            observation.reasons.push(...guest.reasons.map((reason) => `guest target: ${reason}`));
            observation.evidence.push(...guest.evidence);
            if (scriptFile || (["sh", "bash", "zsh"].includes(executable) && !inlineScript)) {
              observation.reasons.push("script-file contents require source-owned provenance");
            }
            if (inlineScript) for (const script of guest.targets) {
              for (const tool of new Set([...toolsInText(script), ...toolsInContent(script)])) observation.targets.push(tool);
            }
            if (["sandbox-exec", "env"].includes(executable)) observation.targets.push(...guest.targets);
          }
          selected = true;
          break;
        }
        if (!selected) observation.reasons.push("launcher guest command is not present in the bounded source expression");
      }
    }
  }
  if (observations.length) return { ...resolver.union(observations), api: [...new Set(observations.map((entry) => entry.api))].join(", "), offset: observations[0].offset };
  if (new RegExp(`\\b(?:${commandTypes})\\s*::\\s*(?:new|spawn|output|status)\\b|\\bProcess\\s*\\.\\s*(?:run|runSync|start)\\b`, "u").test(text)) return resolver.unknown("process API referenced without a resolved call");
  // Member calls count only with Command evidence; task/thread spawn methods
  // are not process APIs merely because they have the same method name.
  for (const match of text.matchAll(/\b(\w+)\s*\.\s*(?:spawn|output|status)\s*\(/gu)) {
    const receiver = match[1];
    const visible = entry.bindings.filter((binding) => binding.name === receiver && binding.start < range.start &&
      binding.scopes.every((scope) => scope.start < range.start && range.start < scope.end));
    const binding = visible.sort((a, b) => b.start - a.start)[0];
    if (binding && new RegExp(`\\b(?:${commandTypes})\\s*::\\s*new\\s*\\(`, "u").test(masked.slice(...binding.expression))) {
      const result = processTargetAttribution(file, { start: binding.start, end: range.end }, sources, aliases, resolver, visited);
      return result && { ...result, offset: range.start + match.index };
    }
    if (binding) {
      const called = entry.functions.find((fn) =>
        new RegExp(`\\b${escapePattern(fn.name)}\\s*\\(`, "u").test(masked.slice(...binding.expression)) &&
        /^(?:std|tokio)::process::Command$/u.test(resolver.api(file,
          masked.slice(fn.close + 1, fn.bodyStart).match(/^\s*->\s*(?:(?:(?:\w+\s*::\s*)*Result)\s*<\s*)?((?:\w+\s*::\s*)*\w+)/u)?.[1] ?? "")));
      if (called) {
        const expression = source.slice(...binding.expression);
        const invocation = expression.match(new RegExp(`\\b${escapePattern(called.name)}\\s*\\(`, "u"));
        const start = binding.expression[0] + invocation.index;
        const open = start + invocation[0].length - 1;
        return { ...resolver.resolve(file, start, findMatching(masked, open, "(", ")") + 1), api: "source-returned Command", offset: range.start + match.index };
      }
    }
    if (new RegExp(`\\b${receiver}\\s*:\\s*(?:&\\s*(?:mut\\s+)?)?(?:[\\w]+\\s*::\\s*)*Command\\b`, "u").test(masked)) return { ...resolver.unknown("Command receiver is supplied by an unresolved caller or field"), offset: range.start + match.index };
  }
  return null;
}

/**
 * Scan runtime sources for developer-tool execution sinks.
 */
export async function inspectDeveloperToolSites({
  repoRoot,
  readdir,
  readFile,
  allowlist = DEVELOPER_TOOL_ALLOWLIST,
  manifests = new Map(),
}) {
  const collected = await collectRuntimeSourceFiles(repoRoot, { readdir });
  const problems = [...collected.problems];
  const sources = new Map();
  const nonRuntimeCrates = nonRuntimeLibraries(manifests);
  for (const file of collected.files) {
    if (nonRuntimeCrates.some((record) => file.startsWith(`${path.posix.dirname(record.path)}/src/`))) continue;
    let raw = "";
    try {
      raw = await readFile(path.join(repoRoot, file), "utf8");
    } catch (error) {
      problems.push(`${file} cannot be read: ${error?.code ?? error?.message ?? "unknown"}`);
      continue;
    }
    const language = file.endsWith(".dart") ? "dart" : "rust";
    problems.push(...lexicalView(raw, language).problems.map((problem) => `${file}: ${problem}`));
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
  const resolver = createTargetAttribution(sources, manifests);

  const relevantSinks = [];
  const unresolved = [];
  const resolvedNonTools = [];
  const nonProcess = [];
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
    const aliases = [...masked.matchAll(/\bCommand\s+as\s+(\w+)/gu)].map((match) => match[1]);
    for (const range of rangedRanges) {
      if (!hasExecutionToken(range.masked, aliases)) {
        continue;
      }
      scannedSinkStatements += 1;
      const attribution = processTargetAttribution(file, range, sources, aliases, resolver);
      const observation = attribution && {
        file, sink: fingerprintFor(file, source, range),
        line: lineForOffset(starts, attribution.offset ?? range.start),
        api: attribution.api ?? "process member/reference",
        targets: attribution.targets, reasons: attribution.reasons, evidence: attribution.evidence,
      };
      if (attribution?.api?.startsWith("non-process:") && attribution.reasons.length === 0) {
        nonProcess.push(observation);
        continue;
      }
      const tools = sinkTools({ file, sinkRange: range, sources, index, callSites });
      for (const target of attribution?.targets ?? []) {
        if (!target.startsWith("native:")) {
          for (const tool of DEVELOPER_TOOL_NAMES) if (toolInLiteral(target, tool)) tools.add(tool);
        }
      }
      if (tools.size === 0) {
        for (const tool of fileTools) {
          tools.add(tool);
        }
      }
      if (tools.size === 0) {
        if (attribution?.reasons.length) unresolved.push(observation);
        else if (attribution) resolvedNonTools.push(observation);
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

  const unresolvedOccurrences = new Map();
  for (const site of unresolved) {
    const key = `${site.file}::${site.sink}`;
    const occurrence = (unresolvedOccurrences.get(key) ?? 0) + 1;
    unresolvedOccurrences.set(key, occurrence);
    if (occurrence > 1) site.sink += `#${occurrence}`;
    problems.push(`${site.file}:${site.line} [${site.sink}] has an unresolved process target (${site.api}): ${site.reasons.join("; ")}; developer-tool execution cannot be excluded`);
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
    if (!entry || sink.tools.length !== new Set(entry.tools).size || sink.tools.some((tool) => !entry.tools.includes(tool))) {
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
    unresolved,
    resolvedNonTools,
    nonProcess,
    nonRuntimeCrates,
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
