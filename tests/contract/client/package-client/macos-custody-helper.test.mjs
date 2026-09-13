import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, realpathSync, readlinkSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { execFileSync } from "node:child_process";
import { parsePackageClientArgs, publicPackageFailure } from "../../../../apps/desktop/scripts/package-client/cli-policy.mjs";
import { stageMacosCustodyHelper } from "../../../../apps/desktop/scripts/package-client/resource-assembly.mjs";
import { copyTree } from "../../../../apps/desktop/scripts/package-client/source-staging.mjs";
import { macosCustodyHelperPaths } from "../../../../apps/desktop/scripts/package-client/macos/metadata.mjs";
import { macosCustodySigningConfiguration, packageSigningPolicyRecord, readMacosProvisioningProfile,
  signMacosBundle, validateMacosCustodyProfile } from "../../../../apps/desktop/scripts/package-client/macos/signing.mjs";
import { verifyMacosCustodyHelper } from "../../../../apps/desktop/scripts/verify-macos-client-bundle.mjs";

const certificate = Buffer.from("synthetic certificate for command planning only");
const identity = createHash("sha1").update(certificate).digest("hex").toUpperCase();
const prefix = "TEST123456.";
const profile = (bundleId) => ({
  ProvisionsAllDevices: true, ExpirationDate: "2099-01-01T00:00:00Z",
  DeveloperCertificates: [certificate.toString("base64")],
  Entitlements: {
    "com.apple.application-identifier": `${prefix}${bundleId}`,
    "keychain-access-groups": [`${prefix}land.lico.licoup`],
  },
});
const options = { platform: "macos", mode: "release", productionEntitlements: true, macosCustodySigning: true };

function fixture(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), "licoup-custody-fixture-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const app = path.join(root, "LicoUp.app");
  const executableDir = path.join(app, "Contents", "MacOS");
  mkdirSync(executableDir, { recursive: true });
  const source = path.join(root, "synthetic-cli");
  writeFileSync(source, "synthetic executable");
  writeFileSync(path.join(executableDir, "licoup-cli"), "superseded executable");
  const executable = stageMacosCustodyHelper(source, { executableDir });
  const appProfile = path.join(root, "app.provisionprofile");
  const helperProfile = path.join(root, "helper.provisionprofile");
  writeFileSync(appProfile, "synthetic app profile");
  writeFileSync(helperProfile, "synthetic helper profile");
  const environment = {
    LICO_MACOS_SIGNING_IDENTITY: identity,
    LICO_MACOS_APP_IDENTIFIER_PREFIX: prefix,
    LICO_MACOS_APP_PROVISIONING_PROFILE: appProfile,
    LICO_MACOS_CUSTODY_PROVISIONING_PROFILE: helperProfile,
  };
  const readProfile = (file) => profile(file === appProfile ? "land.lico.licoup" : "land.lico.licoup.custody");
  return { app, executableDir, executable, environment, readProfile, signingRoot: path.join(root, "signing") };
}

test("custody staging keeps one executable and the permanent public CLI alias", async (t) => {
  const f = fixture(t);
  const entry = path.join(f.executableDir, "licoup-cli");
  assert.equal(readlinkSync(entry), "../Helpers/LicoUpCustody.app/Contents/MacOS/licoup-cli");
  assert.equal(realpathSync(entry), realpathSync(f.executable));
  assert.equal(readFileSync(entry, "utf8"), "synthetic executable");
  assert.deepEqual(await verifyMacosCustodyHelper(f.app, { architectures: () => ["arm64"] }), []);
  const runnableApp = path.join(path.dirname(f.app), "runnable", "LicoUp.app");
  copyTree(f.app, runnableApp);
  assert.deepEqual(await verifyMacosCustodyHelper(runnableApp, { architectures: () => ["arm64"] }), []);
  rmSync(entry);
  writeFileSync(entry, "unexpected second executable");
  assert.deepEqual(await verifyMacosCustodyHelper(f.app, { architectures: () => ["arm64"] }),
    ["public CLI alias missing or not a symlink"]);
});

test("custody mode is explicit, release-only, and its public plan has no identity or profile paths", () => {
  const parsed = parsePackageClientArgs(["--platform", "macos", "--macos-custody-signing", "--dry-run"]);
  assert.equal(parsed.productionEntitlements, true);
  assert.equal(packageSigningPolicyRecord(parsed).signingKind, "local-provisioned-developer-id-codesign");
  assert.equal(packageSigningPolicyRecord({ platform: "macos", mode: "release" }).signingKind, "local-ad-hoc-codesign");
  assert.throws(() => parsePackageClientArgs(["--platform", "linux", "--macos-custody-signing", "--dry-run"]),
    { code: "macos_custody_signing_requires_macos_release" });
  assert.throws(() => parsePackageClientArgs(["--platform", "macos", "--mode", "debug", "--macos-custody-signing", "--dry-run"]),
    { code: "macos_custody_signing_requires_macos_release" });
  assert.equal(JSON.stringify(packageSigningPolicyRecord(parsed)).includes(identity), false);
});

