import { readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";

import { packageClientRuntime } from "../cli-policy.mjs";
import { runPackageProcess } from "../process-runner.mjs";

export function buildNativeSidecars(selected, options) {
  const bins = [
    ...new Set(
      selected.flatMap((item) =>
        [item.cargoBin, item.embeddedCargoBin].filter(Boolean),
      ),
    ),
  ];
  if (bins.length === 0 || options.skipNativeBuild || options.dryRun) return;
  const args = [
    path.join("tools", "scripts", "cargo-client.mjs"),
    "build",
    "--manifest-path",
    path.join("crates", "licoup-native", "Cargo.toml"),
  ];
  if (options.mode === "release") args.push("--release", "--locked");
  if (options.platform === "windows") {
    args.push("--target", packageClientRuntime.windowsX64RustTarget);
  }
  for (const bin of bins) args.push("--bin", bin);
  const environment = {
    ...process.env,
    RUSTFLAGS: rustFlagsWithPathRemap(),
  };
  if (options.mode === "release") {
    environment.LICO_CLIENT_PRODUCT_VERSION = clientProductVersion();
  }
  runPackageProcess(process.execPath, args, {
    failureCode: "native_sidecar_build_failed",
    stage: "native-build",
    env: environment,
  });
}

function clientProductVersion() {
  const manifest = JSON.parse(readFileSync(
    path.join(packageClientRuntime.workspaceRoot, "tools", "client-version.json"),
    "utf8",
  ));
  const version = String(manifest.productVersion || "").trim();
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error(`Invalid productVersion in tools/client-version.json: ${version}`);
  }
  return version;
}

export function cargoTargetDir(mode, options = {}) {
  return options.platform === "windows"
    ? path.join(
        packageClientRuntime.nativeTargetRoot,
        packageClientRuntime.windowsX64RustTarget,
        cargoProfile(mode),
      )
    : path.join(packageClientRuntime.nativeTargetRoot, cargoProfile(mode));
}

export function binarySuffix(platform) {
  return platform === "windows" ? ".exe" : "";
}

function cargoProfile(mode) {
  return mode === "release" ? "release" : "debug";
}

function rustFlagsWithPathRemap() {
  const cargoHome = process.env.CARGO_HOME || path.join(os.homedir(), ".cargo");
  const flags = [
    `--remap-path-prefix=${packageClientRuntime.workspaceRoot}=/lico/source`,
    `--remap-path-prefix=${cargoHome}=/cargo`,
  ];
  return [process.env.RUSTFLAGS, ...flags].filter(Boolean).join(" ");
}
