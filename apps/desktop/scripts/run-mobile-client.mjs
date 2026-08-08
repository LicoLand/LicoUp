#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  seedClientGradleHome,
  withClientToolchainEnv
} from "../../../tools/scripts/client-toolchain-env.mjs";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const flutterClientRoot = path.join(workspaceRoot, "apps", "desktop");

function normalizePlatform(value) {
  const normalized = String(value || "").toLowerCase();
  if (normalized === "android" || normalized === "ios") {
    return normalized;
  }
  throw new Error(`Unsupported mobile platform: ${value}`);
}

function hasDeviceOption(args) {
  return args.some((arg, index) => (
    arg === "-d" ||
    arg === "--device-id" ||
    arg.startsWith("-d=") ||
    arg.startsWith("--device-id=") ||
    (index > 0 && (args[index - 1] === "-d" || args[index - 1] === "--device-id"))
  ));
}

function hasOption(args, name) {
  return args.some((arg) => arg === name || arg.startsWith(`${name}=`));
}

function defaultDeviceId(platform) {
  const platformKey = platform.toUpperCase();
  return process.env[`LICO_CLIENT_${platformKey}_DEVICE`] ||
    process.env.LICO_CLIENT_MOBILE_DEVICE ||
    platform;
}

function prepareFlutterDependencies(env) {
  const result = spawnSync("flutter", ["pub", "get", "--enforce-lockfile", "--offline"], {
    cwd: flutterClientRoot,
    stdio: "inherit",
    env
  });
  if (result.status !== 0) {
    console.error("[client:run:mobile] Flutter dependencies are missing from the local Pub cache.");
    console.error("[client:run:mobile] Run `npm run client:get` once, then retry.");
    process.exit(result.status ?? 1);
  }
}

function runFlutterMobile(platform, extraArgs) {
  const args = ["run"];
  if (!hasOption(extraArgs, "--no-pub") && !hasOption(extraArgs, "--pub")) {
    args.push("--no-pub");
  }
  if (!hasDeviceOption(extraArgs)) {
    args.push("-d", defaultDeviceId(platform));
  }
  args.push(...extraArgs);
  const env = withClientToolchainEnv();
  prepareFlutterDependencies(env);
  if (platform === "android") {
    seedClientGradleHome(env, { log: (message) => console.log(message) });
  }
  const result = spawnSync("flutter", args, {
    cwd: flutterClientRoot,
    stdio: "inherit",
    env
  });
  process.exit(result.status ?? 1);
}

try {
  const [platformArg, ...extraArgs] = process.argv.slice(2);
  runFlutterMobile(normalizePlatform(platformArg), extraArgs);
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
