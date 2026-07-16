import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { DYNAMIC_SELF_TEST_IDS } from "../../../../apps/desktop/scripts/verify-client-plan/dynamic-self-tests.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../../..", import.meta.url)));

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

test("static checks keep the requested deterministic order", async () => {
  const root = await read("apps/desktop/scripts/verify-client-plan.mjs");
  const ids = [
    "package-and-runner",
    "client-boundary",
    "evidence-routing",
    "crypto-redaction-handoff",
    "secret-store",
    "physical-evidence",
    "android-ios",
    "linux-windows",
    "trust-release",
    "docs-readiness",
  ];
  let previous = -1;
  for (const id of ids) {
    const current = root.indexOf(`["${id}",`);
    assert.ok(current > previous, `${id} must follow the fixed check order`);
    previous = current;
  }
});

test("dynamic authority work is isolated behind selectable ids", async () => {
  assert.deepEqual([...DYNAMIC_SELF_TEST_IDS], [
    "contract-binding",
    "scope-authority",
    "authority-proof",
  ]);
  const root = await read("apps/desktop/scripts/verify-client-plan.mjs");
  const dynamic = await read(
    "apps/desktop/scripts/verify-client-plan/dynamic-self-tests.mjs",
  );
  assert.equal(root.includes("DYNAMIC_SELF_TEST_IDS"), false);
  assert.ok(dynamic.includes('argv[index] !== "--check"'));
  assert.ok(dynamic.includes('selected.has("contract-binding")'));
  assert.ok(dynamic.includes('selected.has("scope-authority")'));
  assert.ok(dynamic.includes('selected.has("authority-proof")'));
  assert.ok(dynamic.includes("build/tmp/secure-mesh-authority-proof-template-plan-self-test.json"));
});
