import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { cargoWorkspaceVersionPackages } from "../../../tools/scripts/client-version.mjs";

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
