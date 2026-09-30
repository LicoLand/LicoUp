import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { CLIENT_MODULE_CATALOG } from "../regression/client-module-catalog.mjs";
import { normalizeRepoPath, selectModulesForChangedPaths } from "../regression/client-module-selection.mjs";

const root = fileURLToPath(new URL("../..", import.meta.url));
export const modules = JSON.parse(readFileSync(new URL("modules.json", import.meta.url)));
const stateMachines = JSON.parse(readFileSync(new URL("state-machines.json", import.meta.url)));
export function covers(input, file) {
  return file === input || file === `${input}.rs` || file.startsWith(`${input}/`);
}

export function validateImpactRegistry(owners, catalog = CLIENT_MODULE_CATALOG) {
  const ids = new Set(owners.map((owner) => owner.id));
  if (ids.size !== owners.length) throw new Error("duplicate module owner");
  const suites = new Set(catalog.map((suite) => suite.id));
  for (const owner of owners) {
    for (const suite of owner.regressionModules) if (!suites.has(suite)) throw new Error("unknown regression suite");
    for (const boundary of owner.boundaries ?? []) {
      if (!boundary.inputs?.length || !boundary.consumers?.length) throw new Error("empty boundary");
      for (const consumer of boundary.consumers) if (!ids.has(consumer)) throw new Error("unknown boundary consumer");
    }
  }
}

export function analyzePaths(paths, owners = modules, catalog = CLIENT_MODULE_CATALOG, machines = owners === modules ? stateMachines : []) {
  validateImpactRegistry(owners, catalog);
  paths = [...new Set(paths.map(normalizeRepoPath))].sort();
  const configurationChanges = machines.filter((entry) => paths.includes(entry.configuration));
  const executionPaths = [...new Set([...paths, ...configurationChanges.flatMap((entry) => [entry.executor, ...(entry.consumers ?? [])])])];
  const selected = selectModulesForChangedPaths(executionPaths, catalog);
  const affected = new Set();
  const edges = [];
  const unresolved = [];
  const uncovered = [];
  const adapters = new Set();
  const fallbackSuites = new Set();
  const sharedAdapters = new Set();
  for (const file of executionPaths) {
    const candidates = owners.flatMap((owner) => [owner.guide, ...(owner.sourceRoots ?? [])]
      .filter((input) => covers(input, file)).map((input) => ({ owner: owner.id, length: input.length })));
    const length = Math.max(0, ...candidates.map((entry) => entry.length));
    const direct = [...new Set([...candidates.filter((entry) => entry.length === length).map((entry) => entry.owner),
      ...configurationChanges.filter((entry) => entry.configuration === file).map((entry) => entry.owner)])];
    direct.forEach((id) => affected.add(id));
    if (!direct.length) unresolved.push(file);
    if (!selectModulesForChangedPaths([file], catalog).length && !configurationChanges.some((entry) => entry.configuration === file)) {
      if (direct.length) {
        for (const id of direct) owners.find((owner) => owner.id === id).regressionModules.forEach((suite) => fallbackSuites.add(suite));
      } else uncovered.push(file);
    }
    for (const owner of owners) {
      for (const boundary of owner.boundaries ?? []) {
        if (boundary.inputs.some((input) => covers(input, file))) {
          affected.add(owner.id);
          for (const consumer of boundary.consumers) {
            affected.add(consumer);
            edges.push({ provider: owner.id, consumer, trigger: file });
          }
        }
      }
      const specific = (owner.adapterImpacts ?? []).filter((adapter) => adapter.inputs.some((input) => covers(input, file)));
      if (specific.length) specific.forEach((adapter) => adapters.add(adapter.id));
      else if ((owner.sharedAdapterInputs ?? []).some((input) => covers(input, file))) {
        (owner.adapterImpacts ?? []).forEach((adapter) => { adapters.add(adapter.id); sharedAdapters.add(adapter.id); });
      }
    }
  }
  // A changed public boundary invalidates dependent contracts transitively. Ordinary
  // implementation changes use the catalog's path selection without this expansion.
  const queue = [...new Set(edges.map((edge) => edge.consumer))];
  const visited = new Set();
  for (let index = 0; index < queue.length; index += 1) {
    const id = queue[index];
    if (visited.has(id)) continue;
    visited.add(id);
    for (const boundary of owners.find((owner) => owner.id === id)?.boundaries ?? []) {
      for (const consumer of boundary.consumers) {
        affected.add(consumer);
        edges.push({ provider: id, consumer, trigger: "dependent-contract" });
        if (!visited.has(consumer)) queue.push(consumer);
      }
    }
  }
  const suites = new Set([...selected.map((suite) => suite.id), ...fallbackSuites]);
  // Existing catalog inputs remain the only suite/path authority. A shared
  // transport change selects every suite observing the registered adapters.
  for (const adapter of owners.flatMap((owner) => owner.adapterImpacts ?? [])) {
    if (!sharedAdapters.has(adapter.id)) continue;
    for (const suite of catalog) {
      if (suite.inputs.some((input) => adapter.inputs.some((owned) => {
        const prefix = input.replace(/\/\*\*$/u, "");
        return covers(owned, prefix) || covers(prefix, owned);
      }))) suites.add(suite.id);
    }
  }
  for (const id of new Set(edges.flatMap((edge) => [edge.provider, edge.consumer]))) {
    owners.find((owner) => owner.id === id).regressionModules.forEach((suite) => suites.add(suite));
  }
  return { paths, modules: owners.filter((owner) => affected.has(owner.id)).map(({ id, guide }) => ({ id, guide, command: `npm run verify:${id}` })),
    stateConfigurations: configurationChanges.map(({ configuration, executor, consumers = [] }) => ({ configuration, executors: [executor, ...consumers] })),
    edges, regressionModules: [...suites].sort(), unresolvedOwners: unresolved, uncoveredPaths: uncovered,
    live: [...adapters].sort().map((id) => ({ id, severity: "warning", status: "not-run", blocking: false })),
    meaning: "Declared dependency selection; review ownership gaps. Static coverage does not prove live compatibility." };
}

