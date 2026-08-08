import process from "node:process";
import { ClosureError, requireValue } from "./errors.mjs";

export function parseArgs(argv = process.argv.slice(2)) {
  const options = { platform: "all", selfTest: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--self-test") {
      options.selfTest = true;
    } else if (arg === "--platform" && argv[index + 1]) {
      options.platform = String(argv[index + 1]).toLowerCase();
      index += 1;
    } else {
      throw new ClosureError("simulator_closure_arguments_invalid");
    }
  }
  requireValue(["android", "ios", "all"].includes(options.platform),
    "simulator_closure_platform_invalid");
  return options;
}

export function selectedPlatforms(platform) {
  return platform === "all" ? ["android", "ios"] : [platform];
}
