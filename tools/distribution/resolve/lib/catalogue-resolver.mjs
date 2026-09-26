import { requireFact } from "../../../architecture-graph/lib/canonical.mjs";

/**
 * The install closure, computed with the product's dependency semantics.
 *
 * `crates/licoup-extension-contracts/src/deployment.rs` owns this algorithm for
 * the product: `requires` decides what is installed, `optionalRequires` is
 * reported as declined and never installed, an unknown package is refused with
 * the dependent named, and a `requires` cycle is refused outright. The plan side
 * must preview the same closure, so it reimplements the declared semantics and
 * proves equality against shared test vectors
 * (`tests/contract/v71_distribution/vectors/catalogue-cases.json`) that are
 * anchored to the product source by
 * `tests/contract/v71_distribution/catalogue-differential.test.mjs`.
 *
 * No range is solved here: the product records a version range and leaves
 * constraint resolution to the host package manager. This resolver follows
 * package ids only, exactly like `install_closure`.
 */

export const CATALOGUE_SCHEMA = "licoup.distribution-catalogue.v1";

export const CLOSURE_REFUSALS = Object.freeze({
  PACKAGE_UNAVAILABLE: "install_package_unavailable",
  DEPENDENCY_CYCLE: "install_dependency_cycle",
  CORE_REQUIRES_OPTIONAL: "core_requires_optional_package",
});

function packageIndex(catalogue) {
  requireFact(catalogue !== null && typeof catalogue === "object" && !Array.isArray(catalogue),
    "a catalogue object is required");
  requireFact(typeof catalogue.core_package === "string" && catalogue.core_package.length > 0,
    "a catalogue needs its core package id");
  requireFact(Array.isArray(catalogue.packages), "a catalogue needs a packages array");
  const index = new Map();
  for (const entry of catalogue.packages) {
    requireFact(entry !== null && typeof entry === "object", "each catalogue package must be an object");
    requireFact(typeof entry.id === "string" && entry.id.length > 0, "each catalogue package needs an id");
    requireFact(!index.has(entry.id), `duplicate catalogue package: ${entry.id}`);
    const requires = entry.requires ?? [];
    const optionalRequires = entry.optionalRequires ?? [];
    requireFact(Array.isArray(requires) && Array.isArray(optionalRequires),
      `package ${entry.id} requires and optionalRequires must be arrays`);
    const dependencyId = (dependency, label) => {
      requireFact(dependency !== null && typeof dependency === "object"
        && typeof dependency.packageId === "string" && dependency.packageId.length > 0,
      `package ${entry.id} has ${label} without a packageId`);
      return { packageId: dependency.packageId, range: dependency.range ?? null };
    };
    index.set(entry.id, {
      id: entry.id,
      version: entry.version ?? null,
      source: entry.source ?? null,
      requires: requires.map((dependency) => dependencyId(dependency, "a dependency")),
      optionalRequires: optionalRequires.map((dependency) => dependencyId(dependency, "an optional dependency")),
    });
  }
  return index;
}

/** The distribution graph as a catalogue, so the plan preview reads the same input shape. */
export function catalogueFromGraph(graph) {
  return {
    schema: CATALOGUE_SCHEMA,
    core_package: graph.distribution.core_package,
    packages: [...graph.packages.values()].map((pkg) => ({
      id: pkg.id,
      version: null,
      source: "distribution-graph",
      requires: pkg.requires_package.map((packageId) => ({ packageId, range: null })),
      optionalRequires: [],
    })),
  };
}

/**
 * The minimal core may not depend on anything that can be trimmed away.
 * Mirrors `check_core_dependencies`; a catalogue without the core is accepted
 * because the core's own presence is a deployment fact, not a closure rule.
 */
export function checkCoreDependencies(catalogue, index = packageIndex(catalogue)) {
  const core = index.get(catalogue.core_package);
  if (core === undefined || core.requires.length === 0) return { ok: true };
  const dependency = core.requires[0];
  return {
    ok: false,
    code: CLOSURE_REFUSALS.CORE_REQUIRES_OPTIONAL,
    package: dependency.packageId,
    required_by: null,
    field: "requires",
    note: "The minimal core does not depend on anything removable.",
  };
}

/**
 * Compute the install closure of `roots` with the product's semantics.
 *
 * The traversal mirrors the Rust `install_closure` frame order, including the
 * reversed dependency order, so a refused cycle names the same package on both
 * sides instead of merely reporting the same code.
 */
export function resolveInstallClosure(catalogue, roots) {
  requireFact(Array.isArray(roots), "closure roots must be an array");
  const index = packageIndex(catalogue);
  const coreCheck = checkCoreDependencies(catalogue, index);
  if (!coreCheck.ok) return coreCheck;

  const selected = new Set();
  const declined = new Set();
  const visiting = new Set();
  const done = new Set();

  for (const root of roots) {
    requireFact(typeof root === "string" && root.length > 0, "a closure root must be a package id");
    if (!index.has(root)) {
      return {
        ok: false,
        code: CLOSURE_REFUSALS.PACKAGE_UNAVAILABLE,
        package: root,
        required_by: null,
        field: "packageId",
        note: "The root package is not in this catalogue.",
      };
    }
    const stack = [{ kind: "enter", packageId: root }];
    while (stack.length > 0) {
      const frame = stack.pop();
      if (frame.kind === "exit") {
        visiting.delete(frame.packageId);
        done.add(frame.packageId);
        selected.add(frame.packageId);
        continue;
      }
      const packageId = frame.packageId;
      if (done.has(packageId)) continue;
      visiting.add(packageId);
      stack.push({ kind: "exit", packageId });
      const entry = index.get(packageId);
      for (let position = entry.requires.length - 1; position >= 0; position -= 1) {
        const dependency = entry.requires[position].packageId;
        if (visiting.has(dependency)) {
          return {
            ok: false,
            code: CLOSURE_REFUSALS.DEPENDENCY_CYCLE,
            // The product publishes the revisited package for a cycle and no
            // dependent, so the preview must not invent one.
            package: dependency,
            required_by: null,
            field: "requires",
            note: "A cycle among requires entries has no install order.",
          };
        }
        if (done.has(dependency)) continue;
        if (!index.has(dependency)) {
          return {
            ok: false,
            code: CLOSURE_REFUSALS.PACKAGE_UNAVAILABLE,
            package: dependency,
            required_by: packageId,
            field: "packageId",
            note: "A required package is not in this catalogue.",
          };
        }
        stack.push({ kind: "enter", packageId: dependency });
      }
      for (const dependency of entry.optionalRequires) declined.add(dependency.packageId);
    }
  }

  return {
    ok: true,
    selected: [...selected].sort(),
    declined_optional: [...declined].filter((packageId) => !selected.has(packageId)).sort(),
    note: "Requires decides the closure. Optional dependencies are reported and never installed here.",
  };
}
