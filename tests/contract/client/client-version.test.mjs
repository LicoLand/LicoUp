import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  cargoWorkspaceVersionPackages,
  packageClientCompatibility,
  packageManifestInventory,
} from "../../../tools/scripts/client-version.mjs";
import {
  clientVersionListRefusals,
  clientVersionsCover,
  parseRequirement,
  parseVersion,
} from "../../../tools/scripts/lib/client-package-compatibility.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

function packageName(manifest) {
  return /^name\s*=\s*"([^"]+)"$/mu.exec(manifest)?.[1] ?? "";
}

test("client version sync covers every workspace-version Cargo package", () => {
  const workspace = readFileSync(path.join(repoRoot, "Cargo.toml"), "utf8");
  const membersBlock = /^members\s*=\s*\[([\s\S]*?)^\]$/mu.exec(workspace)?.[1] ?? "";
  const members = [...membersBlock.matchAll(/"([^"]+)"/gu)].map((match) => match[1]);
  const inherited = members.flatMap((member) => {
    const manifest = readFileSync(path.join(repoRoot, member, "Cargo.toml"), "utf8");
    return /^version\.workspace\s*=\s*true$/mu.test(manifest) ? [packageName(manifest)] : [];
  });

  assert.deepEqual(
    [...cargoWorkspaceVersionPackages].sort(),
    [...inherited, "licoup-native"].sort(),
  );
});

// The cases below are the ones where the host's grammar and Node's differ, so
// they are the ones a gate that quietly used a different evaluator would fail.
test("client compatibility evaluation follows the host requirement grammar", () => {
  const cases = [
    // A bare version is a caret requirement, not an exact one.
    ["0.3.0", "0.3.0", true],
    ["0.3.0", "0.3.1", true],
    ["0.3.0", "0.4.0", false],
    // A bare major accepts the whole line, and zero is a line like any other.
    ["1", "1.4.0", true],
    ["1", "0.3.0", false],
    ["0", "0.3.0", true],
    ["0", "1.0.0", false],
    // A caret below one pins the minor, which is where 0.x support breaks.
    ["^0.2", "0.2.9", true],
    ["^0.2", "0.3.0", false],
    // Tilde pins the minor; wildcards are exact partial versions.
    ["~1.2", "1.2.9", true],
    ["~1.2", "1.3.0", false],
    ["1.2.*", "1.2.4", true],
    ["1.2.*", "1.9.0", false],
    // A partial comparison bound is not an exact one.
    [">=1", "1.0.0", true],
    [">=1", "0.9.9", false],
    [">=1.2", "1.2.0", true],
    [">1.2", "1.2.9", false],
    // The shipped package range, and the two ways it stops covering a client.
    [">=0.3.0, <1.0.0", "0.3.0", true],
    [">=0.3.0, <1.0.0", "0.9.9", true],
    [">=1.0.0, <1.0.0", "0.3.0", false],
    [">=0.4.0, <1.0.0", "0.3.0", false],
    // A wildcard is a requirement like any other: it covers no prerelease.
    ["*", "0.3.0", true],
    ["*", "0.3.0-rc.1", false],
    // A prerelease needs a comparator that names its exact version and carries a
    // prerelease, so widening the bound alone does not admit one.
    [">=0.3.0, <1.0.0", "0.3.0-rc.1", false],
    [">=0.3.0-alpha, <1.0.0", "0.3.0-rc.1", true],
    [">=0.3.0-alpha, <1.0.0", "0.4.0-rc.1", false],
    // Build metadata is never part of the decision.
    [">=0.3.0, <1.0.0", "0.3.0+build.9", true],
  ];
  for (const [declared, clientVersion, expected] of cases) {
    assert.equal(
      clientVersionsCover([declared], clientVersion),
      expected,
      `${declared} must ${expected ? "" : "not "}cover ${clientVersion}`,
    );
    assert.notEqual(parseRequirement(declared), null, declared);
    assert.notEqual(parseVersion(clientVersion), null, clientVersion);
  }

  // A client version the grammar cannot read is covered by nothing, which is the
  // fail-closed half of the host's decision: a client whose own identity is
  // unreadable loads no package rather than every package.
  for (const unreadable of ["", "0.3", "1.2", "1.2.3.4", "01.2.3", "v1.2.3", "main"]) {
    assert.equal(parseVersion(unreadable), null, unreadable);
    assert.equal(clientVersionsCover(["*"], unreadable), false, unreadable);
  }
});

