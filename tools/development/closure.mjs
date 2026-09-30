import { spawnSync, execFileSync } from "node:child_process";
import { readFileSync, mkdirSync, writeFileSync, renameSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import { generateReports } from "./reports.mjs";

const root = fileURLToPath(new URL("../..", import.meta.url));
export const steps = JSON.parse(readFileSync(new URL("closure-steps.json", import.meta.url)));

export function liveInventory(drivers) {
  return [...drivers.map(({ agentId }) => `agent:${agentId}`),
    "model-gateway", "mobile-pairing", "usage-accounting", "model-qualification", "installation"]
    .map((id) => ({ id, status: "not-run", reason: "explicit live acceptance required" }));
}

export function runClosure({ entries = steps, invoke, save, live = [], revision = null, now = () => new Date().toISOString() }) {
  const report = { startedAt: now(), sourceRevision: revision, sourceState: "working-tree", status: "running",
    scope: "static-global", manualReview: "required", live,
    steps: entries.map((entry) => ({ ...entry, status: "not-run" })) };
  save(report);
  for (const step of report.steps) {
    step.status = "running";
    step.startedAt = now();
    save(report);
    try {
      step.exitCode = invoke(step.command);
      step.status = step.exitCode === 0 ? "passed" : "failed";
    } catch {
      step.status = "failed";
      step.exitCode = null;
    }
    step.finishedAt = now();
    save(report);
  }
  report.status = report.steps.every((step) => step.status === "passed") ? "passed" : "failed";
  report.finishedAt = now();
  save(report);
  return report;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  if (args.some((arg) => arg !== "--plan")) throw new Error("Only --plan is supported");
  process.stdout.write("Read docs/CLOSURE.md and finish source review before global verification.\n");
  if (args.includes("--plan")) {
    for (const step of steps) process.stdout.write(`${step.kind}: npm run ${step.command}\n`);
  } else {
    const directory = path.join(root, "build/reports/closure");
    mkdirSync(directory, { recursive: true });
    // Each invocation has its own report; an interrupted invocation stays running.
    const file = path.join(directory, `${new Date().toISOString().replaceAll(":", "-")}-${process.pid}.json`);
    const drivers = JSON.parse(readFileSync(path.join(root, "crates/licoup-agent-drivers/resources/agent-conversation-drivers.json"))).drivers;
    const report = runClosure({
      live: liveInventory(drivers),
      revision: execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim(),
      invoke(command) {
        process.stdout.write(`Closure: npm run ${command}\n`);
        if (!process.env.npm_execpath) throw new Error("Run through npm run verify:closure");
        const result = spawnSync(process.execPath, [process.env.npm_execpath, "run", command], { cwd: root, stdio: "inherit" });
        return result.error ? null : result.status;
      },
      save(value) {
        writeFileSync(`${file}.tmp`, JSON.stringify(value, null, 2) + "\n");
        renameSync(`${file}.tmp`, file);
      },
    });
    generateReports();
    process.stdout.write(`Closure ${report.status}: ${path.relative(root, file)}\n`);
    process.exitCode = report.status === "passed" ? 0 : 1;
  }
}
