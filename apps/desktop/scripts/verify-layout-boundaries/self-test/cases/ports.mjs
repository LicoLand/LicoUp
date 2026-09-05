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

export async function runPortCases(fixtureRoot, profiles, surfaces) {
  let checks = 0;
  const neutralPortTypeCases = [
    [
      "layout_widget_producing_port_forbidden",
      `import 'package:flutter/widgets.dart';
abstract interface class LayoutBusinessPort {
  Future<Widget> buildBusinessSurface();
}
`,
    ],
    [
      "layout_widget_producing_port_forbidden",
      `import 'package:flutter/widgets.dart' as ui;
abstract interface class LayoutBusinessPort {
  ui.Widget buildBusinessSurface();
}
`,
    ],
    [
      "layout_widget_producing_port_forbidden",
      `import 'package:flutter/widgets.dart';
typedef LayoutPreviewBuilder = Widget Function();
`,
    ],
    [
      "layout_widget_producing_port_forbidden",
      `import 'package:flutter/widgets.dart';
abstract interface class LayoutPreviewPort {
  WidgetBuilder get previewBuilder;
}
`,
    ],
    [
      "layout_neutral_build_context_forbidden",
      `abstract interface class LayoutBusinessPort {
  Object buildBusinessSurface(BuildContext context);
}
`,
    ],
    [
      "layout_complete_controller_reference",
      `abstract interface class LayoutBusinessPort {
  ClientController get controller;
}
`,
    ],
  ];
  for (const [code, source] of neutralPortTypeCases) {
    await writeCatalogFixture(fixtureRoot, profiles, surfaces);
    await writeRelative(
      fixtureRoot,
      "apps/desktop/lib/src/presentation/shell/shell_layout_contract.dart",
      source,
    );
    await expectViolation(code, () =>
      verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
    );
    checks += 1;
  }

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/presentation/shell/business_surface_contract.dart",
    `import 'package:flutter/widgets.dart';
abstract interface class LayoutBusinessPort {
  Widget buildBusinessSurface();
}
`,
  );
  await expectViolation("layout_widget_producing_port_forbidden", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/presentation/shell/business_preview_api.dart",
    `import 'package:flutter/material.dart';
abstract interface class BusinessPreviewPort {
  Object buildPreview() => Container();
}
`,
  );
  await expectViolation("layout_widget_producing_port_forbidden", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/contracts/presentation/render_result.dart",
    `import 'package:flutter/widgets.dart';
typedef HiddenRenderResult = Widget;
`,
  );
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/frontend/layout/layout_chrome_port.dart",
    `import 'package:licoup/src/contracts/presentation/render_result.dart';
typedef LayoutPreviewRenderer = HiddenRenderResult Function();
`,
  );
  await expectViolation("layout_widget_producing_port_forbidden", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    "final forbiddenScope = LayoutDestinationPresentationScope;\n",
  );
  await expectViolation("layout_destination_presentation_scope_forbidden", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/frontend/layout/retired_destination_scope.dart",
    "final class LayoutDestinationPresentationScope {}\n",
  );
  await expectViolation("layout_destination_presentation_scope_forbidden", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    "typedef HiddenControllerAlias = ClientController;\n",
  );
  await expectViolation("layout_complete_controller_reference", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/frontend/features/agents/agents_surface.dart",
    "final class SharedAgentsSurface {}\n",
  );
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/contracts/presentation/layout_agents_snapshot.dart",
    "export 'package:licoup/src/frontend/features/agents/agents_surface.dart';\n",
  );
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    "import 'package:licoup/src/contracts/presentation/layout_agents_snapshot.dart';\n",
  );
  await expectViolation("layout_shared_feature_ui_import", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    "import /* directive gap */ 'package:licoup/src/application/controller/client_controller.dart';\n",
  );
  await expectViolation("layout_complete_controller_import", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await appendRelative(
    fixtureRoot,
    "apps/desktop/lib/src/frontend/layout/layout_palette.dart",
    "import 'package:licoup/src/application/controller/client_controller.dart';\n",
  );
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/application/controller/client_controller.dart",
    "final class ClientController {}\n",
  );
  await expectViolation("layout_complete_controller_import", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  return checks;
}
