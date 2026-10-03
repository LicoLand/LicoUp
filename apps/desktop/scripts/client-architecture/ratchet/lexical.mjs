/**
 * Minimal lexical maskers for the architecture ratchet.
 *
 * The ratchet must not classify commented-out code as execution and must not
 * miss real code hidden behind lifetimes, raw strings, or nested comments. A
 * full compiler parser is out of scope, so these maskers implement the lexical
 * surface the measurements need: comments (nested), string literals (including
 * Rust raw/byte strings and Dart raw/triple strings), and Rust char literals
 * versus lifetimes. `masked` preserves offsets and newlines while blanking
 * comments and string contents, and `regions` exposes the original spans so
 * occurrences can be searched inside strings while tokens are searched only in
 * code.
 *
 * This is a declared-scope lexical scan, not a compiler front end.
 */

const rustRawPrefixes = new Set(["r", "br", "cr"]);
const dartRawPrefix = "r";

function blank(source, target, from, to) {
  for (let index = from; index < to; index += 1) {
    target[index] = source[index] === "\n" ? "\n" : " ";
  }
}

function scanEscapedString(source, start, quote) {
  let index = start;
  while (index < source.length) {
    if (source[index] === "\\") {
      index += 2;
      continue;
    }
    if (source[index] === quote) {
      return index + 1;
    }
    index += 1;
  }
  return -1;
}

function scanNestedBlockComment(source, start) {
  let depth = 1;
  let index = start + 2;
  while (index < source.length && depth > 0) {
    if (source[index] === "/" && source[index + 1] === "*") {
      depth += 1;
      index += 2;
    } else if (source[index] === "*" && source[index + 1] === "/") {
      depth -= 1;
      index += 2;
    } else {
      index += 1;
    }
  }
  return depth === 0 ? index : -1;
}

function matchRustRawString(source, start) {
  let index = start;
  let prefix = "";
  if (source[index] === "b" || source[index] === "c") {
    prefix += source[index];
    index += 1;
  }
  if (!rustRawPrefixes.has(prefix + (source[index] === "r" ? "r" : ""))) {
    return null;
  }
  if (source[index] !== "r") {
    return null;
  }
  index += 1;
  let hashes = 0;
  while (source[index] === "#") {
    hashes += 1;
    index += 1;
  }
  if (source[index] !== '"') {
    return null;
  }
  const contentStart = index + 1;
  const terminator = `"${"#".repeat(hashes)}`;
  const end = source.indexOf(terminator, contentStart);
  if (end < 0) {
    return { end: source.length, contentStart, contentEnd: source.length, unterminated: true };
  }
  return { end: end + terminator.length, contentStart, contentEnd: end };
}

function scanRustCharLiteral(source, start) {
  const next = source[start + 1];
  if (next === "\\") {
    let index = start + 2;
    while (index < source.length && index < start + 16) {
      if (source[index] === "\\") {
        index += 2;
        continue;
      }
      if (source[index] === "'") {
        return index + 1;
      }
      index += 1;
    }
    return -1;
  }
  if (next !== undefined && source[start + 2] === "'") {
    return start + 3;
  }
  return -1;
}

function scanDartString(source, start, raw) {
  const quote = source[start];
  const triple = source.startsWith(quote.repeat(3), start);
  const terminator = triple ? quote.repeat(3) : quote;
  const contentStart = start + terminator.length;
  let index = contentStart;
  while (index < source.length) {
    if (!raw && source[index] === "\\") {
      index += 2;
      continue;
    }
    if (source.startsWith(terminator, index)) {
      return {
        end: index + terminator.length,
        contentStart,
        contentEnd: index,
      };
    }
    index += 1;
  }
  return { end: source.length, contentStart, contentEnd: source.length, unterminated: true };
}