test("client compatibility requirements are evaluated as the contract parses them", () => {
  // Every entry the contract's `VersionReq::parse` refuses, and the list shape it
  // requires, so a malformed declaration cannot read as one that covers nothing.
  for (const refused of [
    ">=1.0 <2.0",
    "*.*",
    "*, 1.2.3",
    "1.2-alpha",
    "1.2.3,",
    "1.2.3-",
    "1.2.3+",
    "01.2.3",
    "@1.0.0",
    "1.2.3 || =2.3.4",
  ]) {
    assert.equal(parseRequirement(refused), null, refused);
    assert.ok(clientVersionListRefusals([refused]).length > 0, refused);
  }
  for (const accepted of ["*", "x", "1", "1.2", "1.2.3", "1.2.*", ">=0.3.0, <1.0.0", "=1.2.3-alpha.1"]) {
    assert.notEqual(parseRequirement(accepted), null, accepted);
    assert.deepEqual(clientVersionListRefusals([accepted]), [], accepted);
  }

  // The list itself is required: a package that declares none is admitted by
  // nothing, and an empty or missing list is a refusal rather than an empty
  // coverage answer.
  assert.ok(clientVersionListRefusals([]).length > 0);
  assert.ok(clientVersionListRefusals(undefined).length > 0);
  assert.ok(clientVersionListRefusals([""]).length > 0);

  // The bound is the contract's byte bound on one entry, and it is checked on a
  // requirement the grammar accepts rather than on a malformed one.
  const withinBound = Array.from({ length: 7 }, () => ">=1.0.0").join(", ");
  const overBound = Array.from({ length: 8 }, () => ">=1.0.0").join(", ");
  assert.equal(Buffer.byteLength(withinBound, "utf8"), 61);
  assert.equal(Buffer.byteLength(overBound, "utf8"), 70);
  assert.notEqual(parseRequirement(overBound), null);
  assert.deepEqual(clientVersionListRefusals([withinBound]), []);
  assert.ok(clientVersionListRefusals([overBound]).length > 0);
});

test("every checked package manifest declares a client line covering this client", () => {
  const inventory = packageManifestInventory();

  // The inventory is what the check reads, so it cannot be empty: a gate that
  // resolved to no package would pass while checking nothing.
  assert.ok(inventory.length > 0);

  // The release set names every package the release publishes or installs, so
  // each of its manifests has to be in the checked set even when its source
  // directory does not carry the `package/` name.
  const packageSet = JSON.parse(readFileSync(
    path.join(repoRoot, "tools", "client-release-package-set.json"), "utf8"));
  assert.ok(packageSet.packages.length > 0);
  const checked = new Set(inventory);
  for (const declared of packageSet.packages) {
    assert.ok(
      checked.has(`${declared.source}/manifest.json`),
      `${declared.source}/manifest.json must be checked`,
    );
  }

  // Every shipped package declares the same client line today, and each one
  // covers the product version this client is built as.
  const productVersion = JSON.parse(readFileSync(
    path.join(repoRoot, "tools", "client-version.json"), "utf8")).productVersion;
  const verdicts = packageClientCompatibility(productVersion);
  assert.deepEqual(verdicts.map((verdict) => verdict.path), inventory);
  for (const verdict of verdicts) {
    assert.deepEqual(verdict.reasons, [], verdict.path);
    assert.equal(verdict.covered, true, verdict.path);
    assert.equal(verdict.clientVersionParses, true, verdict.path);
    assert.ok(verdict.clientVersions.length > 0, verdict.path);
    assert.deepEqual(clientVersionListRefusals(verdict.clientVersions), [], verdict.path);
  }
});

test("a client version the host cannot read is covered by no package", () => {
  // The version string this client is built as is validated before the check
  // runs, but that validation is looser than the grammar the host matches with:
  // a product version with a leading zero would install nothing. The verdict has
  // to be a refusal on every package, not a green run that compared against a
  // version the host cannot parse.
  const verdicts = packageClientCompatibility("01.2.3");
  assert.ok(verdicts.length > 0);
  for (const verdict of verdicts) {
    assert.equal(verdict.clientVersionParses, false, verdict.path);
    assert.equal(verdict.covered, false, verdict.path);
    assert.ok(verdict.reasons.length > 0, verdict.path);
  }
});

