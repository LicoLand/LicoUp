import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { verifyLayoutBoundaries } from "./verify.mjs";

export async function main() {
  if (process.argv.includes("--self-test")) {
    const selfTestPath = path.join(
      path.dirname(fileURLToPath(import.meta.url)),
      "self-test",
      "run.mjs",
    );
    const result = spawnSync(process.execPath, [selfTestPath], {
      stdio: "inherit",
    });
    if (result.error) {
      throw result.error;
    }
    process.exitCode = result.status ?? 1;
    return;
  }
  const result = await verifyLayoutBoundaries();
  process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
}
