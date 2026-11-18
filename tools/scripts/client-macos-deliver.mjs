#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  CLIENT_GATE_SCHEMA_VERSION,
  CLIENT_RELEASE_TARGETS,
} from "./client-gate-policy.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

function fail(message) {
  throw new Error(message);
}

function readJson(relativePath) {
  return JSON.parse(readFileSync(path.join(repoRoot, relativePath), "utf8"));
}

const localDeliveryAdapters = Object.freeze({
  macos: Object.freeze({
    install: Object.freeze([
      "npm", "run", "client:install:macos", "--", "--launch-installed",
    ]),
  }),
});

export function runLocalClientDelivery({
  host = process.platform,
  architecture = process.arch,
  releaseCatalog = readJson("tools/client-release-targets.json"),
  releaseTargets = CLIENT_RELEASE_TARGETS,
  spawnImpl = spawnSync,
  output = process.stdout,
} = {}) {
  const hostId = `${host}-${architecture}`;
  const target = releaseCatalog.targets?.find((candidate) =>
    releaseTargets[candidate.id]?.localOnly === true &&
    candidate.packageBuildSupported === true &&
    candidate.releaseSupported === true && candidate.buildHost === hostId);
  const adapter = target ? localDeliveryAdapters[target.platform] : null;
  if (!target || !adapter) fail("local client delivery target is unsupported on this host");
  const stages = [
    Object.freeze({
      id: "build",
      argv: Object.freeze(["npm", "run", "client:build", "--", "--platform", target.platform]),
    }),
    Object.freeze({ id: "install-and-launch", argv: adapter.install }),
  ];
  for (const stage of stages) {
    const [command, ...args] = stage.argv;
    const result = spawnImpl(command, args, {
      cwd: repoRoot,
      env: process.env,
      shell: false,
      stdio: "inherit",
    });
    if (result.error || result.status !== 0) {
      output.write(`${JSON.stringify({
        ok: false,
        schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
        target: "delivery",
        stage: stage.id,
        reason: `delivery_${stage.id.replaceAll("-", "_")}_failed`,
      })}\n`);
      return 1;
    }
  }
  output.write(`${JSON.stringify({
    ok: true,
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    target: "delivery",
    deliveryTargetId: target.id,
    platform: target.platform,
    built: true,
    installed: true,
    launchRequested: true,
    uiInspected: false,
    published: false,
  })}\n`);
  return 0;
}

export function main() {
  process.exitCode = runLocalClientDelivery();
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error?.message || error}\n`);
    process.exitCode = 1;
  }
}
