import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  classifyReadmeFastPath,
  readmeFastManifestPath,
  verifyReadmeFastPath,
} from "../../../tools/scripts/readme-fast-path.mjs";

const initialFiles = [
  "README.md",
  "README.zh-CN.md",
  "docs/assets/brand/readme-banner.svg",
];

function git(root, args) {
  const result = spawnSync("git", args, {
    cwd: root,
    encoding: "utf8",
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function fixture() {
  const root = mkdtempSync(path.join(os.tmpdir(), "lico-readme-fast-"));
  mkdirSync(path.join(root, "tools/scripts/config"), { recursive: true });
  mkdirSync(path.join(root, "docs/assets/brand"), { recursive: true });
  writeFileSync(path.join(root, readmeFastManifestPath), `${JSON.stringify(initialFiles, null, 2)}\n`);
  writeFileSync(path.join(root, "README.md"), "English\n");
  writeFileSync(path.join(root, "README.zh-CN.md"), "中文\n");
  writeFileSync(path.join(root, "docs/assets/brand/readme-banner.svg"), "<svg/>\n");
  git(root, ["init", "-b", "nightly"]);
  git(root, ["config", "user.name", "fixture"]);
  git(root, ["config", "user.email", "fixture@example.invalid"]);
  git(root, ["add", "."]);
  git(root, ["commit", "-m", "base"]);
  return { root, base: git(root, ["rev-parse", "HEAD"]) };
}

function commit(root, message) {
  git(root, ["add", "-A"]);
  git(root, ["commit", "-m", message]);
}

test("README files use the fast path while unrelated files use the ordinary path", () => {
  const { root, base } = fixture();
  try {
    writeFileSync(path.join(root, "README.md"), "Updated by the author\n");
    commit(root, "readme");
    assert.equal(classifyReadmeFastPath({ base, root }).eligible, true);

    writeFileSync(path.join(root, "code.mjs"), "export const changed = true;\n");
    commit(root, "code");
    assert.equal(classifyReadmeFastPath({ base, root }).eligible, false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("manifest additions and removals take effect in the same author update", async () => {
  const { root, base } = fixture();
  try {
    const extra = "docs/assets/brand/readme-extra.svg";
    writeFileSync(path.join(root, readmeFastManifestPath),
      `${JSON.stringify([...initialFiles, extra], null, 2)}\n`);
    writeFileSync(path.join(root, extra), "<svg>extra</svg>\n");
    commit(root, "add resource");
    assert.equal(classifyReadmeFastPath({ base, root }).eligible, true);
    await verifyReadmeFastPath({ base, root });

    const added = git(root, ["rev-parse", "HEAD"]);
    writeFileSync(path.join(root, readmeFastManifestPath),
      `${JSON.stringify(initialFiles, null, 2)}\n`);
    rmSync(path.join(root, extra));
    commit(root, "remove resource");
    assert.equal(classifyReadmeFastPath({ base: added, root }).eligible, true);
    await verifyReadmeFastPath({ base: added, root });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("invalid manifests fall back and sensitive author content is rejected only by verification", async () => {
  const first = fixture();
  try {
    writeFileSync(path.join(first.root, readmeFastManifestPath), "not json\n");
    commit(first.root, "invalid manifest");
    assert.equal(classifyReadmeFastPath({ base: first.base, root: first.root }).eligible, false);
  } finally {
    rmSync(first.root, { recursive: true, force: true });
  }

  const second = fixture();
  try {
    const begin = "---" + "--BEGIN PRIVATE KEY---" + "--";
    const end = "---" + "--END PRIVATE KEY---" + "--";
    writeFileSync(path.join(second.root, "README.md"),
      `${begin}\nYWJjZGVmZ2hpamtsbW5vcA==\n${end}\n`);
    commit(second.root, "sensitive readme");
    assert.equal(classifyReadmeFastPath({ base: second.base, root: second.root }).eligible, true);
    await assert.rejects(() => verifyReadmeFastPath({ base: second.base, root: second.root }));
  } finally {
    rmSync(second.root, { recursive: true, force: true });
  }
});
