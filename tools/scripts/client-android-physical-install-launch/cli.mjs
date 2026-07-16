import process from "node:process";
import { defaultPackageName } from "./constants.mjs";

export function positiveInt(value, fallback) {
  const parsed = Number.parseInt(String(value || ""), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

export function parseArgs(argv) {
  const options = {
    apk: "",
    packageName: process.env.LICO_ANDROID_PACKAGE_ID || defaultPackageName,
    serial: process.env.ANDROID_SERIAL ||
      process.env.LICO_CLIENT_ANDROID_DEVICE ||
      process.env.LICO_CLIENT_MOBILE_DEVICE ||
      "",
    install: false,
    launch: false,
    installTimeoutMs: positiveInt(process.env.LICO_ANDROID_ADB_INSTALL_TIMEOUT_MS, 360_000),
    launchTimeoutMs: positiveInt(process.env.LICO_ANDROID_LAUNCH_TIMEOUT_MS, 30_000),
    runtimeTimeoutMs: positiveInt(process.env.LICO_ANDROID_RUNTIME_STATUS_TIMEOUT_MS, 45_000)
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--apk" && next) {
      options.apk = next;
      index += 1;
    } else if (arg.startsWith("--apk=")) {
      options.apk = arg.slice("--apk=".length);
    } else if (arg === "--package" && next) {
      options.packageName = next;
      index += 1;
    } else if (arg.startsWith("--package=")) {
      options.packageName = arg.slice("--package=".length);
    } else if (arg === "--serial" && next) {
      options.serial = next;
      index += 1;
    } else if (arg.startsWith("--serial=")) {
      options.serial = arg.slice("--serial=".length);
    } else if (arg === "--install") {
      options.install = true;
    } else if (arg === "--launch") {
      options.launch = true;
    } else if (arg === "--install-timeout-ms" && next) {
      options.installTimeoutMs = positiveInt(next, options.installTimeoutMs);
      index += 1;
    } else if (arg.startsWith("--install-timeout-ms=")) {
      options.installTimeoutMs = positiveInt(
        arg.slice("--install-timeout-ms=".length),
        options.installTimeoutMs
      );
    } else if (arg === "--launch-timeout-ms" && next) {
      options.launchTimeoutMs = positiveInt(next, options.launchTimeoutMs);
      index += 1;
    } else if (arg.startsWith("--launch-timeout-ms=")) {
      options.launchTimeoutMs = positiveInt(
        arg.slice("--launch-timeout-ms=".length),
        options.launchTimeoutMs
      );
    } else if (arg === "--runtime-timeout-ms" && next) {
      options.runtimeTimeoutMs = positiveInt(next, options.runtimeTimeoutMs);
      index += 1;
    } else if (arg.startsWith("--runtime-timeout-ms=")) {
      options.runtimeTimeoutMs = positiveInt(
        arg.slice("--runtime-timeout-ms=".length),
        options.runtimeTimeoutMs
      );
    } else {
      throw new Error(`Unknown Android physical install/launch option: ${arg}`);
    }
  }
  return options;
}
