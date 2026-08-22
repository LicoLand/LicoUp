#!/usr/bin/env node

import process from "node:process";

import { main as runClientGate } from "../client-gate.mjs";

try {
  runClientGate(["run", "source"]);
} catch (error) {
  process.stderr.write(`${error?.message || error}\n`);
  process.exitCode = 1;
}
