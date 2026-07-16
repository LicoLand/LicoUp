import {
  DEFAULT_LAYOUT_BOUNDARY_CONFIG,
  discoverLayoutBundleProduct,
} from "../verify-layout-boundaries.mjs";

import {
  DEFAULT_LAYOUT_VISUAL_CONFIG,
  scriptRepositoryRoot,
} from "./config.mjs";
import { normalizeRelative } from "./paths.mjs";

export async function discoverLayoutCatalog({
  repositoryRoot = scriptRepositoryRoot,
  config = DEFAULT_LAYOUT_VISUAL_CONFIG,
} = {}) {
  const normalizedConfig = Object.fromEntries(
    Object.entries(config).map(([key, value]) => [key, normalizeRelative(value)]),
  );
  const product = await discoverLayoutBundleProduct({
    repositoryRoot,
    config: {
      ...DEFAULT_LAYOUT_BOUNDARY_CONFIG,
      compositionPath: normalizedConfig.compositionPath,
      surfaceContractPath: normalizedConfig.surfaceContractPath,
      profileSourceRoot: normalizedConfig.profileSourceRoot,
      profileTestRoot: normalizedConfig.profileTestRoot,
      assetRoot: normalizedConfig.assetRoot,
      goldenRoot: normalizedConfig.goldenRoot,
    },
  });
  return Object.freeze({
    config: Object.freeze(normalizedConfig),
    profiles: product.profiles,
    surfaces: product.surfaces,
    bundles: product.bundles,
  });
}
