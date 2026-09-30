import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import {
  developmentRegistries,
  formatMissingRegistryPaths,
  looksLikeRepositoryPath,
  missingRegistryPaths,
  registryStrings,
  repositoryRoot,
  resolveRepositoryPath,
} from "../registry-paths.mjs";

test("development registries name only paths that exist", () => {
  const missing = missingRegistryPaths();
  assert.deepEqual(
    missing,
    [],
    `a registry that names a moved path stops seeing it instead of failing:\n${formatMissingRegistryPaths(missing)}`
  );
});

test("the registries under test are the ones that name paths", () => {
  const registries = developmentRegistries();
  assert.ok(registries.includes("tools/development/modules.json"));
  assert.ok(registries.includes("tools/development/state-machines.json"));
  assert.ok(registries.some((name) => name.startsWith("tools/development/workflows/")));
  assert.ok(registries.every((name) => name.endsWith(".json")));
});

test("a module prefix and an explicit file resolve, a moved module does not", () => {
  assert.ok(looksLikeRepositoryPath("crates/licoup-native/src/platform/pty_transport"));
  assert.ok(looksLikeRepositoryPath("docs/modules/workflow.md"));
  // Glob templates, commands, absolute paths and bare names are not references.
  for (const value of [
    "crates/licoup-foundation/src/**",
    "node tools/development/reports.mjs",
    "/absolute/path.rs",
    "src/core.rs",
    "crates/licoup-native/src/core/task_queue.rs (moved)",
    "https://example.com/docs/page",
  ]) {
    assert.equal(looksLikeRepositoryPath(value), false, value);
  }
  // Resolution follows the extension the repository actually uses, on this checkout.
  assert.equal(
    resolveRepositoryPath(repositoryRoot, "crates/licoup-native/src/platform/copilot_driver"),
    "crates/licoup-native/src/platform/copilot_driver.rs"
  );
  assert.equal(
    resolveRepositoryPath(repositoryRoot, "crates/licoup-foundation/src/core/task_queue"),
    "crates/licoup-foundation/src/core/task_queue.rs"
  );
  assert.equal(resolveRepositoryPath(repositoryRoot, "crates/licoup-native/src/platform/pty_transport"), null);
});

test("a stale entry is reported with its registry, JSON pointer and path", (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), "registry-paths-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, "crates", "licoup-native", "src", "platform"), { recursive: true });
  writeFileSync(path.join(root, "crates", "licoup-native", "src", "platform", "kept.rs"), "//!\n");
  mkdirSync(path.join(root, "docs", "modules"), { recursive: true });
  writeFileSync(path.join(root, "docs", "modules", "example.md"), "# Example\n");
  mkdirSync(path.join(root, "tools", "development"), { recursive: true });
  writeFileSync(path.join(root, "tools", "development", "modules.json"), `${JSON.stringify([
    {
      id: "example",
      guide: "docs/modules/example.md",
      sourceRoots: [
        "crates/licoup-native/src/platform/kept",
        "crates/licoup-native/src/platform/moved",
      ],
    },
  ], null, 2)}\n`);
  const missing = missingRegistryPaths({
    root,
    registries: ["tools/development/modules.json"],
  });
  assert.deepEqual(missing, [{
    registry: "tools/development/modules.json",
    pointer: "[0].sourceRoots[1]",
    path: "crates/licoup-native/src/platform/moved",
  }]);
  assert.match(formatMissingRegistryPaths(missing), /sourceRoots\[1\] names .*moved/u);
});

test("the walk reaches nested arrays and objects", () => {
  const pointers = [...registryStrings({ a: [{ b: "crates/x/y" }], c: { d: "tools/e/f" } })]
    .map((entry) => entry.pointer);
  assert.deepEqual(pointers, ["a[0].b", "c.d"]);
  assert.equal(path.resolve(repositoryRoot, "tools/development/modules.json").endsWith("modules.json"), true);
});
