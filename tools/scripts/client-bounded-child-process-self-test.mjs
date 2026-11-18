#!/usr/bin/env node

import { spawn } from "node:child_process";
import process from "node:process";
import { stopChildProcess } from "./lib/bounded-child-process.mjs";

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

async function readyChild(source) {
  const child = spawn(process.execPath, ["-e", source], {
    stdio: ["ignore", "pipe", "ignore"],
  });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("child_ready_timeout")), 5_000);
    child.once("error", reject);
    child.stdout.once("data", () => {
      clearTimeout(timeout);
      resolve();
    });
  });
  return child;
}

for (let index = 0; index < 20; index += 1) {
  const child = await readyChild(
    "process.stdout.write('ready\\n');setInterval(()=>{},1000)",
  );
  requireValue(await stopChildProcess(child, { gracefulTimeoutMs: 1_000 }),
    "immediate_sigterm_exit_was_lost");
}

const stubborn = await readyChild(
  "process.on('SIGTERM',()=>{});process.stdout.write('ready\\n');setInterval(()=>{},1000)",
);
requireValue(await stopChildProcess(stubborn, {
  gracefulTimeoutMs: 50,
  forceTimeoutMs: 1_000,
}), "sigkill_fallback_failed");

const exited = spawn(process.execPath, ["-e", ""], { stdio: "ignore" });
await new Promise((resolve) => exited.once("exit", resolve));
requireValue(await stopChildProcess(exited, { gracefulTimeoutMs: 100 }),
  "already_exited_child_was_rejected");

console.log(JSON.stringify({
  ok: true,
  caseCount: 22,
  fastExitRaceCovered: true,
  forcedTerminationCovered: true,
  rawRuntimeDataIncluded: false,
  privatePathsIncluded: false,
}));
