import { existsSync, readdirSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const flutterClientRoot = path.join(workspaceRoot, "apps", "desktop");
const macosNativeAssetsDir = path.join(flutterClientRoot, "build", "native_assets", "macos");
const flutterBuildCacheDir = path.join(flutterClientRoot, ".dart_tool", "flutter_build");
const debugAppDir = path.join(
  flutterClientRoot,
  "build",
  "macos",
  "Build",
  "Products",
  "Debug",
  "flutter_client.app"
);

function hasStaleMacosNativeAssetLayout() {
  if (!existsSync(macosNativeAssetsDir)) {
    return false;
  }
  return readdirSync(macosNativeAssetsDir, { withFileTypes: true }).some(
    (entry) => entry.isFile() && (entry.name === "native_assets.json" || entry.name.endsWith(".dylib"))
  );
}

function cleanStaleMacosNativeAssets() {
  if (!hasStaleMacosNativeAssetLayout()) {
    return;
  }
  console.log("[client:run:macos] Cleaning stale Flutter macOS native assets.");
  rmSync(macosNativeAssetsDir, { recursive: true, force: true });
  rmSync(flutterBuildCacheDir, { recursive: true, force: true });
  rmSync(debugAppDir, { recursive: true, force: true });
}

function runFlutterMacos(extraArgs) {
  const result = spawnSync("flutter", ["run", "-d", "macos", ...extraArgs], {
    cwd: flutterClientRoot,
    stdio: "inherit",
    env: process.env
  });
  process.exit(result.status ?? 1);
}

cleanStaleMacosNativeAssets();
runFlutterMacos(process.argv.slice(2));
