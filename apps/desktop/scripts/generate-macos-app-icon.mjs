import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const defaultSourcePath = path.join(workspaceRoot, "apps", "desktop", "assets", "brand", "lico-app-icon.png");
const iconSetRoot = path.join(
  workspaceRoot,
  "apps",
  "desktop",
  "macos",
  "Runner",
  "Assets.xcassets",
  "AppIcon.appiconset"
);
const iconSizes = [16, 32, 64, 128, 256, 512, 1024];
const manifestPath = path.join(iconSetRoot, "SourceManifest.json");
const manifestSchemaVersion = "lico-macos-app-icon-source-v1";

function parseArgs(argv) {
  const options = {
    sourcePath: defaultSourcePath,
    verifyOnly: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--source") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--source requires an image path");
      }
      options.sourcePath = path.isAbsolute(value) ? value : path.resolve(process.cwd(), value);
      index += 1;
      continue;
    }
    if (arg === "--verify") {
      options.verifyOnly = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  return options;
}

function sha256(filePath) {
  return `sha256:${createHash("sha256").update(readFileSync(filePath)).digest("hex")}`;
}

function iconPath(size) {
  return path.join(iconSetRoot, `app_icon_${size}.png`);
}

function readPngSize(filePath) {
  const bytes = readFileSync(filePath);
  const pngSignature = "89504e470d0a1a0a";
  if (bytes.length < 24 || bytes.subarray(0, 8).toString("hex") !== pngSignature) {
    throw new Error(`Lico Arc app icon is not a valid PNG: ${path.basename(filePath)}`);
  }
  return {
    width: bytes.readUInt32BE(16),
    height: bytes.readUInt32BE(20),
  };
}

function createManifest(sourcePath) {
  return {
    schemaVersion: manifestSchemaVersion,
    source: {
      path: path.relative(workspaceRoot, sourcePath).replaceAll(path.sep, "/"),
      digest: sha256(sourcePath),
    },
    icons: iconSizes.map((size) => ({
      size,
      path: path.basename(iconPath(size)),
      digest: sha256(iconPath(size)),
    })),
  };
}

function verifyCommittedIcons(sourcePath) {
  if (!existsSync(manifestPath)) {
    throw new Error("Committed Lico Arc app icon source manifest is missing");
  }
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const expected = createManifest(sourcePath);
  if (manifest.schemaVersion !== expected.schemaVersion ||
      manifest.source?.path !== expected.source.path ||
      manifest.source?.digest !== expected.source.digest) {
    throw new Error("Committed Lico Arc app icons do not match the canonical SVG source");
  }
  const entries = new Map((manifest.icons || []).map((entry) => [entry.size, entry]));
  for (const expectedIcon of expected.icons) {
    const entry = entries.get(expectedIcon.size);
    if (!entry || entry.path !== expectedIcon.path || entry.digest !== expectedIcon.digest) {
      throw new Error(`Committed Lico Arc app icon digest is stale: ${expectedIcon.path}`);
    }
    const dimensions = readPngSize(iconPath(expectedIcon.size));
    if (dimensions.width !== expectedIcon.size || dimensions.height !== expectedIcon.size) {
      throw new Error(`Committed Lico Arc app icon has invalid dimensions: ${expectedIcon.path}`);
    }
  }
}

function run(command, args) {
  execFileSync(command, args, { stdio: "inherit" });
}

function renderSvgToPng(sourcePath, tempDir) {
  run("qlmanage", ["-t", "-s", "1024", "-o", tempDir, sourcePath]);
  const renderedPath = path.join(tempDir, `${path.basename(sourcePath)}.png`);
  if (!existsSync(renderedPath)) {
    throw new Error(`Quick Look did not render the Lico Arc app icon SVG: ${renderedPath}`);
  }
  return renderedPath;
}

function prepareBaseImage(sourcePath, tempDir) {
  const ext = path.extname(sourcePath).toLowerCase();
  if (ext === ".svg") {
    return renderSvgToPng(sourcePath, tempDir);
  }
  // Raster sources (PNG/JPG) are resized directly by sips.
  return sourcePath;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!existsSync(options.sourcePath)) {
    throw new Error(`Lico Arc icon source does not exist: ${options.sourcePath}`);
  }
  const supportedExtensions = new Set([".svg", ".png", ".jpg", ".jpeg"]);
  if (!supportedExtensions.has(path.extname(options.sourcePath).toLowerCase())) {
    throw new Error(`Lico Arc icon source must be an SVG or raster image (PNG/JPG): ${options.sourcePath}`);
  }

  mkdirSync(iconSetRoot, { recursive: true });
  if (options.verifyOnly) {
    verifyCommittedIcons(options.sourcePath);
    console.log("Verified committed Lico Arc macOS app icons");
    return;
  }
  const tempDir = path.join(os.tmpdir(), "lico-client-app-icon");
  rmSync(tempDir, { recursive: true, force: true });
  mkdirSync(tempDir, { recursive: true });
  const renderedPath = prepareBaseImage(options.sourcePath, tempDir);

  for (const size of iconSizes) {
    run("sips", ["-z", String(size), String(size), renderedPath, "--out", iconPath(size)]);
  }
  writeFileSync(manifestPath, `${JSON.stringify(createManifest(options.sourcePath), null, 2)}\n`);
  console.log(`Generated Lico Arc macOS app icons from ${options.sourcePath}`);
}

main();
