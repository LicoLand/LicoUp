import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { createPlanAssertions } from "../../../../apps/desktop/scripts/verify-client-plan/shared/assert.mjs";
import { sanitizePlanDiagnostic } from "../../../../apps/desktop/scripts/verify-client-plan/shared/sanitize.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../../..", import.meta.url)));

test("diagnostics redact cross-platform local paths and secret forms", () => {
  const privateKey = [
    "-----BEGIN ",
    "PRIVATE KEY-----\n",
    "private-material\n",
    "-----END ",
    "PRIVATE KEY-----",
  ].join("");
  const macPath = ["", "Users", "local-user", "work", "private.txt"].join("/");
  const linuxPath = ["", "home", "linux-user", "project", "secret.txt"].join("/");
  const rootPath = ["", "root", "cache", "identity.json"].join("/");
  const windowsPath = ["C:", "Users", "windows-user", "workspace", "credential.json"].join("\\");
  const networkPath = ["", "", "host", "Users", "network-user", "share", "token.txt"].join("\\");
  const privateTmpPath = ["", "private", "tmp", "device-identity", "report.json"].join("/");
  const diagnostic = [
    macPath,
    linuxPath,
    rootPath,
    windowsPath,
    networkPath,
    privateTmpPath,
    ["Bearer", "bearer-value"].join(" "),
    ["to", "ken=query-value"].join(""),
    ['"cipher', 'text":"cipher-value"'].join(""),
    ["github", "_pat_sensitivevalue"].join(""),
    privateKey,
  ].join(" ");
  const sanitized = sanitizePlanDiagnostic(diagnostic);
  for (const secret of [
    "local-user",
    "linux-user",
    "identity.json",
    "windows-user",
    "network-user",
    "device-identity",
    "bearer-value",
    "query-value",
    "cipher-value",
    "sensitivevalue",
    "private-material",
  ]) {
    assert.equal(sanitized.includes(secret), false, `diagnostic leaked ${secret}`);
  }
  assert.ok(sanitized.includes("<local-path>"));
  assert.ok(sanitized.includes("[redacted]"));
});

test("assertion collection is private-copy based", () => {
  const { assert: planAssert, getFailures } = createPlanAssertions();
  planAssert(false, "first");
  const first = getFailures();
  first.push("mutated");
  assert.deepEqual(getFailures(), ["first"]);
});

test("every static leaf is output-free and uses shared read dependencies", async () => {
  const directory = path.join(
    repoRoot,
    "apps/desktop/scripts/verify-client-plan/checks",
  );
  const fileNames = (await fs.readdir(directory))
    .filter((fileName) => fileName.endsWith(".mjs"))
    .sort();
  assert.equal(fileNames.length, 10);
  for (const fileName of fileNames) {
    const source = await fs.readFile(path.join(directory, fileName), "utf8");
    for (const forbidden of [
      "console.",
      "spawnSync",
      "node:fs",
      "node:child_process",
      "writeFile",
      "build/tmp",
    ]) {
      assert.equal(
        source.includes(forbidden),
        false,
        `${fileName} must not expose or mutate through ${forbidden}`,
      );
    }
  }
});
