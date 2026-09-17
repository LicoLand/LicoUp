#!/usr/bin/env node
import process from "node:process";
import path from "node:path";
import fs from "node:fs";
import { inspect } from "../lib/probe.mjs";
import { plan } from "../lib/plan.mjs";
import { convert } from "../lib/convert.mjs";
import { resume } from "../lib/resume.mjs";
import { buildPackageArtifact } from "../lib/package-manifest.mjs";

function readOptionValue(argv, i, flag) {
  const value = argv[i + 1];
  if (value === undefined || value.startsWith("--")) {
    throw new Error(`Missing value for ${flag}`);
  }
  return value;
}

function printUsage() {
  console.log(`
LicoUp Data Migration CLI (licoup-migrate)

Usage:
  licoup-migrate inspect [--data-root <path>] [--format json|text]
  licoup-migrate plan    [--data-root <path>] [--target <version|profile>] [--format json|text]
  licoup-migrate convert [--data-root <path>] [--target <version|profile>] [--dry-run] [--format json|text]
  licoup-migrate resume  [--data-root <path>] [--format json|text]
  licoup-migrate package [--out-dir <path>]
  licoup-migrate --help | -h
  licoup-migrate --version | -v

Commands:
  inspect   Probe actual storage on disk and report current schema versions across domains.
  plan      Calculate forward or backward migration edges to reach target format.
  convert   Execute atomic domain conversions, verify postconditions, and update markers/ledger.
  resume    Resume an interrupted migration from durable progress journal.
  package   Build standalone distribution tarball and release manifest.

Options:
  --data-root <path>     Path to the client data root (defaults to LICO_DATA_ROOT or current directory).
  --target <profile>     Target version or format profile (e.g. v0.1.0, v0.2.0, v0.3.0, latest).
  --dry-run              Plan and validate without mutating stores on disk.
  --format <json|text>   Output formatting (default: text).
`);
}

function parseArgs(argv) {
  const args = {
    command: null,
    dataRoot: process.env.LICO_DATA_ROOT || null,
    target: "latest",
    dryRun: false,
    format: "text",
    outDir: null,
  };

  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      args.help = true;
    } else if (arg === "--version" || arg === "-v") {
      args.version = true;
    } else if (arg === "--dry-run") {
      args.dryRun = true;
    } else if (arg === "--data-root") {
      args.dataRoot = readOptionValue(argv, i, arg); i++;
    } else if (arg === "--target") {
      args.target = readOptionValue(argv, i, arg); i++;
    } else if (arg === "--format") {
      args.format = readOptionValue(argv, i, arg); i++;
    } else if (arg === "--out-dir") {
      args.outDir = readOptionValue(argv, i, arg); i++;
    } else if (!arg.startsWith("--")) {
      positional.push(arg);
    } else {
      throw new Error(`Unknown option: ${arg}`);
    }
  }

  if (args.format !== "json" && args.format !== "text") {
    throw new Error(`Unknown format: "${args.format}" (expected json or text)`);
  }

  args.command = positional[0] || null;
  return args;
}

function resolveDataRoot(providedPath) {
  if (providedPath) {
    return path.resolve(providedPath);
  }
  if (process.env.LICO_DATA_ROOT) {
    return path.resolve(process.env.LICO_DATA_ROOT);
  }
  return process.cwd();
}

function formatTextInspect(result) {
  const lines = [
    `Data Root: ${result.dataRoot}`,
    `Inspected At: ${result.inspectedAt}`,
    `Ledger: ${result.ledger.present ? `Admitted product version: ${result.ledger.highestAdmittedProductVersion} (Frontier: ${result.ledger.frontierId})` : "Not initialized"}`,
    `Pending Journal: ${result.hasPendingJournal ? "YES (run 'resume' to complete)" : "No"}`,
    `Preserved Extensions: ${result.preservations.length} domains`,
    "",
    "Domain Schema Levels:",
    "---------------------",
  ];

  for (const [domainId, info] of Object.entries(result.domains)) {
    const storeStatus = info.storePresent ? `v${info.storeVersion}` : "absent (v0)";
    const markerStatus = info.markerVersion !== null ? `marker=v${info.markerVersion}` : "no-marker";
    lines.push(`  ${domainId.padEnd(28)}: store=${storeStatus.padEnd(12)} ${markerStatus.padEnd(14)} target=v${info.targetSchemaVersion}`);
  }
  return lines.join("\n");
}

