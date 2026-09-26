#!/usr/bin/env node

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

// Surfaces that dispatch, admit, translate or settle a native Agent turn.
const guardedSurfaces = [
  "crates/licoup-native/src/domain/assistant_continuity",
  "crates/licoup-native/src/domain/client_conversation",
  "crates/licoup-native/src/platform",
  "crates/licoup-conversation/src/continuity",
  "apps/desktop/lib/src/platform",
  "apps/desktop/lib/src/protocol",
];

const scanExtensions = [".rs", ".dart", ".mjs", ".ts"];

// A reply-format imposition names one of these keys on a native Agent turn.
// Quoted matches only: reading an embedded object stays allowed.
const forbiddenKeys = [
  "outputSchema",
  "output_schema",
  "responseFormat",
  "response_format",
  "responseSchema",
  "response_schema",
  "textFormat",
  "text_format",
  "jsonSchema",
  "json_schema",
  "json_object",
];

function collectFiles(directory) {
  const found = [];
  for (const entry of readdirSync(join(root, directory), {
    withFileTypes: true,
  })) {
    const path = `${directory}/${entry.name}`;
    if (entry.isDirectory()) {
      found.push(...collectFiles(path));
    } else if (scanExtensions.some((extension) => entry.name.endsWith(extension))) {
      found.push(path);
    }
  }
  return found;
}

function scanImposedFormats() {
  const violations = [];
  for (const directory of guardedSurfaces) {
    for (const path of collectFiles(directory)) {
      const source = readFileSync(join(root, path), "utf8");
      const lines = source.split(/\r?\n/u);
      for (const [index, line] of lines.entries()) {
        for (const key of forbiddenKeys) {
          if (!line.includes(`"${key}"`) && !line.includes(`'${key}'`)) continue;
          if (line.trimStart().startsWith("//") || line.trimStart().startsWith("*")) continue;
          violations.push({ path, line: index + 1, key });
        }
      }
    }
  }
  return violations;
}

try {
  const violations = scanImposedFormats();
  if (violations.length > 0) {
    const first = violations[0];
    process.stdout.write(`${JSON.stringify({
      schemaVersion: "licoup.agent-native-output.receipt.v1",
      ok: false,
      errorCode: "agent_native_output_format_imposed",
      path: relative(root, join(root, first.path)),
      line: first.line,
      key: first.key,
      violationCount: violations.length,
    })}\n`);
    process.exitCode = 1;
  } else {
    process.stdout.write(`${JSON.stringify({
      schemaVersion: "licoup.agent-native-output.receipt.v1",
      ok: true,
      surfaces: guardedSurfaces.length,
      forbiddenKeys: forbiddenKeys.length,
      imposedReplyFormats: 0,
    })}\n`);
  }
} catch (error) {
  process.stdout.write(`${JSON.stringify({
    schemaVersion: "licoup.agent-native-output.receipt.v1",
    ok: false,
    errorCode: "agent_native_output_check_failed",
  })}\n`);
  process.exitCode = 1;
}
