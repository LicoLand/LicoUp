import path from "node:path";
import { fail } from "./errors.mjs";
import { normalizeRelative } from "./paths.mjs";

export function stripDartComments(source) {
  let result = "";
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (character === "\n") {
        lineComment = false;
        result += "\n";
      } else {
        result += " ";
      }
      continue;
    }
    if (blockComment) {
      if (character === "*" && next === "/") {
        result += "  ";
        blockComment = false;
        index += 1;
      } else {
        result += character === "\n" ? "\n" : " ";
      }
      continue;
    }
    if (quote != null) {
      result += character;
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === "/" && next === "/") {
      result += "  ";
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      result += "  ";
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
    }
    result += character;
  }
  return result;
}

export function importsFrom(source) {
  const uncommented = stripDartComments(source);
  const imports = [];
  const directive =
    /^\s*(?:import|export|part)(?!\s+of\b)\s+([\s\S]*?);/gmu;
  for (const match of uncommented.matchAll(directive)) {
    for (const uri of match[1].matchAll(/['"]([^'"\r\n]+)['"]/gu)) {
      imports.push(uri[1]);
    }
  }
  return imports;
}

export function resolveDartImport(importer, specifier) {
  if (specifier.startsWith("package:licoup/")) {
    return normalizeRelative(
      `apps/desktop/lib/${specifier.slice("package:licoup/".length)}`,
    );
  }
  if (specifier.startsWith(".") || !specifier.includes(":")) {
    return normalizeRelative(
      path.posix.join(path.posix.dirname(importer), specifier),
    );
  }
  return null;
}

export function matchingDelimiter(
  source,
  openIndex,
  openToken,
  closeToken,
  code,
  relativePath = "",
) {
  let depth = 0;
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = openIndex; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (character === "\n") {
        lineComment = false;
      }
      continue;
    }
    if (blockComment) {
      if (character === "*" && next === "/") {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === "/" && next === "/") {
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      continue;
    }
    if (character === openToken) {
      depth += 1;
    } else if (character === closeToken) {
      depth -= 1;
      if (depth === 0) {
        return index;
      }
    }
  }
  fail(code, relativePath);
}

export function maskCommentsAndStrings(source) {
  let result = "";
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (character === "\n") {
        lineComment = false;
        result += "\n";
      } else {
        result += " ";
      }
      continue;
    }
    if (blockComment) {
      if (character === "*" && next === "/") {
        result += "  ";
        blockComment = false;
        index += 1;
      } else {
        result += character === "\n" ? "\n" : " ";
      }
      continue;
    }
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      result += character === "\n" ? "\n" : " ";
      continue;
    }
    if (character === "/" && next === "/") {
      result += "  ";
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      result += "  ";
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      result += " ";
      continue;
    }
    result += character;
  }
  return result;
}
