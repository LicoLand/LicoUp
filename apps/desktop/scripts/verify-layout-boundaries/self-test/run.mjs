#!/usr/bin/env node

import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { runIdentityCases } from "./cases/identity.mjs";
import { runImportCases } from "./cases/imports.mjs";
import { runPortCases } from "./cases/ports.mjs";
import { runProductCases } from "./cases/product.mjs";

const fixtureRoot = await mkdtemp(
  path.join(os.tmpdir(), "lico-layout-boundary-"),
);
let checks = 0;
try {
  const profiles = ["alpha", "beta"];
  const surfaces = ["desktop", "mobile"];
  checks += (await runProductCases(fixtureRoot, profiles, surfaces)).checks;
  checks += await runImportCases(fixtureRoot, profiles, surfaces);
  checks += await runPortCases(fixtureRoot, profiles, surfaces);
  checks += await runIdentityCases(fixtureRoot, profiles, surfaces);
  process.stdout.write(
    `${JSON.stringify({ ok: true, mode: "self-test", checks })}\n`,
  );
} finally {
  await rm(fixtureRoot, { recursive: true, force: true });
}
