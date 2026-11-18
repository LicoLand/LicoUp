#!/usr/bin/env node
// Forwards release commands to the release CLI named by
// LICOUP_RELEASE_PLANE_CLI. The CLI's installed name is machine-local and
// intentionally not committed to this repository.
import { spawnSync } from "node:child_process";

const cli = process.env.LICOUP_RELEASE_PLANE_CLI;
if (!cli) {
  console.error(
    "client-release-plane: set LICOUP_RELEASE_PLANE_CLI to the release CLI name",
  );
  process.exit(2);
}
const result = spawnSync(cli, process.argv.slice(2), { stdio: "inherit" });
process.exit(result.status ?? 1);
