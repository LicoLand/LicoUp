#!/usr/bin/env node

import { mkdir, mkdtemp, readFile, rm, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import {
  DEFAULT_LAYOUT_VISUAL_CONFIG,
  LayoutVisualManifestError,
  checkLayoutVisualManifests,
  discoverLayoutCatalog,
  generateLayoutVisualManifests,
  renderLayoutVisualManifest,
  writeLayoutVisualManifests,
} from "./verify-layout-visual-manifests.mjs";

const profileContractPath =
  "apps/desktop/lib/src/contracts/presentation/layout_profile.dart";

function assert(condition, code) {
  if (!condition) {
    throw new Error(code);
  }
}

function variableName(profile, surface) {
  const title = (value) => `${value[0].toUpperCase()}${value.slice(1)}`;
  return `${profile}${title(surface)}Bundle`;
}

async function writeRelative(root, relativePath, source) {
  const absolutePath = path.join(root, ...relativePath.split("/"));
  await mkdir(path.dirname(absolutePath), { recursive: true });
  await writeFile(absolutePath, source);
}

async function writeCatalogFixture(root, profiles, surfaces) {
  await writeRelative(
    root,
    profileContractPath,
    "final class LayoutProfileId {\n  const LayoutProfileId._(this.value);\n  factory LayoutProfileId.parse(String value) => LayoutProfileId._(value);\n  final String value;\n}\n",
  );
  await writeRelative(
    root,
    DEFAULT_LAYOUT_VISUAL_CONFIG.surfaceContractPath,
    `enum LayoutRuntimeSurface { ${surfaces.join(", ")} }\n`,
  );

  const imports = [];
  const definitions = [];
  for (const profile of profiles) {
    const symbols = [];
    for (const surface of surfaces) {
      const symbol = variableName(profile, surface);
      const relativePath =
        `${DEFAULT_LAYOUT_VISUAL_CONFIG.profileSourceRoot}/${profile}/${surface}/${profile}_${surface}_bundle.dart`;
      imports.push(
        `import 'package:licoup/${relativePath.slice("apps/desktop/lib/".length)}';`,
      );
      symbols.push(symbol);
      await writeRelative(
        root,
        relativePath,
        `final LayoutSurfaceBundle ${symbol} = LayoutSurfaceBundle(\n  profile: LayoutProfileDescriptor(id: LayoutProfileId.parse('${profile}')),\n  surface: LayoutRuntimeSurface.${surface},\n);\n`,
      );
    }
    definitions.push(`    LayoutDefinition([${symbols.join(", ")}]),`);
  }
  await writeRelative(
    root,
    DEFAULT_LAYOUT_VISUAL_CONFIG.compositionPath,
    `${imports.join("\n")}\n\nfinal definitions = <LayoutDefinition>[\n${definitions.join("\n")}\n];\n`,
  );
  await writeRelative(
    root,
    DEFAULT_LAYOUT_VISUAL_CONFIG.productionBaselineFixturePath,
    "final class ProductionBaselineFixture {}\n",
  );
  await writeRelative(
    root,
    DEFAULT_LAYOUT_VISUAL_CONFIG.productionBaselineTestPath,
    "void main() {}\n",
  );
  await writeRelative(
    root,
    DEFAULT_LAYOUT_VISUAL_CONFIG.productionContinuityTestPath,
    "void main() {}\n",
  );
}

async function expectViolation(code, operation) {
  try {
    await operation();
  } catch (error) {
    if (
      (error instanceof LayoutVisualManifestError ||
        typeof error?.code === "string") &&
      error.code === code
    ) {
      return;
    }
    throw error;
  }
  throw new Error(`layout_visual_manifest_self_test_missing_${code}`);
}

function ownerDigest(generated, owner) {
  const expected = generated.manifests.find(
    (candidate) =>
      `${candidate.manifest.profile}/${candidate.manifest.surface}` === owner,
  );
  assert(expected != null, "layout_visual_manifest_self_test_owner_missing");
  return expected.manifest.manifestDigest;
}

const fixtureRoot = await mkdtemp(
  path.join(os.tmpdir(), "lico-layout-visual-manifest-"),
);
let checks = 0;
try {
  const profiles = ["alpha", "beta"];
  const surfaces = ["desktop", "mobile"];
  await writeCatalogFixture(fixtureRoot, profiles, surfaces);
  await writeRelative(
    fixtureRoot,
    `${DEFAULT_LAYOUT_VISUAL_CONFIG.assetRoot}/alpha/desktop/icon.bin`,
    Buffer.from([0, 1, 2, 3]),
  );
  await writeRelative(
    fixtureRoot,
    `${DEFAULT_LAYOUT_VISUAL_CONFIG.profileTestRoot}/alpha/desktop/widget_test.dart`,
    "void main() {}\n",
  );
  await writeRelative(
    fixtureRoot,
    `${DEFAULT_LAYOUT_VISUAL_CONFIG.goldenRoot}/alpha/desktop/preview.png`,
    Buffer.from([137, 80, 78, 71]),
  );
  await writeRelative(
    fixtureRoot,
    `${DEFAULT_LAYOUT_VISUAL_CONFIG.goldenRoot}/production-baseline/alpha/desktop/home.png`,
    Buffer.from([137, 80, 78, 71, 13, 10]),
  );

  const baselineCatalog = await discoverLayoutCatalog({
    repositoryRoot: fixtureRoot,
  });
  assert(
    baselineCatalog.profiles.length === profiles.length &&
      baselineCatalog.surfaces.length === surfaces.length &&
      baselineCatalog.bundles.length === profiles.length * surfaces.length,
    "layout_visual_manifest_self_test_baseline_discovery_failed",
  );
  checks += 1;

  const incompleteSurface = "wearable";
  await writeRelative(
    fixtureRoot,
    DEFAULT_LAYOUT_VISUAL_CONFIG.surfaceContractPath,
    `enum LayoutRuntimeSurface { ${[...surfaces, incompleteSurface].join(", ")} }\n`,
  );
  await expectViolation(
    "layout_composition_profile_surface_product_incomplete",
    () => discoverLayoutCatalog({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;
  await writeCatalogFixture(fixtureRoot, profiles, surfaces);

  const baseline = await generateLayoutVisualManifests({
    repositoryRoot: fixtureRoot,
  });
  const siblingOwner = `${profiles[1]}/${surfaces[0]}`;
  const siblingBaselineDigest = ownerDigest(baseline, siblingOwner);
  const alphaDesktop = baseline.manifests.find(
    (candidate) =>
      candidate.manifest.profile === profiles[0] &&
      candidate.manifest.surface === surfaces[0],
  );
  assert(
    alphaDesktop.manifest.sourceRoots.length === 5 &&
      alphaDesktop.manifest.authorityEntries.length === 3 &&
      alphaDesktop.manifest.sourceRoots.some((root) =>
        root.endsWith("/production-baseline/alpha/desktop"),
      ),
    "layout_visual_manifest_self_test_mirrored_roots_missing",
  );
  checks += 1;

  const failureDirectory =
    `${DEFAULT_LAYOUT_VISUAL_CONFIG.profileTestRoot}/alpha/desktop/failures`;
  await writeRelative(
    fixtureRoot,
    `${failureDirectory}/preview_testImage.png`,
    Buffer.from([137, 80, 78, 71]),
  );
  await expectViolation("layout_visual_generated_residue_forbidden", () =>
    generateLayoutVisualManifests({ repositoryRoot: fixtureRoot }),
  );
  await rm(path.join(fixtureRoot, ...failureDirectory.split("/")), {
    recursive: true,
    force: true,
  });
  checks += 1;

  const staleReceipt =
    `${DEFAULT_LAYOUT_VISUAL_CONFIG.goldenRoot}/alpha/desktop/source-golden.sha256`;
  await writeRelative(fixtureRoot, staleReceipt, "stale\n");
  await expectViolation("layout_visual_generated_residue_forbidden", () =>
    generateLayoutVisualManifests({ repositoryRoot: fixtureRoot }),
  );
  await unlink(path.join(fixtureRoot, ...staleReceipt.split("/")));
  checks += 1;

  await writeLayoutVisualManifests({ repositoryRoot: fixtureRoot });
  await checkLayoutVisualManifests({ repositoryRoot: fixtureRoot });
  checks += 1;

  const copiedFrom = baseline.manifests[0];
  const copiedTo = baseline.manifests.find(
    (candidate) => candidate.path !== copiedFrom.path,
  );
  await writeRelative(
    fixtureRoot,
    copiedTo.path,
    renderLayoutVisualManifest(copiedFrom.manifest),
  );
  await expectViolation("layout_visual_manifest_copied", () =>
    checkLayoutVisualManifests({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;
  await writeLayoutVisualManifests({ repositoryRoot: fixtureRoot });

  const crossProfilePath = path.join(
    fixtureRoot,
    ...copiedTo.path.split("/"),
  );
  const crossProfileManifest = JSON.parse(
    await readFile(crossProfilePath, "utf8"),
  );
  crossProfileManifest.entries[0].path =
    copiedFrom.manifest.entries[0].path;
  await writeFile(
    crossProfilePath,
    renderLayoutVisualManifest(crossProfileManifest),
    "utf8",
  );
  await expectViolation("layout_visual_manifest_cross_profile_path", () =>
    checkLayoutVisualManifests({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;
  await writeLayoutVisualManifests({ repositoryRoot: fixtureRoot });

  await unlink(crossProfilePath);
  await expectViolation("layout_visual_manifest_missing", () =>
    checkLayoutVisualManifests({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;
  await writeLayoutVisualManifests({ repositoryRoot: fixtureRoot });

  const baselineBundle = baseline.catalog.bundles[0];
  await writeRelative(
    fixtureRoot,
    baselineBundle.entryPath,
    `${await readFile(
      path.join(fixtureRoot, ...baselineBundle.entryPath.split("/")),
      "utf8",
    )}\n// visual source changed\n`,
  );
  await expectViolation("layout_visual_manifest_stale", () =>
    checkLayoutVisualManifests({ repositoryRoot: fixtureRoot }),
  );
  checks += 1;

  const addedProfile = "gamma";
  const expandedProfiles = [...profiles, addedProfile];
  await writeCatalogFixture(fixtureRoot, expandedProfiles, surfaces);
  const profileExpanded = await generateLayoutVisualManifests({
    repositoryRoot: fixtureRoot,
  });
  assert(
    profileExpanded.catalog.profiles.includes(addedProfile) &&
      profileExpanded.catalog.bundles.length ===
        expandedProfiles.length * surfaces.length &&
      ownerDigest(profileExpanded, siblingOwner) === siblingBaselineDigest,
    "layout_visual_manifest_self_test_added_profile_discovery_failed",
  );
  checks += 1;

  const addedSurface = incompleteSurface;
  const expandedSurfaces = [...surfaces, addedSurface];
  await writeCatalogFixture(
    fixtureRoot,
    expandedProfiles,
    expandedSurfaces,
  );
  const surfaceExpanded = await generateLayoutVisualManifests({
    repositoryRoot: fixtureRoot,
  });
  assert(
    surfaceExpanded.catalog.surfaces.includes(addedSurface) &&
      surfaceExpanded.catalog.bundles.length ===
        expandedProfiles.length * expandedSurfaces.length &&
      ownerDigest(surfaceExpanded, siblingOwner) === siblingBaselineDigest,
    "layout_visual_manifest_self_test_added_surface_discovery_failed",
  );
  checks += 1;

  await writeLayoutVisualManifests({ repositoryRoot: fixtureRoot });
  await checkLayoutVisualManifests({ repositoryRoot: fixtureRoot });
  checks += 1;

  process.stdout.write(
    `${JSON.stringify({ ok: true, mode: "self-test", checks })}\n`,
  );
} finally {
  await rm(fixtureRoot, { recursive: true, force: true });
}
