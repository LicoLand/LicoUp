import {
  DEFAULT_LAYOUT_BOUNDARY_CONFIG,
  verifyLayoutBoundaries,
} from "../../../verify-layout-boundaries.mjs";
import { writeCatalogFixture } from "../fixtures.mjs";
import {
  appendRelative,
  assert,
  bundlePath,
  expectViolation,
  writeRelative,
} from "../helpers.mjs";

export async function runImportCases(fixtureRoot, profiles, surfaces) {
  let checks = 0;
  const forbiddenImports = [
    [
      "layout_shared_styled_chrome_import",
      "package:flutter_client/src/frontend/layout/chrome/shared_shell.dart",
    ],
    [
      "layout_complete_controller_import",
      "package:flutter_client/src/application/controller/client_controller.dart",
    ],
    [
      "layout_controller_scope_import",
      "package:flutter_client/src/application/features/example/controller_scope.dart",
    ],
    [
      "layout_concrete_theme_import",
      "package:flutter_client/src/frontend/shared/ui/theme.dart",
    ],
    [
      "layout_shared_feature_ui_import",
      "package:flutter_client/src/frontend/features/agents/agents_canvas.dart",
    ],
    [
      "layout_shell_implementation_import",
      "package:flutter_client/src/frontend/shell/client_shell.dart",
    ],
    [
      "layout_application_import_forbidden",
      "package:flutter_client/src/application/features/agents/agents_service.dart",
    ],
    [
      "layout_implementation_import",
      "package:flutter_client/src/backend/agents/agents_backend.dart",
    ],
    [
      "layout_implementation_import",
      "package:flutter_client/src/platform/storage/preferences.dart",
    ],
  ];
  for (const [code, specifier] of forbiddenImports) {
    await writeCatalogFixture(fixtureRoot, profiles, surfaces);
    await appendRelative(
      fixtureRoot,
      bundlePath("alpha", "desktop"),
      `import '${specifier}';\n`,
    );
    await expectViolation(code, () =>
      verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
    );
    checks += 1;
  }

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    `import 'package:flutter/widgets.dart'
  if (dart.library.io)
  'package:flutter_client/src/application/controller/client_controller.dart';\n`,
  );
  await expectViolation("layout_complete_controller_import", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  return checks;
}
