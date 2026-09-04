import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);

export const scriptRepositoryRoot = path.resolve(
  path.dirname(scriptPath),
  "../../../..",
);

export const DEFAULT_LAYOUT_BOUNDARY_CONFIG = Object.freeze({
  compositionPath:
    "apps/desktop/lib/src/composition/built_in_layout_composition.dart",
  surfaceContractPath:
    "apps/desktop/lib/src/contracts/presentation/layout_environment.dart",
  profileSourceRoot:
    "apps/desktop/lib/src/frontend/layout/profiles",
  profileTestRoot: "apps/desktop/test/layout/profiles",
  profileTestFixtureRoot: "apps/desktop/test/layout/fixtures",
  assetRoot: "apps/desktop/assets/layout-profiles",
  goldenRoot: "apps/desktop/test/goldens/layout",
  libraryRoot: "apps/desktop/lib",
  testRoot: "apps/desktop/test",
  preferencesPath:
    "apps/desktop/lib/src/platform/presentation/presentation_preferences_repository.dart",
  portableDataRootPath:
    "apps/desktop/lib/src/platform/storage/portable_data_root.dart",
  workspaceManifestPath:
    "apps/desktop/lib/src/platform/storage/client_workspace_manifest.dart",
});

export const NEUTRAL_LAYOUT_CONTRACTS = new Set([
  "apps/desktop/lib/src/frontend/layout/layout_agents_strategy.dart",
  "apps/desktop/lib/src/frontend/layout/layout_chrome_features.dart",
  "apps/desktop/lib/src/frontend/layout/layout_chrome_port.dart",
  "apps/desktop/lib/src/frontend/layout/layout_component_kit.dart",
  "apps/desktop/lib/src/frontend/layout/layout_destination_presentation.dart",
  "apps/desktop/lib/src/frontend/layout/layout_palette.dart",
  "apps/desktop/lib/src/frontend/layout/layout_scope.dart",
  "apps/desktop/lib/src/frontend/layout/layout_surface_bundle.dart",
  "apps/desktop/lib/src/frontend/layout/layout_visual_tokens.dart",
]);
