import assert from "node:assert/strict";
import test from "node:test";
import {
  DOMAIN_DEFINITIONS,
  PUBLISHED_FORMAT_PROFILES,
  resolveTargetProfile,
  getDomainDefinition,
} from "../lib/catalog.mjs";

test("all 12 required migration domains are defined", () => {
  const expectedDomains = [
    "adaptive-flywheel",
    "agent-tab-order",
    "agent-tool-allowlist",
    "appearance-presentation",
    "canonical-conversation",
    "client-state",
    "current-view",
    "gateway-credential-custody",
    "mobile-home-layout",
    "mobile-relay",
    "skill-hub-preferences",
    "workspace-manifest",
  ];

  assert.equal(DOMAIN_DEFINITIONS.length, 12);
  const registeredIds = DOMAIN_DEFINITIONS.map((d) => d.domainId).sort();
  assert.deepEqual(registeredIds, expectedDomains.sort());

  for (const def of DOMAIN_DEFINITIONS) {
    assert.ok(def.steps.length > 0, `${def.domainId} must have forward steps`);
    let cursor = 0;
    for (const step of def.steps) {
      assert.equal(step.fromSchemaVersion, cursor);
      assert.ok(step.toSchemaVersion > cursor);
      cursor = step.toSchemaVersion;
    }
    assert.equal(cursor, def.targetSchemaVersion);
  }
});

test("all published format profiles cover all domains consistently", () => {
  const profiles = Object.keys(PUBLISHED_FORMAT_PROFILES);
  assert.ok(profiles.includes("v0.1.0"));
  assert.ok(profiles.includes("v0.2.0"));
  assert.ok(profiles.includes("v0.3.0"));
  assert.ok(profiles.includes("latest"));

  for (const profileKey of profiles) {
    const profile = PUBLISHED_FORMAT_PROFILES[profileKey];
    assert.ok(profile.productVersion);
    assert.ok(profile.frontierId);
    for (const def of DOMAIN_DEFINITIONS) {
      assert.ok(
        profile.domains[def.domainId] !== undefined,
        `Profile ${profileKey} missing domain ${def.domainId}`
      );
      assert.ok(profile.domains[def.domainId] <= def.targetSchemaVersion);
    }
  }
});

test("target resolver handles version strings and alias profiles", () => {
  assert.equal(resolveTargetProfile("v0.1.0").productVersion, "0.1.0");
  assert.equal(resolveTargetProfile("0.1.0").productVersion, "0.1.0");
  assert.equal(resolveTargetProfile("latest").productVersion, "0.3.0");
  assert.equal(resolveTargetProfile("nightly").productVersion, "0.3.0");

  assert.throws(() => resolveTargetProfile("unknown-999"), /Unknown target/);
});
