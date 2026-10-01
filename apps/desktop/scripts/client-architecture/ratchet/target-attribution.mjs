import path from "node:path";
import { lexicalView } from "./lexical.mjs";

// Bounded source interpretation, not execution. A union is complete only when
// every successful branch/caller is complete. Environment and object fields are
// never assigned a target merely because their names sound trustworthy.
const unknown = (reason) => ({ targets: [], reasons: [reason], evidence: [] });
const known = (targets, evidence) => ({ targets, reasons: [], evidence: [evidence] });
const union = (values) => ({
  targets: [...new Set(values.flatMap((value) => value.targets))].sort(),
  reasons: [...new Set(values.flatMap((value) => value.reasons))],
  evidence: [...new Set(values.flatMap((value) => value.evidence))],
});
const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");

function closeAt(mask, open) {
  const close = { "(": ")", "[": "]", "{": "}" }[mask[open]];
  let depth = 0;
  for (let index = open; index < mask.length; index += 1) {
    if (mask[index] === mask[open]) depth += 1;
    if (mask[index] === close && --depth === 0) return index;
  }
  return -1;
}

function parts(mask, start, end, delimiter = ",") {
  const ranges = [];
  let previous = start;
  for (let index = start; index < end; index += 1) {
    if ("([{".includes(mask[index])) {
      const close = closeAt(mask, index);
      if (close < 0) break;
      index = close;
    } else if (mask[index] === delimiter) {
      ranges.push([previous, index]);
      if (delimiter === ";") return ranges;
      previous = index + 1;
    }
  }
  ranges.push([previous, end]);
  return ranges;
}

function importsFor(mask) {
  const imports = new Map();
  function add(text, prefix = []) {
    const open = text.indexOf("{");
    if (open >= 0) {
      const base = text.slice(0, open).split("::").map((part) => part.trim()).filter(Boolean);
      for (const [start, end] of parts(text, open + 1, closeAt(text, open))) {
        add(text.slice(start, end), [...prefix, ...base]);
      }
    } else {
      const [original, alias] = text.trim().split(/\s+as\s+/u);
      const segments = [...prefix, ...original.split("::").map((part) => part.trim()).filter(Boolean)];
      const name = alias ?? segments.at(-1);
      if (name) {
        const entries = imports.get(name) ?? new Set();
        entries.add(segments.join("::"));
        imports.set(name, entries);
      }
    }
  }
  for (const match of mask.matchAll(/\buse\s+([^;]+);/gu)) add(match[1]);
  return imports;
}

