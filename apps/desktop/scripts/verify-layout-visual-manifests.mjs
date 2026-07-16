#!/usr/bin/env node

import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

export { DEFAULT_LAYOUT_VISUAL_CONFIG } from "./verify-layout-visual-manifests/config.mjs";
export { LayoutVisualManifestError } from "./verify-layout-visual-manifests/errors.mjs";
export { discoverLayoutCatalog } from "./verify-layout-visual-manifests/catalog.mjs";
export { generateLayoutVisualManifests } from "./verify-layout-visual-manifests/generate.mjs";
export { renderLayoutVisualManifest } from "./verify-layout-visual-manifests/manifest-codec.mjs";
export { checkLayoutVisualManifests } from "./verify-layout-visual-manifests/check.mjs";
export { writeLayoutVisualManifests } from "./verify-layout-visual-manifests/write.mjs";

import { main } from "./verify-layout-visual-manifests/cli.mjs";

const isMain =
  process.argv[1] != null &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isMain) {
  await main();
}
