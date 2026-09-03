#!/usr/bin/env node
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { sanitizeError } from "./lib/sanitize-error.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const versionManifestPath = path.join(repoRoot, "tools", "client-version.json");
const versionManifestSchema = "v0.0.1:client-version-manifest-1";
export const cargoWorkspaceVersionPackages = Object.freeze([
  "licoup-agent-adapters",
  "licoup-agent-runtime",
  "licoup-client-state",
  "licoup-conversation",
  "licoup-endpoint-core",
  "licoup-native",
  "licoup-platform-bridges",
  "licoup-protocol-bindings",
  "trybuild",
]);

function readJson(relativePath) {
  return JSON.parse(readFileSync(path.join(repoRoot, relativePath), "utf8"));
}

function writeJson(relativePath, value) {
  writeFileSync(path.join(repoRoot, relativePath), `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), "utf8");
}

function writeText(relativePath, value) {
  writeFileSync(path.join(repoRoot, relativePath), value, "utf8");
}

function loadManifest() {
  const manifest = JSON.parse(readFileSync(versionManifestPath, "utf8"));
  validateManifest(manifest);
  return manifest;
}

function validateManifest(manifest) {
  if (manifest.schemaVersion !== versionManifestSchema) {
    throw new Error(`Invalid client version manifest schema: ${manifest.schemaVersion}`);
  }
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(manifest.productVersion || "")) {
    throw new Error(`Invalid productVersion in tools/client-version.json: ${manifest.productVersion}`);
  }
  if (!Number.isInteger(manifest.buildNumber) || manifest.buildNumber < 1) {
    throw new Error(`Invalid buildNumber in tools/client-version.json: ${manifest.buildNumber}`);
  }
}

function flutterVersion(manifest) {
  return `${manifest.productVersion}+${manifest.buildNumber}`;
}

function replaceExactly(source, regex, replacement, label) {
  let count = 0;
  const next = source.replace(regex, (...args) => {
    count += 1;
    if (typeof replacement === "function") {
      return replacement(...args);
    }
    return replacement.replace(/\$(\d+)/g, (_, index) => args[Number(index)] ?? "");
  });
  if (count !== 1) {
    throw new Error(`${label} must exist exactly once; found ${count}.`);
  }
  return next;
}

function replaceAllRequired(source, regex, replacement, label) {
  let count = 0;
  const next = source.replace(regex, (...args) => {
    count += 1;
    if (typeof replacement === "function") {
      return replacement(...args);
    }
    return replacement.replace(/\$(\d+)/g, (_, index) => args[Number(index)] ?? "");
  });
  if (count < 1) {
    throw new Error(`${label} must exist at least once; found ${count}.`);
  }
  return { source: next, count };
}

function syncPackageJson(manifest) {
  const packageJson = readJson("package.json");
  packageJson.version = manifest.productVersion;
  writeJson("package.json", packageJson);

  const packageLockPath = "package-lock.json";
  if (existsSync(path.join(repoRoot, packageLockPath))) {
    const lock = readJson(packageLockPath);
    lock.version = manifest.productVersion;
    if (!lock.packages || !lock.packages[""]) {
      throw new Error("package-lock.json must contain packages[\"\"] root metadata.");
    }
    lock.packages[""].version = manifest.productVersion;
    writeJson(packageLockPath, lock);
  }
}

function syncTomlManifest(relativePath, sectionName, manifest) {
  const source = readText(relativePath);
  const sectionRegex = new RegExp(
    String.raw`(\[${sectionName.replace(".", String.raw`\.`)}\].*?\nversion\s*=\s*")[^"]+(")`,
    "s",
  );
  writeText(relativePath, replaceExactly(
    source,
    sectionRegex,
    (_, prefix, suffix) => `${prefix}${manifest.productVersion}${suffix}`,
    `${relativePath} [${sectionName}] version`
  ));
}

function syncCargoLock(relativePath, manifest) {
  const absolutePath = path.join(repoRoot, relativePath);
  if (!existsSync(absolutePath)) {
    return;
  }
  let source = readText(relativePath);
  for (const packageName of cargoWorkspaceVersionPackages) {
    const regex = new RegExp(
      String.raw`(\[\[package\]\]\nname = "${packageName}"\nversion = ")[^"]+(")`,
    );
    if (!regex.test(source)) continue;
    source = replaceExactly(
      source,
      regex,
      (_, prefix, suffix) => `${prefix}${manifest.productVersion}${suffix}`,
      `${relativePath} ${packageName} version`,
    );
  }
  writeText(relativePath, source);
}

function syncPubspec(manifest) {
  const relativePath = "apps/desktop/pubspec.yaml";
  const source = readText(relativePath);
  writeText(relativePath, replaceExactly(
    source,
    /^version:\s+.+$/m,
    `version: ${flutterVersion(manifest)}`,
    `${relativePath} version`
  ));
}

function syncXcodeProject(relativePath, manifest) {
  let source = readText(relativePath);
  source = replaceAllRequired(
    source,
    /(CURRENT_PROJECT_VERSION = )[^;]+(;)/g,
    (_, prefix, suffix) => `${prefix}${manifest.buildNumber}${suffix}`,
    `${relativePath} literal CURRENT_PROJECT_VERSION`
  ).source;
  source = replaceAllRequired(
    source,
    /(MARKETING_VERSION = )[^;]+(;)/g,
    (_, prefix, suffix) => `${prefix}${manifest.productVersion}${suffix}`,
    `${relativePath} MARKETING_VERSION`
  ).source;
  writeText(relativePath, source);
}

function syncVersion() {
  const manifest = loadManifest();
  syncPackageJson(manifest);
  syncTomlManifest("Cargo.toml", "workspace.package", manifest);
  syncTomlManifest("crates/licoup-native/Cargo.toml", "package", manifest);
  syncCargoLock("Cargo.lock", manifest);
  syncCargoLock("crates/licoup-native/Cargo.lock", manifest);
  syncPubspec(manifest);
  syncXcodeProject("apps/desktop/ios/Runner.xcodeproj/project.pbxproj", manifest);
  syncXcodeProject("apps/desktop/macos/Runner.xcodeproj/project.pbxproj", manifest);
}

function valueAtRegex(relativePath, regex, label) {
  const source = readText(relativePath);
  const matches = [...source.matchAll(regex)];
  if (matches.length !== 1) {
    throw new Error(`${label} must exist exactly once; found ${matches.length}.`);
  }
  return matches[0][1];
}

function valuesAtRegex(relativePath, regex, label) {
  const source = readText(relativePath);
  const matches = [...source.matchAll(regex)];
  if (matches.length < 1) {
    throw new Error(`${label} must exist at least once; found ${matches.length}.`);
  }
  return matches.map((match) => match[1]);
}

function checkEqual(records, label, actual, expected) {
  const ok = actual === expected;
  records.push({ label, expected, actual, ok });
  return ok;
}

function checkAllEqual(records, label, actualValues, expected) {
  let ok = true;
  for (const actual of actualValues) {
    if (actual !== expected) {
      ok = false;
    }
  }
  records.push({ label, expected, actual: actualValues, ok });
  return ok;
}

function checkVersion() {
  const manifest = loadManifest();
  const records = [];
  let ok = true;

  const packageJson = readJson("package.json");
  ok = checkEqual(records, "package.json version", packageJson.version, manifest.productVersion) && ok;

  const packageLock = readJson("package-lock.json");
  ok = checkEqual(records, "package-lock.json version", packageLock.version, manifest.productVersion) && ok;
  if (!packageLock.packages || !packageLock.packages[""]) {
    throw new Error("package-lock.json must contain packages[\"\"] root metadata.");
  }
  ok = checkEqual(records, "package-lock.json packages root version", packageLock.packages[""].version, manifest.productVersion) && ok;

  ok = checkEqual(
    records,
    "Cargo.toml workspace.package version",
    valueAtRegex("Cargo.toml", /\[workspace\.package\][\s\S]*?\nversion\s*=\s*"([^"]+)"/g, "Cargo.toml workspace.package version"),
    manifest.productVersion
  ) && ok;
  ok = checkEqual(
    records,
    "crates/licoup-native/Cargo.toml package version",
    valueAtRegex("crates/licoup-native/Cargo.toml", /\[package\][\s\S]*?\nversion\s*=\s*"([^"]+)"/g, "crates/licoup-native/Cargo.toml package version"),
    manifest.productVersion
  ) && ok;

  for (const cargoLockPath of ["Cargo.lock", "crates/licoup-native/Cargo.lock"]) {
    if (existsSync(path.join(repoRoot, cargoLockPath))) {
      const source = readText(cargoLockPath);
      for (const packageName of cargoWorkspaceVersionPackages) {
        const matches = [...source.matchAll(new RegExp(
          String.raw`\[\[package\]\]\nname = "${packageName}"\nversion = "([^"]+)"`, "g"))];
        if (matches.length > 1) {
          throw new Error(`${cargoLockPath} ${packageName} version must exist at most once; found ${matches.length}.`);
        }
        if (matches.length === 1) {
          ok = checkEqual(records, `${cargoLockPath} ${packageName} version`,
            matches[0][1], manifest.productVersion) && ok;
        }
      }
    }
  }

  ok = checkEqual(
    records,
    "apps/desktop/pubspec.yaml version",
    valueAtRegex("apps/desktop/pubspec.yaml", /^version:\s+(.+)$/gm, "apps/desktop/pubspec.yaml version"),
    flutterVersion(manifest)
  ) && ok;

  ok = checkEqual(
    records,
    "Android versionCode source",
    valueAtRegex(
      "apps/desktop/android/app/build.gradle.kts",
      /^\s*versionCode\s*=\s*(.+)$/gm,
      "apps/desktop/android/app/build.gradle.kts versionCode"
    ),
    "flutter.versionCode"
  ) && ok;
  ok = checkEqual(
    records,
    "Android versionName source",
    valueAtRegex(
      "apps/desktop/android/app/build.gradle.kts",
      /^\s*versionName\s*=\s*(.+)$/gm,
      "apps/desktop/android/app/build.gradle.kts versionName"
    ),
    "flutter.versionName"
  ) && ok;

  for (const infoPlist of ["apps/desktop/ios/Runner/Info.plist", "apps/desktop/macos/Runner/Info.plist"]) {
    const source = readText(infoPlist);
    ok = checkEqual(
      records,
      `${infoPlist} CFBundleShortVersionString`,
      /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(source)?.[1] || "",
      "$(FLUTTER_BUILD_NAME)"
    ) && ok;
    ok = checkEqual(
      records,
      `${infoPlist} CFBundleVersion`,
      /<key>CFBundleVersion<\/key>\s*<string>([^<]+)<\/string>/.exec(source)?.[1] || "",
      "$(FLUTTER_BUILD_NUMBER)"
    ) && ok;
  }

  ok = checkAllEqual(
    records,
    "iOS RunnerTests MARKETING_VERSION",
    valuesAtRegex("apps/desktop/ios/Runner.xcodeproj/project.pbxproj", /MARKETING_VERSION = ([^;]+);/g, "iOS MARKETING_VERSION"),
    manifest.productVersion
  ) && ok;
  ok = checkAllEqual(
    records,
    "macOS RunnerTests MARKETING_VERSION",
    valuesAtRegex("apps/desktop/macos/Runner.xcodeproj/project.pbxproj", /MARKETING_VERSION = ([^;]+);/g, "macOS MARKETING_VERSION"),
    manifest.productVersion
  ) && ok;
  ok = checkAllEqual(
    records,
    "iOS literal CURRENT_PROJECT_VERSION",
    valuesAtRegex("apps/desktop/ios/Runner.xcodeproj/project.pbxproj", /CURRENT_PROJECT_VERSION = ([0-9]+);/g, "iOS literal CURRENT_PROJECT_VERSION"),
    String(manifest.buildNumber)
  ) && ok;
  ok = checkAllEqual(
    records,
    "macOS literal CURRENT_PROJECT_VERSION",
    valuesAtRegex("apps/desktop/macos/Runner.xcodeproj/project.pbxproj", /CURRENT_PROJECT_VERSION = ([0-9]+);/g, "macOS literal CURRENT_PROJECT_VERSION"),
    String(manifest.buildNumber)
  ) && ok;

  console.log(JSON.stringify({ ok, productVersion: manifest.productVersion, buildNumber: manifest.buildNumber, records }, null, 2));
  if (!ok) {
    process.exitCode = 1;
  }
}

function updateManifest(argv) {
  const manifest = loadManifest();
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--version" && next) {
      manifest.productVersion = next;
      index += 1;
    } else if (arg === "--build-number" && next) {
      manifest.buildNumber = Number(next);
      index += 1;
    } else {
      throw new Error(`Unknown client version option: ${arg}`);
    }
  }
  validateManifest(manifest);
  writeFileSync(versionManifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  syncVersion();
}

function main() {
  const [action = "check", ...args] = process.argv.slice(2);
  try {
    if (action === "check") {
      checkVersion();
    } else if (action === "sync") {
      syncVersion();
      checkVersion();
    } else if (action === "set") {
      updateManifest(args);
      checkVersion();
    } else {
      throw new Error(`Unknown client version action: ${action}`);
    }
  } catch (error) {
    console.error(sanitizeError(error));
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main();
}
