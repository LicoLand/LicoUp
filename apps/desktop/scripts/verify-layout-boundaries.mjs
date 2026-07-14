#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);

const profiles = ["workbench", "studio"];
const surfaces = ["desktop", "mobile"];
const ownerSpecs = profiles.flatMap((profile) =>
  surfaces.map((surface) => ({
    id: `${profile}/${surface}`,
    profile,
    surface,
    prefixes: [
      `apps/desktop/lib/src/frontend/layout/profiles/${profile}/${surface}/`,
      `apps/desktop/test/layout/profiles/${profile}/${surface}/`,
      `apps/desktop/test/goldens/layout/${profile}/${surface}/`,
      `apps/desktop/assets/layout-profiles/${profile}/${surface}/`,
    ],
  })),
);

const compositionRoot =
  "apps/desktop/lib/src/frontend/layout/built_in_layout_composition.dart";

class BoundaryViolation extends Error {
  constructor(code, relativePath = "") {
    super(relativePath ? `${code}: ${relativePath}` : code);
    this.code = code;
  }
}

function normalize(value) {
  return value.split(path.sep).join("/");
}

function ownerFor(relativePath) {
  return ownerSpecs.filter((owner) =>
    owner.prefixes.some((prefix) => relativePath.startsWith(prefix)),
  );
}

async function collectFiles(relativeDirectory) {
  const absoluteDirectory = path.join(repositoryRoot, relativeDirectory);
  let entries;
  try {
    entries = await readdir(absoluteDirectory, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") {
      return [];
    }
    throw error;
  }
  const files = [];
  for (const entry of entries) {
    const child = `${relativeDirectory}/${entry.name}`;
    if (entry.isDirectory()) {
      files.push(...(await collectFiles(child)));
    } else if (entry.isFile()) {
      files.push(child);
    }
  }
  return files.sort();
}

function importsFrom(source) {
  const imports = [];
  const expression = /^\s*(?:import|export|part)\s+['"]([^'"]+)['"]/gm;
  for (const match of source.matchAll(expression)) {
    imports.push(match[1]);
  }
  return imports;
}

function resolveImport(importer, specifier) {
  if (specifier.startsWith("package:flutter_client/")) {
    return `apps/desktop/lib/${specifier.slice("package:flutter_client/".length)}`;
  }
  if (specifier.startsWith(".")) {
    return normalize(path.posix.normalize(path.posix.join(path.posix.dirname(importer), specifier)));
  }
  return null;
}

function validateProfileSource(relativePath, source) {
  const owners = ownerFor(relativePath);
  if (owners.length !== 1) {
    throw new BoundaryViolation("layout_owned_path_ambiguous", relativePath);
  }
  const owner = owners[0];
  for (const specifier of importsFrom(source)) {
    const profileTest = relativePath.startsWith(
      "apps/desktop/test/layout/profiles/",
    );
    if (
      specifier.startsWith("dart:") ||
      specifier.startsWith("package:flutter/") ||
      (profileTest && specifier.startsWith("package:flutter_test/"))
    ) {
      continue;
    }
    const resolved = resolveImport(relativePath, specifier);
    if (resolved == null) {
      throw new BoundaryViolation("layout_external_import_forbidden", relativePath);
    }
    const importedOwners = ownerFor(resolved);
    if (importedOwners.length > 0) {
      if (importedOwners.some((candidate) => candidate.id !== owner.id)) {
        throw new BoundaryViolation("layout_cross_profile_import", relativePath);
      }
      continue;
    }
    const allowed =
      resolved.startsWith("apps/desktop/lib/src/contracts/presentation/") ||
      resolved.startsWith("apps/desktop/lib/src/frontend/l10n/") ||
      (profileTest &&
        resolved.startsWith("apps/desktop/test/layout/fixtures/")) ||
      (resolved.startsWith("apps/desktop/lib/src/frontend/layout/") &&
        !resolved.includes("/profiles/") &&
        !resolved.endsWith("layout_registry.dart") &&
        !resolved.endsWith("built_in_layout_composition.dart")) ||
      resolved === "apps/desktop/lib/src/frontend/shared/ui/theme.dart";
    if (!allowed) {
      if (resolved.includes("client_controller.dart")) {
        throw new BoundaryViolation("layout_complete_controller_import", relativePath);
      }
      if (resolved.includes("/frontend/shell/")) {
        throw new BoundaryViolation("layout_legacy_shell_import", relativePath);
      }
      if (resolved.includes("/backend/") || resolved.includes("/platform/")) {
        throw new BoundaryViolation("layout_implementation_import", relativePath);
      }
      if (resolved.includes("/frontend/shared/ui/")) {
        throw new BoundaryViolation("layout_shared_styled_import", relativePath);
      }
      throw new BoundaryViolation("layout_import_not_allowlisted", relativePath);
    }
  }
  for (const token of [
    "LayoutRegistry(",
    "registerLayout(",
    "registerLayoutProfile(",
    "built_in_layout_composition",
  ]) {
    if (source.includes(token)) {
      throw new BoundaryViolation("layout_mutable_registration_forbidden", relativePath);
    }
  }
}

function isBundleEntryImport(specifier) {
  return /\/profiles\/(workbench|studio)\/(desktop|mobile)\/(?:workbench_desktop|studio_desktop|workbench_mobile_bundle|studio_mobile_bundle)\.dart$/.test(
    specifier,
  );
}

