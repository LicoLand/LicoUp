#!/usr/bin/env node
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { loadClientReleaseTargetCatalog } from "./lib/client-release-targets.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const catalogPath = path.join(repoRoot, "tools", "client-support-matrix.json");
const reportPath = path.join(repoRoot, "docs", "releases", "client-support-matrix.md");
const allowedStatuses = new Set(["supported", "preview", "deferred", "unsupported", "unverified"]);

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

export function validateClientSupportMatrix(raw) {
  requireValue(raw?.schema === "licolite.client-support-matrix", "unexpected client support matrix schema");
  requireValue(Array.isArray(raw.services) && raw.services.length > 0, "support matrix services are empty");
  requireValue(Array.isArray(raw.targets) && raw.targets.length > 0, "support matrix targets are empty");
  const serviceIds = new Set();
  for (const service of raw.services) {
    requireValue(service?.id && service?.label && service?.category, "support matrix service fields are required");
    requireValue(!serviceIds.has(service.id), `duplicate support matrix service: ${service.id}`);
    serviceIds.add(service.id);
    requireValue(typeof service.releaseBlocking === "boolean", `service ${service.id} must declare releaseBlocking`);
    requireValue(service.category !== "external-service" || service.releaseBlocking === false,
      `external service ${service.id} must not block a client release`);
  }
  const releaseCatalog = loadClientReleaseTargetCatalog();
  const releaseTargetIds = releaseCatalog.targets.map((target) => target.id);
  const matrixTargetIds = raw.targets.map((target) => target.targetId);
  requireValue(new Set(matrixTargetIds).size === matrixTargetIds.length, "support matrix target ids must be unique");
  requireValue(JSON.stringify([...matrixTargetIds].sort()) === JSON.stringify([...releaseTargetIds].sort()),
    "support matrix must contain exactly one row for every release target");
  const rows = raw.targets.map((target) => {
    const defaults = raw.defaults?.[target.profile];
    requireValue(defaults && typeof defaults === "object", `unknown support matrix profile: ${target.profile}`);
    const statuses = { ...defaults, ...(target.overrides || {}) };
    requireValue(Object.keys(statuses).every((id) => serviceIds.has(id)),
      `target ${target.targetId} contains an unknown service`);
    for (const id of serviceIds) {
      requireValue(allowedStatuses.has(statuses[id]), `target ${target.targetId} has invalid status for ${id}`);
    }
    return { targetId: target.targetId, statuses };
  });
  const android = rows.find((row) => row.targetId === "android-arm64");
  requireValue(android?.statuses["gemini-local-oauth"] === "deferred",
    "Android Gemini local OAuth must remain deferred until a verified optional integration is selected");
  requireValue(android?.statuses["kimi-local-oauth"] === "deferred",
    "Android Kimi local OAuth must remain deferred until a verified optional integration is selected");
  return { services: raw.services, releaseCatalog, rows };
}

export function selectedReleaseBlockingSupportReady(validated, selectedTargetIds) {
  const ids = Array.isArray(selectedTargetIds) ? selectedTargetIds : [];
  if (ids.length === 0 || new Set(ids).size !== ids.length) return false;
  const rows = new Map(validated.rows.map((row) => [row.targetId, row]));
  const blockingServiceIds = validated.services
    .filter((service) => service.releaseBlocking === true)
    .map((service) => service.id);
  return blockingServiceIds.length > 0 && ids.every((targetId) => {
    const row = rows.get(targetId);
    return row && blockingServiceIds.every((serviceId) =>
      row.statuses[serviceId] === "supported");
  });
}

function renderReport(validated, productVersion) {
  const targetById = new Map(validated.releaseCatalog.targets.map((target) => [target.id, target]));
  const lines = [
    "# Lico Arc Client Support Matrix",
    "",
    `Product version: \`${productVersion}\``,
    "",
    "This report is generated from the release-target and capability catalogs. Optional external services never block a client release. `preview`, `deferred`, `unsupported`, and `unverified` are not support claims.",
    "",
    "| Target | Build capability | Current release closure | " + validated.services.map((service) => service.label).join(" | ") + " |",
    "| --- | --- | --- | " + validated.services.map(() => "---").join(" | ") + " |"
  ];
  for (const row of validated.rows) {
    const target = targetById.get(row.targetId);
    lines.push(`| ${row.targetId} | ${target.supported ? "available" : "unavailable"} | ${target.releaseSupported ? "selected-capable" : "not-in-current-closure"} | ${validated.services.map((service) => row.statuses[service.id]).join(" | ")} |`);
  }
  lines.push(
    "",
    "## Release interpretation",
    "",
    "- `Build capability` means a builder exists; it is not a release-readiness claim. Only targets marked `selected-capable` may enter the current local-install release closure.",
    "- The first release closure authority is macOS arm64, Android arm64, and Linux glibc arm64. Other build-capable targets remain outside this closure and fail closed if selected.",
    "- External-service rows disclose current integration support only. They are optional and never participate in client release readiness.",
    "- Gemini and Kimi local OAuth are deferred on Android. Their incomplete descriptors remain fail-closed and are outside the current Android release scope.",
    "- Conversation voice input is visible as deferred and is not a supported release capability.",
    ""
  );
  return lines.join("\n");
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "")) {
  const action = process.argv[2] || "check";
  const productVersion = readJson(path.join(repoRoot, "tools", "client-version.json")).productVersion;
  const validated = validateClientSupportMatrix(readJson(catalogPath));
  const report = renderReport(validated, productVersion);
  if (action === "sync") {
    mkdirSync(path.dirname(reportPath), { recursive: true });
    writeFileSync(reportPath, report, "utf8");
  } else if (action === "check") {
    requireValue(readFileSync(reportPath, "utf8") === report,
      "client support matrix report is stale; run npm run client:support-matrix:sync");
  } else {
    throw new Error(`unknown client support matrix action: ${action}`);
  }
  console.log(JSON.stringify({ ok: true, productVersion, targetCount: validated.rows.length, serviceCount: validated.services.length }));
}
