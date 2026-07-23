import os from "node:os";
import path from "node:path";
import process from "node:process";

import { packageClientRuntime } from "../cli-policy.mjs";
import { runPackageProcess } from "../process-runner.mjs";

export function buildNativeSidecars(selected, options) {
  const bins = [
    ...new Set(
      selected.filter((item) => item.cargoBin).map((item) => item.cargoBin),
    ),
  ];
  if (bins.length === 0 || options.skipNativeBuild || options.dryRun) return;
  const args = [
    "build",
    "--manifest-path",
    path.join("crates", "lico-client-native", "Cargo.toml"),
  ];
  if (options.mode === "release") args.push("--release", "--locked");
  if (options.platform === "windows") {
    args.push("--target", packageClientRuntime.windowsX64RustTarget);
  }
  for (const bin of bins) args.push("--bin", bin);
  runPackageProcess("cargo", args, {
    failureCode: "native_sidecar_build_failed",
    stage: "native-build",
    env: {
      ...process.env,
      CARGO_TARGET_DIR: packageClientRuntime.nativeTargetRoot,
      RUSTFLAGS: rustFlagsWithPathRemap(),
    },
  });
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
