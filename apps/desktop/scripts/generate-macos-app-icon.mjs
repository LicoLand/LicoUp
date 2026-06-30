import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const defaultSourcePath = path.join(workspaceRoot, "apps", "desktop", "assets", "brand", "lico-app-icon.svg");
const iconSetRoot = path.join(
  workspaceRoot,
  "desktop-app",
  "macos",
  "Runner",
  "Assets.xcassets",
  "AppIcon.appiconset"
);
const iconSizes = [16, 32, 64, 128, 256, 512, 1024];

function parseArgs(argv) {
  const options = {
    sourcePath: defaultSourcePath,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--source") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--source requires an SVG path");
      }
      options.sourcePath = path.isAbsolute(value) ? value : path.resolve(process.cwd(), value);
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  return options;
}

function run(command, args) {
  execFileSync(command, args, { stdio: "inherit" });
}

function renderSvgToPng(sourcePath, tempDir) {
  run("qlmanage", ["-t", "-s", "1024", "-o", tempDir, sourcePath]);
  const renderedPath = path.join(tempDir, `${path.basename(sourcePath)}.png`);
  if (!existsSync(renderedPath)) {
    throw new Error(`Quick Look did not render the LicoLite app icon SVG: ${renderedPath}`);
  }
  return renderedPath;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!existsSync(options.sourcePath)) {
    throw new Error(`LicoLite icon source SVG does not exist: ${options.sourcePath}`);
  }
  if (path.extname(options.sourcePath).toLowerCase() !== ".svg") {
    throw new Error(`LicoLite icon source must be an SVG file: ${options.sourcePath}`);
  }

  mkdirSync(iconSetRoot, { recursive: true });
  const tempDir = path.join(os.tmpdir(), "lico-client-app-icon");
  rmSync(tempDir, { recursive: true, force: true });
  mkdirSync(tempDir, { recursive: true });
  const renderedPath = renderSvgToPng(options.sourcePath, tempDir);

  for (const size of iconSizes) {
    run("sips", ["-z", String(size), String(size), renderedPath, "--out", path.join(iconSetRoot, `app_icon_${size}.png`)]);
  }
  console.log(`Generated LicoLite macOS app icons from ${options.sourcePath}`);
}

main();
