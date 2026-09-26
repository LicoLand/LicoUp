import { requireFact } from "../../../architecture-graph/lib/canonical.mjs";

/**
 * The product's capability ownership table (C12), read from the plan side.
 *
 * The product owns this fact in `crates/licoup-extension-contracts/src/deployment.rs`
 * (`CAPABILITY_OWNERSHIP`) and publishes it in
 * `docs/architecture/DEPLOYMENT-PROFILES.md` (section 3). The copy below exists
 * only because a Node tool cannot link the Rust crate;
 * `tests/contract/distribution/provider-ownership.test.mjs` extracts both
 * owners and fails when the three disagree, so this cannot drift silently.
 *
 * Owner means "the package that must be present for this capability to work at
 * all". One capability may be offered by several packages; the table names the
 * one the default distribution provides.
 */

export const NAMESPACED_CAPABILITY_PATTERN = /^[a-z0-9]+(?:[.-][a-z0-9]+)+(?:[./-][A-Za-z0-9_-]+)*$/u;

export const PRODUCT_CAPABILITY_OWNERSHIP = Object.freeze(
  [
    { capability: "conversation.v1", owner: "org.licoland.core", set: "core" },
    { capability: "extension-host.v1", owner: "org.licoland.core", set: "core" },
    { capability: "usage-journal.v1", owner: "org.licoland.core", set: "core" },
    { capability: "declarative-ui.v1", owner: "org.licoland.core", set: "core" },
    { capability: "agent-execution.v1", owner: "org.licoland.adapter.generic", set: "optional" },
    { capability: "model-provider.v1", owner: "org.licoland.provider.compat", set: "optional" },
    { capability: "model-gateway.v1", owner: "org.licoland.feature.gateway", set: "optional" },
    { capability: "analytics.v1", owner: "org.licoland.feature.analytics", set: "optional" },
    { capability: "endpoint-collaboration.v1", owner: "org.licoland.feature.collaboration", set: "optional" },
    { capability: "workflow.v1", owner: "org.licoland.feature.workflow", set: "optional" },
    { capability: "mcp-server.v1", owner: "org.licoland.feature.mcp", set: "optional" },
    { capability: "channel-connector.v1", owner: "org.licoland.feature.channels", set: "optional" },
  ].map((row) => Object.freeze(row)),
);

/**
 * Capabilities the host itself publishes. They are core-owned but are compiled
 * into the host, so a package's `provides` list is not expected to name them.
 * This exception is enumerated rather than implied by a missing check.
 */
export const HOST_PUBLISHED_CAPABILITIES = Object.freeze(
  [
    Object.freeze({
      capability: "declarative-ui.v1",
      reason: "The declarative interface primitives are compiled into the client, so the core package's provides list does not name them; ownership still belongs to the core.",
    }),
  ],
);

export function capabilityOwnership(capability, ownership = PRODUCT_CAPABILITY_OWNERSHIP) {
  return ownership.find((row) => row.capability === capability) ?? null;
}

export function coreOwnedCapabilities(ownership = PRODUCT_CAPABILITY_OWNERSHIP) {
  return ownership.filter((row) => row.set === "core").map((row) => row.capability);
}

export function optionalOwnedCapabilities(ownership = PRODUCT_CAPABILITY_OWNERSHIP) {
  return ownership.filter((row) => row.set === "optional").map((row) => row.capability);
}

/**
 * The capability/provider facts the distribution graph claims, checked against
 * the product's ownership table and its naming rule.
 *
 * This is a declaration check only. It does not observe an installation, prove
 * that a provider is loadable, or grant permission for anything.
 */
export function providerDependencyChecks(graph, {
  ownership = PRODUCT_CAPABILITY_OWNERSHIP,
  hostPublished = HOST_PUBLISHED_CAPABILITIES,
} = {}) {
  const issues = [];
  const hostPublishedIds = new Set(hostPublished.map((entry) => entry.capability));
  const corePackageId = graph.distribution?.core_package ?? null;
  requireFact(corePackageId !== null, "provider checks need a distribution graph with a core package");

  for (const pkg of graph.packages.values()) {
    const declared = pkg.provides ?? [];
    const seen = new Set();
    for (const capability of declared) {
      if (!NAMESPACED_CAPABILITY_PATTERN.test(capability)) {
        issues.push({ code: "capability_id_invalid", severity: "error", package: pkg.id, capability, detail: "a provided capability must be a namespaced name" });
      }
      if (seen.has(capability)) {
        issues.push({ code: "capability_duplicate", severity: "error", package: pkg.id, capability, detail: "a package repeats a provided capability" });
      }
      seen.add(capability);
      if (hostPublishedIds.has(capability) && pkg.id !== corePackageId) {
        issues.push({
          code: "host_capability_claimed_by_package",
          severity: "error",
          package: pkg.id,
          capability,
          detail: "a capability compiled into the host cannot be claimed as an optional package's own capability",
        });
      }
    }
  }

  for (const row of ownership) {
    const owner = graph.packages.get(row.owner);
    if (hostPublishedIds.has(row.capability)) {
      // Owned by the core, carried by the client itself. A package claiming it
      // was already refused above.
      continue;
    }
    if (owner === undefined) {
      issues.push({
        code: "capability_owner_absent",
        severity: "error",
        capability: row.capability,
        package: row.owner,
        detail: `the product names ${row.owner} as the owner of ${row.capability}, but the graph does not declare that package`,
      });
      continue;
    }
    if (!(owner.provides ?? []).includes(row.capability)) {
      issues.push({
        code: "capability_owner_not_providing",
        severity: "error",
        capability: row.capability,
        package: row.owner,
        detail: `the product names ${row.owner} as the owner of ${row.capability}, but the package does not provide it`,
      });
    }
  }

  return {
    kind: "licoup-provider-dependency-checks.v1",
    ok: issues.length === 0,
    checked: {
      capabilities: ownership.length,
      packages: graph.packages.size,
      host_published: [...hostPublishedIds].sort(),
    },
    issues: issues.sort((a, b) => `${a.code}\u0000${a.package ?? ""}\u0000${a.capability ?? ""}`.localeCompare(`${b.code}\u0000${b.package ?? ""}\u0000${b.capability ?? ""}`)),
    note: "Declared provider ownership only; it does not observe an installation, load a provider or grant permission.",
  };
}
