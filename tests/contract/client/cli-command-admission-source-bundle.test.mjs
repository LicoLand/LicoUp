import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const commandRoot = "crates/licoup-native/src/ffi/commands";
const commandFacade = `${commandRoot}/mod.rs`;

const retiredRegistrationApis = new Set([
  "register",
  "register_rest",
  "register_with_positionals",
  "register_family",
  "register_prefix",
]);
const commandTableRetiredRegistrationApis = new Set([
  "register",
  "register_rest",
  "register_with_positionals",
]);

// These were formerly registered as family prefixes and dispatched a second
// time inside handlers. Each supported action must instead be an exact route.
const retiredFamilyRoutes = new Set([
  "adapter",
  "agent conversation",
  "agents pair",
  "catalog",
  "conversations",
  "mobile relay",
  "openclaw-gateway",
  "opencode-serve",
  "secure-mesh",
  "snapshots archive",
  "snapshots profiles",
  "snapshots root",
  "update",
]);

const retiredPublicCompatibilityResidueDefinitions = [
  ...["status", "invalidate", "refresh", "receipt", "purge", "reconnect"].map(
    (action) => ({
      owner: `${commandRoot}/catalog.rs`,
      path: `catalog ${action}`,
      action: ["catalog", action],
      symbols: [],
      strings: [`catalog ${action}`],
      moduleRemoved: true,
    }),
  ),
  {
    owner: `${commandRoot}/collaboration.rs`,
    path: "collaboration runner-trust import",
    action: ["runner-trust", "import"],
    symbols: ["handle_runner_trust_import"],
    strings: ["runner-trust import"],
  },
  {
    owner: `${commandRoot}/collaboration.rs`,
    path: "collaboration runner-trust remove",
    action: ["runner-trust", "remove"],
    symbols: ["handle_runner_trust_remove"],
    strings: ["runner-trust remove"],
  },
  {
    owner: `${commandRoot}/collaboration.rs`,
    path: "collaboration mcp-bridge",
    action: ["mcp-bridge"],
    symbols: ["handle_mcp_bridge"],
    strings: ["collaboration mcp-bridge"],
  },
  {
    owner: `${commandRoot}/collaboration.rs`,
    path: "collaboration uninstall",
    action: ["uninstall"],
    symbols: ["handle_uninstall"],
    strings: ["collaboration uninstall"],
  },
  ...["ensure", "start", "stop", "restart", "status"].map((action) => ({
    owner: `${commandRoot}/openclaw_gateway.rs`,
    path: `openclaw-gateway ${action}`,
    action: ["openclaw-gateway", action],
    symbols: [],
    strings: [`openclaw-gateway ${action}`],
    moduleRemoved: true,
  })),
  {
    owner: `${commandRoot}/mobile.rs`,
    path: "mobile relay e2ee status",
    action: ["e2ee", "status"],
    symbols: [],
    strings: ["e2ee status"],
  },
  {
    owner: `${commandRoot}/mobile.rs`,
    path: "mobile relay e2ee secret-store-self-test",
    action: ["e2ee", "secret-store-self-test"],
    symbols: [],
    strings: ["e2ee secret-store-self-test", "secret-store-self-test"],
  },
  ...[
    "configure-authority",
    "publication-request",
    "revocation-request",
    "provision",
    "gossip",
    "self-monitor",
    "status",
  ].map((action) => ({
    owner: `${commandRoot}/mobile.rs`,
    path: `mobile relay kt ${action}`,
    action: ["kt", action],
    symbols: [],
    strings: [`kt ${action}`],
  })),
];
const retiredPublicCompatibilityResidues =
  retiredPublicCompatibilityResidueDefinitions.map((residue) => ({
    ...residue,
    strings: [residue.path, ...residue.strings],
  }));
const retiredPublicCompatibilityRoutes = new Set(
  retiredPublicCompatibilityResidues.map(({ path: route }) => route),
);
const retiredPublicCompatibilityModules = new Set(
  retiredPublicCompatibilityResidues
    .filter(({ moduleRemoved }) => moduleRemoved)
    .map(({ owner }) => owner),
);
const ownerScopedRetiredActionPaths = new Set([
  "collaboration runner-trust import",
  "collaboration runner-trust remove",
  "collaboration uninstall",
  "mobile relay e2ee status",
  "mobile relay kt status",
]);

async function discoverRustSources(relativeDirectory = commandRoot) {
  const entries = await fs.readdir(path.join(repoRoot, relativeDirectory), {
    withFileTypes: true,
  });
  const sources = [];
  for (const entry of entries) {
    const relativePath = path.posix.join(relativeDirectory, entry.name);
    assert.equal(
      entry.isSymbolicLink(),
      false,
      `${relativePath} must not redirect the CLI admission source scan`,
    );
    if (entry.isDirectory()) {
      sources.push(...await discoverRustSources(relativePath));
    } else if (entry.isFile() && entry.name.endsWith(".rs")) {
      sources.push(relativePath);
    }
  }
  return sources.sort();
}

async function commandSources() {
  const paths = await discoverRustSources();
  return new Map(await Promise.all(paths.map(async (relativePath) => [
    relativePath,
    await fs.readFile(path.join(repoRoot, relativePath), "utf8"),
  ])));
}

function lexRust(source) {
  const tokens = [];
  let cursor = 0;
  while (cursor < source.length) {
    const character = source[cursor];
    if (/\s/u.test(character)) {
      cursor += 1;
      continue;
    }
    if (source.startsWith("//", cursor)) {
      const newline = source.indexOf("\n", cursor + 2);
      cursor = newline === -1 ? source.length : newline + 1;
      continue;
    }
    if (source.startsWith("/*", cursor)) {
      let depth = 1;
      cursor += 2;
      while (cursor < source.length && depth > 0) {
        if (source.startsWith("/*", cursor)) {
          depth += 1;
          cursor += 2;
        } else if (source.startsWith("*/", cursor)) {
          depth -= 1;
          cursor += 2;
        } else {
          cursor += 1;
        }
      }
      assert.equal(depth, 0, "unterminated Rust block comment");
      continue;
    }

    const raw = rawStringAt(source, cursor);
    if (raw !== null) {
      tokens.push({ kind: "string", value: raw.value });
      cursor = raw.end;
      continue;
    }

    const stringPrefix = source.startsWith('b"', cursor) ? 1 : 0;
    if (source[cursor + stringPrefix] === '"') {
      const parsed = quotedLiteral(source, cursor + stringPrefix, '"');
      tokens.push({ kind: "string", value: parsed.value });
      cursor = parsed.end;
      continue;
    }
    const charPrefix = source.startsWith("b'", cursor) ? 1 : 0;
    if (source[cursor + charPrefix] === "'" && looksLikeChar(source, cursor + charPrefix)) {
      const parsed = quotedLiteral(source, cursor + charPrefix, "'");
      tokens.push({ kind: "char", value: parsed.value });
      cursor = parsed.end;
      continue;
    }
    if (/[A-Za-z_]/u.test(character)) {
      let end = cursor + 1;
      while (end < source.length && /[A-Za-z0-9_]/u.test(source[end])) end += 1;
      tokens.push({ kind: "identifier", value: source.slice(cursor, end) });
      cursor = end;
      continue;
    }
    if (/[0-9]/u.test(character)) {
      let end = cursor + 1;
      while (end < source.length && /[A-Za-z0-9_]/u.test(source[end])) end += 1;
      tokens.push({ kind: "number", value: source.slice(cursor, end) });
      cursor = end;
      continue;
    }
    tokens.push({ kind: "punctuation", value: character });
    cursor += 1;
  }
  return tokens;
}

function rawStringAt(source, start) {
  let prefixLength;
  if (source.startsWith("br", start)) prefixLength = 2;
  else if (source[start] === "r") prefixLength = 1;
  else return null;
  let cursor = start + prefixLength;
  let hashes = "";
  while (source[cursor] === "#") {
    hashes += "#";
    cursor += 1;
  }
  if (source[cursor] !== '"') return null;
  const contentStart = cursor + 1;
  const terminator = `"${hashes}`;
  const contentEnd = source.indexOf(terminator, contentStart);
  assert.notEqual(contentEnd, -1, "unterminated Rust raw string");
  return {
    value: source.slice(contentStart, contentEnd),
    end: contentEnd + terminator.length,
  };
}

function quotedLiteral(source, quoteStart, quote) {
  let cursor = quoteStart + 1;
  let value = "";
  while (cursor < source.length) {
    if (source[cursor] === "\\") {
      assert.ok(cursor + 1 < source.length, "unterminated Rust escape");
      value += source.slice(cursor, cursor + 2);
      cursor += 2;
    } else if (source[cursor] === quote) {
      return { value, end: cursor + 1 };
    } else {
      value += source[cursor];
      cursor += 1;
    }
  }
  assert.fail(`unterminated Rust ${quote} literal`);
}

function looksLikeChar(source, quoteStart) {
  let cursor = quoteStart + 1;
  if (source[cursor] === "\\") cursor += 2;
  else cursor += 1;
  return source[cursor] === "'";
}

function values(tokens) {
  return tokens.map((token) => token.value);
}

function sequenceIndex(tokens, expected, start = 0) {
  const tokenValues = values(tokens);
  outer:
  for (let index = start; index <= tokenValues.length - expected.length; index += 1) {
    for (let offset = 0; offset < expected.length; offset += 1) {
      if (tokenValues[index + offset] !== expected[offset]) continue outer;
    }
    return index;
  }
  return -1;
}

