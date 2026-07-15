#!/usr/bin/env node

import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import {
  DEFAULT_LAYOUT_BOUNDARY_CONFIG,
  LayoutBoundaryError,
  verifyLayoutBoundaries,
} from "./verify-layout-boundaries.mjs";

const profileContractPath =
  "apps/desktop/lib/src/contracts/presentation/layout_profile.dart";

function assert(condition, code) {
  if (!condition) {
    throw new Error(code);
  }
}

function title(value) {
  return `${value[0].toUpperCase()}${value.slice(1)}`;
}

function bundleSymbol(profile, surface) {
  return `${profile}${title(surface)}Bundle`;
}

function bundlePath(profile, surface) {
  return `${DEFAULT_LAYOUT_BOUNDARY_CONFIG.profileSourceRoot}/${profile}/${surface}/${profile}_${surface}_bundle.dart`;
}

async function writeRelative(root, relativePath, source) {
  const absolutePath = path.join(root, ...relativePath.split("/"));
  await mkdir(path.dirname(absolutePath), { recursive: true });
  await writeFile(absolutePath, source);
}

async function appendRelative(root, relativePath, source) {
  const absolutePath = path.join(root, ...relativePath.split("/"));
  const current = await readFile(absolutePath, "utf8");
  await writeFile(absolutePath, `${current}${source}`, "utf8");
}

async function resetFixture(root) {
  await rm(root, { recursive: true, force: true });
  await mkdir(root, { recursive: true });
}

async function writeStateAuthorityFixture(root) {
  await writeRelative(
    root,
    DEFAULT_LAYOUT_BOUNDARY_CONFIG.preferencesPath,
    `import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
final class Preferences {
  static const _fileName = 'appearance-preferences.json';
  Future<void> file() async {
    final root = await _portableData.clientDirectory();
    return File(p.join(root.path, _fileName));
  }
}
`,
  );
  await writeRelative(
    root,
    DEFAULT_LAYOUT_BOUNDARY_CONFIG.portableDataRootPath,
    `final class PortableDataRoot {
  static const String _workspaceManifestFileName = '.lico-workspace.json';
  Future<Directory> clientDirectory() async {
    final directory = Directory(p.join(dataDir.path, 'lico-client'));
    return directory;
  }
}
`,
  );
  await writeRelative(
    root,
    DEFAULT_LAYOUT_BOUNDARY_CONFIG.workspaceManifestPath,
    "static const licoClientAppId = 'lico-client';\n",
  );
}

async function writeNeutralContracts(root) {
  const files = {
    "apps/desktop/lib/src/frontend/layout/layout_chrome_port.dart":
      "abstract interface class LayoutChromePort {}\n",
    "apps/desktop/lib/src/frontend/layout/layout_palette.dart":
      "final class LayoutPalette {}\n",
    "apps/desktop/lib/src/frontend/layout/layout_destination_presentation.dart":
      "abstract interface class LayoutDestinationPresentation {}\n",
  };
  for (const [relativePath, source] of Object.entries(files)) {
    await writeRelative(root, relativePath, source);
  }
}

