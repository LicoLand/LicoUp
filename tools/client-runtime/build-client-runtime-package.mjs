#!/usr/bin/env node
import {
  copyFileSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const outputRoot = path.join(repoRoot, "build", "client-runtime", "client-local-runtime");
const runtimeSourceRoot = path.join(outputRoot, "source");
const packagingPath = path.join(repoRoot, "apps", "desktop", "packaging.modules.json");
const runtimeScript = path.join(repoRoot, "tools", "client-runtime", "start-client-runtime.mjs");

function readJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function writeJson(file, value) {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function enabledFeatures(packaging) {
  return Object.entries(packaging.modules || {})
    .filter(([, moduleConfig]) => moduleConfig.enabled !== false)
    .map(([id, moduleConfig]) => ({
      id,
      label: moduleConfig.label || id,
      category: moduleConfig.category || "runtime",
      packaging: moduleConfig.packaging || "runtime-capability",
      required: moduleConfig.required === true,
      platforms: Array.isArray(moduleConfig.platforms) ? moduleConfig.platforms : [],
      requires: Array.isArray(moduleConfig.requires) ? moduleConfig.requires : []
    }))
    .sort((left, right) => left.id.localeCompare(right.id));
}

const packaging = readJson(packagingPath);
const activeFeatures = enabledFeatures(packaging);
const activeFeatureIds = activeFeatures.map((feature) => feature.id);
const generatedAtUnix = Math.floor(Date.now() / 1000);

rmSync(runtimeSourceRoot, { recursive: true, force: true });
mkdirSync(path.join(runtimeSourceRoot, "runtime"), { recursive: true });
copyFileSync(runtimeScript, path.join(runtimeSourceRoot, "runtime", "start-client-runtime.mjs"));

writeJson(path.join(runtimeSourceRoot, "feature-profile", "feature-profile.json"), {
  schemaVersion: "v0.0.1:client-runtime:feature-profile-1",
  runtimeKind: "client-local",
  edition: "client-local",
  generatedAtUnix,
  features: activeFeatureIds,
  activeFeatureIds,
  activeFeatures
});

writeJson(path.join(runtimeSourceRoot, "feature-profile", "active-features.json"), {
  schemaVersion: "v0.0.1:client-runtime:active-features-1",
  runtimeKind: "client-local",
  edition: "client-local",
  generatedAtUnix,
  activeFeatureIds,
  activeFeatures
});

writeJson(path.join(runtimeSourceRoot, "feature-profile", "disabled-features.json"), {
  schemaVersion: "v0.0.1:client-runtime:disabled-features-1",
  runtimeKind: "client-local",
  edition: "client-local",
  generatedAtUnix,
  disabledFeatureIds: [],
  disabledFeatures: []
});

writeJson(path.join(runtimeSourceRoot, "runtime-plan", "runtime-plan.json"), {
  schemaVersion: "v0.0.1:client-runtime:runtime-plan-1",
  runtimeKind: "client-local",
  edition: "client-local",
  generatedAtUnix,
  featureRuntime: {
    edition: "client-local",
    activeFeatureIds,
    activeFeatures,
    disabledFeatureIds: [],
    disabledFeatures: []
  },
  packagePlan: {
    runtimeModules: activeFeatureIds,
    mounts: [],
    eventTopics: []
  }
});

process.stdout.write(`${JSON.stringify({
  ok: true,
  runtimeSourceRoot,
  activeFeatureIds
}, null, 2)}\n`);
