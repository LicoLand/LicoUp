#!/usr/bin/env node
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { CLIENT_MODULE_CATALOG } from "../regression/client-module-catalog.mjs";
import { executeClientModules } from "../regression/client-module-execution.mjs";
import {
  changedPathsSince,
  selectModulesById,
  selectModulesForChangedPaths,
  validateClientModuleCatalog,
} from "../regression/client-module-selection.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

const usage = `Usage:
  npm run client:regression:list
  npm run client:regression -- --module <module-id> [--module <module-id> ...]
  npm run client:regression -- --changed-from <git-revision>

Options:
  --list                 List independently runnable modules.
  --module <id>          Run one module; repeat the option or use comma-separated ids.
  --changed-from <ref>   Run only modules selected by changed repository paths.
  --dry-run              Print the selected module ids without executing commands.
  --help                 Show this help.
`;

function moduleIds(value) {
  const ids = String(value || "").split(",").filter(Boolean);
  if (ids.length === 0) throw new Error("module id is required");
  return ids;
}

export function parseClientModuleRegressionArgs(argv) {
  const options = {
    changedFrom: null,
    dryRun: false,
    help: false,
    list: false,
    moduleIds: [],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--list") {
      options.list = true;
    } else if (argument === "--dry-run") {
      options.dryRun = true;
    } else if (argument === "--help" || argument === "-h") {
      options.help = true;
    } else if (argument === "--module") {
      if (!argv[index + 1]) throw new Error("module id is required");
      options.moduleIds.push(...moduleIds(argv[index + 1]));
      index += 1;
    } else if (argument.startsWith("--module=")) {
      options.moduleIds.push(...moduleIds(argument.slice("--module=".length)));
    } else if (argument === "--changed-from") {
      if (!argv[index + 1] || options.changedFrom !== null) {
        throw new Error("exactly one changed-from revision is required");
      }
      options.changedFrom = argv[index + 1];
      index += 1;
    } else if (argument.startsWith("--changed-from=")) {
      if (options.changedFrom !== null) {
        throw new Error("exactly one changed-from revision is required");
      }
      options.changedFrom = argument.slice("--changed-from=".length);
    } else {
      throw new Error("unknown client module regression option");
    }
  }

  const selectorCount = Number(options.list) +
    Number(options.moduleIds.length > 0) +
    Number(options.changedFrom !== null) +
    Number(options.help);
  if (selectorCount !== 1) {
    throw new Error("choose exactly one of --list, --module, --changed-from, or --help");
  }
  if (options.list && options.dryRun) {
    throw new Error("--dry-run requires --module or --changed-from");
  }
  return Object.freeze({ ...options, moduleIds: Object.freeze(options.moduleIds) });
}

function writeModuleList(output) {
  for (const module of CLIENT_MODULE_CATALOG) {
    output.write(`${module.id}\t${module.kind}\t${module.summary}\n`);
  }
}

function writeSelection(modules, output) {
  if (modules.length === 0) {
    output.write("[client-regression] no module matched the changed paths\n");
    return;
  }
  for (const module of modules) output.write(`${module.id}\n`);
}

export function main(argv = process.argv.slice(2), {
  output = process.stdout,
  errorOutput = process.stderr,
  changedPathLoader = changedPathsSince,
  executor = executeClientModules,
} = {}) {
  try {
    validateClientModuleCatalog();
    const options = parseClientModuleRegressionArgs(argv);
    if (options.help) {
      output.write(usage);
      return 0;
    }
    if (options.list) {
      writeModuleList(output);
      return 0;
    }

    const selected = options.moduleIds.length > 0
      ? selectModulesById(options.moduleIds)
      : selectModulesForChangedPaths(changedPathLoader({
        revision: options.changedFrom,
        repoRoot,
      }));
    if (options.dryRun || selected.length === 0) {
      writeSelection(selected, output);
      return 0;
    }
    const result = executor(selected, { repoRoot, output });
    return result.exitCode;
  } catch (error) {
    errorOutput.write(`client module regression: ${error?.message || "failed"}\n`);
    return 2;
  }
}

const isMain = process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) process.exitCode = main();
