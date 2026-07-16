import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const shellRoot =
  "apps/desktop/lib/src/frontend/layout/profiles/workbench/desktop/shell";
const productionLeaves = Object.freeze([
  "workbench_desktop_navigation.dart",
  "workbench_desktop_search.dart",
  "workbench_desktop_status.dart",
  "workbench_desktop_topbar.dart",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all(productionLeaves.map(async (leaf) => [
    leaf,
    await read(`${shellRoot}/${leaf}`),
  ])));
}

test("Workbench desktop chrome root exports exactly four ordinary libraries", async () => {
  const facade = await read(`${shellRoot}/workbench_desktop_chrome.dart`);
  assert.deepEqual(
    [...facade.matchAll(/^export '([^']+)';$/gmu)]
      .map((match) => match[1])
      .sort(),
    [...productionLeaves].sort(),
  );
  assert.equal(facade.trimEnd().split(/\r?\n/u).length, 4);
  assert.equal(facade.includes("part "), false);
  assert.equal(facade.includes("class "), false);
  assert.equal(facade.includes("Widget build"), false);
});

test("Workbench chrome leaves are bounded and never reverse-import the facade", async () => {
  const source = await sources();
  for (const leaf of productionLeaves) {
    assert.ok(source[leaf].trimEnd().split(/\r?\n/u).length <= 320, `${leaf} is oversized`);
    assert.equal(source[leaf].includes("workbench_desktop_chrome.dart"), false);
    assert.equal(source[leaf].includes("part of"), false);
  }
  assert.ok(source["workbench_desktop_topbar.dart"].includes("workbench_desktop_navigation.dart"));
  assert.ok(source["workbench_desktop_topbar.dart"].includes("workbench_desktop_search.dart"));
  for (const independent of [
    "workbench_desktop_navigation.dart",
    "workbench_desktop_search.dart",
    "workbench_desktop_status.dart",
  ]) {
    assert.equal(source[independent].includes("workbench_desktop_topbar.dart"), false);
  }
});

test("top bar composes search, navigation, pairing, and settings without owning their internals", async () => {
  const source = (await sources())["workbench_desktop_topbar.dart"];
  for (const token of [
    "WorkbenchDesktopTopBar",
    "WorkbenchDesktopNavigation",
    "WorkbenchDesktopSearch",
    "chrome.openPairing(context)",
    "ClientSection.settings",
    "WorkbenchDesktopChromeMetrics",
  ]) {
    assert.ok(source.includes(token), `missing topbar composition: ${token}`);
  }
  assert.equal(source.includes("Autocomplete<"), false);
  assert.equal(source.includes("CustomPainter"), false);
  assert.equal(source.includes("ValueListenableBuilder"), false);
});

test("search, navigation, and status retain independent interaction policies", async () => {
  const source = await sources();
  for (const token of [
    "Autocomplete<_WorkbenchSearchItem>",
    "LogicalKeyboardKey.escape",
    "_sectionSearchAliases",
    "startsWith(normalized)",
  ]) {
    assert.ok(source["workbench_desktop_search.dart"].includes(token));
  }
  for (const token of [
    "WorkbenchDesktopNavigation",
    "topbar-agents-icon",
    "_WorkbenchAgentRobotIconPainter",
    "ImageFilter.blur",
  ]) {
    assert.ok(source["workbench_desktop_navigation.dart"].includes(token));
  }
  for (const token of [
    "ValueListenableBuilder<LayoutChromeSnapshot>",
    "snapshot.status.displayText",
    "AnimatedSwitcher",
    "shell-status-text:",
  ]) {
    assert.ok(source["workbench_desktop_status.dart"].includes(token));
  }
});

test("every Workbench chrome leaf retains a dedicated widget regression", async () => {
  for (const leaf of productionLeaves) {
    const testName = leaf.replace(".dart", "_test.dart");
    await fs.access(path.join(
      repoRoot,
      `apps/desktop/test/layout/profiles/workbench/desktop/${testName}`,
    ));
  }
});