export function workingPaths(base, repoRoot = root) {
  const git = (args) => execFileSync("git", args, { cwd: repoRoot, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).split("\0").filter(Boolean);
  const changed = [...new Set([
    ...git(["diff", "--name-only", "-z", ...(base ? [`${base}...HEAD`] : ["HEAD"]), "--"]),
    ...(base ? git(["diff", "--name-only", "-z", "HEAD", "--"]) : []),
    ...git(["ls-files", "--others", "--exclude-standard", "-z"]),
  ])];
  // A removed path still appears in the diff, but it has no reader left to own
  // and no check left to select, so only the paths that exist carry coverage.
  return changed.filter((relative) => existsSync(path.join(repoRoot, relative)));
}

export function eventBase(event) {
  const candidate = event.pull_request?.base?.sha ?? event.before;
  return typeof candidate === "string" && /^[0-9a-f]{40}$/u.test(candidate) && !/^0+$/u.test(candidate) ? candidate : null;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { values } = parseArgs({ options: { path: { type: "string", multiple: true }, base: { type: "string" } } });
  const event = process.env.GITHUB_EVENT_PATH ? JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8")) : {};
  const base = values.base ?? eventBase(event);
  const paths = values.path ?? (process.env.GITHUB_ACTIONS === "true" && !base
    ? execFileSync("git", ["ls-files", "-z"], { cwd: root, encoding: "utf8" }).split("\0").filter(Boolean)
    : workingPaths(base));
  const result = { comparisonBase: base ?? (process.env.GITHUB_ACTIONS === "true" ? "entire-candidate" : "HEAD-and-worktree"), ...analyzePaths(paths) };
  mkdirSync(path.join(root, "build/reports"), { recursive: true });
  writeFileSync(path.join(root, "build/reports/change-impact.json"), JSON.stringify(result, null, 2) + "\n");
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  // Missing live checks are always warnings. Unmapped executable source needs a
  // registered static check before the source gate can be considered complete.
  process.exitCode = result.uncoveredPaths.some((file) => /\.(?:rs|dart|mjs|[cm]?jsx?|tsx?)$/u.test(file)) ? 1 : 0;
}