function formatTextPlan(result) {
  const lines = [
    `Target: ${result.targetProfileLabel} (v${result.targetVersion})`,
    `Direction: ${result.direction.toUpperCase()}`,
    `Current Admitted: v${result.currentHighestAdmittedVersion} -> Target: v${result.targetHighestAdmittedVersion}`,
    "",
  ];

  if (result.isNoOp) {
    lines.push("No store migrations required (all stores match target schema).");
  } else {
    lines.push(`Planned Steps (${result.steps.length}):`);
    for (const s of result.steps) {
      lines.push(`  [${s.direction.toUpperCase()}] ${s.domainId}: v${s.fromVersion} -> v${s.toVersion} (${s.stepId})`);
    }
  }

  if (result.preservationsPlanned.length > 0) {
    lines.push("");
    lines.push(`Preservations Required (${result.preservationsPlanned.length}):`);
    for (const p of result.preservationsPlanned) {
      lines.push(`  * ${p.domainId}: v${p.fromVersion} -> v${p.toVersion} (${p.note})`);
    }
  }

  return lines.join("\n");
}

function formatTextConvert(result) {
  const lines = [
    `Status: ${result.status.toUpperCase()}`,
    `Target Product Version: v${result.targetVersion}`,
    `Direction: ${result.direction}`,
    `Converted Steps: ${result.convertedSteps.length}`,
  ];

  for (const s of result.convertedSteps) {
    lines.push(`  ✔ ${s.domainId}: v${s.fromVersion} -> v${s.toVersion} (${s.details})`);
  }

  if (result.preservations && result.preservations.length > 0) {
    lines.push("");
    lines.push(`Preserved Extensions (${result.preservations.length}):`);
    for (const p of result.preservations) {
      lines.push(`  * ${p.domainId}: from v${p.fromVersion} to v${p.targetVersion} (${p.notes})`);
    }
  }

  if (result.pendingAuthorizationDomains && result.pendingAuthorizationDomains.length > 0) {
    lines.push("");
    lines.push(`Pending Authorization (${result.pendingAuthorizationDomains.length}):`);
    for (const d of result.pendingAuthorizationDomains) {
      lines.push(`  * ${d}: requires the platform credential custody bridge; store left untouched`);
    }
  }

  return lines.join("\n");
}

function main() {
  const argv = process.argv.slice(2);
  let args;
  try {
    args = parseArgs(argv);
  } catch (err) {
    console.error(`Error: ${err.message}. Run 'licoup-migrate --help' for usage.`);
    process.exit(1);
  }

  if (args.help || (!args.command && !args.version)) {
    printUsage();
    process.exit(0);
  }

  if (args.version) {
    const pkg = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));
    console.log(`licoup-data-migration v${pkg.version}`);
    process.exit(0);
  }

  try {
    switch (args.command) {
      case "inspect": {
        const root = resolveDataRoot(args.dataRoot);
        const result = inspect(root);
        if (args.format === "json") {
          console.log(JSON.stringify(result, null, 2));
        } else {
          console.log(formatTextInspect(result));
        }
        break;
      }
      case "plan": {
        const root = resolveDataRoot(args.dataRoot);
        const result = plan(root, args.target);
        if (args.format === "json") {
          console.log(JSON.stringify(result, null, 2));
        } else {
          console.log(formatTextPlan(result));
        }
        break;
      }
      case "convert": {
        const root = resolveDataRoot(args.dataRoot);
        const result = convert(root, args.target, { dryRun: args.dryRun });
        if (args.format === "json") {
          console.log(JSON.stringify(result, null, 2));
        } else {
          console.log(formatTextConvert(result));
        }
        break;
      }
      case "resume": {
        const root = resolveDataRoot(args.dataRoot);
        const result = resume(root);
        if (args.format === "json") {
          console.log(JSON.stringify(result, null, 2));
        } else {
          console.log(`Resume result: ${result.status}`);
          if (result.resumedSteps) {
            for (const s of result.resumedSteps) {
              console.log(`  * ${s.domainId}: ${s.status} (v${s.version})`);
            }
          }
          if (result.pendingAuthorizationDomains) {
            for (const d of result.pendingAuthorizationDomains) {
              console.log(`  * ${d}: pending authorization (platform credential custody bridge)`);
            }
          }
        }
        break;
      }
      case "package": {
        const result = buildPackageArtifact({ outDir: args.outDir });
        if (args.format === "json") {
          console.log(JSON.stringify(result.manifest, null, 2));
        } else {
          console.log(`Package built: ${result.tarballPath}`);
          console.log(`Manifest:     ${result.manifestPath}`);
        }
        break;
      }
      default:
        console.error(`Unknown command: "${args.command}". Run 'licoup-migrate --help' for usage.`);
        process.exit(1);
    }
  } catch (err) {
    if (args.format === "json") {
      console.error(JSON.stringify({ error: err.message, stack: err.stack }));
    } else {
      console.error(`Error: ${err.message}`);
    }
    process.exit(1);
  }
}

main();