export function createTargetAttribution(sources, manifests = new Map()) {
  const models = new Map();
  function model(file) {
    if (models.has(file)) return models.get(file);
    const entry = sources.get(file);
    const { source, masked: mask, language } = entry;
    const braces = [];
    const stack = [];
    for (let offset = 0; offset < mask.length; offset += 1) {
      if (mask[offset] === "{") stack.push(offset);
      if (mask[offset] === "}") braces.push({ start: stack.pop(), end: offset });
    }
    const scopes = (offset) => braces.filter((scope) => scope.start < offset && offset < scope.end);
    const functions = [];
    for (const match of mask.matchAll(/\bfn\s+(\w+)\s*(?:<[^{}]*?>)?\s*\(/gu)) {
      const open = match.index + match[0].length - 1;
      const close = closeAt(mask, open);
      const after = mask.slice(close + 1).search(/[;{]/u);
      const bodyStart = close + 1 + after;
      if (close < 0 || after < 0 || mask[bodyStart] !== "{") continue;
      const bodyEnd = closeAt(mask, bodyStart);
      const declarations = parts(mask, open + 1, close).map(([start, end]) => mask.slice(start, end).trim());
      const parameters = declarations.map((declaration) => declaration.match(/^(?:mut\s+)?(\w+)\s*:/u)?.[1] ?? null);
      const prefix = mask.slice(Math.max(0, match.index - 80), match.index);
      functions.push({ name: match[1], start: match.index, open, close, bodyStart, bodyEnd, parameters,
        private: !declarations.some((declaration) => /\bself\b/u.test(declaration)) &&
          !/pub(?:\s*\([^)]*\))?\s*(?:async\s+)?$/u.test(prefix) });
    }
    const bindings = [];
    const pattern = language === "dart"
      ? /\b(?:final|const|var)\s+(?:(?:String|File)\??\s+)?(\w+)\s*=/gu
      : /\b(?:let\s+(?:mut\s+)?|const\s+|static\s+)(\w+)(?:\s*:[^=;]+)?\s*=/gu;
    for (const match of mask.matchAll(pattern)) {
      const start = match.index + match[0].length;
      const [range] = parts(mask, start, mask.length, ";");
      bindings.push({ name: match[1], start: match.index, expression: range, scopes: scopes(match.index) });
    }
    const result = { ...entry, mask, braces, scopes, functions, bindings, imports: importsFor(mask) };
    models.set(file, result);
    return result;
  }
  function imported(file, name, seen = new Set()) {
    if (seen.has(file)) return name;
    seen.add(file);
    if (new RegExp(`\\b(?:mod|struct|enum|type|trait)\\s+${escape(name)}\\b`, "u").test(model(file).mask)) return name;
    const entries = model(file).imports.get(name);
    if (entries?.size === 1) return [...entries][0];
    const alternatives = new Set();
    for (const wildcard of model(file).imports.get("*") ?? []) {
      if (!/^(?:super::)+\*$/u.test(wildcard)) continue;
      const levels = wildcard.split("::").length - 1;
      let directory = path.posix.dirname(file);
      if (path.posix.basename(file) === "mod.rs") directory = path.posix.dirname(directory);
      for (let index = 1; index < levels; index += 1) directory = path.posix.dirname(directory);
      for (const target of [`${directory}/mod.rs`, `${directory}/lib.rs`, `${directory}/main.rs`]) {
        if (sources.has(target)) {
          const resolved = imported(target, name, seen);
          if (resolved !== name) alternatives.add(resolved);
        }
      }
    }
    return alternatives.size === 1 ? [...alternatives][0] : name;
  }
  function api(file, spelling) {
    const compact = spelling.replace(/\s/gu, "");
    const segments = compact.split("::");
    segments[0] = imported(file, segments[0]);
    const qualified = segments.join("::");
    if (/^(?:std|tokio)::process::Command$/u.test(qualified)) return qualified;
    const owner = [...manifests.values()].filter((manifest) => file.startsWith(`${path.posix.dirname(manifest.path)}/src/`))
      .sort((a, b) => b.path.length - a.path.length)[0];
    if (qualified === "clap::Command" && owner?.deps.some((dependency) =>
      dependency.alias === "clap" && (dependency.spec.package ?? "clap") === "clap" && !dependency.localName) &&
      !/\b(?:mod\s+clap|(?:struct|enum|type)\s+Command)\b/u.test(model(file).mask)) return "non-process:clap::Command";
    if (compact === "Process" && /import\s+['"]dart:io['"](?:\s+show\s+[^;]*\bProcess\b)?\s*;/u.test(model(file).source)) return "dart:io.Process";
    const prefixed = compact.match(/^(\w+)\.Process$/u);
    if (prefixed && new RegExp(`import\\s+['"]dart:io['"]\\s+as\\s+${escape(prefixed[1])}\\s*;`, "u").test(model(file).source)) return "dart:io.Process";
    return `unresolved-api:${compact}`;
  }
  function reference(file, offset, description) {
    return `${file}:${model(file).source.slice(0, offset).split("\n").length} ${description}`;
  }
  function resolve(file, start, end, seen = new Set()) {
    const entry = model(file);
    const { source, mask, language } = entry;
    while (start < end && /\s/u.test(source[start])) start += 1;
    while (end > start && /\s/u.test(source[end - 1])) end -= 1;
    const key = `${file}:${start}:${end}`;
    if (seen.size > 24 || seen.has(key)) return unknown("cyclic or over-depth target provenance");
    const next = new Set([...seen, key]);
    const recurse = (from, to) => resolve(file, from, to, next);
    const text = source.slice(start, end);
    const code = mask.slice(start, end);
    const proof = reference(file, start, text.replace(/\s+/gu, " ").slice(0, 180));
    if (source[start] === "&") return recurse(start + 1, end);
    if (source[start] === "(" && closeAt(mask, start) === end - 1) return recurse(start + 1, end - 1);
    const literal = lexicalView(text, language).regions;
    if (literal.length === 1 && literal[0].kind === "string" && literal[0].start === 0 && literal[0].end === text.length) {
      if (language === "dart" && !text.startsWith("r") && /(?<!\\)\$/u.test(text)) return unknown("interpolated target string");
      const raw = text.match(/^r(#+)?"([\s\S]*)"\1$/u) ?? text.match(/^r['"]([\s\S]*)['"]$/u);
      let value;
      if (raw) value = raw[2] ?? raw[1];
      else {
        if (text.startsWith("'") && text.includes("\\")) return unknown("unsupported target literal escape");
        try { value = text.startsWith('"') ? JSON.parse(text) : text.slice(1, -1).replace(/\\'/gu, "'"); }
        catch { return unknown("unsupported target literal escape"); }
      }
      return known([value], proof);
    }
    // All branches are required; the condition does not establish a target.
    if (language === "dart") {
      const question = code.indexOf("?");
      if (question >= 0 && code[question + 1] !== "?") {
        let nesting = 0;
        for (let i = question + 1; i < code.length; i += 1) {
          if (code[i] === "?") nesting += 1;
          if (code[i] === ":" && nesting-- === 0) return union([recurse(start + question + 1, start + i), recurse(start + i + 1, end)]);
        }
      }
    }
    if (/^if\b/u.test(code)) {
      const open = mask.indexOf("{", start);
      const close = closeAt(mask, open);
      const remaining = mask.slice(close + 1, end).match(/^\s*else\s*/u);
      if (open < 0 || close < 0 || !remaining) return unknown("target conditional lacks a resolved alternative");
      const other = close + 1 + remaining[0].length;
      return union([recurse(open + 1, close), mask[other] === "{" && closeAt(mask, other) === end - 1
        ? recurse(other + 1, end - 1) : recurse(other, end)]);
    }
    const wrapper = code.match(/^(?:Ok|Some|(?:std\s*::\s*path\s*::\s*)?(?:Path|PathBuf)\s*::\s*(?:new|from))\s*\(/u);
    if (wrapper) {
      const open = start + wrapper[0].length - 1;
      if (/^Path(?:Buf)?\b/u.test(code) && !/^std::path::Path(?:Buf)?$/u.test(imported(file, code.match(/^\w+/u)[0]))) return unknown("unresolved path constructor identity");
      if (closeAt(mask, open) === end - 1) return recurse(open + 1, end - 1);
    }
    const copied = code.match(/\.(?:to_string|to_owned|to_path_buf|clone|as_str)\s*\(\s*\)\s*$/u);
    if (copied) return recurse(start, start + copied.index);
    for (const successful of code.matchAll(/\.(?:context|with_context|map_err|ok_or_else)\s*\(/gu)) {
      const open = start + successful.index + successful[0].length - 1;
      if (/^\s*\??\s*$/u.test(code.slice(closeAt(mask, open) - start + 1))) return recurse(start, start + successful.index);
    }
    if (code.endsWith("?")) return recurse(start, end - 1);
    if (/^(?:std\s*::\s*)?env\s*::\s*consts\s*::\s*EXE_SUFFIX$/u.test(code) &&
        (code.startsWith("std") || imported(file, "env") === "std::env")) return known(["", ".exe"], proof);
    const joined = [...code.matchAll(/\.join\s*\(/gu)].at(-1);
    if (joined) {
      const open = start + joined.index + joined[0].length - 1;
      if (closeAt(mask, open) === end - 1) {
        if (!pathExpression(file, start, start + joined.index, new Set())) return unknown("join receiver is not a source-proven std::path value");
        const result = recurse(open + 1, end - 1);
        if (result.targets.some((value) => !value || value === "." || value === ".." || /[/\\]/u.test(value))) return unknown("path join does not establish a single target basename");
        return { ...result, targets: result.targets.map((value) => `source-path/${value}`) };
      }
    }
    if (/^format!\s*\(/u.test(code)) {
      const open = mask.indexOf("(", start);
      if (closeAt(mask, open) === end - 1) {
        const args = parts(mask, open + 1, end - 1);
        const template = recurse(...args[0]);
        if (template.targets.length === 1 && /^(?:\{\})+$/u.test(template.targets[0]) && args.length - 1 === template.targets[0].length / 2) {
          const values = args.slice(1).map((range) => recurse(...range));
          const combined = union(values);
          let targets = [""];
          for (const value of values) targets = targets.flatMap((left) => value.targets.map((right) => left + right));
          if (targets.length > 64) return unknown("target alternatives exceed the bounded resolver");
          return { ...combined, targets };
        }
      }
    }
    const current = code.match(/^((?:std\s*::\s*)?env)\s*::\s*current_exe\s*\(\s*\)$/u);
    if (current && (current[1].replace(/\s/gu, "") === "std::env" || imported(file, "env") === "std::env")) {
      const owner = [...manifests.values()].filter((manifest) => file.startsWith(`${path.posix.dirname(manifest.path)}/src/`))
        .sort((a, b) => b.path.length - a.path.length)[0];
      if (!owner?.bins.length) return unknown("current executable has no declared native binary owner");
      return known(owner.bins.map((binary) => `native:${owner.name}/${binary}`), reference(file, start, `std::env::current_exe; ${owner.path}`));
    }
    if (/^\w+$/u.test(code)) {
      const visible = entry.bindings.filter((binding) => binding.name === code && binding.start < start &&
        binding.scopes.every((scope) => scope.start < start && start < scope.end));
      const binding = visible.sort((a, b) => b.start - a.start)[0];
      if (binding) {
        const between = mask.slice(binding.expression[1] + 1, start);
        if (new RegExp(`\\b${escape(code)}\\s*(?:[+*/%&|^\\-]|<<|>>)?=(?!=)|&\\s*mut\\s+${escape(code)}\\b`, "u").test(between)) return unknown(`target binding ${code} is reassigned or mutably borrowed`);
        const readOnlyMethods = new Set(["clone", "to_owned", "to_string", "to_path_buf", "as_str", "as_os_str", "as_ref", "to_str", "to_string_lossy", "len", "is_empty", "exists", "is_file", "is_dir", "display", "file_name", "parent", "extension"]);
        const constructor = mask.slice(...binding.expression).trim().match(/^((?:\w+\s*::\s*)*\w+)\s*::\s*new\s*\(/u);
        if (constructor && /^(?:std|tokio)::process::Command$/u.test(api(file, constructor[1]))) {
          // These Command methods configure arguments/environment, not the
          // executable. Shell guest arguments are inspected by the sink owner.
          for (const method of ["arg", "args", "env", "envs", "env_clear", "env_remove", "current_dir", "stdin", "stdout", "stderr", "uid", "gid", "groups", "process_group", "creation_flags", "kill_on_drop"]) readOnlyMethods.add(method);
        }
        for (const use of between.matchAll(new RegExp(`\\b${escape(code)}\\s*\\.\\s*(\\w+)\\s*\\(`, "gu"))) {
          if (!readOnlyMethods.has(use[1])) return unknown(`target binding ${code} may be mutated by ${use[1]}`);
        }
        return recurse(...binding.expression);
      }
      const fn = entry.functions.find((fn) => fn.bodyStart < start && start < fn.bodyEnd);
      const position = fn?.parameters.indexOf(code) ?? -1;
      if (position >= 0) return parameterTargets(file, fn, position, next);
      for (const match of mask.slice(0, start).matchAll(/\bfor\s+(\w+)\s+in\s*\[/gu)) {
        if (match[1] !== code) continue;
        const open = match.index + match[0].length - 1;
        const close = closeAt(mask, open);
        const body = mask.indexOf("{", close + 1);
        if (body < start && start < closeAt(mask, body)) return union(parts(mask, open + 1, close)
          .filter(([left, right]) => source.slice(left, right).trim()).map((range) => recurse(...range)));
      }
      // The first element is a target; the remaining argv may be dynamic.
      for (const match of mask.slice(0, start).matchAll(/\blet\s*\(\s*(\w+)\s*,\s*\w+\s*\)\s*=\s*(\w+)\.split_first\(\)\?/gu)) {
        if (match[1] !== code || !entry.scopes(match.index).every((scope) => scope.start < start && start < scope.end)) continue;
        const owner = entry.functions.find((candidate) => candidate.bodyStart < match.index && match.index < candidate.bodyEnd);
        const index = owner?.parameters.indexOf(match[2]) ?? -1;
        if (index >= 0) return parameterTargets(file, owner, index, next, true);
      }
      return unknown(`unresolved binding ${code}`);
    }
    const invocation = code.match(/^(\w+)\s*\(/u);
    if (invocation) {
      const open = start + invocation[0].length - 1;
      const candidates = entry.functions.filter((fn) => fn.name === invocation[1]);
      if (closeAt(mask, open) === end - 1 && candidates.length === 1) return returnedTargets(file, candidates[0], next);
    }
    const command = code.match(/^((?:\w+\s*::\s*)*\w+)\s*::\s*new\s*\(/u);
    if (command && !api(file, command[1]).startsWith("unresolved") && !api(file, command[1]).startsWith("non-process")) {
      const open = start + command[0].length - 1;
      return recurse(...parts(mask, open + 1, closeAt(mask, open))[0]);
    }
    if (/\b(?:var_os|var|environment)\b/u.test(code)) return unknown("environment-selected target has no closed source value set");
    if (/\b(?:self|config|record|params|registration)\s*\./u.test(code)) return unknown("runtime-selected field has no closed source value set");
    return unknown(`unsupported or dynamic target expression: ${text.replace(/\s+/gu, " ").slice(0, 140)}`);
  }
  function pathExpression(file, start, end, seen) {
    const key = `${file}:${start}:${end}`;
    if (seen.has(key) || seen.size > 24) return false;
    const next = new Set([...seen, key]);
    const entry = model(file);
    const code = entry.mask.slice(start, end).trim().replace(/\?$/u, "").trim();
    const trimStart = start + entry.mask.slice(start, end).indexOf(code);
    const type = (name, owner = file) => /^std::path::Path(?:Buf)?$/u.test(name.includes("::") ? name : imported(owner, name));
    const ctor = code.match(/^((?:std\s*::\s*path\s*::\s*)?Path(?:Buf)?)\s*::\s*(?:new|from)\s*\(/u);
    if (ctor && type(ctor[1].replace(/\s/gu, ""))) return true;
    if (/^(?:std\s*::\s*)?env\s*::\s*current_exe\s*\(/u.test(code) && (code.startsWith("std") || imported(file, "env") === "std::env")) return true;
    if (/^\w+$/u.test(code)) {
      const binding = entry.bindings.filter((binding) => binding.name === code && binding.start < start &&
        binding.scopes.every((scope) => scope.start < start && start < scope.end)).sort((a, b) => b.start - a.start)[0];
      if (binding) return pathExpression(file, ...binding.expression, next);
      const fn = entry.functions.find((fn) => fn.bodyStart < start && start < fn.bodyEnd);
      const parameter = fn && entry.mask.slice(fn.open + 1, fn.close).match(new RegExp(`\\b${escape(code)}\\s*:\\s*&?\\s*((?:std\\s*::\\s*path\\s*::\\s*)?Path(?:Buf)?)\\b`, "u"));
      return Boolean(parameter && type(parameter[1].replace(/\s/gu, "")));
    }
    const joined = code.match(/\.join\s*\(/u);
    if (joined) return pathExpression(file, trimStart, trimStart + joined.index, next);
    const call = code.match(/^((?:\w+\s*::\s*)*\w+)\s*\(/u);
    if (!call) return false;
    const segments = call[1].replace(/\s/gu, "").split("::");
    const name = segments.pop();
    let files = [file];
    if (segments.length) {
      const crate = [...manifests.values()].find((manifest) => manifest.name?.replaceAll("-", "_") === segments[0]);
      if (!crate) return false;
      const module = `${path.posix.dirname(crate.path)}/src/${segments.slice(1).join("/")}`;
      files = [`${module}.rs`, `${module}/mod.rs`].filter((candidate) => sources.has(candidate));
    }
    return files.length === 1 && model(files[0]).functions.some((fn) => fn.name === name &&
      /->[^{};]*\bPath(?:Buf)?\b/u.test(model(files[0]).mask.slice(fn.close + 1, fn.bodyStart)) &&
      (type("Path", files[0]) || type("PathBuf", files[0])));
  }
  function returnedTargets(file, fn, seen) {
    const { mask, source } = model(file);
    const values = [];
    for (const match of mask.slice(fn.bodyStart + 1, fn.bodyEnd).matchAll(/\breturn\s+/gu)) {
      const start = fn.bodyStart + 1 + match.index + match[0].length;
      const [range] = parts(mask, start, fn.bodyEnd, ";");
      if (!/^\s*Err\s*\(/u.test(mask.slice(...range))) values.push(resolve(file, ...range, seen));
    }
    // Require an explicit fall-through result; do not infer returns from just
    // the conveniently parseable branch of a match or nested expression.
    const tail = source.slice(fn.bodyStart + 1, fn.bodyEnd).match(/(?:^|[;}])\s*((?:Ok|Err)\s*\([^;]*\))\s*$/u);
    if (!tail) return unknown(`function ${fn.name} has an unsupported fall-through target`);
    const start = fn.bodyEnd - tail[1].length - (tail[0].match(/\s*$/u)?.[0].length ?? 0);
    if (!tail[1].startsWith("Err")) values.push(resolve(file, start, start + tail[1].length, seen));
    return values.length ? union(values) : unknown(`function ${fn.name} has no successful target`);
  }
  function parameterTargets(file, fn, position, seen, head = false) {
    const { mask, source, functions } = model(file);
    if (!fn.private || functions.filter((other) => other.name === fn.name).length !== 1) return unknown(`parameter ${fn.name}.${fn.parameters[position]} has an open caller boundary`);
    const evidence = [];
    let references = 0;
    let calls = 0;
    for (const match of mask.matchAll(new RegExp(`\\b${escape(fn.name)}\\b`, "gu"))) {
      if (/\bfn\s*$/u.test(mask.slice(0, match.index))) continue;
      references += 1;
      const after = mask.slice(match.index + fn.name.length).match(/^\s*\(/u);
      if (!after || /[.:]/u.test(mask[match.index - 1] ?? "")) {
        const owner = callbackOwner(file, match.index);
        if (owner) {
          calls += 1;
          evidence.push(callbackTargets(file, owner.fn, owner.parameter, position, seen));
        }
        continue;
      }
      const open = match.index + fn.name.length + after[0].length - 1;
      const args = parts(mask, open + 1, closeAt(mask, open));
      let range = args[position];
      if (!range) return unknown(`incomplete caller arguments for ${fn.name}`);
      if (head) {
        const text = source.slice(...range);
        const array = text.search(/\[/u);
        if (array < 0 || !/^\s*&?\s*$/u.test(text.slice(0, array))) return unknown(`dynamic argv head in caller of ${fn.name}`);
        const offset = range[0] + array;
        range = parts(mask, offset + 1, closeAt(mask, offset))[0];
      }
      calls += 1;
      evidence.push(resolve(file, ...range, seen));
    }
    if (calls === 0 || calls !== references) return unknown(`non-call or unresolved references to ${fn.name} prevent a closed caller proof`);
    return union(evidence);
  }
  function callbackOwner(file, offset) {
    const { mask, functions } = model(file);
    for (let open = offset - 1; open >= 0; open -= 1) {
      if (mask[open] !== "(" || closeAt(mask, open) < offset) continue;
      const name = mask.slice(0, open).match(/\b(\w+)\s*$/u)?.[1];
      const candidates = functions.filter((fn) => fn.name === name && fn.open !== open);
      if (candidates.length !== 1) return null;
      const position = parts(mask, open + 1, closeAt(mask, open)).findIndex(([left, right]) => left <= offset && offset < right);
      return { fn: candidates[0], parameter: candidates[0].parameters[position] };
    }
    return null;
  }
  function callbackTargets(file, fn, parameter, position, seen) {
    const key = `${file}:callback:${fn.start}:${parameter}:${position}`;
    if (!parameter || seen.has(key) || seen.size > 24) return unknown("unresolved callback provenance");
    const next = new Set([...seen, key]);
    const { mask } = model(file);
    const values = [];
    for (const match of mask.slice(fn.bodyStart + 1, fn.bodyEnd).matchAll(new RegExp(`\\b${escape(parameter)}\\b`, "gu"))) {
      const offset = fn.bodyStart + 1 + match.index;
      const after = mask.slice(offset + parameter.length).match(/^\s*\(/u);
      if (after) {
        const open = offset + parameter.length + after[0].length - 1;
        const range = parts(mask, open + 1, closeAt(mask, open))[position];
        values.push(range ? resolve(file, ...range, next) : unknown("missing callback argument"));
      } else {
        const owner = callbackOwner(file, offset);
        values.push(owner ? callbackTargets(file, owner.fn, owner.parameter, position, next) : unknown("callback escapes the source-proven call graph"));
      }
    }
    return values.length ? union(values) : unknown("callback has no source-proven invocation");
  }
  return { resolve, api, model, reference, known, unknown, union, closeAt, parts };
}
