import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const defaultSourcePath = path.join(workspaceRoot, "apps", "desktop", "assets", "brand", "lico-app-icon.svg");
const deployedRasterPath = path.join(workspaceRoot, "apps", "desktop", "assets", "brand", "lico-app-icon.png");
const iconSetRoot = path.join(
  workspaceRoot,
  "apps",
  "desktop",
  "macos",
  "Runner",
  "Assets.xcassets",
  "AppIcon.appiconset"
);
const iosIconSetRoot = path.join(
  workspaceRoot,
  "apps",
  "desktop",
  "ios",
  "Runner",
  "Assets.xcassets",
  "AppIcon.appiconset",
);
const androidIconRoots = new Map([
  [48, "mipmap-mdpi"],
  [72, "mipmap-hdpi"],
  [96, "mipmap-xhdpi"],
  [144, "mipmap-xxhdpi"],
  [192, "mipmap-xxxhdpi"],
]);
const iosIcons = new Map([
  ["Icon-App-20x20-1x.png", 20],
  ["Icon-App-20x20-2x.png", 40],
  ["Icon-App-20x20-3x.png", 60],
  ["Icon-App-29x29-1x.png", 29],
  ["Icon-App-29x29-2x.png", 58],
  ["Icon-App-29x29-3x.png", 87],
  ["Icon-App-40x40-1x.png", 40],
  ["Icon-App-40x40-2x.png", 80],
  ["Icon-App-40x40-3x.png", 120],
  ["Icon-App-60x60-2x.png", 120],
  ["Icon-App-60x60-3x.png", 180],
  ["Icon-App-76x76-1x.png", 76],
  ["Icon-App-76x76-2x.png", 152],
  ["Icon-App-83.5x83.5-2x.png", 167],
  ["Icon-App-1024x1024-1x.png", 1024],
]);
const windowsIconSizes = [16, 24, 32, 48, 64, 128, 256];
const windowsIconPath = path.join(
  workspaceRoot,
  "apps",
  "desktop",
  "windows",
  "runner",
  "resources",
  "app_icon.ico",
);
const iconSizes = [16, 32, 64, 128, 256, 512, 1024];
const manifestPath = path.join(iconSetRoot, "SourceManifest.json");
const manifestSchemaVersion = "lico-app-icon-source-v2";

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

function androidIconPath(size) {
  return path.join(
    workspaceRoot,
    "apps",
    "desktop",
    "android",
    "app",
    "src",
    "main",
    "res",
    androidIconRoots.get(size),
    "ic_launcher.png",
  );
}

function iosIconPath(fileName) {
  return path.join(iosIconSetRoot, fileName);
}

function readPngSize(filePath) {
  const bytes = readFileSync(filePath);
  const pngSignature = "89504e470d0a1a0a";
  if (bytes.length < 24 || bytes.subarray(0, 8).toString("hex") !== pngSignature) {
    throw new Error(`LicoUp app icon is not a valid PNG: ${path.basename(filePath)}`);
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
    deployed: {
      raster: {
        path: path.relative(workspaceRoot, deployedRasterPath).replaceAll(path.sep, "/"),
        digest: sha256(deployedRasterPath),
      },
      android: [...androidIconRoots.keys()].map((size) => ({
        size,
        path: path.relative(workspaceRoot, androidIconPath(size)).replaceAll(path.sep, "/"),
        digest: sha256(androidIconPath(size)),
      })),
      ios: [...iosIcons].map(([fileName, size]) => ({
        size,
        path: path.relative(workspaceRoot, iosIconPath(fileName)).replaceAll(path.sep, "/"),
        digest: sha256(iosIconPath(fileName)),
      })),
      windows: {
        sizes: windowsIconSizes,
        path: path.relative(workspaceRoot, windowsIconPath).replaceAll(path.sep, "/"),
        digest: sha256(windowsIconPath),
      },
    },
  };
}

function validateSvgSource(sourcePath) {
  if (path.extname(sourcePath).toLowerCase() !== ".svg") {
    return;
  }
  const source = readFileSync(sourcePath, "utf8");
  if (!/<svg\b/u.test(source) || !/\bviewBox=/u.test(source)) {
    throw new Error("LicoUp app icon SVG is missing its vector root or viewBox");
  }
  if (/<image\b/u.test(source) || /data:image\//u.test(source)) {
    throw new Error("LicoUp app icon SVG must not embed raster images");
  }
}

