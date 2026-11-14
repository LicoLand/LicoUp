import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

/** Placeholder for an argv position the Desktop fills at run time. */
export const DYNAMIC_TOKEN = "*";

/** Dart sources whose CLI invocations the release contract must admit. */
export const DESKTOP_INVOCATION_SOURCE_ROOT = "apps/desktop/lib";

// Generated protocol bindings are verified through the conversation protocol
// digest, not through argv extraction.
const EXCLUDED_DIRECTORIES = new Set(["generated"]);

// An argv list literal is recognised by the position it is written in: passed
// to a runner entry point or a process start, or assigned to an argv-named
// variable, parameter or field, optionally as either branch of a conditional.
// Lists elsewhere (search keywords, pattern matches) are not invocations.
const INVOCATION_HEADS = [
  String.raw`\b_?(?:run|invoke|execute|stream)[A-Za-z]*\(\s*(?:[A-Za-z_][\w.]*\s*,\s*)?`,
  String.raw`\bstartProcess\(\s*[^;]*?,\s*`,
  String.raw`\b(?:args|arguments|argv)\s*[:=]\s*`,
];
const CONDITIONAL_TAILS = [
  "",
  String.raw`[^;,()[\]]*\?\s*`,
  String.raw`[^;,()[\]]*\?\s*(?:const\s+)?(?:<String>\s*)?\[[^\]]*\]\s*:\s*`,
];
const INVOCATION_CONTEXT = new RegExp(
  `(?:${INVOCATION_HEADS.join("|")})(?:${CONDITIONAL_TAILS.join("|")})$`,
  "u",
);
const LITERAL_PREFIX = /(?:const\s+)?(?:<String>\s*)?$/u;
const COMMAND_WORD = /^[a-z][a-z0-9-]*$/u;

/**
 * Every CLI command shape the Desktop source invokes, as token patterns.
 *
 * A pattern holds the literal command words up to the first option flag; an
 * argument computed at run time becomes [DYNAMIC_TOKEN]. The set is derived
 * from source, so a new invocation is covered without a hand-kept list.
 */
export function extractInvokedCliCommands(
  repositoryRoot,
  sourceRoot = DESKTOP_INVOCATION_SOURCE_ROOT,
) {
  const patterns = new Map();
  for (const file of dartFiles(path.join(repositoryRoot, ...sourceRoot.split("/")))) {
    for (const pattern of invocationPatterns(readFileSync(file, "utf8"))) {
      patterns.set(pattern.join(" "), pattern);
    }
  }
  return [...patterns.values()].sort((left, right) =>
    left.join(" ").localeCompare(right.join(" ")));
}

/** Argv patterns found in one Dart source text. */
export function invocationPatterns(source) {
  const code = withoutComments(source);
  const patterns = [];
  for (let index = code.indexOf("["); index >= 0; index = code.indexOf("[", index + 1)) {
    const before = code.slice(Math.max(0, index - 240), index);
    const prefix = before.replace(LITERAL_PREFIX, "");
    if (!INVOCATION_CONTEXT.test(prefix)) continue;
    const elements = listElements(code, index);
    if (!elements) continue;
    patterns.push(...commandPatterns(elements));
  }
  return patterns;
}

/**
 * The invoked patterns no `contract.commands` entry admits.
 *
 * An entry admits a pattern when its `path` equals the pattern's leading
 * tokens (a dynamic token matches any word) and the remaining tokens fit the
 * entry's required positional arguments.
 */
export function unadmittedInvocations(invoked, contractCommands) {
  const paths = contractCommands.map((entry) => ({
    path: entry.path,
    positionals: Array.isArray(entry.requiredPositionals)
      ? entry.requiredPositionals.length
      : 0,
  }));
  return invoked.filter((pattern) => !paths.some((entry) => admits(entry, pattern)));
}

function admits(entry, pattern) {
  if (entry.path.length > pattern.length) return false;
  for (let index = 0; index < entry.path.length; index += 1) {
    if (pattern[index] !== DYNAMIC_TOKEN && pattern[index] !== entry.path[index]) {
      return false;
    }
  }
  return pattern.length - entry.path.length <= entry.positionals;
}

/**
 * The command patterns one argv list spells. A conditional choosing between
 * two command words (`enabled ? 'enable' : 'disable'`) spells both.
 */
function commandPatterns(elements) {
  let patterns = [[]];
  for (const element of elements) {
    const literal = stringLiteral(element);
    if (literal !== null) {
      if (literal.startsWith("-")) break;
      if (patterns[0].length === 0 && !COMMAND_WORD.test(literal)) return [];
      patterns = patterns.map((pattern) => [...pattern, literal]);
      continue;
    }
    if (patterns[0].length === 0) return [];
    if (element.startsWith("...") || /^(?:if|for)\b/u.test(element)) break;
    const choices = literalChoices(element);
    patterns = choices
      ? patterns.flatMap((pattern) => choices.map((choice) => [...pattern, choice]))
      : patterns.map((pattern) => [...pattern, DYNAMIC_TOKEN]);
  }
  return patterns[0].length === 0 ? [] : patterns;
}

function stringLiteral(element) {
  const match = /^(?:'([^'\\$]*)'|"([^"\\$]*)")$/u.exec(element);
  if (!match) return null;
  return match[1] ?? match[2];
}

function literalChoices(element) {
  const match = /\?\s*'([a-z][a-z0-9-]*)'\s*:\s*'([a-z][a-z0-9-]*)'$/u.exec(element);
  return match ? [match[1], match[2]] : null;
}

/** Top-level elements of the list literal opening at [open], or null. */
function listElements(code, open) {
  const elements = [];
  let depth = 0;
  let start = open + 1;
  for (let index = open; index < code.length; index += 1) {
    const char = code[index];
    if (char === "'" || char === "\"") {
      index = skipString(code, index);
      continue;
    }
    if (char === "[" || char === "(" || char === "{") {
      depth += 1;
    } else if (char === "]" || char === ")" || char === "}") {
      depth -= 1;
      if (depth === 0) {
        const tail = code.slice(start, index).trim();
        if (tail) elements.push(tail);
        return elements;
      }
    } else if (char === "," && depth === 1) {
      elements.push(code.slice(start, index).trim());
      start = index + 1;
    }
  }
  return null;
}

function skipString(code, open) {
  const quote = code[open];
  for (let index = open + 1; index < code.length; index += 1) {
    if (code[index] === "\\") {
      index += 1;
    } else if (code[index] === quote) {
      return index;
    }
  }
  return code.length;
}

function withoutComments(source) {
  let result = "";
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (char === "'" || char === "\"") {
      const end = skipString(source, index);
      result += source.slice(index, end + 1);
      index = end;
    } else if (char === "/" && source[index + 1] === "/") {
      const end = source.indexOf("\n", index);
      index = end < 0 ? source.length : end - 1;
    } else if (char === "/" && source[index + 1] === "*") {
      const end = source.indexOf("*/", index + 2);
      index = end < 0 ? source.length : end + 1;
    } else {
      result += char;
    }
  }
  return result;
}

function dartFiles(directory) {
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      if (!EXCLUDED_DIRECTORIES.has(entry.name)) files.push(...dartFiles(absolute));
    } else if (entry.isFile() && entry.name.endsWith(".dart")) {
      files.push(absolute);
    }
  }
  return files.sort();
}
