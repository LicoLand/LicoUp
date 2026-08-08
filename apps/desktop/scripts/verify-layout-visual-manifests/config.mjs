import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);

export const scriptRepositoryRoot = path.resolve(
  path.dirname(scriptPath),
  "../../../..",
);

export const manifestSchema = "licomesh.layout-visual-manifest";
export const manifestSchemaVersion = 2;
export const digestPattern = /^sha256:[a-f0-9]{64}$/u;
export const generatedDiagnosticDirectories = new Set(["failures"]);
export const ignoredBasenames = new Set([".DS_Store", "Thumbs.db"]);
export const forbiddenResidueBasenames = new Set(["source-golden.sha256"]);
export const forbiddenDiagnosticBasename =
  /_(?:masterImage|testImage|isolatedDiff|maskedDiff)\.png$/u;

export const DEFAULT_LAYOUT_VISUAL_CONFIG = Object.freeze({
  compositionPath:
    "apps/desktop/lib/src/application/composition/built_in_layout_composition.dart",
  surfaceContractPath:
    "apps/desktop/lib/src/contracts/presentation/layout_environment.dart",
  profileSourceRoot:
    "apps/desktop/lib/src/frontend/layout/profiles",
  assetRoot: "apps/desktop/assets/layout-profiles",
  profileTestRoot: "apps/desktop/test/layout/profiles",
  goldenRoot: "apps/desktop/test/goldens/layout",
  expectedManifestRoot:
    "apps/desktop/test/layout/visual-manifests",
  productionBaselineTestPath:
    "apps/desktop/test/layout/production_baseline/production_layout_baseline_test.dart",
  productionContinuityTestPath:
    "apps/desktop/test/layout/production_baseline/production_layout_switch_continuity_test.dart",
  productionBaselineFixturePath:
    "apps/desktop/test/layout/fixtures/production_client_shell_fixture.dart",
});