async function writeCatalogFixture(
  root,
  profiles,
  surfaces,
  {
    omitOwners = new Set(),
    duplicateDefinitionOwner = null,
    identityOverrides = new Map(),
  } = {},
) {
  await resetFixture(root);
  await writeRelative(
    root,
    profileContractPath,
    `final class LayoutProfileId {
  const LayoutProfileId._(this.value);
  factory LayoutProfileId.parse(String value) => LayoutProfileId._(value);
  final String value;
}
`,
  );
  await writeRelative(
    root,
    DEFAULT_LAYOUT_BOUNDARY_CONFIG.surfaceContractPath,
    `enum LayoutRuntimeSurface { ${surfaces.join(", ")} }\n`,
  );
  await writeNeutralContracts(root);
  await writeStateAuthorityFixture(root);

  const imports = [];
  const definitions = [];
  for (const profile of profiles) {
    const symbols = [];
    for (const surface of surfaces) {
      const owner = `${profile}/${surface}`;
      const symbol = bundleSymbol(profile, surface);
      const relativePath = bundlePath(profile, surface);
      const identity = identityOverrides.get(owner) ?? { profile, surface };
      await writeRelative(
        root,
        relativePath,
        `import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';

final LayoutSurfaceBundle ${symbol} = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(id: LayoutProfileId.parse('${identity.profile}')),
  surface: LayoutRuntimeSurface.${identity.surface},
);
`,
      );
      await writeRelative(
        root,
        `${DEFAULT_LAYOUT_BOUNDARY_CONFIG.profileTestRoot}/${profile}/${surface}/${profile}_${surface}_bundle_test.dart`,
        `import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_client/${relativePath.slice("apps/desktop/lib/".length)}';
void main() {}
`,
      );
      if (!omitOwners.has(owner)) {
        imports.push(
          `import 'package:flutter_client/${relativePath.slice("apps/desktop/lib/".length)}';`,
        );
        symbols.push(symbol);
        if (duplicateDefinitionOwner === owner) {
          symbols.push(symbol);
        }
      }
    }
    definitions.push(`    LayoutDefinition([${symbols.join(", ")}]),`);
  }
  await writeRelative(
    root,
    DEFAULT_LAYOUT_BOUNDARY_CONFIG.compositionPath,
    `${imports.join("\n")}

final definitions = <LayoutDefinition>[
${definitions.join("\n")}
];
`,
  );
}

async function expectViolation(code, operation) {
  try {
    await operation();
  } catch (error) {
    if (error instanceof LayoutBoundaryError && error.code === code) {
      return;
    }
    throw error;
  }
  throw new Error(`layout_boundary_self_test_missing_${code}`);
}

