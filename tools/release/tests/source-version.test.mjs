import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { verifySourceVersion } from "../verify-source-version.mjs";

async function fixture(context, versions = ["1.2.3", "1.2.3"]) {
  const root = await mkdtemp(path.join(tmpdir(), "licoup-source-version-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(path.join(root, "tools", "release"), { recursive: true });
  await writeFile(path.join(root, "package.json"), JSON.stringify({ version: versions[0] }));
  await writeFile(path.join(root, "client.json"), JSON.stringify({ productVersion: versions[1] }));
  await writeFile(path.join(root, "CHANGELOG.md"), `# Changelog\n\n## ${versions[0]} — current\n`);
  await writeFile(path.join(root, "tools", "release", "source-version.json"), JSON.stringify({
    schemaVersion: 1,
    versionSources: [
      { path: "package.json", pointer: "/version" },
      { path: "client.json", pointer: "/productVersion" }
    ],
    changelog: "CHANGELOG.md",
    tagPrefix: "v"
  }));
  return root;
}

test("accepts synchronized sources, changelog and exact tag", async (context) => {
  const root = await fixture(context);
  assert.deepEqual(await verifySourceVersion({ root, tag: "v1.2.3" }), {
    ok: true, version: "1.2.3", sources: 2, tagChecked: true
  });
});

test("rejects a mismatched source", async (context) => {
  const root = await fixture(context, ["1.2.3", "1.2.4"]);
  await assert.rejects(verifySourceVersion({ root }), /source-version-mismatch/u);
});

test("rejects a tag that does not match the source version", async (context) => {
  const root = await fixture(context);
  await assert.rejects(verifySourceVersion({ root, tag: "v1.2.4" }), /source-version-tag/u);
});

test("rejects sources that escape the repository", async (context) => {
  const root = await fixture(context);
  const configPath = path.join(root, "tools", "release", "source-version.json");
  await writeFile(configPath, JSON.stringify({
    schemaVersion: 1,
    versionSources: [{ path: "../outside.json", pointer: "/version" }],
    changelog: "CHANGELOG.md"
  }));
  await assert.rejects(verifySourceVersion({ root }), /ENOENT|source-version-path/u);
});