function verifyCommittedIcons(sourcePath) {
  if (!existsSync(manifestPath)) {
    throw new Error("Committed LicoUp app icon source manifest is missing");
  }
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const expected = createManifest(sourcePath);
  if (manifest.schemaVersion !== expected.schemaVersion ||
      manifest.source?.path !== expected.source.path ||
      manifest.source?.digest !== expected.source.digest) {
    throw new Error("Committed LicoUp app icons do not match the canonical SVG source");
  }
  if (JSON.stringify(manifest.deployed) !== JSON.stringify(expected.deployed)) {
    throw new Error("Committed LicoUp platform icons do not match the canonical SVG source");
  }
  const entries = new Map((manifest.icons || []).map((entry) => [entry.size, entry]));
  for (const expectedIcon of expected.icons) {
    const entry = entries.get(expectedIcon.size);
    if (!entry || entry.path !== expectedIcon.path || entry.digest !== expectedIcon.digest) {
      throw new Error(`Committed LicoUp app icon digest is stale: ${expectedIcon.path}`);
    }
    const dimensions = readPngSize(iconPath(expectedIcon.size));
    if (dimensions.width !== expectedIcon.size || dimensions.height !== expectedIcon.size) {
      throw new Error(`Committed LicoUp app icon has invalid dimensions: ${expectedIcon.path}`);
    }
  }
  for (const [size] of androidIconRoots) {
    const dimensions = readPngSize(androidIconPath(size));
    if (dimensions.width !== size || dimensions.height !== size) {
      throw new Error(`Committed LicoUp Android icon has invalid dimensions: ${size}`);
    }
  }
  for (const [fileName, size] of iosIcons) {
    const dimensions = readPngSize(iosIconPath(fileName));
    if (dimensions.width !== size || dimensions.height !== size) {
      throw new Error(`Committed LicoUp iOS icon has invalid dimensions: ${fileName}`);
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
    throw new Error(`Quick Look did not render the LicoUp app icon SVG: ${renderedPath}`);
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

function writeWindowsIcon(renderedPath, tempDir) {
  const images = windowsIconSizes.map((size) => {
    const outputPath = path.join(tempDir, `windows-${size}.png`);
    run("sips", ["-z", String(size), String(size), renderedPath, "--out", outputPath]);
    return { size, bytes: readFileSync(outputPath) };
  });
  const headerSize = 6;
  const entrySize = 16;
  const header = Buffer.alloc(headerSize + entrySize * images.length);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(images.length, 4);
  let imageOffset = header.length;
  for (let index = 0; index < images.length; index += 1) {
    const { size, bytes } = images[index];
    const entryOffset = headerSize + index * entrySize;
    header.writeUInt8(size === 256 ? 0 : size, entryOffset);
    header.writeUInt8(size === 256 ? 0 : size, entryOffset + 1);
    header.writeUInt8(0, entryOffset + 2);
    header.writeUInt8(0, entryOffset + 3);
    header.writeUInt16LE(1, entryOffset + 4);
    header.writeUInt16LE(32, entryOffset + 6);
    header.writeUInt32LE(bytes.length, entryOffset + 8);
    header.writeUInt32LE(imageOffset, entryOffset + 12);
    imageOffset += bytes.length;
  }
  writeFileSync(windowsIconPath, Buffer.concat([header, ...images.map(({ bytes }) => bytes)]));
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!existsSync(options.sourcePath)) {
    throw new Error(`LicoUp icon source does not exist: ${options.sourcePath}`);
  }
  const supportedExtensions = new Set([".svg", ".png", ".jpg", ".jpeg"]);
  if (!supportedExtensions.has(path.extname(options.sourcePath).toLowerCase())) {
    throw new Error(`LicoUp icon source must be an SVG or raster image (PNG/JPG): ${options.sourcePath}`);
  }
  validateSvgSource(options.sourcePath);

  mkdirSync(iconSetRoot, { recursive: true });
  if (options.verifyOnly) {
    verifyCommittedIcons(options.sourcePath);
    console.log("Verified committed LicoUp platform app icons");
    return;
  }
  const tempDir = path.join(os.tmpdir(), "licoup-app-icon");
  rmSync(tempDir, { recursive: true, force: true });
  mkdirSync(tempDir, { recursive: true });
  const renderedPath = prepareBaseImage(options.sourcePath, tempDir);

  run("sips", ["-z", "1024", "1024", renderedPath, "--out", deployedRasterPath]);

  for (const size of iconSizes) {
    run("sips", ["-z", String(size), String(size), renderedPath, "--out", iconPath(size)]);
  }
  for (const [size] of androidIconRoots) {
    run("sips", [
      "-z",
      String(size),
      String(size),
      renderedPath,
      "--out",
      androidIconPath(size),
    ]);
  }
  for (const [fileName, size] of iosIcons) {
    run("sips", [
      "-z",
      String(size),
      String(size),
      renderedPath,
      "--out",
      iosIconPath(fileName),
    ]);
  }
  writeWindowsIcon(renderedPath, tempDir);
  writeFileSync(manifestPath, `${JSON.stringify(createManifest(options.sourcePath), null, 2)}\n`);
  console.log(`Generated LicoUp platform app icons from ${options.sourcePath}`);
}

main();
