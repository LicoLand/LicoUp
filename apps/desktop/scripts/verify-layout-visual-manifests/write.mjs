import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";

import {
  DEFAULT_LAYOUT_VISUAL_CONFIG,
  scriptRepositoryRoot,
} from "./config.mjs";
import { generateLayoutVisualManifests } from "./generate.mjs";
import { renderLayoutVisualManifest } from "./manifest-codec.mjs";
import { containedPath } from "./paths.mjs";

export async function writeLayoutVisualManifests({
  repositoryRoot = scriptRepositoryRoot,
  config = DEFAULT_LAYOUT_VISUAL_CONFIG,
} = {}) {
  const generated = await generateLayoutVisualManifests({
    repositoryRoot,
    config,
  });
  const expectedRoot = generated.catalog.config.expectedManifestRoot;
  const absoluteExpectedRoot = containedPath(repositoryRoot, expectedRoot);
  await rm(absoluteExpectedRoot, { recursive: true, force: true });
  for (const expected of generated.manifests) {
    const absolutePath = containedPath(repositoryRoot, expected.path);
    await mkdir(path.dirname(absolutePath), { recursive: true });
    await writeFile(
      absolutePath,
      renderLayoutVisualManifest(expected.manifest),
      "utf8",
    );
  }
  return Object.freeze({
    profiles: generated.catalog.profiles.length,
    surfaces: generated.catalog.surfaces.length,
    manifests: generated.manifests.length,
    entries: generated.manifests.reduce(
      (total, expected) => total + expected.manifest.entries.length,
      0,
    ) + generated.manifests.reduce(
      (total, expected) => total + expected.manifest.authorityEntries.length,
      0,
    ),
  });
}