function validateBundleImporter(relativePath, source) {
  for (const specifier of importsFrom(source)) {
    const resolved = resolveImport(relativePath, specifier);
    if (resolved == null || !isBundleEntryImport(`/${resolved}`)) {
      continue;
    }
    if (relativePath === compositionRoot) {
      continue;
    }
    const importedOwner = ownerFor(resolved)[0];
    const importerOwner = ownerFor(relativePath)[0];
    const allowedProfileTest =
      relativePath.startsWith("apps/desktop/test/layout/profiles/") &&
      importedOwner != null &&
      importerOwner != null &&
      importedOwner.id === importerOwner.id;
    if (!allowedProfileTest) {
      throw new BoundaryViolation("layout_bundle_importer_unauthorized", relativePath);
    }
  }
}

function digestManifest(files) {
  const hash = createHash("sha256");
  for (const [relativePath, source] of [...files].sort(([left], [right]) => left.localeCompare(right))) {
    hash.update(relativePath);
    hash.update("\0");
    hash.update(source);
    hash.update("\0");
  }
  return hash.digest("hex");
}

function expectViolation(code, operation) {
  try {
    operation();
  } catch (error) {
    if (error instanceof BoundaryViolation && error.code === code) {
      return;
    }
    throw error;
  }
  throw new Error(`layout_boundary_self_test_missing_${code}`);
}

function runSelfTests() {
  const base =
    "apps/desktop/lib/src/frontend/layout/profiles/workbench/desktop/workbench_desktop.dart";
  expectViolation("layout_cross_profile_import", () =>
    validateProfileSource(
      base,
      "import '../../studio/desktop/studio_desktop.dart';",
    ),
  );
  expectViolation("layout_complete_controller_import", () =>
    validateProfileSource(
      base,
      "import 'package:flutter_client/src/application/controller/client_controller.dart';",
    ),
  );
  expectViolation("layout_cross_profile_import", () =>
    validateProfileSource(
      base,
      "import '../mobile/workbench_mobile_bundle.dart';",
    ),
  );
  expectViolation("layout_legacy_shell_import", () =>
    validateProfileSource(
      base,
      "import 'package:flutter_client/src/frontend/shell/client_shell.dart';",
    ),
  );
  expectViolation("layout_implementation_import", () =>
    validateProfileSource(
      base,
      "import 'package:flutter_client/src/platform/storage/portable_data_root.dart';",
    ),
  );
  expectViolation("layout_shared_styled_import", () =>
    validateProfileSource(
      base,
      "import 'package:flutter_client/src/frontend/shared/ui/panel_frame.dart';",
    ),
  );
  expectViolation("layout_mutable_registration_forbidden", () =>
    validateProfileSource(base, "void build() { registerLayout(); }"),
  );
  expectViolation("layout_bundle_importer_unauthorized", () =>
    validateBundleImporter(
      "apps/desktop/lib/app.dart",
      "import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/workbench_desktop.dart';",
    ),
  );

  const before = new Map([
    ["workbench/a.dart", "alpha"],
    ["studio/b.dart", "beta"],
  ]);
  const workbenchBefore = digestManifest(
    [...before].filter(([relativePath]) =>
      relativePath.startsWith("workbench/"),
    ),
  );
  const studioBefore = digestManifest(
    [...before].filter(([relativePath]) => relativePath.startsWith("studio/")),
  );
  before.set("workbench/a.dart", "changed");
  const workbenchAfter = digestManifest(
    [...before].filter(([relativePath]) =>
      relativePath.startsWith("workbench/"),
    ),
  );
  const studioAfter = digestManifest(
    [...before].filter(([relativePath]) => relativePath.startsWith("studio/")),
  );
  if (workbenchBefore === workbenchAfter || studioBefore !== studioAfter) {
    throw new Error("layout_change_impact_isolation_failed");
  }
  return 9;
}

async function runLiveChecks() {
  const ownedFiles = (
    await Promise.all(
      ownerSpecs.flatMap((owner) => owner.prefixes.map(collectFiles)),
    )
  ).flat();
  const uniqueOwnedFiles = [...new Set(ownedFiles)].sort();
  for (const relativePath of uniqueOwnedFiles) {
    if (ownerFor(relativePath).length !== 1) {
      throw new BoundaryViolation("layout_owned_path_overlap", relativePath);
    }
  }

  const profileDartFiles = uniqueOwnedFiles.filter((relativePath) =>
    relativePath.endsWith(".dart"),
  );
  for (const relativePath of profileDartFiles) {
    validateProfileSource(
      relativePath,
      await readFile(path.join(repositoryRoot, relativePath), "utf8"),
    );
  }

  const importScanFiles = [
    ...(await collectFiles("apps/desktop/lib")),
    ...(await collectFiles("apps/desktop/test/layout")),
  ].filter((relativePath) => relativePath.endsWith(".dart"));
  for (const relativePath of importScanFiles) {
    validateBundleImporter(
      relativePath,
      await readFile(path.join(repositoryRoot, relativePath), "utf8"),
    );
  }
  return { ownedFiles: uniqueOwnedFiles.length, profileFiles: profileDartFiles.length };
}

const selfTests = runSelfTests();
const live = process.argv.includes("--self-test")
  ? { ownedFiles: 0, profileFiles: 0 }
  : await runLiveChecks();

process.stdout.write(
  `${JSON.stringify({ ok: true, selfTests, ...live })}\n`,
);