function matchingDelimiter(tokens, openIndex) {
  const pairs = new Map([["(", ")"], ["[", "]"], ["{", "}"]]);
  const open = tokens[openIndex]?.value;
  const close = pairs.get(open);
  assert.ok(close, `token ${openIndex} is not an opening delimiter`);
  let depth = 0;
  for (let index = openIndex; index < tokens.length; index += 1) {
    if (tokens[index].value === open) depth += 1;
    if (tokens[index].value === close) {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  assert.fail(`unclosed ${open} delimiter`);
}

function provenCommandTableReceiverStart(tokens, dotIndex, binding) {
  if (
    tokens[dotIndex - 1]?.kind === "identifier"
    && tokens[dotIndex - 1].value === binding
  ) {
    return dotIndex - 1;
  }
  if (tokens[dotIndex - 1]?.value !== ")") return -1;
  let depth = 0;
  for (let index = dotIndex - 1; index >= 0; index -= 1) {
    if (tokens[index].value === ")") depth += 1;
    if (tokens[index].value === "(") {
      depth -= 1;
      if (depth !== 0) continue;
      let receiver = tokens.slice(index + 1, dotIndex - 1);
      const unwrapParentheses = () => {
        while (
          receiver[0]?.value === "("
          && matchingDelimiter(receiver, 0) === receiver.length - 1
        ) receiver = receiver.slice(1, -1);
      };
      unwrapParentheses();
      if (receiver[0]?.value === "&") {
        receiver = receiver.slice(
          receiver[1]?.value === "mut" ? 2 : 1,
        );
        unwrapParentheses();
      }
      return receiver.length === 1
        && receiver[0].kind === "identifier"
        && receiver[0].value === binding
        ? index
        : -1;
    }
  }
  return -1;
}

function isProvenCommandTableReceiver(tokens, dotIndex, binding) {
  return provenCommandTableReceiverStart(tokens, dotIndex, binding) !== -1;
}

function callOpenAfterIdentifier(tokens, nameIndex) {
  let cursor = nameIndex + 1;
  if (
    tokens[cursor]?.value === ":"
    && tokens[cursor + 1]?.value === ":"
    && tokens[cursor + 2]?.value === "<"
  ) {
    cursor += 2;
    let angleDepth = 0;
    for (; cursor < tokens.length; cursor += 1) {
      if (tokens[cursor].value === "<") angleDepth += 1;
      if (tokens[cursor].value === ">") {
        angleDepth -= 1;
        if (angleDepth === 0) {
          cursor += 1;
          break;
        }
      }
    }
  }
  return tokens[cursor]?.value === "(" ? cursor : -1;
}

function stripLeadingImplGenerics(tokens) {
  if (tokens[0]?.value !== "<") return tokens;
  let depth = 0;
  for (let index = 0; index < tokens.length; index += 1) {
    if (tokens[index].value === "<") depth += 1;
    if (tokens[index].value === ">") {
      depth -= 1;
      if (depth === 0) return tokens.slice(index + 1);
    }
  }
  assert.fail("unclosed impl generic parameter list");
}

function isExactLocalType(tokens, typeName) {
  return (
    tokens.length === 1
    && tokens[0].kind === "identifier"
    && tokens[0].value === typeName
  ) || (
    tokens.length === 4
    && tokens[0].kind === "identifier"
    && tokens[0].value === "self"
    && tokens[1].value === ":"
    && tokens[2].value === ":"
    && tokens[3].kind === "identifier"
    && tokens[3].value === typeName
  );
}

function isLocalTypeDirectUfcs(tokens, nameIndex, typeName) {
  if (
    tokens[nameIndex - 1]?.value !== ":"
    || tokens[nameIndex - 2]?.value !== ":"
  ) return false;
  if (
    tokens[nameIndex - 3]?.kind === "identifier"
    && tokens[nameIndex - 3].value === typeName
    && tokens[nameIndex - 4]?.value !== ":"
  ) return true;
  return (
    tokens[nameIndex - 6]?.kind === "identifier"
    && tokens[nameIndex - 6].value === "self"
    && tokens[nameIndex - 5]?.value === ":"
    && tokens[nameIndex - 4]?.value === ":"
    && tokens[nameIndex - 3]?.kind === "identifier"
    && tokens[nameIndex - 3].value === typeName
    && tokens[nameIndex - 7]?.value !== ":"
  );
}

function isCommandTableQualifiedUfcs(tokens, nameIndex) {
  if (
    tokens[nameIndex - 1]?.value !== ":"
    || tokens[nameIndex - 2]?.value !== ":"
    || tokens[nameIndex - 3]?.value !== ">"
  ) return false;
  let depth = 0;
  for (let index = nameIndex - 3; index >= 0; index -= 1) {
    if (tokens[index].value === ">") depth += 1;
    if (tokens[index].value !== "<") continue;
    depth -= 1;
    if (depth !== 0) continue;
    const qualifier = tokens.slice(index + 1, nameIndex - 3);
    const asIndex = qualifier.findIndex((token) => token.value === "as");
    const target = asIndex === -1
      ? qualifier
      : qualifier.slice(0, asIndex);
    return isExactLocalType(target, "CommandTable");
  }
  return false;
}

function splitTopLevelUseBranches(tokens) {
  const branches = [];
  let start = 0;
  const stack = [];
  for (let index = 0; index < tokens.length; index += 1) {
    if (["(", "[", "{"].includes(tokens[index].value)) {
      stack.push(tokens[index].value);
    } else if ([")", "]", "}"].includes(tokens[index].value)) {
      stack.pop();
    } else if (tokens[index].value === "," && stack.length === 0) {
      branches.push(tokens.slice(start, index));
      start = index + 1;
    }
  }
  branches.push(tokens.slice(start));
  return branches.filter((branch) => branch.length > 0);
}

function rustUseTreeBranches(tokens, prefix = []) {
  let braceDepth = 0;
  let treeOpen = -1;
  for (let index = 0; index < tokens.length; index += 1) {
    if (tokens[index].value === "{" && braceDepth === 0) {
      treeOpen = index;
      break;
    }
    if (tokens[index].value === "{") braceDepth += 1;
    if (tokens[index].value === "}") braceDepth -= 1;
  }
  const normalized = (branch) =>
    branch
      .filter(
        (token) =>
          token.kind === "identifier"
          || token.value === "*",
      )
      .map((token) => token.value);
  if (treeOpen === -1) return [[...prefix, ...normalized(tokens)]];
  const treeClose = matchingDelimiter(tokens, treeOpen);
  const branchPrefix = [
    ...prefix,
    ...normalized(tokens.slice(0, treeOpen)),
  ];
  return splitTopLevelUseBranches(
    tokens.slice(treeOpen + 1, treeClose),
  ).flatMap((branch) => rustUseTreeBranches(branch, branchPrefix));
}

function productionTokens(source) {
  const tokens = lexRust(source);
  const output = [];
  let braceDepth = 0;
  const exactTestModule = [
    "#", "[", "cfg", "(", "test", ")", "]", "mod", "tests", "{",
  ];
  for (let index = 0; index < tokens.length; index += 1) {
    const isExactTopLevelTestModule =
      braceDepth === 0
      && exactTestModule.every(
        (value, offset) => tokens[index + offset]?.value === value,
      );
    if (isExactTopLevelTestModule) {
      index = matchingDelimiter(tokens, index + exactTestModule.length - 1);
      continue;
    }
    output.push(tokens[index]);
    if (tokens[index].value === "{") braceDepth += 1;
    if (tokens[index].value === "}") {
      braceDepth -= 1;
      assert.ok(braceDepth >= 0, "unexpected top-level Rust closing brace");
    }
  }
  assert.equal(braceDepth, 0, "unclosed Rust production item");
  return output;
}

function builderRegistrationCalls(tokens, binding) {
  const calls = [];
  for (let index = 0; index + 2 < tokens.length; index += 1) {
    if (
      tokens[index].value !== "."
      || tokens[index + 1].kind !== "identifier"
      || tokens[index + 1].value !== "register_command"
      || tokens[index + 2].value !== "("
      || delimiterDepthAt(tokens, index) !== 0
      || !isProvenCommandTableReceiver(tokens, index, binding)
    ) continue;
    const close = matchingDelimiter(tokens, index + 2);
    const receiverStart = provenCommandTableReceiverStart(
      tokens,
      index,
      binding,
    );
    const statementStart =
      values(tokens.slice(0, receiverStart)).lastIndexOf(";") + 1;
    if (
      receiverStart !== statementStart
      || tokens[close + 1]?.value !== ";"
    ) continue;
    calls.push({
      index,
      method: tokens[index + 1].value,
      tokens: tokens.slice(index + 3, close),
    });
    index = close;
  }
  return calls;
}

function containsContiguousStringValues(tokens, expected) {
  for (let start = 0; start < tokens.length; start += 1) {
    if (
      tokens[start].kind !== "string"
      || tokens[start].value !== expected[0]
    ) continue;
    let cursor = start;
    let matches = true;
    for (const value of expected.slice(1)) {
      cursor += 1;
      if (tokens[cursor]?.value === ",") cursor += 1;
      if (
        tokens[cursor]?.kind !== "string"
        || tokens[cursor]?.value !== value
      ) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

function delimiterDepthAt(tokens, end) {
  const stack = [];
  for (let index = 0; index < end; index += 1) {
    if (["(", "[", "{"].includes(tokens[index].value)) {
      stack.push(tokens[index].value);
    } else if ([")", "]", "}"].includes(tokens[index].value)) {
      stack.pop();
    }
  }
  return stack.length;
}

function commandSpecBody(call, sourcePath) {
  const spec = call.tokens.findIndex((token) => token.value === "CommandSpec");
  assert.notEqual(spec, -1, `${sourcePath} registration must use CommandSpec`);
  const open = call.tokens.findIndex(
    (token, index) => index > spec && token.value === "{",
  );
  assert.notEqual(open, -1, `${sourcePath} CommandSpec must be a named-field literal`);
  const close = matchingDelimiter(call.tokens, open);
  return call.tokens.slice(open + 1, close);
}

function fieldValue(tokens, field, sourcePath) {
  const fieldIndex = tokens.findIndex(
    (token, index) =>
      token.value === field && tokens[index + 1]?.value === ":",
  );
  assert.notEqual(fieldIndex, -1, `${sourcePath} CommandSpec is missing ${field}`);
  const output = [];
  const delimiterStack = [];
  for (let index = fieldIndex + 2; index < tokens.length; index += 1) {
    const value = tokens[index].value;
    if (["(", "[", "{"].includes(value)) delimiterStack.push(value);
    if ([")", "]", "}"].includes(value)) delimiterStack.pop();
    if (value === "," && delimiterStack.length === 0) break;
    output.push(tokens[index]);
  }
  assert.ok(output.length > 0, `${sourcePath} CommandSpec.${field} must be explicit`);
  return output;
}

function structFieldType(tokens, field, sourcePath) {
  const fieldIndex = tokens.findIndex(
    (token, index) =>
      token.kind === "identifier"
      && token.value === field
      && tokens[index + 1]?.value === ":",
  );
  assert.notEqual(fieldIndex, -1, `${sourcePath} struct is missing ${field}`);
  const output = [];
  const delimiterStack = [];
  let genericDepth = 0;
  for (let index = fieldIndex + 2; index < tokens.length; index += 1) {
    const value = tokens[index].value;
    if (["(", "[", "{"].includes(value)) delimiterStack.push(value);
    if ([")", "]", "}"].includes(value)) delimiterStack.pop();
    if (value === "<") genericDepth += 1;
    if (value === ">" && genericDepth > 0) genericDepth -= 1;
    if (
      value === ","
      && delimiterStack.length === 0
      && genericDepth === 0
    ) break;
    output.push(tokens[index]);
  }
  assert.equal(
    genericDepth,
    0,
    `${sourcePath} struct field ${field} has unclosed generic arguments`,
  );
  assert.ok(
    output.length > 0,
    `${sourcePath} struct field ${field} must have an explicit type`,
  );
  return output;
}

function namedStructLiteralFieldValue(tokens, field, sourcePath) {
  const delimiterStack = [];
  for (let index = 0; index < tokens.length; index += 1) {
    const value = tokens[index].value;
    if (["(", "[", "{"].includes(value)) delimiterStack.push(value);
    if ([")", "]", "}"].includes(value)) delimiterStack.pop();
    if (
      delimiterStack.length !== 0
      || tokens[index].kind !== "identifier"
      || value !== field
    ) continue;
    if (tokens[index + 1]?.value === ":") {
      return fieldValue(tokens, field, sourcePath);
    }
    if (
      tokens[index + 1]?.value === ","
      || index === tokens.length - 1
    ) return [tokens[index]];
  }
  assert.fail(`${sourcePath} struct literal is missing ${field}`);
}

function literalStringArray(tokens, field, sourcePath) {
  const fieldTokens = fieldValue(tokens, field, sourcePath);
  const open = fieldTokens.findIndex((token) => token.value === "[");
  assert.notEqual(open, -1, `${sourcePath} CommandSpec.${field} must be a literal array`);
  const close = matchingDelimiter(fieldTokens, open);
  assert.equal(
    close,
    fieldTokens.length - 1,
    `${sourcePath} CommandSpec.${field} must contain only its literal array`,
  );
  const entries = fieldTokens.slice(open + 1, close);
  for (const token of entries) {
    assert.ok(
      token.kind === "string" || token.value === ",",
      `${sourcePath} CommandSpec.${field} must contain only string literals`,
    );
  }
  return entries.filter((token) => token.kind === "string").map((token) => token.value);
}

function requiredArgumentSchemas(tokens, sourcePath) {
  const fieldTokens = fieldValue(tokens, "required_positionals", sourcePath);
  const open = fieldTokens.findIndex((token) => token.value === "[");
  assert.notEqual(open, -1);
  const close = matchingDelimiter(fieldTokens, open);
  assert.equal(close, fieldTokens.length - 1);
  const entries = [];
  let start = open + 1;
  const stack = [];
  for (let index = open + 1; index <= close; index += 1) {
    const value = fieldTokens[index]?.value;
    if (["(", "[", "{"].includes(value)) stack.push(value);
    if ([")", "]", "}"].includes(value)) stack.pop();
    if ((value !== "," && index !== close) || stack.length > 0) continue;
    const entry = fieldTokens.slice(start, index);
    start = index + 1;
    if (entry.length === 0) continue;
    const open = entry.findIndex((token) => token.value === "{");
    assert.notEqual(
      open,
      -1,
      `${sourcePath} required arguments must use typed named-field schemas`,
    );
    const body = entry.slice(open + 1, matchingDelimiter(entry, open));
    const nameTokens = fieldValue(body, "name", sourcePath);
    assert.equal(
      nameTokens.length,
      1,
      `${sourcePath} required argument name must be one literal`,
    );
    assert.equal(nameTokens[0]?.kind, "string");
    const kind = fieldValue(body, "kind", sourcePath)
      .filter((token) => token.kind === "identifier")
      .at(-1)?.value;
    assert.ok(
      ["Json", "Text"].includes(kind),
      `${sourcePath} required argument kind must be Text or Json`,
    );
    entries.push({ name: nameTokens[0].value, kind });
  }
  return entries;
}

function optionSchemas(tokens, sourcePath, sharedOptionArrays) {
  let fieldTokens = fieldValue(tokens, "options", sourcePath);
  if (!fieldTokens.some((token) => token.value === "[")) {
    assert.equal(
      fieldTokens.length,
      1,
      `${sourcePath} CommandSpec.options must be an array or one audited shared constant`,
    );
    fieldTokens = sharedOptionArrays.get(fieldTokens[0]?.value);
    assert.ok(
      fieldTokens,
      `${sourcePath} CommandSpec.options references an unaudited shared constant`,
    );
  }
  const open = fieldTokens.findIndex((token) => token.value === "[");
  assert.notEqual(open, -1);
  const close = matchingDelimiter(fieldTokens, open);
  assert.equal(close, fieldTokens.length - 1);
  const schemas = [];
  for (let index = open + 1; index < close; index += 1) {
    if (fieldTokens[index].value !== "{") continue;
    const body = fieldTokens.slice(index + 1, matchingDelimiter(fieldTokens, index));
    const name = fieldValue(body, "name", sourcePath);
    assert.equal(name.length, 1);
    assert.equal(name[0]?.kind, "string");
    const enumField = (field) =>
      fieldValue(body, field, sourcePath)
        .filter((token) => token.kind === "identifier")
        .at(-1)?.value;
    const arity = enumField("arity");
    const valueKind = enumField("value_kind");
    assert.ok(["Boolean", "Value"].includes(arity));
    assert.ok(["Json", "Text"].includes(valueKind));
    const repeatable = values(fieldValue(body, "repeatable", sourcePath));
    const required = values(fieldValue(body, "required", sourcePath));
    assert.ok([["true"], ["false"]].some((value) =>
      value[0] === repeatable[0] && repeatable.length === 1));
    assert.ok([["true"], ["false"]].some((value) =>
      value[0] === required[0] && required.length === 1));
    schemas.push({
      name: name[0].value,
      arity,
      repeatable: repeatable[0] === "true",
      valueKind,
      required: required[0] === "true",
    });
    index = matchingDelimiter(fieldTokens, index);
  }
  return schemas;
}

function sharedOptionArray(tokens, name, sourcePath) {
  const declaration = sequenceIndex(tokens, ["const", name]);
  assert.notEqual(
    declaration,
    -1,
    `${sourcePath} must declare shared option array ${name}`,
  );
  const assignment = tokens.findIndex(
    (token, index) => index > declaration && token.value === "=",
  );
  assert.notEqual(assignment, -1, `${sourcePath} ${name} must have a value`);
  const open = tokens.findIndex(
    (token, index) => index > assignment && token.value === "[",
  );
  assert.notEqual(open, -1, `${sourcePath} ${name} must be an array`);
  const close = matchingDelimiter(tokens, open);
  return tokens.slice(open, close + 1);
}

function functionTokens(tokens, name, sourcePath) {
  const declaration = sequenceIndex(tokens, ["fn", name]);
  assert.notEqual(declaration, -1, `${sourcePath} must declare fn ${name}`);
  const open = tokens.findIndex(
    (token, index) => index > declaration && token.value === "{",
  );
  assert.notEqual(open, -1, `${sourcePath} fn ${name} has no body`);
  const close = matchingDelimiter(tokens, open);
  return {
    header: tokens.slice(declaration, open),
    body: tokens.slice(open + 1, close),
  };
}

function allFunctionRanges(tokens) {
  const ranges = [];
  for (let index = 0; index + 1 < tokens.length; index += 1) {
    if (tokens[index].value !== "fn" || tokens[index + 1].kind !== "identifier") continue;
    const open = tokens.findIndex(
      (token, candidate) => candidate > index + 1 && token.value === "{",
    );
    const semicolon = tokens.findIndex(
      (token, candidate) => candidate > index + 1 && token.value === ";",
    );
    if (open === -1 || (semicolon !== -1 && semicolon < open)) continue;
    const close = matchingDelimiter(tokens, open);
    ranges.push({
      name: tokens[index + 1].value,
      declaration: index,
      open,
      close,
      header: tokens.slice(index, open),
      body: tokens.slice(open + 1, close),
    });
  }
  return ranges;
}

function structTokens(tokens, name, sourcePath) {
  const declaration = sequenceIndex(tokens, ["struct", name]);
  assert.notEqual(declaration, -1, `${sourcePath} must declare struct ${name}`);
  const open = tokens.findIndex(
    (token, index) => index > declaration && token.value === "{",
  );
  assert.notEqual(open, -1, `${sourcePath} struct ${name} must use named fields`);
  return tokens.slice(open + 1, matchingDelimiter(tokens, open));
}

function implTokens(tokens, name, sourcePath) {
  const declaration = sequenceIndex(tokens, ["impl", name]);
  assert.notEqual(declaration, -1, `${sourcePath} must declare impl ${name}`);
  const open = tokens.findIndex(
    (token, index) => index > declaration && token.value === "{",
  );
  assert.notEqual(open, -1, `${sourcePath} impl ${name} must have a body`);
  return tokens.slice(open + 1, matchingDelimiter(tokens, open));
}

function traitImplBodiesForType(tokens, typeName) {
  const bodies = [];
  for (let index = 0; index < tokens.length; index += 1) {
    if (tokens[index].value !== "impl") continue;
    const open = tokens.findIndex(
      (token, candidate) => candidate > index && token.value === "{",
    );
    if (open === -1) continue;
    const header = tokens.slice(index + 1, open);
    const forIndex = header.findIndex((token) => token.value === "for");
    if (forIndex === -1) continue;
    const whereIndex = header.findIndex(
      (token, candidate) =>
        candidate > forIndex && token.value === "where",
    );
    const target = header.slice(
      forIndex + 1,
      whereIndex === -1 ? header.length : whereIndex,
    );
    if (!isExactLocalType(target, typeName)) continue;
    const close = matchingDelimiter(tokens, open);
    bodies.push(tokens.slice(open + 1, close));
    index = close;
  }
  return bodies;
}

function inherentImplBodiesForType(tokens, typeName) {
  const bodies = [];
  for (let index = 0; index < tokens.length; index += 1) {
    if (tokens[index].value !== "impl") continue;
    const open = tokens.findIndex(
      (token, candidate) => candidate > index && token.value === "{",
    );
    if (open === -1) continue;
    const header = tokens.slice(index + 1, open);
    const whereIndex = header.findIndex((token) => token.value === "where");
    const target = stripLeadingImplGenerics(header.slice(
      0,
      whereIndex === -1 ? header.length : whereIndex,
    ));
    if (
      header.some((token) => token.value === "for")
      || !isExactLocalType(target, typeName)
    ) continue;
    const close = matchingDelimiter(tokens, open);
    bodies.push(tokens.slice(open + 1, close));
    index = close;
  }
  return bodies;
}

function namedStructFields(tokens) {
  const fields = [];
  const stack = [];
  for (let index = 0; index + 1 < tokens.length; index += 1) {
    const value = tokens[index].value;
    if (["(", "[", "{"].includes(value)) stack.push(value);
    if ([")", "]", "}"].includes(value)) stack.pop();
    if (
      stack.length === 0
      && tokens[index].kind === "identifier"
      && tokens[index + 1].value === ":"
    ) fields.push(tokens[index].value);
  }
  return fields;
}

function concreteHandler(spec, sourcePath) {
  const handler = fieldValue(spec, "handler", sourcePath).filter(
    (token) =>
      token.kind === "identifier" && token.value.startsWith("handle_"),
  );
  assert.equal(
    handler.length,
    1,
    `${sourcePath} CommandSpec.handler must name exactly one concrete handler`,
  );
  return handler[0].value;
}

test("recognized CommandSpec literals use typed admitted handler accessors", async () => {
  const sources = await commandSources();
  const routes = new Set();
  const registrations = [];
  assert.ok(retiredPublicCompatibilityResidues.length > 0);
  assert.equal(
    retiredPublicCompatibilityRoutes.size,
    retiredPublicCompatibilityResidues.length,
  );
  for (const retiredModule of retiredPublicCompatibilityModules) {
    assert.equal(
      sources.has(retiredModule),
      false,
      `${retiredModule} must be removed because it owns no public-help route`,
    );
  }
  const rootTokens = productionTokens(sources.get(commandFacade));
  const sharedOptionArrays = new Map([
    [
      "UPDATE_ROUTE_OPTIONS",
      sharedOptionArray(rootTokens, "UPDATE_ROUTE_OPTIONS", commandFacade),
    ],
  ]);
  const builder = functionTokens(rootTokens, "build_command_table", commandFacade);
  assert.notEqual(
    sequenceIndex(rootTokens, ["fn", "build_command_table", "(", ")", "-", ">", "CommandTable"]),
    -1,
    "command root must own build_command_table() -> CommandTable",
  );
  for (const forbiddenBranch of [
    "break",
    "cfg",
    "cfg_attr",
    "continue",
    "for",
    "if",
    "loop",
    "match",
    "return",
    "while",
  ]) {
    assert.equal(
      builder.body.some((token) => token.value === forbiddenBranch),
      false,
      `build_command_table must unconditionally execute all registrations; found ${forbiddenBranch}`,
    );
  }
  assert.equal(
    sequenceIndex(builder.body, ["cfg", "!"]),
    -1,
    "build_command_table must not branch through cfg!",
  );
  for (const hiddenRegistrationToken of ["async", "move", "|", "!"]) {
    assert.equal(
      builder.body.some((token) => token.value === hiddenRegistrationToken),
      false,
      `build_command_table must not hide registrations behind ${hiddenRegistrationToken}`,
    );
  }
  const builderBindings = [];
  for (let index = 0; index < builder.body.length; index += 1) {
    if (builder.body[index].value !== "let") continue;
    const bindingIndex =
      builder.body[index + 1]?.value === "mut" ? index + 2 : index + 1;
    if (
      builder.body[bindingIndex]?.kind !== "identifier"
      || sequenceIndex(builder.body, [
        "=", "CommandTable", ":", ":", "new", "(", ")", ";",
      ], bindingIndex + 1) !== bindingIndex + 1
    ) continue;
    assert.equal(
      delimiterDepthAt(builder.body, index),
      0,
      "CommandTable construction must be a top-level builder statement",
    );
    builderBindings.push(builder.body[bindingIndex].value);
  }
  assert.equal(
    builderBindings.length,
    1,
    "build_command_table must own exactly one direct CommandTable::new binding",
  );
  const [builderBinding] = builderBindings;
  for (let index = 0; index + 1 < builder.body.length; index += 1) {
    if (builder.body[index].value !== ".") continue;
    for (const retired of retiredRegistrationApis) {
      assert.equal(
        builder.body[index + 1]?.kind === "identifier"
          && builder.body[index + 1].value === retired
          && callOpenAfterIdentifier(builder.body, index + 1) !== -1
          && isProvenCommandTableReceiver(
            builder.body,
            index,
            builderBinding,
          ),
        false,
        `build_command_table calls retired ${builderBinding}.${retired}`,
      );
    }
  }
  const builderCalls = builderRegistrationCalls(
    builder.body,
    builderBinding,
  );
  assert.ok(builderCalls.length > 0, "command registry must not be empty");
  const provenBindingRegistrationCalls = builder.body.filter(
    (token, index) =>
      token.value === "."
      && builder.body[index + 1]?.kind === "identifier"
      && builder.body[index + 1].value === "register_command"
      && callOpenAfterIdentifier(builder.body, index + 1) !== -1
      && isProvenCommandTableReceiver(
        builder.body,
        index,
        builderBinding,
      ),
  ).length;
  assert.equal(
    provenBindingRegistrationCalls,
    builderCalls.length,
    "every proven CommandTable registration must be a top-level direct builder statement",
  );
  for (const call of builderCalls) {
    assert.ok(
      isProvenCommandTableReceiver(
        builder.body,
        call.index,
        builderBinding,
      ),
      "every registration must use the proven CommandTable binding",
    );
  }
  const lastRegistration = builderCalls.at(-1);
  const lastRegistrationClose = matchingDelimiter(
    builder.body,
    lastRegistration.index + 2,
  );
  assert.deepEqual(
    values(builder.body.slice(lastRegistrationClose + 1)),
    [";", builderBinding],
    "build_command_table must return the fully registered table directly",
  );

  const productionBySource = new Map(
    [...sources].map(([sourcePath, source]) => [
      sourcePath,
      productionTokens(source),
    ]),
  );
  for (const residue of retiredPublicCompatibilityResidues) {
    for (const [sourcePath, sourceTokens] of productionBySource) {
      for (const symbol of residue.symbols) {
        assert.equal(
          sourceTokens.some(
            (token) => token.kind === "identifier" && token.value === symbol,
          ),
          false,
          `${sourcePath} retains globally retired symbol ${symbol}`,
        );
      }
      assert.equal(
        sourceTokens.some(
          (token) =>
            token.kind === "string" && token.value.includes(residue.strings[0]),
        ),
        false,
        `${sourcePath} retains full retired route string '${residue.strings[0]}'`,
      );
      if (!ownerScopedRetiredActionPaths.has(residue.path)) {
        assert.equal(
          containsContiguousStringValues(sourceTokens, residue.action),
          false,
          `${sourcePath} retains globally unique retired action '${residue.action.join(" ")}'`,
        );
      }
    }
    if (ownerScopedRetiredActionPaths.has(residue.path)) {
      assert.ok(
        sources.has(residue.owner),
        `ambiguous retired action owner ${residue.owner} must remain auditable`,
      );
      const ownerTokens = productionBySource.get(residue.owner);
      assert.equal(
        containsContiguousStringValues(ownerTokens, residue.action),
        false,
        `${residue.owner} retains scoped retired action '${residue.action.join(" ")}'`,
      );
    }
  }

  const commandTableImplementation = implTokens(
    rootTokens,
    "CommandTable",
    commandFacade,
  );
  for (const retired of retiredRegistrationApis) {
    assert.equal(
      sequenceIndex(commandTableImplementation, ["fn", retired]),
      -1,
      `impl CommandTable retains retired ${retired} declaration`,
    );
  }

  for (const [sourcePath, source] of sources) {
    const allTokens = productionTokens(source);
    for (let index = 0; index < allTokens.length; index += 1) {
      if (
        allTokens[index].value === "include"
        && allTokens[index + 1]?.value === "!"
      ) {
        assert.fail(
          `${sourcePath} must not inject command-bundle source through ${allTokens[index].value}!`,
        );
      }
      if (
        allTokens[index].value === "#"
        && allTokens[index + 1]?.value === "["
      ) {
        const attributeClose = matchingDelimiter(allTokens, index + 1);
        const attribute = allTokens.slice(index + 2, attributeClose);
        const directPathRedirect = attribute[0]?.value === "path";
        const conditionalPathRedirect =
          attribute[0]?.value === "cfg_attr"
          && attribute.some(
            (token, attributeIndex) =>
              token.value === "path"
              && ["=", "("].includes(attribute[attributeIndex + 1]?.value),
          );
        assert.equal(
          directPathRedirect || conditionalPathRedirect,
          false,
          `${sourcePath} must use discoverable same-directory mod declarations, not #[path] redirection`,
        );
      }
    }
    const ownedCommandTableImplementations = [
      ...inherentImplBodiesForType(allTokens, "CommandTable"),
      ...traitImplBodiesForType(allTokens, "CommandTable"),
    ];
    for (const ownedImplementation of ownedCommandTableImplementations) {
      for (const retired of commandTableRetiredRegistrationApis) {
        assert.equal(
          sequenceIndex(ownedImplementation, ["fn", retired]),
          -1,
          `${sourcePath} CommandTable impl retains retired ${retired}`,
        );
      }
    }
    assert.equal(
      sequenceIndex(allTokens, ["fn", "register_commands"]),
      -1,
      `${sourcePath} must not retain a secondary registration function`,
    );
    for (let index = 0; index < allTokens.length; index += 1) {
      for (const retired of retiredRegistrationApis) {
        const retiredNameIndex =
          allTokens[index].kind === "identifier"
          && allTokens[index].value === retired
            ? index
            : -1;
        const retiredCall =
          retiredNameIndex !== -1
          && callOpenAfterIdentifier(allTokens, retiredNameIndex) !== -1;
        const directCommandTableUfcs =
          retiredCall
          && isLocalTypeDirectUfcs(
            allTokens,
            index,
            "CommandTable",
          );
        const qualifiedCommandTableUfcs =
          retiredCall
          && isCommandTableQualifiedUfcs(allTokens, index);
        assert.equal(
          directCommandTableUfcs || qualifiedCommandTableUfcs,
          false,
          `${sourcePath} calls retired CommandTable API ${retired}`,
        );
      }
      if (
        allTokens[index].kind === "identifier"
        && allTokens[index].value === "register_command"
        && callOpenAfterIdentifier(allTokens, index) !== -1
        && (
          isLocalTypeDirectUfcs(allTokens, index, "CommandTable")
          || isCommandTableQualifiedUfcs(allTokens, index)
        )
      ) {
        assert.fail(`${sourcePath} must not register through CommandTable UFCS`);
      }
    }
    const calls = sourcePath === commandFacade ? builderCalls : [];
    for (const call of calls) {
      assert.equal(
        retiredRegistrationApis.has(call.method),
        false,
        `${sourcePath} still uses retired ${call.method}`,
      );
      assert.equal(
        call.method,
        "register_command",
        `${sourcePath} must use the final register_command API`,
      );
      const spec = commandSpecBody(call, sourcePath);
      const route = literalStringArray(spec, "path", sourcePath);
      const required = requiredArgumentSchemas(spec, sourcePath);
      const options = optionSchemas(spec, sourcePath, sharedOptionArrays);
      const constraintCount = fieldValue(spec, "constraints", sourcePath)
        .filter((token) => token.value === "OptionConstraintSpec").length;
      assert.ok(route.length > 0, `${sourcePath} cannot register an empty route`);
      for (const positional of required) {
        assert.match(
          positional.name,
          /^[a-z][a-z0-9-]*$/u,
          `${sourcePath} required positional names must be stable public labels`,
        );
      }
      const cardinality = fieldValue(spec, "cardinality", sourcePath);
      const cardinalityValues = values(cardinality);
      const cardinalityMode = cardinality
        .filter((token) => token.kind === "identifier")
        .at(-1)?.value;
      assert.ok(
        ["Exact", "Options"].includes(cardinalityMode),
        `${sourcePath} cardinality must be typed Exact or Options`,
      );
      assert.equal(
        cardinalityValues.at(-2),
        ":",
        `${sourcePath} cardinality must use an enum variant`,
      );
      assert.equal(
        cardinalityValues.at(-3),
        ":",
        `${sourcePath} cardinality must use an enum variant`,
      );
      assert.equal(
        cardinalityMode,
        options.length === 0 ? "Exact" : "Options",
        `${sourcePath} cardinality must be derived from its explicit OptionSpec schema`,
      );
      assert.equal(
        new Set(options.map(({ name }) => name)).size,
        options.length,
        `${sourcePath} option names must be unique within a route`,
      );
      for (const option of options) {
        assert.match(option.name, /^[a-z][a-z0-9-]*$/u);
        if (option.arity === "Boolean") {
          assert.equal(
            option.valueKind,
            "Text",
            `${sourcePath} boolean option ${option.name} cannot carry a typed value`,
          );
        }
      }
      const handler = concreteHandler(spec, sourcePath);
      fieldValue(spec, "help", sourcePath);
      const sourceModule = fieldValue(spec, "source_module", sourcePath)
        .filter((token) => token.kind === "string");
      assert.equal(sourceModule.length, 1);
      const handlerSourcePath = `${commandRoot}/${sourceModule[0].value}`;
      assert.ok(sources.has(handlerSourcePath));

      const routeKey = route.join(" ");
      assert.equal(
        retiredFamilyRoutes.has(routeKey),
        false,
        `${sourcePath} must expand retired family route '${routeKey}' into exact actions`,
      );
      assert.equal(routes.has(routeKey), false, `duplicate CLI route '${routeKey}'`);
      routes.add(routeKey);
      registrations.push({
        sourcePath: handlerSourcePath,
        tokens: productionTokens(sources.get(handlerSourcePath)),
        route,
        required,
        cardinality: cardinalityMode,
        options,
        constraintCount,
        handler,
      });
    }
  }
  assert.equal(registrations.length, builderCalls.length);
  for (const registration of registrations) {
    assert.equal(
      retiredPublicCompatibilityRoutes.has(registration.route.join(" ")),
      false,
      `builder retains retired public compatibility route '${registration.route.join(" ")}'`,
    );
  }
  let tableConstructorCalls = 0;
  for (const [sourcePath, source] of sources) {
    const tokens = productionTokens(source);
    const functions = allFunctionRanges(tokens);
    let cursor = 0;
    while (
      (cursor = sequenceIndex(
        tokens,
        ["CommandTable", ":", ":", "new", "(", ")"],
        cursor,
      )) !== -1
    ) {
      tableConstructorCalls += 1;
      const owner = functions
        .filter((range) => range.open < cursor && cursor < range.close)
        .sort((left, right) =>
          left.close - left.open - (right.close - right.open))[0];
      assert.equal(sourcePath, commandFacade);
      assert.equal(owner?.name, "build_command_table");
      cursor += 6;
    }
  }
  assert.equal(
    tableConstructorCalls,
    1,
    "CommandTable::new may only be called by build_command_table",
  );
  assert.ok(registrations.length > 0, "command registry must not be empty");
  for (const [method, terminal] of [
    ["schemas", ["map", "(", "CommandDef", ":", ":", "schema", ")", ".", "collect"]],
    ["help_text", ["map", "(", "|", "definition", "|"]],
  ]) {
    const projection = functionTokens(rootTokens, method, commandFacade);
    assert.notEqual(
      sequenceIndex(projection.body, ["self", ".", "defs", ".", "iter", "(", ")"]),
      -1,
      `${method} must project every registered command from CommandTable.defs`,
    );
    assert.notEqual(
      sequenceIndex(projection.body, terminal),
      -1,
      `${method} must structurally map the registered command authority`,
    );
    for (const narrowing of ["filter", "take", "skip"]) {
      assert.equal(
        projection.body.some((token) => token.value === narrowing),
        false,
        `${method} must not narrow the registered command authority`,
      );
    }
  }
  assert.ok(
    registrations.every((registration) =>
      registration.options.length >= 0 && registration.constraintCount >= 0),
    "registered option schemas and constraints must remain structurally typed",
  );

  const analyzedHandlers = new Map();
  for (const registration of registrations) {
    const handlerKey = `${registration.sourcePath}|${registration.handler}`;
    if (analyzedHandlers.has(handlerKey)) continue;
    const handlerFunction = functionTokens(
      registration.tokens,
      registration.handler,
      registration.sourcePath,
    );
    assert.notEqual(
      sequenceIndex(handlerFunction.header, ["Result", "<", "CliExecution", ">"]),
      -1,
      `${registration.sourcePath} ${registration.handler} must return Result<CliExecution>`,
    );
    assert.equal(
      sequenceIndex(handlerFunction.header, ["&", "[", "String", "]"]),
      -1,
      `${registration.sourcePath} ${registration.handler} must not accept raw string slices`,
    );
    assert.equal(
      sequenceIndex(handlerFunction.header, ["Vec", "<", "String", ">"]),
      -1,
      `${registration.sourcePath} ${registration.handler} must not accept raw string vectors`,
    );
    const carriers = handlerFunction.header
      .map((token, index) => ({ token, index }))
      .filter(({ token }) =>
        ["AdmittedCommand", "ValidatedCommandArguments"].includes(token.value));
    assert.equal(
      carriers.length,
      1,
      `${registration.sourcePath} ${registration.handler} must accept one admitted argument carrier`,
    );
    const carrierIndex = carriers[0].index;
    assert.equal(
      handlerFunction.header[carrierIndex - 1]?.value,
      ":",
      `${registration.sourcePath} ${registration.handler} carrier must be a direct value parameter`,
    );
    const carrierName = handlerFunction.header[carrierIndex - 2]?.value;
    assert.match(carrierName, /^[A-Za-z_][A-Za-z0-9_]*$/u);
    const handlerTokens = [...handlerFunction.header, ...handlerFunction.body];
    assert.equal(
      handlerTokens.some(
        (token) => token.kind === "identifier" && token.value === "args",
      ),
      false,
      `${registration.sourcePath} ${registration.handler} must not retain a raw args alias`,
    );
    for (let index = 0; index < handlerFunction.body.length; index += 1) {
      if (handlerFunction.body[index].value !== carrierName) continue;
      assert.notEqual(
        handlerFunction.body[index + 1]?.value,
        "[",
        `${registration.sourcePath} ${registration.handler} must not index admitted arguments`,
      );
      assert.equal(
        handlerFunction.body[index + 1]?.value,
        ".",
        `${registration.sourcePath} ${registration.handler} must not alias or forward its admitted carrier`,
      );
      const method = handlerFunction.body[index + 2]?.value;
      assert.ok(
        [
          "option_flag",
          "option_json",
          "option_text",
          "path",
          "required_json",
          "required_text",
          "take_option_json",
        ].includes(method),
        `${registration.sourcePath} ${registration.handler} uses unsafe carrier method ${method}`,
      );
      assert.equal(
        handlerFunction.body[index + 3]?.value,
        "(",
        `${registration.sourcePath} ${registration.handler} carrier access must be a direct call`,
      );
      const close = matchingDelimiter(handlerFunction.body, index + 3);
      assert.equal(
        handlerFunction.body[close + 1]?.value === "["
          || (
            handlerFunction.body[close + 1]?.value === "."
            && ["expect", "get", "unwrap"].includes(
              handlerFunction.body[close + 2]?.value,
            )
          ),
        false,
        `${registration.sourcePath} ${registration.handler} must not index or unwrap carrier output`,
      );
    }
    analyzedHandlers.set(handlerKey, {
      ...handlerFunction,
      carrierName,
      sourcePath: registration.sourcePath,
      handler: registration.handler,
    });
  }
  for (const registration of registrations) {
    const handler = analyzedHandlers.get(
      `${registration.sourcePath}|${registration.handler}`,
    );
    assert.ok(handler, `registered handler ${registration.handler} was not analyzed`);
    for (const required of registration.required) {
      const directRequired = sequenceIndex(
        handler.body,
        [handler.carrierName, ".", "required_text", "(", required.name, ")"],
      );
      const jsonRequired = sequenceIndex(
        handler.body,
        [handler.carrierName, ".", "required_json", "(", required.name, ")"],
      );
      if (required.kind === "Json") {
        assert.notEqual(
          jsonRequired,
          -1,
          `${registration.sourcePath} ${registration.handler} must retrieve '${required.name}' as admitted JSON`,
        );
        continue;
      }
      assert.notEqual(
        directRequired,
        -1,
        `${registration.sourcePath} ${registration.handler} must retrieve '${required.name}' as admitted text`,
      );
    }
    for (const option of registration.options) {
      const accessors = option.arity === "Boolean"
        ? ["option_flag"]
        : option.valueKind === "Json"
          ? ["option_json", "take_option_json"]
          : ["option_text"];
      assert.ok(
        accessors.some((accessor) => sequenceIndex(
          handler.body,
          [handler.carrierName, ".", accessor, "(", option.name, ")"],
        ) !== -1),
        `${registration.sourcePath} ${registration.handler} must retrieve --${option.name} through ${accessors.join(" or ")}`,
      );
    }
  }
  for (const [handlerKey, handler] of analyzedHandlers) {
    const schemas = registrations
      .filter((registration) =>
        `${registration.sourcePath}|${registration.handler}` === handlerKey)
      .flatMap((registration) => registration.required);
    const allowed = {
      required_json: new Set(
        schemas.filter(({ kind }) => kind === "Json").map(({ name }) => name),
      ),
      required_text: new Set(
        schemas.filter(({ kind }) => kind === "Text").map(({ name }) => name),
      ),
      option_flag: new Set(
        registrations
          .filter((registration) =>
            `${registration.sourcePath}|${registration.handler}` === handlerKey)
          .flatMap((registration) => registration.options)
          .filter(({ arity }) => arity === "Boolean")
          .map(({ name }) => name),
      ),
      option_json: new Set(
        registrations
          .filter((registration) =>
            `${registration.sourcePath}|${registration.handler}` === handlerKey)
          .flatMap((registration) => registration.options)
          .filter(({ arity, valueKind }) =>
            arity === "Value" && valueKind === "Json")
          .map(({ name }) => name),
      ),
      take_option_json: new Set(
        registrations
          .filter((registration) =>
            `${registration.sourcePath}|${registration.handler}` === handlerKey)
          .flatMap((registration) => registration.options)
          .filter(({ arity, valueKind }) =>
            arity === "Value" && valueKind === "Json")
          .map(({ name }) => name),
      ),
      option_text: new Set(
        registrations
          .filter((registration) =>
            `${registration.sourcePath}|${registration.handler}` === handlerKey)
          .flatMap((registration) => registration.options)
          .filter(({ arity, valueKind }) =>
            arity === "Value" && valueKind === "Text")
          .map(({ name }) => name),
      ),
    };
    for (let index = 0; index < handler.body.length; index += 1) {
      if (
        handler.body[index].value !== handler.carrierName
        || handler.body[index + 1]?.value !== "."
        || ![
          "option_flag",
          "option_json",
          "option_text",
          "required_json",
          "required_text",
          "take_option_json",
        ].includes(
          handler.body[index + 2]?.value,
        )
      ) continue;
      const accessor = handler.body[index + 2].value;
      const open = index + 3;
      const close = matchingDelimiter(handler.body, open);
      const argument = handler.body.slice(open + 1, close);
      assert.equal(
        argument.length,
        1,
        `${handler.sourcePath} ${handler.handler} required access must use one literal authority name`,
      );
      assert.equal(argument[0]?.kind, "string");
      assert.ok(
        allowed[accessor].has(argument[0].value),
        `${handler.sourcePath} ${handler.handler} cannot retrieve '${argument[0].value}' through ${accessor}`,
      );
    }
  }
  const jsonRequiredSources = new Set(
    registrations
      .filter((registration) =>
        registration.required.some(({ kind }) => kind === "Json"))
      .map(({ sourcePath }) => sourcePath),
  );
  for (const sourcePath of jsonRequiredSources) {
    const tokens = productionTokens(sources.get(sourcePath));
    for (let index = 0; index < tokens.length; index += 1) {
      if (
        tokens[index].value === "fn"
        && /^(decode|parse)/u.test(tokens[index + 1]?.value ?? "")
      ) {
        assert.fail(
          `${sourcePath} must not define a JSON decode/parse helper for admitted required fields`,
        );
      }
      if (tokens[index].value !== "use") continue;
      const end = tokens.findIndex(
        (token, candidate) => candidate > index && token.value === ";",
      );
      assert.notEqual(end, -1);
      assert.equal(
        tokens
          .slice(index + 1, end)
          .some((token) =>
            token.kind === "identifier"
            && /^(decode|parse)/u.test(token.value)),
        false,
        `${sourcePath} must not import a JSON decode/parse helper for admitted required fields`,
      );
      index = end;
    }
  }
});

test("Usage is confined to exact command-root help", async () => {
  const sources = await commandSources();
  const usageSequence = ["CliExecution", ":", ":", "Usage"];
  const references = [];
  for (const [sourcePath, source] of sources) {
    const tokens = productionTokens(source);
    let cursor = 0;
    while ((cursor = sequenceIndex(tokens, usageSequence, cursor)) !== -1) {
      references.push({ sourcePath, tokenIndex: cursor });
      cursor += usageSequence.length;
    }
  }
  assert.equal(
    references.length,
    1,
    "production commands must contain exactly one CliExecution::Usage reference",
  );
  assert.equal(
    references[0].sourcePath,
    commandFacade,
    "CliExecution::Usage is reserved for command-root exact help",
  );

  const root = productionTokens(sources.get(commandFacade));
  const execution = functionTokens(root, "execute_cli", commandFacade).body;
  assert.notEqual(
    sequenceIndex(execution, usageSequence),
    -1,
    "the sole Usage reference must be inside execute_cli exact help",
  );
  for (const helpToken of ["help", "--help", "-h"]) {
    assert.ok(
      execution.some((token) => token.kind === "string" && token.value === helpToken),
      `execute_cli exact help branch is missing ${helpToken}`,
    );
  }
});

test("production command authority has no conditional compilation split", async () => {
  const sources = await commandSources();
  const approved = [
    "#", "[", "cfg", "(", "test", ")", "]", "mod", "tests", "{",
  ];
  for (const [sourcePath, source] of sources) {
    const tokens = lexRust(source);
    const functions = allFunctionRanges(tokens);
    let braceDepth = 0;
    for (let index = 0; index < tokens.length; index += 1) {
      if (
        tokens[index].value === "#"
        && tokens[index + 1]?.value === "["
        && ["cfg", "cfg_attr"].includes(tokens[index + 2]?.value)
      ) {
        if (braceDepth === 0) {
          assert.deepEqual(
            values(tokens.slice(index, index + approved.length)),
            approved,
            `${sourcePath} may only conditionally compile a top-level tests module`,
          );
        } else {
          const owner = functions
            .filter((range) => range.open < index && index < range.close)
            .sort((left, right) =>
              left.close - left.open - (right.close - right.open))[0];
          assert.ok(
            owner?.name.startsWith("handle_"),
            `${sourcePath} conditionals may only occur inside a handler implementation`,
          );
        }
      }
      if (tokens[index].value === "{") braceDepth += 1;
      if (tokens[index].value === "}") braceDepth -= 1;
    }
    assert.equal(braceDepth, 0);
  }
});

test("admission and its failure chain have no output side channel", async () => {
  const sources = await commandSources();
  const externalSinkMacros = new Set([
    "dbg",
    "debug",
    "eprint",
    "eprintln",
    "error",
    "info",
    "log_enabled",
    "print",
    "println",
    "trace",
    "warn",
  ]);
  const loggingCalls = new Set(["debug", "error", "info", "trace", "warn"]);
  function assertNoOutput(tokens, label) {
    for (let index = 0; index < tokens.length; index += 1) {
      const token = tokens[index];
      if (token.kind !== "identifier") continue;
      assert.equal(
        token.value.includes("stdout") || token.value.includes("stderr"),
        false,
        `${label} must not access stdout/stderr`,
      );
      assert.equal(
        token.value === "log" || token.value === "tracing",
        false,
        `${label} must not call a logging/tracing backend`,
      );
      if (tokens[index + 1]?.value === "!") {
        assert.equal(
          externalSinkMacros.has(token.value),
          false,
          `${label} must not invoke external sink macro ${token.value}!`,
        );
      }
      if (tokens[index + 1]?.value === "(") {
        assert.equal(
          loggingCalls.has(token.value),
          false,
          `${label} must not invoke logging call ${token.value}`,
        );
      }
    }
  }

  for (const [sourcePath, source] of sources) {
    const tokens = productionTokens(source);
    for (let index = 0; index < tokens.length; index += 1) {
      const token = tokens[index];
      if (token.kind !== "identifier") continue;
      if (tokens[index + 1]?.value === "!") {
        assert.equal(
          externalSinkMacros.has(token.value),
          false,
          `${sourcePath} must not invoke direct external sink macro ${token.value}!`,
        );
      }
    }
  }

  const root = productionTokens(sources.get(commandFacade));
  const rootFunctions = allFunctionRanges(root);
  for (const range of rootFunctions) {
    assert.equal(
      /^(emit|log|print)(_|$)/u.test(range.name),
      false,
      `command admission root must not define custom output wrapper ${range.name}`,
    );
  }
  const protectedNames = new Set([
    "admit",
    "admit_cli_command",
    "dispatch",
    "execute_cli",
    "parse_json_arg",
    "required_json",
    "validate_cli_admission",
    "validate_command_arguments",
  ]);
  const protectedRanges = rootFunctions.filter((range) =>
    protectedNames.has(range.name)
    || range.body.some((token) => token.value === "CliCommandError"));
  for (const range of protectedRanges) {
    assertNoOutput(range.body, `${commandFacade} ${range.name}`);
  }
  assert.ok(
    protectedRanges.some((range) => range.name === "admit_cli_command"),
    "the public admission seam must be covered by the no-output oracle",
  );
  assert.ok(
    protectedRanges.some((range) => range.name === "admit"),
    "CommandTable::admit must be covered by the no-output oracle",
  );
  assert.ok(
    protectedRanges.some((range) => range.name === "parse_json_arg"),
    "the JSON admission helper must be covered by the no-output oracle",
  );
});

test("JSON admission is fallible and has no malformed-to-value compatibility path", async () => {
  const sources = await commandSources();
  const tokenEntries = [...sources].map(([sourcePath, source]) => [
    sourcePath,
    productionTokens(source),
  ]);
  const definitions = tokenEntries.filter(([, tokens]) =>
    sequenceIndex(tokens, ["fn", "parse_json_arg"]) !== -1);
  assert.equal(definitions.length, 1, "parse_json_arg must have one authoritative owner");
  const [definitionPath, definitionTokens] = definitions[0];
  const parser = functionTokens(definitionTokens, "parse_json_arg", definitionPath);
  assert.notEqual(
    sequenceIndex(parser.header, ["-", ">", "Result"]),
    -1,
    "parse_json_arg must expose a fallible Result contract",
  );
  const parseCallIndex = sequenceIndex(
    parser.body,
    ["serde_json", ":", ":", "from_str", "("],
  );
  assert.ok(
    parseCallIndex >= 0,
    "parse_json_arg must directly call serde_json::from_str(raw)",
  );
  const parseCallOpen = parseCallIndex + 4;
  const parseCallClose = matchingDelimiter(parser.body, parseCallOpen);
  const parsePrefix = values(parser.body.slice(0, parseCallIndex));
  assert.ok(
    [
      [],
      ["return"],
    ].some((approved) =>
      approved.length === parsePrefix.length
      && approved.every((value, index) => parsePrefix[index] === value)),
    "serde_json::from_str must be the direct parse_json_arg return expression",
  );
  const parsePostfix = parser.body.slice(parseCallClose + 1);
  const hasMapErr =
    parsePostfix[0]?.value === "."
    && parsePostfix[1]?.value === "map_err"
    && parsePostfix[2]?.value === "(";
  if (hasMapErr) {
    const mapErrClose = matchingDelimiter(parsePostfix, 2);
    const terminal = values(parsePostfix.slice(mapErrClose + 1));
    const approvedTerminals = parsePrefix[0] === "return"
      ? [[";"], ["?", ";"]]
      : [[], ["?"]];
    assert.ok(
      approvedTerminals.some((approved) =>
        approved.length === terminal.length
        && approved.every((value, index) => terminal[index] === value)),
      "map_err must immediately terminate parse_json_arg or propagate with ?",
    );
    assert.equal(
      parser.body.filter((token) => token.value === "map_err").length,
      1,
      "parse_json_arg may contain only the from_str error-mapping postfix",
    );
    assert.equal(
      parser.body.filter((token) => token.value === "?").length,
      terminal.includes("?") ? 1 : 0,
      "parse_json_arg may use ? only as the terminal map_err postfix",
    );
    assert.ok(
      parser.body.some((token) => token.value === "CliCommandError"),
      "parse_json_arg map_err must construct the typed CLI error",
    );
  } else {
    const terminal = values(parsePostfix);
    const approvedTerminal = parsePrefix[0] === "return" ? [";"] : [];
    assert.ok(
      approvedTerminal.length === terminal.length
        && approvedTerminal.every(
          (value, index) => terminal[index] === value,
        ),
      "serde_json::from_str may only be returned directly",
    );
    assert.equal(
      parser.body.some(
        (token) => token.value === "map_err" || token.value === "?",
      ),
      false,
      "direct parse_json_arg return must not contain unrelated map_err or ?",
    );
  }
  for (let index = 0; index < parser.body.length; index += 1) {
    const token = parser.body[index];
    assert.equal(
      token.kind === "identifier"
        && parser.body[index - 1]?.value === "."
        && (
          token.value.startsWith("unwrap")
          || token.value === "ok"
          || token.value === "or_else"
          || token.value === "map_or"
          || token.value === "map_or_else"
          || token.value === "default"
        ),
      false,
      `parse_json_arg contains forbidden fallback ${token.value}`,
    );
  }

  let serdeParserCalls = 0;
  const serdeCalls = [];
  const parserHelpers = [];
  for (const [sourcePath, tokens] of tokenEntries) {
    assert.equal(
      tokens.some((token) => token.value === "handle_unsupported_adapter_action"),
      false,
      `${sourcePath} retains the unsupported-adapter compatibility handler`,
    );
    for (const forbiddenDeserializer of [
      "Deserialize",
      "Deserializer",
      "FromStr",
      "deserialize",
    ]) {
      assert.equal(
        tokens.some(
          (token) =>
            token.kind === "identifier"
            && token.value === forbiddenDeserializer,
        ),
        false,
        `${sourcePath} contains alternate JSON deserializer ${forbiddenDeserializer}`,
      );
    }
    for (let index = 0; index < tokens.length; index += 1) {
      if (
        tokens[index].kind === "identifier"
        && tokens[index].value === "parse"
        && tokens[index - 1]?.value === "."
      ) {
        const scalarType = values(tokens.slice(index + 1, index + 6));
        assert.deepEqual(scalarType.slice(0, 3), [":", ":", "<"]);
        assert.ok(
          ["i64", "u16"].includes(scalarType[3]) && scalarType[4] === ">",
          `${sourcePath} raw.parse is permitted only for an admitted numeric scalar`,
        );
      }
      if (
        tokens[index].kind === "identifier"
        && tokens[index].value === "from_str"
      ) {
        assert.deepEqual(
          values(tokens.slice(index - 3, index)),
          ["serde_json", ":", ":"],
          `${sourcePath} from_str must use the sole serde_json::from_str entry`,
        );
      }
    }
    for (let index = 0; index < tokens.length; index += 1) {
      if (
        tokens[index].kind !== "identifier"
        || tokens[index].value !== "serde_json"
      ) continue;
      for (
        let candidate = index + 1;
        candidate < tokens.length
          && !["(", ";", "{", "}", ","].includes(tokens[candidate].value);
        candidate += 1
      ) {
        if (
          tokens[candidate].kind === "identifier"
          && tokens[candidate].value.startsWith("from_")
        ) {
          assert.equal(
            candidate,
            index + 3,
            `${sourcePath} must not deserialize through a nested serde_json path`,
          );
        }
      }
    }
    for (let index = 0; index < tokens.length; index += 1) {
      if (
        tokens[index].value === "extern"
        && tokens[index + 1]?.value === "crate"
        && tokens[index + 2]?.value === "serde_json"
      ) {
        assert.fail(`${sourcePath} must not alias serde_json through extern crate`);
      }
      if (tokens[index].value !== "use") continue;
      const end = tokens.findIndex(
        (token, candidate) => candidate > index && token.value === ";",
      );
      assert.notEqual(end, -1, `${sourcePath} has an unterminated use item`);
      const importTokens = tokens.slice(index, end);
      const serdeBranches = rustUseTreeBranches(importTokens.slice(1))
        .filter((branch) => branch[0] === "serde_json");
      for (const branch of serdeBranches) {
        const serdeMembers = branch.slice(1);
        assert.ok(
          serdeMembers.length > 0
            && !["*", "self", "as"].includes(serdeMembers[0]),
          `${sourcePath} must not glob-import, self-import, or alias the serde_json root`,
        );
        for (const member of serdeMembers) {
          assert.equal(
            member === "de"
              || member === "parser"
              || member.startsWith("from_"),
            false,
            `${sourcePath} imports forbidden serde_json branch ${branch.join("::")}`,
          );
        }
      }
      index = end;
    }

    const functions = allFunctionRanges(tokens);
    const sourceCalls = [];
    for (let index = 0; index + 3 < tokens.length; index += 1) {
      if (
        tokens[index].value !== "serde_json"
        || tokens[index + 1].value !== ":"
        || tokens[index + 2].value !== ":"
        || !tokens[index + 3].value.startsWith("from_")
      ) continue;
      const method = tokens[index + 3].value;
      if (method === "from_value") {
        assert.equal(
          sourcePath,
          "crates/licoup-native/src/ffi/commands/state.rs",
          `${sourcePath} may not convert admitted JSON values outside state handling`,
        );
        const owner = functions
          .filter((range) => range.open < index && index < range.close)
          .sort((left, right) => left.close - left.open - (right.close - right.open))[0];
        assert.ok(
          owner && ["handle_state_get", "handle_state_set"].includes(owner.name),
          `${sourcePath} serde_json::from_value must stay inside typed state handlers`,
        );
        assert.notEqual(
          sequenceIndex(tokens.slice(index, index + 12), ["ClientStateCollection"]),
          -1,
          `${sourcePath} serde_json::from_value must target ClientStateCollection`,
        );
        continue;
      }
      assert.equal(
        method,
        "from_str",
        `${sourcePath} uses an unaudited serde_json parser ${method}`,
      );
      serdeParserCalls += 1;
      serdeCalls.push({
        sourcePath,
        method,
        tokenIndex: index,
      });
      sourceCalls.push(index);
    }
    for (const callIndex of sourceCalls) {
      const owner = functions
        .filter((range) => range.open < callIndex && callIndex < range.close)
        .sort((left, right) => left.close - left.open - (right.close - right.open))[0];
      assert.ok(owner, `${sourcePath} serde_json parser must be owned by a function`);
      if (
        !parserHelpers.some(
          (helper) =>
            helper.sourcePath === sourcePath
            && helper.declaration === owner.declaration,
        )
      ) parserHelpers.push({ sourcePath, ...owner });
    }
  }
  assert.equal(
    serdeParserCalls,
    1,
    "command sources must have exactly one serde_json deserialization call",
  );
  assert.deepEqual(
    serdeCalls.map(({ sourcePath, method }) => ({ sourcePath, method })),
    [{ sourcePath: definitionPath, method: "from_str" }],
    "parse_json_arg must own the sole serde_json::from_str entry",
  );
  assert.equal(
    parserHelpers.length,
    1,
    "parse_json_arg must be the only JSON parser helper",
  );
  assert.equal(parserHelpers[0].name, "parse_json_arg");

  const fallbackIdentifier = (token) =>
    token.kind === "identifier"
    && (
      token.value.startsWith("unwrap")
      || token.value === "or_else"
      || token.value === "default"
    );
  for (const helper of parserHelpers) {
    assert.notEqual(
      sequenceIndex(helper.header, ["-", ">", "Result"]),
      -1,
      `${helper.sourcePath} ${helper.name} must return Result`,
    );
    assert.equal(
      helper.body.some(fallbackIdentifier),
      false,
      `${helper.sourcePath} ${helper.name} contains a parser fallback`,
    );
  }

  let parserIdentifierUses = 0;
  for (const [sourcePath, tokens] of tokenEntries) {
    const functions = allFunctionRanges(tokens);
    for (let index = 0; index < tokens.length; index += 1) {
      if (
        tokens[index].kind !== "identifier"
        || tokens[index].value !== "parse_json_arg"
      ) continue;
      parserIdentifierUses += 1;
      if (tokens[index - 1]?.value === "fn") continue;
      assert.equal(
        tokens[index + 1]?.value,
        "(",
        `${sourcePath} must not alias, re-export, import, or retain parse_json_arg as a function pointer`,
      );
      const owner = functions
        .filter((range) => range.open < index && index < range.close)
        .sort((left, right) => left.close - left.open - (right.close - right.open))[0];
      assert.equal(
        owner?.name,
        "admit",
        `${sourcePath} parse_json_arg may only run inside CommandTable::admit`,
      );
      const close = matchingDelimiter(tokens, index + 1);
      assert.equal(
        tokens[close + 1]?.value,
        "?",
        `${sourcePath} admission must directly propagate parse_json_arg failure`,
      );
    }
  }
  assert.equal(
    parserIdentifierUses,
    2,
    "parse_json_arg must have exactly one definition and one admitted-accessor call",
  );
  const requiredJson = functionTokens(
    definitionTokens,
    "required_json",
    definitionPath,
  );
  assert.notEqual(
    sequenceIndex(requiredJson.header, ["-", ">", "&", "Value"]),
    -1,
    "AdmittedCommand::required_json must return a borrowed parsed Value",
  );
  assert.equal(
    requiredJson.body.some((token) => token.value === "parse_json_arg"),
    false,
    "required_json must retrieve an admission-owned Value without reparsing raw text",
  );
  const optionJson = functionTokens(
    definitionTokens,
    "option_json",
    definitionPath,
  );
  assert.notEqual(
    sequenceIndex(optionJson.header, ["-", ">", "Option", "<", "&", "Value", ">"]),
    -1,
    "AdmittedCommand::option_json must return an optional borrowed parsed Value",
  );
  assert.equal(
    optionJson.body.some((token) => token.value === "parse_json_arg"),
    false,
    "option_json must retrieve an admission-owned Value without reparsing raw text",
  );
});

test("command root owns one bounded typed public admission seam", async () => {
  const sources = await commandSources();
  const root = productionTokens(sources.get(commandFacade));

  assert.notEqual(
    sequenceIndex(
      root,
      ["const", "MAX_CLI_ARGUMENT_COUNT", ":", "usize", "=", "4_096", ";"],
    ),
    -1,
    "MAX_CLI_ARGUMENT_COUNT must be exactly 4096",
  );
  assert.notEqual(
    sequenceIndex(
      root,
      [
        "const",
        "MAX_CLI_ARGUMENT_BYTES",
        ":",
        "usize",
        "=",
        "2",
        "*",
        "1024",
        "*",
        "1024",
        ";",
      ],
    ),
    -1,
    "MAX_CLI_ARGUMENT_BYTES must be exactly 2 * 1024 * 1024 per argument",
  );

  const errorFields = structTokens(root, "CliCommandError", commandFacade);
  assert.deepEqual(
    namedStructFields(errorFields).sort(),
    ["code", "stage", "component", "retryable", "recovery"].sort(),
    "CliCommandError must contain exactly the five stable public metadata fields",
  );
  for (const field of ["code", "stage", "component", "recovery"]) {
    assert.deepEqual(
      values(fieldValue(errorFields, field, commandFacade)),
      ["&", "'", "static", "str"],
      `CliCommandError.${field} must be a redacted static value`,
    );
  }
  assert.deepEqual(
    values(fieldValue(errorFields, "retryable", commandFacade)),
    ["bool"],
    "CliCommandError.retryable must be a bool",
  );

  const commandTableFields = structTokens(root, "CommandTable", commandFacade);
  const defsField = commandTableFields.findIndex(
    (token, index) =>
      token.kind === "identifier"
      && token.value === "defs"
      && commandTableFields[index + 1]?.value === ":",
  );
  assert.notEqual(defsField, -1, "CommandTable must own defs");
  const fieldStart =
    commandTableFields
      .map((token) => token.value)
      .lastIndexOf(",", defsField - 1) + 1;
  assert.equal(
    commandTableFields
      .slice(fieldStart, defsField)
      .some((token) => token.value === "pub"),
    false,
    "CommandTable.defs must remain private",
  );
  const validation = functionTokens(root, "validate_cli_admission", commandFacade);
  assert.notEqual(
    sequenceIndex(validation.header, ["-", ">", "Result"]),
    -1,
    "validate_cli_admission must be fallible",
  );
  for (const bound of ["MAX_CLI_ARGUMENT_COUNT", "MAX_CLI_ARGUMENT_BYTES"]) {
    assert.ok(
      validation.body.some((token) => token.value === bound),
      `validate_cli_admission does not enforce ${bound}`,
    );
  }

  const tableDeclaration = sequenceIndex(root, ["struct", "CommandTable"]);
  const tableOpen = root.findIndex(
    (token, index) => index > tableDeclaration && token.value === "{",
  );
  const tableClose = matchingDelimiter(root, tableOpen);
  const functionRanges = allFunctionRanges(root);
  let fieldDeclarations = 0;
  let initializations = 0;
  let writerCalls = 0;
  let immutableReads = 0;
  let defsUsages = 0;
  for (const [sourcePath, source] of sources) {
    const tokens = productionTokens(source);
    for (let index = 0; index < tokens.length; index += 1) {
      if (
        tokens[index].kind !== "identifier"
        || tokens[index].value !== "defs"
      ) continue;
      defsUsages += 1;
      assert.equal(
        sourcePath,
        commandFacade,
        `${sourcePath} contains unowned CommandTable defs usage`,
      );
      if (
        index > tableOpen
        && index < tableClose
        && tokens[index + 1]?.value === ":"
      ) {
        fieldDeclarations += 1;
        continue;
      }
      const owner = functionRanges
        .filter((range) => range.open < index && index < range.close)
        .sort((left, right) => left.close - left.open - (right.close - right.open))[0];
      assert.ok(owner, `unclassified CommandTable.defs usage at token ${index}`);
      if (owner.name === "new" && tokens[index + 1]?.value === ":") {
        initializations += 1;
        continue;
      }
      const selfField =
        tokens[index - 2]?.value === "self"
        && tokens[index - 1]?.value === ".";
      if (
        owner.name === "register_command"
        && selfField
        && tokens[index + 1]?.value === "."
        && tokens[index + 2]?.value === "push"
        && tokens[index + 3]?.value === "("
      ) {
        writerCalls += 1;
        continue;
      }
      assert.ok(
        ["admit", "help_text", "schemas"].includes(owner.name),
        `CommandTable.defs is used by unapproved function ${owner.name}`,
      );
      assert.ok(selfField, `${owner.name} must read defs through &self`);
      const borrowed = tokens[index - 3]?.value === "&";
      const readMethod =
        tokens[index + 1]?.value === "."
          ? tokens[index + 2]?.value
          : null;
      const approvedReadMethods = [
        "contains",
        "first",
        "get",
        "is_empty",
        "iter",
        "last",
        "len",
      ];
      const indexedRead = tokens[index + 1]?.value === "[";
      if (indexedRead) {
        const close = matchingDelimiter(tokens, index + 1);
        assert.equal(
          ["=", "+", "-", "*", "/", "%"].includes(tokens[close + 1]?.value),
          false,
          `${owner.name} must not assign through defs indexing`,
        );
      }
      assert.ok(
        borrowed || approvedReadMethods.includes(readMethod) || indexedRead,
        `${owner.name} contains unknown or mutable defs usage`,
      );
      immutableReads += 1;
    }
  }
  assert.equal(fieldDeclarations, 1, "CommandTable must declare one private defs field");
  assert.equal(initializations, 1, "CommandTable::new must initialize defs exactly once");
  const newBody = functionTokens(root, "new", commandFacade).body;
  const selfLiteral = newBody.findIndex((token) => token.value === "Self");
  const selfLiteralOpen = newBody.findIndex(
    (token, index) => index > selfLiteral && token.value === "{",
  );
  const defsInitializer = values(fieldValue(
    newBody.slice(
      selfLiteralOpen + 1,
      matchingDelimiter(newBody, selfLiteralOpen),
    ),
    "defs",
    commandFacade,
  ));
  assert.ok(
    [
      ["Vec", ":", ":", "new", "(", ")"],
      ["vec", "!", "[", "]"],
    ].some((approved) =>
      approved.length === defsInitializer.length
      && approved.every((value, index) => defsInitializer[index] === value)),
    "CommandTable::new must initialize defs to an empty Vec::new() or vec![]",
  );
  assert.equal(writerCalls, 1, "register_command must be the unique defs writer");
  assert.ok(immutableReads > 0, "admission/help must read registered definitions");
  assert.equal(
    defsUsages,
    fieldDeclarations + initializations + writerCalls + immutableReads,
    "every defs identifier must be consumed by an approved usage shape",
  );

  const schemasMethod = functionTokens(root, "schemas", commandFacade);
  assert.equal(
    allFunctionRanges(root).filter(({ name }) => name === "schemas").length,
    1,
    "CommandTable::schemas must be the sole schemas implementation",
  );
  const mechanicalSchemas = [
    "self", ".", "defs", ".", "iter", "(", ")", ".", "map", "(",
    "CommandDef", ":", ":", "schema", ")", ".", "collect", "(", ")",
  ];
  const schemasIndex = sequenceIndex(schemasMethod.body, mechanicalSchemas);
  assert.notEqual(
    schemasIndex,
    -1,
    "CommandTable::schemas must mechanically map CommandDef::schema",
  );
  assert.ok(
    schemasMethod.body
      .slice(schemasIndex + mechanicalSchemas.length)
      .every((token) => token.value === ";"),
    "CommandTable::schemas must not filter or enrich the registry projection",
  );

  const schemaMethod = functionTokens(root, "schema", commandFacade);
  assert.equal(
    allFunctionRanges(root).filter(({ name }) => name === "schema").length,
    1,
    "CommandDef::schema must be the sole schema implementation",
  );
  assert.notEqual(
    sequenceIndex(schemaMethod.header, [
      "fn", "schema", "(", "&", "self", ")", "-", ">", "CliCommandSchema",
    ]),
    -1,
    "CommandDef::schema must be an immutable CliCommandSchema projection",
  );
  const schemaLiteral = sequenceIndex(
    schemaMethod.body,
    ["CliCommandSchema", "{"],
  );
  assert.notEqual(
    schemaLiteral,
    -1,
    "CommandDef::schema must return one explicit CliCommandSchema projection",
  );
  const schemaLiteralOpen = schemaLiteral + 1;
  const schemaLiteralBody = schemaMethod.body.slice(
    schemaLiteralOpen + 1,
    matchingDelimiter(schemaMethod.body, schemaLiteralOpen),
  );
  const projectedSchemaFields = [
    "source_module",
    "handler_name",
    "path",
    "required_positionals",
    "options",
    "constraints",
    "cardinality",
  ];
  assert.deepEqual(
    namedStructFields(schemaLiteralBody).sort(),
    [...projectedSchemaFields].sort(),
    "CommandDef::schema must project exactly the stable registry fields",
  );
  for (const field of projectedSchemaFields) {
    assert.deepEqual(
      values(fieldValue(schemaLiteralBody, field, commandFacade)),
      ["self", ".", field],
      `CommandDef::schema must project self.${field} unchanged`,
    );
  }

  const schemaProjection = functionTokens(
    root,
    "cli_command_schemas",
    commandFacade,
  );
  assert.notEqual(
    sequenceIndex(root, ["pub", "fn", "cli_command_schemas"]),
    -1,
    "cli_command_schemas must be a public read-only registry projection",
  );
  assert.notEqual(
    sequenceIndex(schemaProjection.body, [
      "build_command_table", "(", ")", ".", "schemas", "(", ")",
    ]),
    -1,
    "schema projection must directly return build_command_table().schemas()",
  );
  assert.equal(
    schemaProjection.body.some((token) =>
      ["push", "register_command"].includes(token.value)),
    false,
    "schema projection must remain read-only",
  );
  const schemaReturn = sequenceIndex(schemaProjection.body, [
    "build_command_table", "(", ")", ".", "schemas", "(", ")",
  ]);
  assert.ok(
    schemaProjection.body
      .slice(schemaReturn + 7)
      .every((token) => token.value === ";"),
    "schema projection must not filter or hand-build registry metadata",
  );

  assert.equal(
    sequenceIndex(root, ["fn", "dispatch"]),
    -1,
    "the pre-admission CommandTable::dispatch bypass must be removed",
  );

  const commandFn = sequenceIndex(root, ["type", "CommandFn", "="]);
  assert.notEqual(commandFn, -1, "command root must own CommandFn");
  const commandFnEnd = root.findIndex(
    (token, index) => index > commandFn && token.value === ";",
  );
  const commandFnTokens = values(root.slice(commandFn + 3, commandFnEnd));
  assert.ok(
    [
      ["fn", "(", "AdmittedCommand", ")", "-", ">", "Result", "<", "CliExecution", ">"],
      [
        "fn", "(", "ValidatedCommandArguments", ")", "-", ">",
        "Result", "<", "CliExecution", ">",
      ],
    ].some((approved) =>
      approved.length === commandFnTokens.length
      && approved.every((value, index) => commandFnTokens[index] === value)),
    "CommandFn must receive only an admitted or validated command carrier",
  );

  const commandDefinition = structTokens(root, "CommandDef", commandFacade);
  const commandSpec = structTokens(root, "CommandSpec", commandFacade);
  assert.notEqual(
    sequenceIndex(root, ["pub", "enum", "RequiredArgumentKind"]),
    -1,
    "required argument schema kind must be public",
  );
  const requiredKindDeclaration = sequenceIndex(
    root,
    ["enum", "RequiredArgumentKind"],
  );
  const requiredKindOpen = root.findIndex(
    (token, index) => index > requiredKindDeclaration && token.value === "{",
  );
  const requiredKinds = root.slice(
    requiredKindOpen + 1,
    matchingDelimiter(root, requiredKindOpen),
  );
  for (const kind of ["Json", "Text"]) {
    assert.ok(
      requiredKinds.some((token) => token.value === kind),
      `RequiredArgumentKind must own ${kind}`,
    );
  }
  assert.notEqual(
    sequenceIndex(root, ["pub", "enum", "OptionArity"]),
    -1,
    "OptionArity must be public",
  );
  const optionArityDeclaration = sequenceIndex(root, ["enum", "OptionArity"]);
  const optionArityOpen = root.findIndex(
    (token, index) => index > optionArityDeclaration && token.value === "{",
  );
  const optionArities = root.slice(
    optionArityOpen + 1,
    matchingDelimiter(root, optionArityOpen),
  );
  for (const arity of ["Boolean", "Value"]) {
    assert.ok(optionArities.some((token) => token.value === arity));
  }
  const optionSpecFields = structTokens(root, "OptionSpec", commandFacade);
  assert.deepEqual(
    namedStructFields(optionSpecFields).sort(),
    ["arity", "name", "repeatable", "required", "value_kind"].sort(),
    "OptionSpec must freeze name/arity/repeatability/value kind/required",
  );
  assert.notEqual(
    sequenceIndex(root, ["pub", "enum", "OptionConstraintKind"]),
    -1,
    "option relationship kinds must be public registry metadata",
  );
  for (const kind of [
    "AtLeastOne",
    "ConditionalRequired",
    "MutuallyExclusive",
    "OneOf",
  ]) {
    assert.ok(root.some((token) => token.value === kind));
  }
  const constraintFields = structTokens(
    root,
    "OptionConstraintSpec",
    commandFacade,
  );
  for (const field of [
    "condition_option",
    "condition_value",
    "kind",
    "members",
    "required_option",
  ]) {
    assert.notEqual(sequenceIndex(constraintFields, [field, ":"]), -1);
  }
  for (const field of [
    "path",
    "required_positionals",
    "options",
    "constraints",
    "cardinality",
    "handler",
  ]) {
    assert.notEqual(
      sequenceIndex(commandSpec, [field, ":"]),
      -1,
      `CommandSpec must own ${field}`,
    );
    assert.notEqual(
      sequenceIndex(commandDefinition, [field, ":"]),
      -1,
      `CommandDef must retain ${field}`,
    );
  }
  const admittedFields = structTokens(root, "AdmittedCommand", commandFacade);
  for (const field of [
    "handler",
    "option_flags",
    "option_json",
    "option_text",
    "required_json",
    "required_text",
    "schema",
  ]) {
    assert.notEqual(
      sequenceIndex(admittedFields, [field, ":"]),
      -1,
      `AdmittedCommand must own ${field}`,
    );
  }
  for (const duplicatedSchemaField of [
    "source_module",
    "handler_name",
    "path",
    "required_positionals",
    "cardinality",
    "option_specs",
    "constraints",
  ]) {
    assert.equal(
      sequenceIndex(admittedFields, [duplicatedSchemaField, ":"]),
      -1,
      `AdmittedCommand must read ${duplicatedSchemaField} through its owned schema`,
    );
  }
  assert.ok(
    structFieldType(admittedFields, "required_json", commandFacade)
      .some((token) => token.value === "Value"),
    "AdmittedCommand.required_json must store owned serde_json::Value entries",
  );
  assert.ok(
    structFieldType(admittedFields, "option_json", commandFacade)
      .some((token) => token.value === "Value"),
    "AdmittedCommand.option_json must store owned serde_json::Value entries",
  );

  const registration = functionTokens(root, "register_command", commandFacade);
  const push = sequenceIndex(
    registration.body,
    ["self", ".", "defs", ".", "push", "(", "CommandDef", "{"],
  );
  assert.notEqual(
    push,
    -1,
    "register_command must push one explicit CommandDef",
  );
  const literalOpen = push + 7;
  const literalClose = matchingDelimiter(registration.body, literalOpen);
  const definitionLiteral = registration.body.slice(literalOpen + 1, literalClose);
  for (const field of [
    "path",
    "required_positionals",
    "options",
    "constraints",
    "cardinality",
    "handler",
  ]) {
    assert.deepEqual(
      values(fieldValue(definitionLiteral, field, commandFacade)),
      ["spec", ".", field],
      `register_command must project CommandSpec.${field} unchanged`,
    );
  }

  const admission = functionTokens(root, "admit_cli_command", commandFacade);
  assert.notEqual(
    sequenceIndex(root, ["pub", "fn", "admit_cli_command"]),
    -1,
    "admit_cli_command must be a public production seam",
  );
  assert.notEqual(
    sequenceIndex(admission.header, [
      "-", ">", "Result", "<", "AdmittedCommand", ">",
    ]),
    -1,
    "admit_cli_command must return Result<AdmittedCommand>",
  );
  const directAdmissionChain = [
    "build_command_table", "(", ")", ".", "admit", "(", "args", ")",
  ];
  const directAdmissionIndex = sequenceIndex(
    admission.body,
    directAdmissionChain,
  );
  assert.notEqual(
    directAdmissionIndex,
    -1,
    "admit_cli_command must directly return build_command_table().admit(args)",
  );
  assert.deepEqual(
    values(admission.body),
    directAdmissionChain,
    "admit_cli_command must be the pure build_command_table().admit(args) delegate",
  );
  for (const forbidden of [
    "defs",
    "handler",
    "parse_json_arg",
    "validate_cli_admission",
    "validate_command_arguments",
  ]) {
    assert.equal(
      admission.body.some((token) => token.value === forbidden),
      false,
      `admit_cli_command must not retain ${forbidden} matching or validation logic`,
    );
  }

  const tableAdmission = functionTokens(root, "admit", commandFacade);
  assert.equal(
    allFunctionRanges(root).filter(({ name }) => name === "admit").length,
    1,
    "CommandTable::admit must be the sole admission matcher",
  );
  assert.notEqual(
    sequenceIndex(tableAdmission.header, [
      "-", ">", "Result", "<", "AdmittedCommand", ">",
    ]),
    -1,
    "CommandTable::admit must return Result<AdmittedCommand>",
  );
  const definitionBinding = [
    "let", "definition", "=", "self", ".", "defs", ".", "iter", "(", ")",
    ".", "find", "(",
  ];
  const definitionBindingIndex = sequenceIndex(
    tableAdmission.body,
    definitionBinding,
  );
  assert.notEqual(
    definitionBindingIndex,
    -1,
    "CommandTable::admit must select one definition through self.defs.iter().find",
  );
  const findOpen = definitionBindingIndex + definitionBinding.length - 1;
  const findClose = matchingDelimiter(tableAdmission.body, findOpen);
  const findBody = tableAdmission.body.slice(findOpen + 1, findClose);
  assert.notEqual(
    sequenceIndex(findBody, ["|", "definition", "|"]),
    -1,
    "the registry matcher must bind the selected candidate as definition",
  );
  assert.notEqual(
    sequenceIndex(findBody, ["definition", ".", "path"]),
    -1,
    "route matching must use the registered definition.path",
  );
  assert.ok(
    findBody.some((token) => token.value === "args"),
    "route matching must compare definition.path with admitted args",
  );
  const definitionSelectionEnd = tableAdmission.body.findIndex(
    (token, index) => index > findClose && token.value === ";",
  );
  assert.notEqual(
    definitionSelectionEnd,
    -1,
    "selected definition binding must terminate before argument parsing",
  );
  const definitionSelectionTail = tableAdmission.body.slice(
    findClose + 1,
    definitionSelectionEnd,
  );
  assert.ok(
    definitionSelectionTail.some(
      (token) => ["ok_or", "ok_or_else"].includes(token.value),
    ),
    "definition selection must map a missing route to an admission error",
  );
  assert.ok(
    definitionSelectionTail.some((token) => token.value === "?"),
    "definition selection must fail closed before argument parsing",
  );
  assert.equal(
    tableAdmission.body.filter((token) => token.value === "defs").length,
    1,
    "CommandTable::admit may read defs only through the selecting iterator",
  );
  assert.equal(
    findBody.some((token) => token.kind === "string"),
    false,
    "CommandTable::admit route matching must not compare against literal routes",
  );
  assert.equal(
    tableAdmission.body.some((token) =>
      ["CommandDef", "CommandSpec", "register_command"].includes(token.value)),
    false,
    "CommandTable::admit must not embed a literal route table or second registry",
  );
  for (const field of [
    "path",
    "required_positionals",
    "cardinality",
    "options",
    "constraints",
  ]) {
    assert.notEqual(
      sequenceIndex(tableAdmission.body, ["definition", ".", field]),
      -1,
      `CommandTable::admit must read ${field} from the selected definition`,
    );
  }
  for (const validationName of [
    "validate_cli_admission",
    "validate_command_arguments",
  ]) {
    const call = sequenceIndex(tableAdmission.body, [validationName, "("]);
    assert.notEqual(call, -1, `CommandTable::admit must call ${validationName}`);
    const close = matchingDelimiter(tableAdmission.body, call + 1);
    assert.equal(
      tableAdmission.body[close + 1]?.value,
      "?",
      `CommandTable::admit must short-circuit ${validationName} failure`,
    );
  }
  const admittedLiteral = sequenceIndex(
    tableAdmission.body,
    ["AdmittedCommand", "{"],
  );
  assert.notEqual(
    admittedLiteral,
    -1,
    "CommandTable::admit must return validated metadata instead of invoking a handler",
  );
  const admittedLiteralOpen = admittedLiteral + 1;
  const admittedLiteralBody = tableAdmission.body.slice(
    admittedLiteralOpen + 1,
    matchingDelimiter(tableAdmission.body, admittedLiteralOpen),
  );
  assert.deepEqual(
    values(fieldValue(admittedLiteralBody, "handler", commandFacade)),
    ["definition", ".", "handler"],
    "AdmittedCommand.handler must come from the selected definition",
  );
  assert.deepEqual(
    values(fieldValue(admittedLiteralBody, "schema", commandFacade)),
    ["definition", ".", "schema", "(", ")"],
    "AdmittedCommand.schema must be the selected definition's exact projection",
  );
  for (const parsedField of [
    "required_text",
    "required_json",
    "option_flags",
    "option_text",
    "option_json",
  ]) {
    assert.deepEqual(
      values(namedStructLiteralFieldValue(
        admittedLiteralBody,
        parsedField,
        commandFacade,
      )),
      [parsedField],
      `AdmittedCommand.${parsedField} must use the validated parse result`,
    );
  }
  const parseJsonIndex = sequenceIndex(
    tableAdmission.body,
    ["parse_json_arg", "("],
  );
  assert.ok(
    parseJsonIndex >= 0,
    "CommandTable::admit must own the sole parse_json_arg call",
  );
  assert.ok(
    parseJsonIndex < admittedLiteral,
    "JSON required fields must be parsed before AdmittedCommand construction",
  );
  assert.equal(
    tableAdmission.body.some(
      (token, index) =>
        token.value === "handler"
        && tableAdmission.body[index + 1]?.value === ")"
        && tableAdmission.body[index + 2]?.value === "(",
    ),
    false,
    "CommandTable::admit must never execute a handler",
  );
  assert.equal(
    sequenceIndex(root, ["fn", "matches"]),
    -1,
    "CommandTable::admit must be the sole route matcher",
  );
  for (const validationName of [
    "validate_cli_admission",
    "validate_command_arguments",
  ]) {
    let calls = 0;
    for (let index = 0; index + 1 < root.length; index += 1) {
      if (
        root[index].value !== validationName
        || root[index + 1].value !== "("
        || root[index - 1]?.value === "fn"
      ) continue;
      calls += 1;
      const owner = functionRanges
        .filter((range) => range.open < index && index < range.close)
        .sort((left, right) =>
          left.close - left.open - (right.close - right.open))[0];
      assert.equal(
        owner?.name,
        "admit",
        `${validationName} may only be orchestrated by CommandTable::admit`,
      );
    }
    assert.equal(calls, 1, `${validationName} must have one admission call site`);
  }
  let parseJsonCalls = 0;
  for (let index = 0; index + 1 < root.length; index += 1) {
    if (
      root[index].value !== "parse_json_arg"
      || root[index + 1].value !== "("
      || root[index - 1]?.value === "fn"
    ) continue;
    parseJsonCalls += 1;
    const owner = functionRanges
      .filter((range) => range.open < index && index < range.close)
      .sort((left, right) =>
        left.close - left.open - (right.close - right.open))[0];
    assert.equal(
      owner?.name,
      "admit",
      "parse_json_arg may only be called inside CommandTable::admit",
    );
  }
  assert.equal(
    parseJsonCalls,
    1,
    "parse_json_arg must have exactly one production call site",
  );

  let admissionCalls = 0;
  for (let index = 0; index < root.length; index += 1) {
    if (
      root[index].kind !== "identifier"
      || root[index].value !== "admit_cli_command"
      || root[index - 1]?.value === "fn"
    ) continue;
    admissionCalls += 1;
    const owner = functionRanges
      .filter((range) => range.open < index && index < range.close)
      .sort((left, right) => left.close - left.open - (right.close - right.open))[0];
    assert.equal(
      owner?.name,
      "execute_cli",
      "execute_cli must be the sole caller of the production admission seam",
    );
    assert.equal(
      root[index + 1]?.value,
      "(",
      "admit_cli_command must be called directly",
    );
    const close = matchingDelimiter(root, index + 1);
    assert.equal(
      root[close + 1]?.value,
      "?",
      "execute_cli must short-circuit admission before handler execution",
    );
  }
  assert.equal(admissionCalls, 1, "admit_cli_command must have one production caller");

  const execution = functionTokens(root, "execute_cli", commandFacade).body;
  assert.equal(
    execution.some((token) => token.value === "validate_cli_admission"),
    false,
    "execute_cli must not duplicate or bypass the admission seam",
  );
  const executionAdmission = sequenceIndex(
    execution,
    ["admit_cli_command", "("],
  );
  assert.notEqual(
    executionAdmission,
    -1,
    "execute_cli must call the sole admission seam",
  );
  const admittedClose = matchingDelimiter(execution, executionAdmission + 1);
  assert.equal(
    execution[admittedClose + 1]?.value,
    "?",
    "execute_cli must short-circuit admission failure",
  );
  const directExecutionChain = [
    "admit_cli_command", "(", "args", ")", "?", ".", "execute", "(", ")",
  ];
  const directExecutionIndex = sequenceIndex(execution, directExecutionChain);
  assert.notEqual(
    directExecutionIndex,
    -1,
    "execute_cli must directly return admit_cli_command(raw_args)?.execute()",
  );
  const executionCall = sequenceIndex(execution, [".", "execute", "(", ")"]);
  assert.ok(
    executionCall > admittedClose,
    "only an admitted command may reach execution",
  );
  assert.ok(
    execution
      .slice(directExecutionIndex + directExecutionChain.length)
      .every((token) => ["?", ";"].includes(token.value)),
    "AdmittedCommand execution must directly determine execute_cli's result",
  );
  const rawArgsUses = execution
    .map((token, index) => ({ token, index }))
    .filter(({ token }) => token.kind === "identifier" && token.value === "args")
    .map(({ index }) => index);
  assert.equal(
    rawArgsUses.length,
    2,
    "execute_cli may use raw args only for exact help and owned admission",
  );
  const helpArgs = rawArgsUses.find((index) => index !== executionAdmission + 2);
  assert.deepEqual(
    values(execution.slice(helpArgs - 3, helpArgs + 5)),
    ["matches", "!", "(", "args", ".", "as_slice", "(", ")"],
    "the sole pre-admission args use must be the exact help predicate",
  );
  assert.equal(
    rawArgsUses.includes(executionAdmission + 2),
    true,
    "the second and final args use must move ownership into admit_cli_command",
  );

  let executeMethodCalls = 0;
  for (const [sourcePath, source] of sources) {
    const tokens = productionTokens(source);
    for (let index = 0; index + 3 < tokens.length; index += 1) {
      if (
        tokens[index].value === "."
        && tokens[index + 1]?.value === "execute"
        && tokens[index + 2]?.value === "("
        && tokens[index + 3]?.value === ")"
      ) {
        executeMethodCalls += 1;
        assert.equal(
          sourcePath,
          commandFacade,
          `${sourcePath} contains a legacy second .execute() path`,
        );
      }
    }
  }
  assert.equal(
    executeMethodCalls,
    1,
    "the command bundle must contain exactly one admitted .execute() call",
  );

  let handlerInvocations = 0;
  for (const range of functionRanges) {
    for (let index = 0; index < range.body.length; index += 1) {
      if (
        range.body[index].value !== "handler"
        || range.body[index - 1]?.value !== "."
        || range.body[index + 1]?.value !== ")"
        || range.body[index + 2]?.value !== "("
      ) continue;
      handlerInvocations += 1;
      assert.equal(
        range.name,
        "execute",
        "only AdmittedCommand::execute may invoke CommandFn",
      );
      assert.equal(
        range.body[index - 2]?.value,
        "self",
        "the invoked handler must come from AdmittedCommand",
      );
      assert.equal(
        range.body[index + 3]?.value,
        "self",
        "CommandFn must receive the admitted carrier rather than raw arguments",
      );
    }
  }
  assert.equal(
    handlerInvocations,
    1,
    "the admitted carrier must own the sole handler invocation",
  );
});
