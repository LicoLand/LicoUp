#!/usr/bin/env node

/**
 * Cursor same-session sequential conversation gate (CLI --resume).
 *
 * Authority for Cursor send enablement: one create-chat, then three sequential
 * turns on the same sessionId with a non-empty result each. Does not launch
 * the release UI or product e2e LicoUp.app path.
 *
 * Implementation authority: client-same-session-conversation-gate.mjs
 */

import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runSameSessionConversationGate } from "./client-same-session-conversation-gate.mjs";

async function main() {
  let output;
  try {
    output = await runSameSessionConversationGate(["--agent", "cursor", ...process.argv.slice(2)]);
  } catch (error) {
    const reasonCode = /^[a-z0-9_-]+$/u.test(error?.message || "")
      ? error.message
      : "unexpected_failure";
    output = {
      status: "failed",
      gateKind: "cursor-same-session-sequential-v1",
      agent: "cursor",
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
