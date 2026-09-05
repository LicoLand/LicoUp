import {
  cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync,
  realpathSync, renameSync, rmSync,
} from "node:fs";
import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const MACOS_APP_NAME = "LicoUp.app";
export const MACOS_BUNDLE_ID = "land.lico.licoup";
const LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
const METADATA_DIRECTORY = path.join("package-metadata", "licoup");
const WORKSPACE_ROOT = fileURLToPath(new URL("../../..", import.meta.url));

export class MacosInstallError extends Error {
  constructor(code, stage = "") {
    super(code);
    this.code = code;
    this.stage = stage;
  }
}

function fail(code, stage) {
  throw new MacosInstallError(code, stage);
}

function isLicoUp(info) {
  return info?.CFBundleIdentifier === MACOS_BUNDLE_ID &&
    [info.CFBundleName, info.CFBundleDisplayName].includes("LicoUp");
}

// A bundle identifier alone is insufficient: another product can accidentally
// reuse it. Missing paths are accepted only from LicoUp's own registration.
export function registeredLicoUpApps(dump) {
  const apps = new Set();
  for (const record of dump.split(/\n-{20,}\n/u)) {
    const field = (name) => record.match(new RegExp(`^${name}:\\s*(.+)$`, "m"))?.[1]?.trim();
    if (field("identifier") !== MACOS_BUNDLE_ID || field("name") !== "LicoUp") continue;
    const app = field("path")?.replace(/ \(0x[\da-f]+\)$/iu, "");
    if (app && path.isAbsolute(app)) apps.add(path.normalize(app));
  }
  return [...apps];
}

function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) &&
    relative !== ".." && !path.isAbsolute(relative));
}

function inventory(installDir, ports) {
  const roots = new Set([installDir, ...ports.installationRoots()].map((p) => path.resolve(p)));
  const registered = ports.registeredApps();
  const buildSet = new Set(ports.buildApps());
  const candidates = new Set([
    ...registered,
    ...ports.indexedApps(),
    ...buildSet,
    ...[...roots].flatMap((root) => ports.directoryEntries(root).map((name) => path.join(root, name))),
  ]);
  const installed = [];
  const builds = [];
  const registrations = new Set();
  const registeredSet = new Set(registered);
  for (const candidate of candidates) {
    const info = ports.bundleInfo(candidate);
    if (!info && registeredSet.has(candidate)) registrations.add(candidate);
    if (!isLicoUp(info)) continue;
    registrations.add(candidate);
    if (roots.has(path.dirname(candidate)) && !ports.isSymlink(candidate)) installed.push(candidate);
    else if (buildSet.has(candidate) && !ports.isSymlink(candidate)) builds.push(candidate);
  }
  return { installed, builds, registrations: [...registrations] };
}

function unregister(apps, ports, stage) {
  if (apps.length && !ports.unregister(apps)) fail("macos_install_unregister_failed", stage);
}

function removeInstallation(app, ports) {
  ports.remove(app);
  ports.remove(path.join(path.dirname(app), METADATA_DIRECTORY));
}

export function installMacosApplication(
  { sourceApp, installDir, manifestRoot, stages = [] },
  ports = createMacosAppPorts(),
) {
  const installedAppPath = path.join(installDir, MACOS_APP_NAME);
  const source = ports.canonicalPath(sourceApp);
  const destination = ports.canonicalPath(installedAppPath);
  if (inside(source, destination) || inside(destination, source)) {
    fail("macos_install_source_destination_overlap", "macos-install-validate-destination");
  }
  if (!isLicoUp(ports.bundleInfo(sourceApp))) {
    fail("macos_install_bundle_identity_invalid", "macos-install-validate-runnable");
  }
  if (ports.exists(installedAppPath) &&
      (ports.isSymlink(installedAppPath) || !isLicoUp(ports.bundleInfo(installedAppPath)))) {
    fail("macos_install_destination_conflict", "macos-install-validate-destination");
  }
  const current = inventory(installDir, ports);

  // Prepare the new bytes before quitting or removing any installed version.
  // This temporary payload is not an app bundle or a backup of the old app.
  stages.push("macos-install-stage-payload");
  ports.mkdir(installDir);
  const staging = ports.makeTempDirectory(installDir);
  try {
    const payload = path.join(staging, "payload");
    ports.copyTree(sourceApp, payload);
    if (manifestRoot) ports.copyTree(manifestRoot, path.join(staging, "metadata"));

    stages.push("macos-install-quit-running");
    ports.quitRunning([...new Set([...current.installed, ...current.registrations])]);
    stages.push("macos-install-unregister");
    unregister([...new Set([...current.registrations, ...current.installed, sourceApp])], ports, "macos-install-unregister");

    stages.push("macos-install-replace-destination");
    ports.remove(installedAppPath);
    ports.move(payload, installedAppPath);
    const installedMetadata = path.join(installDir, METADATA_DIRECTORY);
    ports.remove(installedMetadata);
    if (manifestRoot) {
      ports.mkdir(path.dirname(installedMetadata));
      ports.move(path.join(staging, "metadata"), installedMetadata);
    }
    for (const app of current.installed) {
      if (ports.canonicalPath(app) !== ports.canonicalPath(installedAppPath)) {
        // Siblings share the newly installed manifest.
        if (path.dirname(app) === installDir) ports.remove(app);
        else removeInstallation(app, ports);
      }
    }

    stages.push("macos-install-register");
    if (!ports.register(installedAppPath)) fail("macos_install_register_failed", "macos-install-register");
    stages.push("macos-install-clean-build-apps");
    for (const app of current.builds) {
      if (ports.canonicalPath(app) !== ports.canonicalPath(installedAppPath)) ports.remove(app);
    }
    return {
      installedAppPath, removedApplications: current.installed.length,
      removedBuildApplications: current.builds.length,
      unregisteredApplications: current.registrations.length,
    };
  } finally {
    ports.remove(staging);
  }
}

