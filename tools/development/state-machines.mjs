import { existsSync, readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = fileURLToPath(new URL("../..", import.meta.url));
export function validateMachines(document) {
  const summaries = [];
  const machineIds = new Set();
  for (const machine of document.machines ?? []) {
    if (typeof machine.id !== "string" || !machine.id.trim()) throw new Error("missing machine id");
    if (machineIds.has(machine.id)) throw new Error("duplicate machine");
    machineIds.add(machine.id);
    const states = new Set(machine.states.map((state) => state.id));
    if ([...states].some((state) => typeof state !== "string" || !state.trim())) throw new Error("invalid state id");
    if (states.size !== machine.states.length) throw new Error("duplicate state");
    const initial = machine.initial ?? machine.initial_state;
    if (!states.has(initial)) throw new Error("initial state is missing");
    const eventNames = machine.events ?? Object.keys(document.actions ?? {});
    const events = new Set(eventNames);
    if (events.size !== eventNames.length) throw new Error("duplicate event");
    if ([...events].some((event) => typeof event !== "string" || !event.trim())) throw new Error("invalid event id");
    const edges = new Set();
    const terminal = new Set(machine.terminal ?? []);
    if ([...terminal].some((state) => !states.has(state))) throw new Error("unknown terminal state");
    for (const edge of machine.transitions) {
      if (!states.has(edge.from_state) || !states.has(edge.to_state)) throw new Error("unknown transition state");
      const event = edge.event ?? edge.action;
      if (!events.has(event)) throw new Error("unknown transition event");
      const key = `${edge.from_state}\0${event}`;
      if (edges.has(key)) throw new Error("ambiguous transition");
      edges.add(key);
      if (terminal.has(edge.from_state) && edge.to_state !== edge.from_state) throw new Error("terminal state escapes");
    }
    summaries.push({ id: machine.id, states: states.size, transitions: edges.size });
  }
  if (!summaries.length) throw new Error("no state machines registered");
  return summaries;
}

// Discover declarations independently of the registry, so adding a new config
// cannot silently bypass registration. Fixture models are verified by their own
// tests; the executable UI model is deliberately not excluded as a test asset.
export function unregisteredConfigurations(files, read, registry) {
  const registered = new Set(registry.map((entry) => entry.configuration).filter(Boolean));
  const missing = [];
  for (const file of files) {
    if (!file.endsWith(".json") || /(?:^|\/)fixtures?\//u.test(file)) continue;
    let document;
    try { document = JSON.parse(read(file)); } catch { continue; }
    if (Array.isArray(document?.machines) && !registered.has(file)) missing.push(file);
  }
  return missing.sort();
}

export function inspectRegistry(registry, { read, exists, scripts }) {
  const ids = new Set();
  const machineIds = new Set();
  const configurations = new Set();
  return registry.map((entry) => {
    try {
      if (ids.has(entry.id)) throw new Error("duplicate registry id");
      ids.add(entry.id);
      if (!entry.owner || !scripts[entry.verification] || !exists(entry.executor)) throw new Error("missing binding");
      if ((entry.consumers ?? []).some((consumer) => !exists(consumer))) throw new Error("missing consumer binding");
      if (entry.kind === "dynamic") {
        if (!exists(entry.provider) || !entry.format) throw new Error("missing definition provider");
        return { ...entry, status: "provider-registered", behavior: "not-run" };
      }
      if (configurations.has(entry.configuration)) throw new Error("configuration has two owners");
      configurations.add(entry.configuration);
      const machines = validateMachines(JSON.parse(read(entry.configuration)));
      for (const machine of machines) {
        if (machineIds.has(machine.id)) throw new Error("machine has two owners");
        machineIds.add(machine.id);
      }
      return { ...entry, status: "configuration-valid", behavior: "not-run", machines };
    } catch {
      // Filesystem and parser errors can carry host paths or input fragments.
      return { ...entry, status: "failed", behavior: "not-run", reason: "configuration-invalid-or-unreadable" };
    }
  });
}

export function sourceCandidates(files, read, registry) {
  const declarations = new Set(registry.filter((entry) => entry.source).map((entry) => `${entry.source}\0${entry.symbol}`));
  const candidates = [];
  for (const file of files) {
    if (!/\.(?:rs|dart)$/u.test(file) || /(?:^|\/)(?:tests?|generated|fixtures)\//u.test(file) || /generated\./u.test(file)) continue;
    const source = read(file);
    for (const match of source.matchAll(/\benum\s+(\w*(?:State|Phase|Stage|Status|Lifecycle))\b/gu)) {
      if (declarations.has(`${file}\0${match[1]}`)) continue;
      candidates.push({ file, line: source.slice(0, match.index).split("\n").length, symbol: match[1], status: "needs-classification" });
    }
  }
  return candidates;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  if (args.some((arg) => !["--list", "--refresh"].includes(arg))) throw new Error("Only --list and --refresh are supported");
  const registry = JSON.parse(readFileSync(new URL("state-machines.json", import.meta.url)));
  const read = (file) => readFileSync(path.join(root, file), "utf8");
  const entries = inspectRegistry(registry, { read, exists: (file) => existsSync(path.join(root, file)), scripts: JSON.parse(read("package.json")).scripts });
  for (const entry of entries) {
    if (entry.execution !== "generated-dart" || entry.status !== "configuration-valid") continue;
    const result = spawnSync(process.execPath, ["tools/development/compile-dart-machines.mjs", "--config", entry.configuration,
      args.includes("--refresh") ? "--refresh" : "--check"], { cwd: root, stdio: "inherit" });
    if (result.error || result.status !== 0) {
      entry.status = "failed";
      entry.reason = "generated-state-machine-stale-or-invalid";
    }
  }
  const files = execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], { cwd: root, encoding: "utf8" })
    .split("\0").filter((file) => file && existsSync(path.join(root, file)));
  const candidates = sourceCandidates([...new Set(files)], read, registry);
  const unregistered = unregisteredConfigurations([...new Set(files)], read, registry);
  mkdirSync(path.join(root, "build/reports"), { recursive: true });
  writeFileSync(path.join(root, "build/reports/state-machines.json"), JSON.stringify({ observedAt: new Date().toISOString(), coverage: "review-required", entries, candidates, unregisteredConfigurations: unregistered,
    limitation: "Source heuristics identify review candidates, not a proof of complete state-machine coverage. Module review must trace each candidate to its actual executor or projection authority." }, null, 2) + "\n");
  for (const entry of entries) {
    for (const machine of entry.machines ?? [{ id: entry.id }]) {
      process.stdout.write(`${machine.id}\t${entry.owner}\t${entry.status}\t${entry.configuration ?? entry.provider ?? entry.source}\tnpm run ${entry.verification}\n`);
    }
  }
  process.stdout.write(`Source candidates needing classification: ${candidates.length}; details: build/reports/state-machines.json\n`);
  for (const file of unregistered) process.stderr.write(`Unregistered state configuration: ${file}\n`);
  process.exitCode = unregistered.length || entries.some((entry) => entry.status === "failed") ? 1 : 0;
}
