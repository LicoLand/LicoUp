import path from "node:path";
import process from "node:process";
import { parseArgs } from "./cli.mjs";
import { withToolchainTestArtifactLeases } from "./artifacts.mjs";
import { ROOT } from "./constants.mjs";
import { prepareFlutterCommand, runPreparedCommand } from "./flutter.mjs";
import { verifyToolchain } from "./process.mjs";

export async function main(argv = process.argv.slice(2)) {
  try {
    const { checks, cwd, command, args } = parseArgs(argv);
    await verifyToolchain(checks);
    await withToolchainTestArtifactLeases({ command, args, cwd }, async () => {
      const prepared = await prepareFlutterCommand(command, args, cwd);
      console.log(`[client-toolchain-runner] ${path.relative(ROOT, cwd) || "."}$ ${[prepared.command, ...prepared.args].join(" ")}`);
      await runPreparedCommand(prepared, cwd);
    });
  } catch (error) {
    console.error(`[client-toolchain-runner] ${error.message}`);
    process.exitCode = 1;
  }
}