export function uninstallMacosApplication({ installDir }, ports = createMacosAppPorts()) {
  const stages = ["macos-uninstall-discover"];
  const current = inventory(installDir, ports);
  stages.push("macos-uninstall-quit-running");
  ports.quitRunning([...new Set([...current.installed, ...current.registrations])]);
  stages.push("macos-uninstall-unregister");
  unregister([...new Set([...current.registrations, ...current.installed])], ports, "macos-uninstall-unregister");
  stages.push("macos-uninstall-remove");
  for (const app of current.installed) removeInstallation(app, ports);
  for (const app of current.builds) ports.remove(app);
  // Also retire a manifest left by an interrupted removal.
  for (const root of new Set([installDir, ...ports.installationRoots()])) {
    ports.remove(path.join(root, METADATA_DIRECTORY));
  }
  return {
    ok: true, stages, removedApplications: current.installed.length,
    removedBuildApplications: current.builds.length,
    unregisteredApplications: current.registrations.length, userDataPreserved: true,
  };
}

function command(program, args) {
  return spawnSync(program, args, {
    encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 64 * 1024 * 1024,
  });
}

function capture(program, args) {
  const result = command(program, args);
  if (result.status !== 0) fail("macos_install_discovery_failed", "macos-install-discover");
  return result.stdout;
}

function bundleInfo(app) {
  const plist = path.join(app, "Contents", "Info.plist");
  if (!existsSync(plist)) return null;
  const result = command("/usr/bin/plutil", ["-convert", "json", "-o", "-", plist]);
  if (result.status !== 0) return null;
  try { return JSON.parse(result.stdout); } catch { return null; }
}

function canonicalPath(target) {
  if (existsSync(target)) return realpathSync(target);
  const parent = path.dirname(target);
  return parent === target ? target : path.join(canonicalPath(parent), path.basename(target));
}

function buildApps() {
  const apps = [];
  function visit(root) {
    if (!existsSync(root)) return;
    for (const entry of readdirSync(root, { withFileTypes: true })) {
      if (!entry.isDirectory() || entry.isSymbolicLink()) continue;
      const target = path.join(root, entry.name);
      if (entry.name.toLowerCase().endsWith(".app")) apps.push(target);
      else visit(target);
    }
  }
  // Only published local packaging outputs; active temporary builds and
  // compiler/dependency caches belong to their own artifact lifecycle.
  for (const root of [
    "build/apps/desktop/runnable/macos",
    "build/apps/desktop/bundles/macos",
    "apps/desktop/build/macos/Build/Products",
  ]) visit(path.join(WORKSPACE_ROOT, root));
  return apps;
}

function quitRunning(apps) {
  const markers = [...new Set(apps)].map((app) => `${app}/Contents/MacOS/`);
  const processes = () => capture("/bin/ps", ["-axo", "pid=,comm="])
    .split(/\r?\n/u).flatMap((line) => {
      const match = /^\s*(\d+)\s+(.+)$/u.exec(line);
      return match && markers.some((marker) => match[2].startsWith(marker)) ? [Number(match[1])] : [];
    });
  const pids = processes();
  // Address each exact process, not a bundle-id lookup that can select another
  // registered copy or another product. Allow native save/quit handling to finish.
  for (const pid of pids) {
    const result = command("/usr/bin/osascript", ["-l", "JavaScript", "-e",
      `ObjC.import('AppKit'); const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(${pid}); if (app && !app.terminate) throw Error('quit_failed');`,
    ]);
    if (result.status !== 0 && processes().includes(pid)) fail("macos_install_quit_failed", "macos-install-quit-running");
  }
  while (processes().some((pid) => pids.includes(pid))) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 250);
  }
}

export function createMacosAppPorts() {
  return {
    exists: existsSync,
    canonicalPath,
    bundleInfo,
    isSymlink: (target) => lstatSync(target, { throwIfNoEntry: false })?.isSymbolicLink() || false,
    installationRoots: () => ["/Applications", path.join(os.homedir(), "Applications")],
    directoryEntries: (root) => existsSync(root) ? readdirSync(root) : [],
    registeredApps: () => registeredLicoUpApps(capture(LSREGISTER, ["-dump", "Bundle"])),
    indexedApps: () => capture("/usr/bin/mdfind", [`kMDItemCFBundleIdentifier == "${MACOS_BUNDLE_ID}"`]).split(/\r?\n/u).filter(Boolean),
    buildApps,
    quitRunning,
    mkdir: (root) => mkdirSync(root, { recursive: true }),
    makeTempDirectory: (root) => mkdtempSync(path.join(root, ".licoup-install-")),
    remove: (target) => rmSync(target, { recursive: true, force: true }),
    move: renameSync,
    copyTree: (source, target) => cpSync(source, target, { recursive: true, dereference: false, verbatimSymlinks: true }),
    unregister: (apps) => {
      for (let index = 0; index < apps.length; index += 100) {
        if (command(LSREGISTER, ["-u", ...apps.slice(index, index + 100)]).status !== 0) return false;
      }
      return true;
    },
    register: (app) => command(LSREGISTER, ["-f", app]).status === 0 &&
      command("/usr/bin/mdimport", [app]).status === 0,
  };
}
