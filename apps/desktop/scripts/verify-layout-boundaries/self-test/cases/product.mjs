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

export async function runProductCases(fixtureRoot, profiles, surfaces) {
  let checks = 0;
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

  return { checks };
}
