#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import process from "node:process";

const steps = [
  ["npm", ["run", "repo:client-boundary"]],
  ["npm", ["run", "client:runtime:package"]],
  ["npm", ["run", "client:get"]],
  ["npm", ["run", "client:verify:plan"]],
  ["npm", ["run", "client:verify:architecture"]],
  ["npm", ["run", "client:verify:agent-usage"]],
  ["npm", ["run", "client:contracts:test"]],
  ["npm", ["run", "client:verify:update-release"]],
  ["npm", ["run", "client:verify:windows-file-security"]],
  ["npm", ["run", "client:format:check"]],
  ["npm", ["run", "client:native:fmt:check"]],
  ["npm", ["run", "client:native:clippy"]],
  ["npm", ["run", "client:deps:audit"]],
  ["npm", ["run", "client:analyze"]],
  ["npm", ["run", "client:test"]],
  ["npm", ["run", "client:native:test"]],
  ["npm", ["run", "client:native:smoke"]]
];

for (const [command, args] of steps) {
  const label = `${command} ${args.join(" ")}`;
  console.log(`\n[client-verify] ${label}`);
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    env: process.env,
    shell: process.platform === "win32",
    stdio: "inherit"
  });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

console.log("\n[client-verify] ok");
