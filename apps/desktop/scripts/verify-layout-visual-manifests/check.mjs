import {
  DEFAULT_LAYOUT_VISUAL_CONFIG,
  scriptRepositoryRoot,
} from "./config.mjs";
import { fail } from "./errors.mjs";
import { generateLayoutVisualManifests } from "./generate.mjs";
import {
  renderLayoutVisualManifest,
  validateStoredManifest,
} from "./manifest-codec.mjs";
import { collectFiles } from "./owner-roots.mjs";
import { readUtf8 } from "./paths.mjs";

export async function checkLayoutVisualManifests({
  repositoryRoot = scriptRepositoryRoot,
  config = DEFAULT_LAYOUT_VISUAL_CONFIG,
} = {}) {
  const generated = await generateLayoutVisualManifests({
    repositoryRoot,
    config,
  });
  const expectedByPath = new Map(
    generated.manifests.map((entry) => [entry.path, entry]),
  );
  const storedFiles = await collectFiles(
    repositoryRoot,
    generated.catalog.config.expectedManifestRoot,
    { excludeGeneratedDiagnostics: false },
  );
  const storedFileSet = new Set(storedFiles);
  for (const relativePath of storedFiles) {
    if (!expectedByPath.has(relativePath)) {
      fail("layout_visual_manifest_unexpected", relativePath);
    }
  }
  let entryCount = 0;
  for (const expected of generated.manifests) {
    if (!storedFileSet.has(expected.path)) {
      fail("layout_visual_manifest_missing", expected.path);
    }
    const source = await readUtf8(repositoryRoot, expected.path);
    let stored;
    try {
      stored = JSON.parse(source);
    } catch {
      fail("layout_visual_manifest_json_invalid", expected.path);
    }
    validateStoredManifest({
      catalog: generated.catalog,
      ownerRoots: generated.ownerRoots,
      expected,
      stored,
    });
    if (source !== renderLayoutVisualManifest(expected.manifest)) {
      fail("layout_visual_manifest_stale", expected.path);
    }
    entryCount +=
      expected.manifest.entries.length +
      expected.manifest.authorityEntries.length;
  }
  return Object.freeze({
    profiles: generated.catalog.profiles.length,
    surfaces: generated.catalog.surfaces.length,
    manifests: generated.manifests.length,
    entries: entryCount,
  });
}
