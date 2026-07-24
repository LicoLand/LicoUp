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

export async function runIdentityCases(fixtureRoot, profiles, surfaces) {
  let checks = 0;
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
    "import 'package:licoup/src/frontend/layout/profiles/alpha/desktop/private_component.dart';\n",
  );
  await expectViolation("layout_profile_private_importer_unauthorized", () =>
    verifyLayoutBoundaries({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    "apps/desktop/lib/src/unauthorized_bundle_importer.dart",
    `import 'package:licoup/src/frontend/layout/profiles/alpha/desktop/alpha_desktop_bundle.dart';\n`,
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

  return checks;
}
