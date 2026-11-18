import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createPlanAssertions } from "../../../../apps/desktop/scripts/verify-client-plan/shared/assert.mjs";
import { createPlanFileReader } from "../../../../apps/desktop/scripts/verify-client-plan/shared/fs.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../../..", import.meta.url)));
const scriptRoot = path.join(repoRoot, "apps/desktop/scripts/verify-client-plan/checks");
const fixtures = Object.freeze([
  ["package-and-runner.mjs", "checkPackageAndRunner", "tools/scripts/client-gate-policy.mjs"],
  ["client-boundary.mjs", "checkClientBoundary", "client-boundary.json"],
  ["docs-readiness.mjs", "checkDocsReadiness", "packaging.modules.json"],
]);

test("every leaf imports without side effects and owns its fixture family", async () => {
  for (const [fileName, exportName, fixtureToken] of fixtures) {
    const modulePath = path.join(scriptRoot, fileName);
    const source = await fs.readFile(modulePath, "utf8");
    const module = await import(pathToFileURL(modulePath).href);
    assert.equal(typeof module[exportName], "function");
    assert.ok(source.includes(fixtureToken), `${fileName} must keep fixture ${fixtureToken}`);
  }
});

test("shared file reader accepts repository fixtures and rejects traversal", async () => {
  const files = createPlanFileReader(repoRoot);
  const packageJson = await files.readJson("package.json");
  assert.equal(packageJson.license, "AGPL-3.0-or-later");
  await assert.rejects(
    files.readText("../outside.json"),
    /escapes the repository root/u,
  );
});

test("platform leaves close independently against their complete source bundles", async () => {
  const files = createPlanFileReader(repoRoot);
  const { checkClientBoundary } = await import(
    pathToFileURL(path.join(scriptRoot, "client-boundary.mjs")).href,
  );
  for (const check of [checkClientBoundary]) {
    const { assert: planAssert, getFailures } = createPlanAssertions();
    await check({ assert: planAssert, files });
    assert.deepEqual(getFailures(), []);
  }
});
