#!/usr/bin/env node

/**
 * Antigravity same-session sequential conversation gate.
 *
 * Implementation authority: client-same-session-conversation-gate.mjs
 * Adapter ownership: crates/licoup-native/src/platform/antigravity_driver/
 */

import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runSameSessionConversationGate } from "./client-same-session-conversation-gate.mjs";

async function main() {
  let output;
  try {
    output = await runSameSessionConversationGate([
      "--agent",
      "antigravity",
      ...process.argv.slice(2),
    ]);
  } catch (error) {
    const reasonCode = /^[a-z0-9_-]+$/u.test(error?.message || "")
      ? error.message
      : "unexpected_failure";
    output = {
      status: "failed",
      gateKind: "antigravity-same-session-sequential-v1",
      agent: "antigravity",
      reasonCode,
      sendEnabled: false,
    };
  }
  process.stdout.write(`${JSON.stringify(output)}\n`);
  if (output.status !== "passed") process.exitCode = 1;
}

const invoked = process.argv[1]
  && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invoked) {
  await main();
}
