import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../../..", import.meta.url)));

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

test("static checks keep the requested deterministic order", async () => {
  const root = await read("apps/desktop/scripts/verify-client-plan.mjs");
  const ids = [
    "package-and-runner",
    "client-boundary",
    "docs-readiness",
  ];
  let previous = -1;
  for (const id of ids) {
    const current = root.indexOf(`["${id}",`);
    assert.ok(current > previous, `${id} must follow the fixed check order`);
    previous = current;
  }
});

test("static facade does not retain retired dynamic self-test authority", async () => {
  const root = await read("apps/desktop/scripts/verify-client-plan.mjs");
  assert.equal(root.includes("dynamic-self-tests"), false);
  assert.equal(root.includes("DYNAMIC_SELF_TEST_IDS"), false);
  assert.equal(root.includes("--check"), false);
});
