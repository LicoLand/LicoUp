// Catalog of published formats, domain frontiers, and migration step graphs.
//
// Two graphs live here and they are not the same graph. The *frontier* graph is
// the one the compiled admission owns: a domain version with one chain of
// steps, and this tool's ledger has to match it exactly or the admission
// refuses the root. The *store-format* graph (below, and in
// `./published-strategy-format.mjs`) is the strategy database's own publication
// history: shapes that shipped under one and the same domain version because
// they only added tables. A store-format step is therefore not a frontier step,
// and the two must not be conflated: the ledger stays valid for the admission
// while the file moves to the shape the current product publishes.

import {
  PUBLISHED_STRATEGY_FORMATS,
  STRATEGY_STORE_EDGES,
  currentStrategyFormat,
  strategyFormatForDomainVersion,
} from "./published-strategy-format.mjs";

export { PUBLISHED_STRATEGY_FORMATS, STRATEGY_STORE_EDGES };

export const FRONTIER_SCHEMA = "v0.0.1:client-state-migration-frontier-1";
export const LEDGER_SCHEMA = "v0.0.1:client-state-migration-ledger-1";
export const DOMAIN_MARKER_SCHEMA = "v0.0.1:client-state-domain-marker-1";
export const PRESERVATION_SCHEMA = "v0.0.1:data-migration-preservation-1";
export const JOURNAL_SCHEMA = "v0.0.1:data-migration-journal-1";

