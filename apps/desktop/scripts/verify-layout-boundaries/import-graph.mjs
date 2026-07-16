import { importsFrom, resolveDartImport } from "./dart-source.mjs";
import {
  containsCompleteControllerReference,
  containsDestinationPresentationScope,
  containsPublicBusinessPortDeclaration,
  forbiddenDependencyCode,
  forbiddenNeutralPortApiCode,
  importsFlutterWidgetFramework,
  isDirectNeutralDependency,
  isNeutralClosureDependency,
} from "./dependency-policy.mjs";
import { fail } from "./errors.mjs";
import {
  codeOwnerFor,
  ownerKey,
  sourceOwnerFor,
  testOwnerFor,
} from "./ownership.mjs";
import { compareCanonical } from "./paths.mjs";

export function validatePublicLayoutPortApis(catalog, sourceByPath, graph) {
  const publicPortSeeds = [...sourceByPath]
    .filter(
      ([relativePath, source]) =>
        sourceOwnerFor(catalog, relativePath) == null &&
        containsPublicBusinessPortDeclaration(catalog, relativePath, source),
    )
    .map(([relativePath]) => relativePath);
  const publicPortSeedSet = new Set(publicPortSeeds);
  const publicPortClosure = transitiveClosure(graph, publicPortSeeds);
  for (const relativePath of publicPortClosure) {
    const source = sourceByPath.get(relativePath);
    if (source == null) {
      continue;
    }
    if (containsDestinationPresentationScope(source)) {
      fail("layout_destination_presentation_scope_forbidden", relativePath);
    }
    if (
      publicPortSeedSet.has(relativePath) &&
      importsFlutterWidgetFramework(source)
    ) {
      fail("layout_widget_producing_port_forbidden", relativePath);
    }
    const forbiddenCode = forbiddenNeutralPortApiCode(source);
    if (forbiddenCode != null) {
      fail(forbiddenCode, relativePath);
    }
  }
}

export function validateBundleImporter(catalog, relativePath, source) {
  const bundleEntries = new Set(
    catalog.bundles.map((bundle) => bundle.entryPath),
  );
  for (const specifier of importsFrom(source)) {
    const resolved = resolveDartImport(relativePath, specifier);
    if (resolved == null || !bundleEntries.has(resolved)) {
      continue;
    }
    if (relativePath === catalog.config.compositionPath) {
      continue;
    }
    const importerOwner = testOwnerFor(catalog, relativePath);
    const importedOwner = sourceOwnerFor(catalog, resolved);
    if (importerOwner != null && importerOwner.id === importedOwner?.id) {
      continue;
    }
    fail("layout_bundle_importer_unauthorized", relativePath);
  }
}

export function validateProfilePrivateImporter(catalog, relativePath, source) {
  const bundleEntries = new Set(
    catalog.bundles.map((bundle) => bundle.entryPath),
  );
  const importerOwner = codeOwnerFor(catalog, relativePath);
  for (const specifier of importsFrom(source)) {
    const resolved = resolveDartImport(relativePath, specifier);
    if (resolved == null) {
      continue;
    }
    const importedOwner = sourceOwnerFor(catalog, resolved);
    if (importedOwner == null) {
      continue;
    }
    if (
      relativePath === catalog.config.compositionPath &&
      bundleEntries.has(resolved)
    ) {
      continue;
    }
    if (importerOwner?.id === importedOwner.id) {
      continue;
    }
    fail("layout_profile_private_importer_unauthorized", relativePath);
  }
}

export function buildImportGraph(sourceByPath) {
  const graph = new Map();
  for (const [relativePath, source] of sourceByPath) {
    graph.set(
      relativePath,
      importsFrom(source)
        .map((specifier) => resolveDartImport(relativePath, specifier))
        .filter((candidate) => candidate != null && sourceByPath.has(candidate)),
    );
  }
  return graph;
}

export function transitiveClosure(graph, starts) {
  const visited = new Set();
  const pending = [...starts];
  while (pending.length > 0) {
    const current = pending.pop();
    if (visited.has(current)) {
      continue;
    }
    visited.add(current);
    for (const dependency of graph.get(current) ?? []) {
      if (!visited.has(dependency)) {
        pending.push(dependency);
      }
    }
  }
  return visited;
}

export function validateTransitiveClosures(catalog, sourceByPath, sourceFiles) {
  const graph = buildImportGraph(sourceByPath);
  for (const [relativePath, source] of sourceByPath) {
    if (containsDestinationPresentationScope(source)) {
      fail("layout_destination_presentation_scope_forbidden", relativePath);
    }
  }
  const neutralSeeds = [...sourceByPath.keys()].filter(isDirectNeutralDependency);
  const neutralClosure = transitiveClosure(graph, neutralSeeds);
  for (const relativePath of neutralClosure) {
    const forbiddenCode = forbiddenDependencyCode(relativePath);
    if (forbiddenCode != null) {
      fail(forbiddenCode, relativePath);
    }
    if (!isNeutralClosureDependency(relativePath)) {
      fail("layout_neutral_contract_closure_forbidden", relativePath);
    }
  }
  validatePublicLayoutPortApis(catalog, sourceByPath, graph);

  const closureByOwner = new Map();
  for (const bundle of catalog.bundles) {
    const owner = ownerKey(bundle.profile, bundle.surface);
    const starts = sourceFiles.filter(
      (relativePath) => sourceOwnerFor(catalog, relativePath)?.id === owner,
    );
    const closure = transitiveClosure(graph, starts);
    for (const relativePath of closure) {
      const dependencyOwner = sourceOwnerFor(catalog, relativePath);
      if (dependencyOwner != null && dependencyOwner.id !== owner) {
        if (dependencyOwner.profile !== bundle.profile) {
          fail("layout_cross_profile_import", bundle.entryPath);
        }
        fail("layout_cross_surface_import", bundle.entryPath);
      }
      const forbiddenCode = forbiddenDependencyCode(relativePath);
      if (forbiddenCode != null) {
        fail(forbiddenCode, bundle.entryPath);
      }
      const source = sourceByPath.get(relativePath);
      if (source != null && containsCompleteControllerReference(source)) {
        fail("layout_complete_controller_reference", bundle.entryPath);
      }
      if (source != null && containsDestinationPresentationScope(source)) {
        fail("layout_destination_presentation_scope_forbidden", bundle.entryPath);
      }
    }
    closureByOwner.set(owner, closure);
  }

  const owners = [...closureByOwner.keys()].sort(compareCanonical);
  for (let leftIndex = 0; leftIndex < owners.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < owners.length; rightIndex += 1) {
      const leftOwner = owners[leftIndex];
      const rightOwner = owners[rightIndex];
      const rightClosure = closureByOwner.get(rightOwner);
      for (const relativePath of closureByOwner.get(leftOwner)) {
        if (rightClosure.has(relativePath) && !neutralClosure.has(relativePath)) {
          fail(
            "layout_transitive_closure_intersection_forbidden",
            `${leftOwner}:${rightOwner}:${relativePath}`,
          );
        }
      }
    }
  }
  return closureByOwner;
}
