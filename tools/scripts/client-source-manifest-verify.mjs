#!/usr/bin/env node

import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  readAndVerifyClientSourceManifest,
} from "./lib/client-source-state-digest.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const manifestPath = path.join(
  repoRoot,
  ".lico-source-attestation",
  "client-source-manifest.json",
);
const expectedSourceDigest = String(
  process.env.LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST || "",
).trim();

const result = readAndVerifyClientSourceManifest(
  repoRoot,
  manifestPath,
  expectedSourceDigest,
  { expectedSourceRoots: CANONICAL_CLIENT_SOURCE_ROOTS },
);

console.log(JSON.stringify({
  ok: true,
  sourceManifestVerified: true,
  entryCount: result.entryCount,
  localPathIncluded: false,
  rawSourceIncluded: false,
}));