test("custody profile rejects an outer-only ID, foreign group, expired profile, and unrelated certificate", () => {
  const scope = { bundleId: "land.lico.licoup.custody", prefix, identity };
  validateMacosCustodyProfile(profile(scope.bundleId), scope);
  for (const invalid of [profile("land.lico.licoup"),
    { ...profile(scope.bundleId), ProvisionsAllDevices: false },
    { ...profile(scope.bundleId), ExpirationDate: "2000-01-01T00:00:00Z" },
    { ...profile(scope.bundleId), Entitlements: { ...profile(scope.bundleId).Entitlements, "keychain-access-groups": ["FOREIGN.group"] } }]) {
    assert.throws(() => validateMacosCustodyProfile(invalid, scope), { code: "macos_custody_profile_scope_invalid" });
  }
  assert.throws(() => validateMacosCustodyProfile({ ...profile(scope.bundleId), DeveloperCertificates: [] }, scope),
    { code: "macos_custody_profile_certificate_mismatch" });
});

test("custody signing requires both profiles and rejects ad hoc before signing", (t) => {
  const f = fixture(t);
  assert.throws(() => macosCustodySigningConfiguration({ ...f, environment: { ...f.environment, LICO_MACOS_SIGNING_IDENTITY: "-" } }),
    { code: "macos_custody_signing_identity_invalid" });
  assert.throws(() => macosCustodySigningConfiguration({ ...f, environment: { ...f.environment, LICO_MACOS_CUSTODY_PROVISIONING_PROFILE: "" } }),
    { code: "macos_custody_profile_missing" });
  let calls = 0;
  try {
    signMacosBundle({ executableDir: f.executableDir }, [f.executable], options,
      { ...f, readProfile: () => profile("land.lico.licoup"), runProcess: () => { calls++; } });
    assert.fail("must reject an outer-only profile");
  } catch (error) {
    assert.deepEqual(publicPackageFailure(error), { ok: false, error: "macos_custody_profile_scope_invalid", privatePathsIncluded: false });
  }
  assert.equal(calls, 0);
});

test("custody signing embeds separate profiles and signs helper then outer exactly once", async (t) => {
  const f = fixture(t);
  const calls = [];
  signMacosBundle({ executableDir: f.executableDir }, [f.executable], options,
    { ...f, runProcess: (command, args) => calls.push({ command, args }) });
  const signs = calls.filter(({ args }) => args.includes("--sign"));
  assert.deepEqual(signs.map(({ args }) => args.at(-1)), [macosCustodyHelperPaths(f.app).appPath, f.app]);
  for (const { command, args } of signs) {
    assert.equal(command, "codesign");
    assert.equal(args[args.indexOf("--sign") + 1], identity);
    assert.equal(args.includes("runtime"), true);
    assert.equal(args.includes("--timestamp=none"), true);
  }
  assert.equal(calls.filter(({ args }) => args.includes("--verify")).length, 2);
  const helperEntitlements = readFileSync(signs[0].args[signs[0].args.indexOf("--entitlements") + 1], "utf8");
  assert.match(helperEntitlements, /TEST123456\.land\.lico\.licoup\.custody/);
  assert.match(helperEntitlements, /<string>TEST123456\.land\.lico\.licoup<\/string>/);
  assert.equal(readFileSync(macosCustodyHelperPaths(f.app).profilePath, "utf8"), "synthetic helper profile");
  assert.equal(readFileSync(path.join(f.app, "Contents", "embedded.provisionprofile"), "utf8"), "synthetic app profile");
  assert.deepEqual(await verifyMacosCustodyHelper(f.app, { provisioned: true, architectures: () => ["arm64"] }), []);
  signMacosBundle({ executableDir: f.executableDir }, [f.executable],
    { platform: "macos", mode: "release" }, { runProcess: () => {} });
  assert.deepEqual(await verifyMacosCustodyHelper(f.app, { architectures: () => ["arm64"] }), []);
});

test("Apple plist parser extracts synthetic profile dates and certificate data without JSON conversion loss", { skip: process.platform !== "darwin" }, () => {
  const plist = `<?xml version="1.0"?><plist version="1.0"><dict>
    <key>ProvisionsAllDevices</key><true/><key>ExpirationDate</key><date>2099-01-01T00:00:00Z</date>
    <key>DeveloperCertificates</key><array><data>${certificate.toString("base64")}</data></array>
    <key>Entitlements</key><dict><key>com.apple.application-identifier</key><string>${prefix}land.lico.licoup.custody</string>
    <key>keychain-access-groups</key><array><string>${prefix}land.lico.licoup</string></array></dict></dict></plist>`;
  const parsed = readMacosProvisioningProfile("synthetic-profile", (command, args, options) => {
    if (command === "/usr/bin/security") return plist;
    return execFileSync(command, args, { input: options.input, encoding: "utf8" });
  });
  validateMacosCustodyProfile(parsed, { bundleId: "land.lico.licoup.custody", prefix, identity });
});
