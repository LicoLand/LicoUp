import { spawnSync } from "node:child_process";
import process from "node:process";
import { nodeOnlyContractTestFiles } from "../regression/client-contract-selection.mjs";

const files = nodeOnlyContractTestFiles(".");
if (files.length === 0) {
  throw new Error("zero node-only contract tests selected");
}
const result = spawnSync(process.execPath, ["--test", ...files], {
  stdio: "inherit",
});
process.exit(result.status ?? 1);