export const DOMAIN_DEFINITIONS = [
  {
    domainId: "adaptive-flywheel",
    durability: "durable",
    targetSchemaVersion: 2,
    steps: [
      { stepId: "adaptive-flywheel.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 },
      { stepId: "adaptive-flywheel.workflow-routing-to-2", fromSchemaVersion: 1, toSchemaVersion: 2 },
    ],
    reverseSteps: [
      { stepId: "adaptive-flywheel.workflow-routing-to-1", fromSchemaVersion: 2, toSchemaVersion: 1 },
      { stepId: "adaptive-flywheel.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 },
    ],
  },
  {
    domainId: "agent-tab-order",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "agent-tab-order.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "agent-tab-order.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
  {
    domainId: "agent-tool-allowlist",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "agent-tool-allowlist.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "agent-tool-allowlist.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
  {
    domainId: "appearance-presentation",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "appearance-presentation.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "appearance-presentation.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
  {
    domainId: "canonical-conversation",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "canonical-conversation.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "canonical-conversation.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
  {
    domainId: "client-state",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "client-state.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "client-state.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
  {
    domainId: "current-view",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "current-view.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "current-view.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
  {
    domainId: "gateway-credential-custody",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "gateway-credential-custody.classic-to-data-protection", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "gateway-credential-custody.data-protection-to-classic", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
  {
    domainId: "mobile-home-layout",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "mobile-home-layout.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "mobile-home-layout.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
  {
    domainId: "mobile-relay",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "mobile-relay.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "mobile-relay.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
  {
    domainId: "skill-hub-preferences",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "skill-hub-preferences.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "skill-hub-preferences.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
  {
    domainId: "workspace-manifest",
    durability: "durable",
    targetSchemaVersion: 1,
    steps: [{ stepId: "workspace-manifest.absent-to-1", fromSchemaVersion: 0, toSchemaVersion: 1 }],
    reverseSteps: [{ stepId: "workspace-manifest.1-to-absent", fromSchemaVersion: 1, toSchemaVersion: 0 }],
  },
];

export const PUBLISHED_FORMAT_PROFILES = {
  "0.0.1-alpha": {
    label: "LicoUp 0.0.1-alpha Development Baseline",
    productVersion: "0.0.1-alpha",
    frontierId: "licoup-state-0.2.2",
    storeFormats: { "adaptive-flywheel": "strategy-store-4" },
    domains: {
      "adaptive-flywheel": 2,
      "agent-tab-order": 1,
      "agent-tool-allowlist": 1,
      "appearance-presentation": 1,
      "canonical-conversation": 1,
      "client-state": 1,
      "current-view": 1,
      "gateway-credential-custody": 1,
      "mobile-home-layout": 1,
      "mobile-relay": 1,
      "skill-hub-preferences": 1,
      "workspace-manifest": 1,
    },
  },
  "v0.1.0": {
    label: "LicoUp v0.1.0 Legacy Profile",
    productVersion: "0.1.0",
    frontierId: "licoup-state-0.1.0",
    domains: {
      "adaptive-flywheel": 0,
      "agent-tab-order": 0,
      "agent-tool-allowlist": 0,
      "appearance-presentation": 0,
      "canonical-conversation": 0,
      "client-state": 0,
      "current-view": 0,
      "gateway-credential-custody": 0,
      "mobile-home-layout": 0,
      "mobile-relay": 0,
      "skill-hub-preferences": 0,
      "workspace-manifest": 0,
    },
  },
  "v0.1.1": {
    label: "LicoUp v0.1.1 Profile",
    productVersion: "0.1.1",
    frontierId: "licoup-state-0.1.0",
    domains: {
      "adaptive-flywheel": 0,
      "agent-tab-order": 0,
      "agent-tool-allowlist": 0,
      "appearance-presentation": 0,
      "canonical-conversation": 0,
      "client-state": 0,
      "current-view": 0,
      "gateway-credential-custody": 0,
      "mobile-home-layout": 0,
      "mobile-relay": 0,
      "skill-hub-preferences": 0,
      "workspace-manifest": 0,
    },
  },
  "v0.1.2": {
    label: "LicoUp v0.1.2 Profile",
    productVersion: "0.1.2",
    frontierId: "licoup-state-0.1.0",
    domains: {
      "adaptive-flywheel": 0,
      "agent-tab-order": 0,
      "agent-tool-allowlist": 0,
      "appearance-presentation": 0,
      "canonical-conversation": 0,
      "client-state": 0,
      "current-view": 0,
      "gateway-credential-custody": 0,
      "mobile-home-layout": 0,
      "mobile-relay": 0,
      "skill-hub-preferences": 0,
      "workspace-manifest": 0,
    },
  },
  "v0.2.0": {
    label: "LicoUp v0.2.0 Initial SQLite Profile",
    productVersion: "0.2.0",
    frontierId: "licoup-state-0.2.0",
    domains: {
      "adaptive-flywheel": 0,
      "agent-tab-order": 1,
      "agent-tool-allowlist": 1,
      "appearance-presentation": 1,
      "canonical-conversation": 1,
      "client-state": 1,
      "current-view": 1,
      "gateway-credential-custody": 1,
      "mobile-home-layout": 1,
      "mobile-relay": 1,
      "skill-hub-preferences": 1,
      "workspace-manifest": 1,
    },
  },
  "v0.2.1": {
    label: "LicoUp v0.2.1 Flywheel Schema 2 Profile",
    productVersion: "0.2.1",
    frontierId: "licoup-state-0.2.1",
    domains: {
      "adaptive-flywheel": 1,
      "agent-tab-order": 1,
      "agent-tool-allowlist": 1,
      "appearance-presentation": 1,
      "canonical-conversation": 1,
      "client-state": 1,
      "current-view": 1,
      "gateway-credential-custody": 1,
      "mobile-home-layout": 1,
      "mobile-relay": 1,
      "skill-hub-preferences": 1,
      "workspace-manifest": 1,
    },
  },
  "v0.2.2": {
    label: "LicoUp v0.2.2 Flywheel Schema 3 Profile",
    productVersion: "0.2.2",
    frontierId: "licoup-state-0.2.2",
    domains: {
      "adaptive-flywheel": 2,
      "agent-tab-order": 1,
      "agent-tool-allowlist": 1,
      "appearance-presentation": 1,
      "canonical-conversation": 1,
      "client-state": 1,
      "current-view": 1,
      "gateway-credential-custody": 1,
      "mobile-home-layout": 1,
      "mobile-relay": 1,
      "skill-hub-preferences": 1,
      "workspace-manifest": 1,
    },
  },
  "v0.3.0": {
    label: "LicoUp v0.3.0 Current Product Profile",
    productVersion: "0.3.0",
    frontierId: "licoup-state-0.2.2",
    domains: {
      "adaptive-flywheel": 2,
      "agent-tab-order": 1,
      "agent-tool-allowlist": 1,
      "appearance-presentation": 1,
      "canonical-conversation": 1,
      "client-state": 1,
      "current-view": 1,
      "gateway-credential-custody": 1,
      "mobile-home-layout": 1,
      "mobile-relay": 1,
      "skill-hub-preferences": 1,
      "workspace-manifest": 1,
    },
  },
  "nightly": {
    label: "LicoUp Nightly / Current Baseline",
    productVersion: "0.3.0",
    frontierId: "licoup-state-0.2.2",
    storeFormats: { "adaptive-flywheel": "strategy-store-4" },
    domains: {
      "adaptive-flywheel": 2,
      "agent-tab-order": 1,
      "agent-tool-allowlist": 1,
      "appearance-presentation": 1,
      "canonical-conversation": 1,
      "client-state": 1,
      "current-view": 1,
      "gateway-credential-custody": 1,
      "mobile-home-layout": 1,
      "mobile-relay": 1,
      "skill-hub-preferences": 1,
      "workspace-manifest": 1,
    },
  },
  "latest": {
    label: "LicoUp Latest Profile",
    productVersion: "0.3.0",
    frontierId: "licoup-state-0.2.2",
    storeFormats: { "adaptive-flywheel": "strategy-store-4" },
    domains: {
      "adaptive-flywheel": 2,
      "agent-tab-order": 1,
      "agent-tool-allowlist": 1,
      "appearance-presentation": 1,
      "canonical-conversation": 1,
      "client-state": 1,
      "current-view": 1,
      "gateway-credential-custody": 1,
      "mobile-home-layout": 1,
      "mobile-relay": 1,
      "skill-hub-preferences": 1,
      "workspace-manifest": 1,
    },
  },
};

export function resolveTargetProfile(targetNameOrVersion) {
  if (!targetNameOrVersion) {
    return PUBLISHED_FORMAT_PROFILES["latest"];
  }
  const clean = targetNameOrVersion.trim();
  if (PUBLISHED_FORMAT_PROFILES[clean]) {
    return PUBLISHED_FORMAT_PROFILES[clean];
  }
  const normalized = clean.startsWith("v") ? clean : `v${clean}`;
  if (PUBLISHED_FORMAT_PROFILES[normalized]) {
    return PUBLISHED_FORMAT_PROFILES[normalized];
  }
  throw new Error(`Unknown target format or version: "${targetNameOrVersion}". Available targets: ${Object.keys(PUBLISHED_FORMAT_PROFILES).join(", ")}`);
}

/**
 * The published store format a profile asks a domain's store to be in.
 *
 * A profile that names no store format means the shape its domain version
 * already published, which is what keeps the older profiles immutable: `v0.3.0`
 * shipped without the delivery tables, so re-migrating to it must not create
 * them.
 */
export function resolveProfileStoreFormat(profile, domainId) {
  if (!profile) return null;
  if (profile.storeFormats && profile.storeFormats[domainId]) {
    return profile.storeFormats[domainId];
  }
  if (domainId !== "adaptive-flywheel") return null;
  const version = profile.domains ? profile.domains[domainId] : undefined;
  if (version === undefined) return null;
  return strategyFormatForDomainVersion(version).formatId;
}

export function getDomainDefinition(domainId) {
  const definition = DOMAIN_DEFINITIONS.find((d) => d.domainId === domainId);
  if (!definition) {
    throw new Error(`Unknown domain: "${domainId}"`);
  }
  return definition;
}
