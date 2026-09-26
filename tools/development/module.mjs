import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { CLIENT_MODULE_CATALOG } from "../regression/client-module-catalog.mjs";
import { selectModulesForChangedPaths } from "../regression/client-module-selection.mjs";

const root = fileURLToPath(new URL("../..", import.meta.url));
const modules = JSON.parse(readFileSync(new URL("modules.json", import.meta.url)));
const [id, ...args] = process.argv.slice(2);
const owner = modules.find((entry) => entry.id === id);
if (!owner || args.some((arg) => arg !== "--plan")) {
  process.stderr.write("Choose a registered module; only --plan is optional.\n");
  process.exitCode = 1;
} else {
  const machines = JSON.parse(readFileSync(new URL("state-machines.json", import.meta.url)));
  const machineInputs = machines.filter((entry) => entry.owner === id)
    .flatMap((entry) => [entry.executor, ...(entry.consumers ?? [])]);
  const suites = [...new Set([...owner.regressionModules,
    ...selectModulesForChangedPaths(machineInputs, CLIENT_MODULE_CATALOG).map((suite) => suite.id)])];
  const commands = id === "development"
    ? [[process.execPath, "--test", "tools/development/tests/*.test.mjs"], ...owner.regressionModules.map((name) => {
      const { command } = CLIENT_MODULE_CATALOG.find((suite) => suite.id === name);
      return [command.program, ...command.args];
    })]
    : [[process.execPath, "tools/scripts/client-module-regression.mjs",
      "--static-compatibility", ...suites.flatMap((name) => ["--module", name])]];
  for (const [program, ...parameters] of commands) {
    if (args.includes("--plan")) {
      process.stdout.write(`${program === process.execPath ? "node" : program} ${parameters.join(" ")}\n`);
      continue;
    }
    const result = spawnSync(program, parameters, { cwd: root, stdio: "inherit" });
    if (result.error || result.status !== 0) {
      process.exitCode = 1;
      break;
    }
  }
}