const fixtureRoot = await mkdtemp(
  path.join(os.tmpdir(), "lico-layout-boundary-"),
);
let checks = 0;
try {
  const profiles = ["alpha", "beta"];
  const surfaces = ["desktop", "mobile"];
  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  const baseline = await verifyLayoutBoundaries({ repositoryRoot: fixtureRoot });
  assert(
    baseline.profiles === profiles.length &&
      baseline.surfaces === surfaces.length &&
      baseline.bundles === profiles.length * surfaces.length,
    "layout_boundary_self_test_baseline_product_failed",
  );
  checks += 1;

  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/frontend/layout/layout_surface_bundle.dart",
    `import 'package:flutter/widgets.dart';
typedef LayoutDestinationBuilder = Widget Function(BuildContext context);
final class LayoutSurfaceBundle {}
`,
  );
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/frontend/layout/layout_component_kit.dart",
    `import 'package:flutter/widgets.dart';
abstract interface class LayoutComponentKit {
  Widget panel(BuildContext context, Widget child);
}
`,
  );
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    `import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/layout_component_kit.dart';
`,
  );
  await verifyLayoutBoundaries({ repositoryRoot: fixtureRoot });
  checks += 1;

  const expandedProfiles = [...profiles, "gamma"];
  await writeCatalogFixture(fixtureRoot, expandedProfiles, surfaces);
  const profileExpanded = await verifyLayoutBoundaries({
    repositoryRoot: fixtureRoot,
  });
  assert(
    profileExpanded.bundles === expandedProfiles.length * surfaces.length,
    "layout_boundary_self_test_dynamic_profile_failed",
  );
  checks += 1;

  const expandedSurfaces = [...surfaces, "wearable"];
  await writeCatalogFixture(
    fixtureRoot,
    expandedProfiles,
    expandedSurfaces,
  );
  const surfaceExpanded = await verifyLayoutBoundaries({
    repositoryRoot: fixtureRoot,
  });
  assert(
    surfaceExpanded.bundles ===
      expandedProfiles.length * expandedSurfaces.length,
    "layout_boundary_self_test_dynamic_surface_failed",
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, expandedProfiles, expandedSurfaces, {
    omitOwners: new Set(["gamma/wearable"]),
  });
  await expectViolation(
    "layout_composition_profile_surface_product_incomplete",
    () => verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces, {
    duplicateDefinitionOwner: "alpha/desktop",
  });
  await expectViolation("layout_composition_bundle_symbol_duplicate", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    `${DEFAULT_LAYOUT_BOUNDARY_CONFIG.profileSourceRoot}/retired/desktop/stale.dart`,
    "void stale() {}\n",
  );
  await expectViolation("layout_stale_profile_ownership", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces, {
    identityOverrides: new Map([
      ["alpha/desktop", { profile: "beta", surface: "desktop" }],
    ]),
  });
  await expectViolation("layout_bundle_path_profile_mismatch", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces, {
    identityOverrides: new Map([
      ["alpha/desktop", { profile: "alpha", surface: "mobile" }],
    ]),
  });
  await expectViolation("layout_bundle_path_surface_mismatch", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    `import 'package:flutter_client/src/frontend/layout/profiles/beta/desktop/beta_desktop_bundle.dart';\n`,
  );
  await expectViolation("layout_cross_profile_import", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    `import 'package:flutter_client/src/frontend/layout/profiles/alpha/mobile/alpha_mobile_bundle.dart';\n`,
  );
  await expectViolation("layout_cross_surface_import", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

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
      "apps/desktop/lib/src/frontend/layout/layout_chrome_port.dart",
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
    "apps/desktop/lib/src/frontend/layout/business_surface_contract.dart",
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
    "apps/desktop/lib/src/frontend/layout/business_preview_api.dart",
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
    `import 'package:flutter_client/src/contracts/presentation/render_result.dart';
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
    "export 'package:flutter_client/src/frontend/features/agents/agents_surface.dart';\n",
  );
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    "import 'package:flutter_client/src/contracts/presentation/layout_agents_snapshot.dart';\n",
  );
  await expectViolation("layout_shared_feature_ui_import", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    "import /* directive gap */ 'package:flutter_client/src/application/controller/client_controller.dart';\n",
  );
  await expectViolation("layout_complete_controller_import", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await appendRelative(
    fixtureRoot,
    "apps/desktop/lib/src/frontend/layout/layout_palette.dart",
    "import 'package:flutter_client/src/application/controller/client_controller.dart';\n",
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

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    "bool active(data) { if (data.profileId == LayoutProfileId.parse('alpha')) { return true; } return false; }\n",
  );
  await expectViolation("layout_profile_identity_branch_forbidden", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/frontend/shared_profile_branch.dart",
    "bool active(data) { if (data.profileId == LayoutProfileId.parse('alpha')) { return true; } return false; }\n",
  );
  await expectViolation("layout_profile_identity_branch_forbidden", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    `${DEFAULT_LAYOUT_BOUNDARY_CONFIG.profileSourceRoot}/alpha/desktop/private_component.dart`,
    "final class PrivateComponent {}\n",
  );
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/frontend/shared_private_importer.dart",
    "import 'package:flutter_client/src/frontend/layout/profiles/alpha/desktop/private_component.dart';\n",
  );
  await expectViolation("layout_profile_private_importer_unauthorized", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/unauthorized_bundle_importer.dart",
    `import 'package:flutter_client/src/frontend/layout/profiles/alpha/desktop/alpha_desktop_bundle.dart';\n`,
  );
  await expectViolation("layout_bundle_importer_unauthorized", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  const before = await verifyLayoutBoundaries({ repositoryRoot: fixtureRoot });
  await appendRelative(
    fixtureRoot,
    bundlePath("alpha", "desktop"),
    "\nvoid ownerOnlyChange() {}\n",
  );
  const after = await verifyLayoutBoundaries({ repositoryRoot: fixtureRoot });
  assert(
    before.ownerDigests["alpha/desktop"] !==
        after.ownerDigests["alpha/desktop"] &&
      before.ownerDigests["beta/mobile"] === after.ownerDigests["beta/mobile"],
    "layout_boundary_self_test_change_isolation_failed",
  );
  checks += 1;

  process.stdout.write(
    `${JSON.stringify({ ok: true, mode: "self-test", checks })}\n`,
  );
} finally {
  await rm(fixtureRoot, { recursive: true, force: true });
}
