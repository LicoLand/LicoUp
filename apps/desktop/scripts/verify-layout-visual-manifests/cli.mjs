import process from "node:process";

import { checkLayoutVisualManifests } from "./check.mjs";
import { fail, LayoutVisualManifestError } from "./errors.mjs";
import { writeLayoutVisualManifests } from "./write.mjs";

export async function main() {
  try {
    await runCli();
  } catch (error) {
    const code =
      error instanceof LayoutVisualManifestError
        ? error.code
        : "layout_visual_manifest_internal_error";
    const relativePath =
      error instanceof LayoutVisualManifestError && error.relativePath
        ? error.relativePath
        : undefined;
    process.stderr.write(
      `${JSON.stringify({ ok: false, code, path: relativePath })}\n`,
    );
    process.exitCode = 1;
  }
}

async function runCli() {
  const modes = process.argv.slice(2);
  const valid =
    modes.length === 0 ||
    (modes.length === 1 && ["--check", "--write"].includes(modes[0]));
  if (!valid) {
    fail("layout_visual_manifest_arguments_invalid");
  }
  const mode = modes[0] === "--write" ? "write" : "check";
  const result =
    mode === "write"
      ? await writeLayoutVisualManifests()
      : await checkLayoutVisualManifests();
  process.stdout.write(`${JSON.stringify({ ok: true, mode, ...result })}\n`);
}
