#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const requiredVerifierScripts = [
  "repo:client-boundary",
  "client:verify",
  "client:verify:architecture",
  "client:verify:plan",
  "client:contracts:test",
  "client:native:smoke",
  "client:verify:update-release",
  "client:verify:windows-file-security",
  "client:runtime:package",
  "client:verify:state-store",
  "client:verify:targets",
  "client:verify:config-writes",
  "client:verify:pairing-skill-cli",
  "client:verify:skill-installer",
  "client:verify:mcp-plugins",
  "client:verify:thin-forwarding",
  "client:verify:agent-usage"
];
const firstTargets = [
  "Antigravity",
  "Claude Code",
  "Codex",
  "Cursor",
  "GitHub Copilot",
  "Hermes Agent",
  "Kilo Code",
  "OpenClaw",
  "OpenCode"
];
const sevenModules = ["Agents", "MCP Plugins", "Skill Hub", "Model Forwarding", "Mobile Relay", "Activity", "Settings"];

const failures = [];

function assert(condition, message) {
  if (!condition) {
    failures.push(message);
  }
}

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function readJson(relativePath) {
  return JSON.parse(await readText(relativePath));
}

function linesContaining(source, token) {
  return source
    .split(/\r?\n/)
    .map((line, index) => ({ line, number: index + 1 }))
    .filter((item) => item.line.includes(token));
}

const packageJson = await readJson("package.json");
const scripts = packageJson.scripts || {};
assert(packageJson.private === true, "package.json must keep the client repository private");
assert(packageJson.license === "UNLICENSED", "package.json must keep license=UNLICENSED for the proprietary client");
for (const scriptName of requiredVerifierScripts) {
  assert(Boolean(scripts[scriptName]), `package.json must define ${scriptName}`);
}
for (const scriptName of [
  "repo:client-boundary",
  "client:get",
  "client:package:plan",
  "client:runtime:package",
  "client:run:macos",
  "client:icon:macos",
  "client:build:macos",
  "client:build:linux",
  "client:build:windows",
  "client:build:android",
  "client:install:macos",
  "client:analyze",
  "client:test",
  "client:native:test"
]) {
  assert(Boolean(scripts[scriptName]), `package.json must define ${scriptName}`);
}
const verifyRunner = await readText("tools/run-client-verify.mjs");
for (const scriptName of [
  "repo:client-boundary",
  "client:verify:plan",
  "client:verify:architecture",
  "client:verify:agent-usage",
  "client:contracts:test",
  "client:runtime:package",
  "client:analyze",
  "client:test",
  "client:native:test",
  "client:native:smoke"
]) {
  assert(verifyRunner.includes(scriptName), `tools/run-client-verify.mjs must include ${scriptName}`);
}

const architecture = await readText("docs/functionality/CLIENT-DESKTOP.md");
const testFramework = await readText("docs/RUNBOOK.md");
const readme = await readText("README.md");

for (const target of firstTargets) {
  assert(architecture.includes(target), `CLIENT_ARCHITECTURE must include target ${target}`);
}
for (const moduleName of sevenModules) {
  assert(architecture.includes(moduleName), `CLIENT_ARCHITECTURE must include module ${moduleName}`);
}
for (const scriptName of requiredVerifierScripts) {
  assert(testFramework.includes(scriptName) || readme.includes(scriptName),
    `RUNBOOK or README must document ${scriptName}`);
}
assert(readme.includes("Lico-Arc is the private repository"), "README must describe Lico-Arc as the private client repository");
assert(readme.includes("Public gateway-facing work stays in `LicoLite/LicoLite`"),
  "README must keep the public/private repository boundary explicit");

const protocolLines = linesContaining(architecture, "protocol_deferred");
assert(protocolLines.length > 0, "CLIENT_ARCHITECTURE must preserve protocol_deferred boundary language");
for (const item of protocolLines) {
  assert(!/\bdone\b|已完成|完成落地/.test(item.line), `CLIENT_ARCHITECTURE must not mark protocol_deferred as done at line ${item.number}`);
}

const packaging = await readJson("apps/desktop/packaging.modules.json");
assert(packaging.packageProfile === "future-client", "packaging.modules.json must default to future-client profile");
assert(!JSON.stringify(packaging).toLowerCase().includes("legacy"), "packaging.modules.json must not retain legacy modules");

if (failures.length > 0) {
  console.error(JSON.stringify({ ok: false, failures }, null, 2));
  process.exit(1);
}

console.log(JSON.stringify({
  ok: true,
  verifierScripts: requiredVerifierScripts,
  targets: firstTargets,
  modules: sevenModules,
  protocolDeferredReferences: protocolLines.length
}, null, 2));
