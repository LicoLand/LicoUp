#!/usr/bin/env node
import { spawn } from "node:child_process";
import { chmodSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { TextDecoder } from "node:util";
import { adapterIds, assertAdapterAndScenario, isWithin, scenarioClasses, schemaVersion, sha256 } from "./shared.mjs";

function usage() {
  throw new Error(`usage: record.mjs --adapter <${adapterIds.join("|")}> --scenario <${scenarioClasses.join("|")}> --output <private-raw.json> -- <command> [args...]`);
}

const separator = process.argv.indexOf("--");
if (separator < 0) usage();
const options = process.argv.slice(2, separator);
const commandLine = process.argv.slice(separator + 1);
const option = (name) => {
  const index = options.indexOf(name);
  return index >= 0 ? options[index + 1] : undefined;
};
const adapterId = option("--adapter");
const scenario = option("--scenario");
const output = option("--output");
if (!adapterId || !scenario || !output || commandLine.length === 0) usage();
assertAdapterAndScenario(adapterId, scenario);
if (process.env.LICO_TRANSCRIPT_SYNTHETIC_ACK !== "1") {
  throw new Error("synthetic_ack_required:set_LICO_TRANSCRIPT_SYNTHETIC_ACK=1_only_for_a_synthetic_engineering_task");
}

const repositoryRoot = realpathSync(resolve(import.meta.dirname, "../../.."));
const outputPath = resolve(output);
if (isWithin(repositoryRoot, outputPath)) {
  throw new Error("raw_transcript_must_be_outside_repository");
}
mkdirSync(dirname(outputPath), { recursive: true, mode: 0o700 });

const started = process.hrtime.bigint();
const decoders = new Map();
const frames = [];
let index = 0;
const capture = (direction, channel, chunk) => {
  let payload;
  try {
    const decoderKey = `${direction}:${channel}`;
    const decoder = decoders.get(decoderKey) || new TextDecoder("utf-8", { fatal: true });
    decoders.set(decoderKey, decoder);
    payload = decoder.decode(chunk, { stream: true });
  } catch {
    throw new Error("protocol_frame_is_not_utf8");
  }
  frames.push({
    index: index++,
    atMicros: Number((process.hrtime.bigint() - started) / 1000n),
    direction,
    channel,
    payload,
    projection: [],
  });
};

const [command, ...args] = commandLine;
const child = spawn(command, args, {
  cwd: process.cwd(),
  env: process.env,
  shell: false,
  stdio: ["pipe", "pipe", "pipe"],
});
child.stdout.on("data", (chunk) => {
  capture("agent-to-client", "stdout", chunk);
  process.stdout.write(chunk);
});
child.stderr.on("data", (chunk) => {
  capture("agent-to-client", "stderr", chunk);
  process.stderr.write(chunk);
});
process.stdin.on("data", (chunk) => {
  capture("client-to-agent", "stdin", chunk);
  child.stdin.write(chunk);
});
process.stdin.on("end", () => child.stdin.end());

const exit = await new Promise((resolveExit, reject) => {
  child.once("error", reject);
  child.once("exit", (code, signal) => resolveExit({ code, signal }));
});
const raw = {
  schemaVersion,
  adapterId,
  scenario,
  provenance: {
    source: "developer-run-real-agent-session",
    taskContent: "synthetic-engineering-only",
    redacted: false,
    humanReviewed: false,
  },
  invocation: { command, args, cwd: process.cwd() },
  frames,
  exit,
};
const serialized = `${JSON.stringify(raw, null, 2)}\n`;
writeFileSync(outputPath, serialized, { mode: 0o600, flag: "wx" });
chmodSync(outputPath, 0o600);
process.stderr.write(`raw transcript written outside repository; sha256:${sha256(serialized)}\n`);
process.exitCode = exit.code ?? (exit.signal ? 1 : 0);
