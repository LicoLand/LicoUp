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
  "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell";
const productionLeaves = Object.freeze([
  "dashboard_desktop_search.dart",
  "dashboard_folder_sidebar.dart",
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

test("Dashboard desktop chrome root exports exactly the two ordinary libraries", async () => {
  const facade = await read(`${shellRoot}/dashboard_desktop_chrome.dart`);
  assert.deepEqual(
    [...facade.matchAll(/^export '([^']+)';$/gmu)]
      .map((match) => match[1])
      .sort(),
    [...productionLeaves].sort(),
  );
  assert.equal(facade.includes("part "), false);
  assert.equal(facade.includes("class "), false);
  assert.equal(facade.includes("Widget build"), false);
});

test("Dashboard chrome leaves are bounded and never reverse-import the facade", async () => {
  const source = await sources();
  for (const leaf of productionLeaves) {
    assert.equal(source[leaf].includes("dashboard_desktop_chrome.dart"), false);
    assert.equal(source[leaf].includes("part of"), false);
  }
  assert.ok(source["dashboard_folder_sidebar.dart"].includes("dashboard_desktop_search.dart"));
  assert.equal(source["dashboard_desktop_search.dart"].includes("dashboard_folder_sidebar.dart"), false);
});

test("folder sidebar owns the notes navigation and the house selection rule", async () => {
  const source = (await sources())["dashboard_folder_sidebar.dart"];
  for (const token of [
    "DashboardFolderSidebar",
    "dashboard-folder-nav-",
    "dashboard-folder-sidebar-traffic-light-reservation",
    "DashboardDesktopSearch",
    "colors.primary",
    "colors.textOnPrimary",
  ]) {
    assert.ok(source.includes(token), `missing folder sidebar composition: ${token}`);
  }
  // The retired chrome stays retired: no top bar, no status bar, no pairing dialog.
  for (const retired of [
    "DashboardDesktopTopBar",
    "DashboardDesktopNavigation",
    "DashboardDesktopStatusBar",
    "chrome.openPairing",
  ]) {
    assert.equal(source.includes(retired), false, `retired chrome leaked: ${retired}`);
  }
});

test("search retains its independent interaction policies", async () => {
  const source = (await sources())["dashboard_desktop_search.dart"];
  for (const token of [
    "Autocomplete<_DashboardSearchItem>",
    "LogicalKeyboardKey.escape",
    "_sectionSearchAliases",
    "startsWith(normalized)",
  ]) {
    assert.ok(source.includes(token), `missing search policy: ${token}`);
  }
});

test("every Dashboard chrome leaf retains a dedicated widget regression", async () => {
  for (const leaf of productionLeaves) {
    const testName = leaf.replace(".dart", "_test.dart");
    await fs.access(path.join(
      repoRoot,
      `apps/desktop/test/layout/profiles/dashboard/desktop/${testName}`,
    ));
  }
});
