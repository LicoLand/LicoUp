#!/usr/bin/env node

import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

export { DEFAULT_LAYOUT_BOUNDARY_CONFIG } from "./verify-layout-boundaries/config.mjs";
export { LayoutBoundaryError } from "./verify-layout-boundaries/errors.mjs";
export { discoverLayoutBundleProduct } from "./verify-layout-boundaries/bundle-product.mjs";
export { verifyLayoutBoundaries } from "./verify-layout-boundaries/verify.mjs";

import { main } from "./verify-layout-boundaries/cli.mjs";

const isMain =
  process.argv[1] != null &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isMain) {
  await main();
}
