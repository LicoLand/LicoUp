#!/usr/bin/env node
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { CLIENT_COMPATIBILITY_ENTRIES } from "../regression/client-regression-entries/index.mjs";

export function parseEnvironmentProbeArgs(argv) {
  let kind = "";
  let id = "";
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!["--platform", "--agent"].includes(argument) || !argv[index + 1]) {
      throw new Error("environment_probe_argument_invalid");
    }
    if (kind) throw new Error("environment_probe_selector_conflict");
    kind = argument.slice(2);
    id = argv[++index].trim().toLowerCase();
  }
  if (!kind || !id) throw new Error("environment_probe_selector_missing");
  return Object.freeze({ kind, id });
}

export async function probeClientRegressionEnvironment({ kind, id }) {
  const entry = CLIENT_COMPATIBILITY_ENTRIES.find((candidate) =>
    candidate.kind === kind && candidate.id === id);
  if (!entry) throw new Error("environment_probe_target_unknown");
  const result = await entry.probe();
  return Object.freeze({
    schemaVersion: "licoup.client-regression-environment.v1",
    kind,
    id,
    eligible: result.eligible === true,
    reason: result.reason || null,
  });
}

export async function main(argv = process.argv.slice(2), output = process.stdout, error = process.stderr) {
  try {
    output.write(`${JSON.stringify(await probeClientRegressionEnvironment(parseEnvironmentProbeArgs(argv)))}\n`);
    return 0;
  } catch (failure) {
    error.write(`${JSON.stringify({
      schemaVersion: "licoup.client-regression-environment.v1",
      status: "failed",
      reason: /^[a-z0-9_-]+$/u.test(failure?.message || "")
        ? failure.message
        : "environment_probe_failed",
    })}\n`);
    return 2;
  }
}

const invoked = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invoked) process.exitCode = await main();