function lexRustSource(source) {
  const masked = source.split("");
  const regions = [];
  const problems = [];
  let index = 0;
  while (index < source.length) {
    const character = source[index];
    if (character === "/" && source[index + 1] === "/") {
      const end = source.indexOf("\n", index);
      const stop = end < 0 ? source.length : end;
      regions.push({ kind: "comment", start: index, end: stop });
      blank(source, masked, index, stop);
      index = stop;
      continue;
    }
    if (character === "/" && source[index + 1] === "*") {
      const close = scanNestedBlockComment(source, index);
      if (close < 0) problems.push("unterminated block comment");
      const end = close < 0 ? source.length : close;
      regions.push({ kind: "comment", start: index, end });
      blank(source, masked, index, end);
      index = end;
      continue;
    }
    const raw = matchRustRawString(source, index);
    if (raw) {
      if (raw.unterminated) problems.push("unterminated raw string");
      regions.push({ kind: "string", start: index, end: raw.end, raw: true });
      blank(source, masked, index, raw.end);
      index = raw.end;
      continue;
    }
    if (character === '"') {
      const close = scanEscapedString(source, index + 1, '"');
      if (close < 0) problems.push("unterminated string");
      const end = close < 0 ? source.length : close;
      regions.push({ kind: "string", start: index, end, raw: false });
      blank(source, masked, index, end);
      index = end;
      continue;
    }
    if (character === "'") {
      const end = scanRustCharLiteral(source, index);
      if (end > 0) {
        regions.push({ kind: "string", start: index, end, raw: false, char: true });
        blank(source, masked, index, end);
        index = end;
        continue;
      }
      // Lifetime or label: remains code.
    }
    index += 1;
  }
  return { masked: masked.join(""), regions, problems };
}

function lexDartSource(source) {
  const masked = source.split("");
  const regions = [];
  const problems = [];
  let index = 0;
  while (index < source.length) {
    const character = source[index];
    if (character === "/" && source[index + 1] === "/") {
      const end = source.indexOf("\n", index);
      const stop = end < 0 ? source.length : end;
      regions.push({ kind: "comment", start: index, end: stop });
      blank(source, masked, index, stop);
      index = stop;
      continue;
    }
    if (character === "/" && source[index + 1] === "*") {
      const close = scanNestedBlockComment(source, index);
      if (close < 0) problems.push("unterminated block comment");
      const end = close < 0 ? source.length : close;
      regions.push({ kind: "comment", start: index, end });
      blank(source, masked, index, end);
      index = end;
      continue;
    }
    const rawQuoted =
      character === dartRawPrefix &&
      (source[index + 1] === "'" || source[index + 1] === '"');
    if (character === "'" || character === '"' || rawQuoted) {
      const quoteStart = rawQuoted ? index + 1 : index;
      const scanned = scanDartString(source, quoteStart, rawQuoted);
      if (scanned.unterminated) problems.push("unterminated string");
      regions.push({
        kind: "string",
        start: index,
        end: scanned.end,
        raw: rawQuoted,
      });
      blank(source, masked, index, scanned.end);
      index = scanned.end;
      continue;
    }
    index += 1;
  }
  return { masked: masked.join(""), regions, problems };
}

export function lexRust(source) {
  return lexRustSource(source);
}

export function lexDart(source) {
  return lexDartSource(source);
}

/** Lex a runtime source by language name. */
export function lexicalView(source, language) {
  return language === "dart" ? lexDartSource(source) : lexRustSource(source);
}

/**
 * Code statement ranges: boundaries are every block brace and every `;` that
 * is not inside parentheses or brackets. This keeps a multi-line command
 * builder as one statement while never merging separate blocks, so a
 * `Command::new` in one function cannot classify literals in another.
 */
export function statementRanges(masked) {
  const ranges = [];
  let start = 0;
  let parenDepth = 0;
  for (let index = 0; index < masked.length; index += 1) {
    const character = masked[index];
    if (character === "(" || character === "[") {
      parenDepth += 1;
    } else if (character === ")" || character === "]") {
      parenDepth = Math.max(0, parenDepth - 1);
    } else if (character === "{") {
      ranges.push({ start, end: index });
      start = index + 1;
    } else if (character === "}") {
      ranges.push({ start, end: index });
      start = index + 1;
    } else if (character === ";" && parenDepth === 0) {
      ranges.push({ start, end: index + 1 });
      start = index + 1;
    }
  }
  ranges.push({ start, end: masked.length });
  return ranges;
}

export function statementAt(ranges, offset) {
  for (const range of ranges) {
    if (offset >= range.start && offset < range.end) {
      return range;
    }
  }
  return ranges.length > 0 ? ranges[ranges.length - 1] : { start: 0, end: 0 };
}

export function normalizeSnippet(text) {
  return text.replace(/\s+/gu, " ").trim();
}
