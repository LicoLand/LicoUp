#!/usr/bin/env node
import { sanitizeError } from "./lib/sanitize-error.mjs";
import { main } from "./client-cli-vm/run.mjs";

try {
  main();
} catch (error) {
  console.error(sanitizeError(error));
  process.exitCode = 1;
}
