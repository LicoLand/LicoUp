#!/usr/bin/env node

import process from "node:process";

import { packageClient } from "../../../apps/desktop/scripts/package-client.mjs";
import { publicPackageFailure } from "../../../apps/desktop/scripts/package-client/cli-policy.mjs";

try {
  packageClient(["--platform", "macos", "--mode", "release"]);
} catch (error) {
  process.stderr.write(`${JSON.stringify(publicPackageFailure(error))}\n`);
  process.exitCode = 1;
}
