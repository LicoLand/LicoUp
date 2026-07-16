import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../../..", import.meta.url)));
const scriptRoot = "apps/desktop/scripts/verify-client-plan";
const leaves = Object.freeze([
  ["package-and-runner.mjs", "checkPackageAndRunner"],
  ["client-boundary.mjs", "checkClientBoundary"],
  ["evidence-routing.mjs", "checkEvidenceRouting"],
  ["crypto-redaction-handoff.mjs", "checkCryptoRedactionHandoff"],
  ["secret-store.mjs", "checkSecretStore"],
  ["physical-evidence.mjs", "checkPhysicalEvidence"],
  ["android-ios.mjs", "checkAndroidIos"],
  ["linux-windows.mjs", "checkLinuxWindows"],
  ["trust-release.mjs", "checkTrustRelease"],
  ["docs-readiness.mjs", "checkDocsReadiness"],
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

test("verify-client-plan root is a thin ordered static facade", async () => {
  const root = await read("apps/desktop/scripts/verify-client-plan.mjs");
  assert.ok(root.split(/\r?\n/u).length <= 70);
  for (const [fileName, exportName] of leaves) {
    assert.match(root, new RegExp(`import \\{ ${exportName} \\} from "\\./verify-client-plan/checks/${fileName.replace(".", "\\.")}"`, "u"));
  }
  for (const forbidden of [
    "spawnSync",
    "node:child_process",
    "build/tmp",
    "writeFile",
    "mkdir",
    "dynamic-self-tests",
    "await import(",
  ]) {
    assert.equal(root.includes(forbidden), false, `static facade must not contain ${forbidden}`);
  }
});

test("each requested static leaf has one callable source authority", async () => {
  for (const [fileName, exportName] of leaves) {
    const source = await read(`${scriptRoot}/checks/${fileName}`);
    assert.match(source, new RegExp(`export async function ${exportName}\\(`, "u"));
    assert.equal(source.includes("/checks/"), false, `${fileName} must not import another check leaf`);
  }
});

test("shared registries and reducer-owned summary are declared once", async () => {
  const sharedFiles = ["assert.mjs", "context.mjs", "fs.mjs", "sanitize.mjs"];
  const checkSources = await Promise.all(
    leaves.map(([fileName]) => read(`${scriptRoot}/checks/${fileName}`)),
  );
  const sharedSources = await Promise.all(
    sharedFiles.map((fileName) => read(`${scriptRoot}/shared/${fileName}`)),
  );
  const source = [...sharedSources, ...checkSources].join("\n");
  assert.equal((source.match(/export const requiredVerifierScripts\s*=\s*\[/gu) || []).length, 1);
  assert.equal((source.match(/function formatAdapterReadinessSummary\(/gu) || []).length, 1);
  assert.equal((source.match(/import \{ loadSecureClientContract \}/gu) || []).length, 1);
  assert.equal((source.match(/SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS\s*=\s*\[/gu) || []).length, 0);
});
