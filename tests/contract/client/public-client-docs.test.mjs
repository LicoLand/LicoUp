import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

const pairs = Object.freeze([
  ["CONTRIBUTING.md", "CONTRIBUTING.zh-CN.md"],
  ["SECURITY.md", "SECURITY.zh-CN.md"],
  ["docs/functionality/USER-GUIDE.md", "docs/functionality/USER-GUIDE.zh-CN.md"],
  ["docs/architecture/README.md", "docs/architecture/README.zh-CN.md"],
  ["docs/COMPATIBILITY.md", "docs/COMPATIBILITY.zh-CN.md"],
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

test("public client documents keep matching English and Chinese entry points", async () => {
  for (const [englishPath, chinesePath] of pairs) {
    const [english, chinese] = await Promise.all([read(englishPath), read(chinesePath)]);
    assert.match(english, new RegExp(chinesePath.split("/").at(-1).replace(".", "\\."), "u"));
    assert.match(chinese, new RegExp(englishPath.split("/").at(-1).replace(".", "\\."), "u"));
  }
});

test("public client document links resolve inside the repository", async () => {
  for (const relativePath of pairs.flat()) {
    const source = await read(relativePath);
    for (const match of source.matchAll(/\[[^\]]+\]\(([^)]+)\)/gu)) {
      const target = match[1].split("#", 1)[0];
      if (target.length === 0 || /^[a-z][a-z0-9+.-]*:/iu.test(target)) continue;
      const resolved = path.resolve(repoRoot, path.dirname(relativePath), target);
      await assert.doesNotReject(fs.access(resolved), `${relativePath} has a missing link`);
    }
  }
});
