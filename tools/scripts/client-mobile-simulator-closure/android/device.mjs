import { randomInt } from "node:crypto";
import process from "node:process";
import { findAndroidAdbTool } from "../../lib/android-apk-facts.mjs";
import { repoRoot } from "../constants.mjs";
import { ClosureError, requireValue } from "../errors.mjs";
import { command, commandReady } from "../process.mjs";

export function parseAdbDevices(output) {
  return String(output || "")
    .split(/\r?\n/u)
    .slice(1)
    .map((line) => line.trim().split(/\s+/u))
    .filter(([serial, state]) => serial && state === "device")
    .map(([serial]) => serial);
}

export function androidSimulatorProof(adb, serial) {
  const readProp = (name) => {
    const result = command(adb, ["-s", serial, "shell", "getprop", name], {
      timeoutMs: 5_000,
    });
    return commandReady(result) ? String(result.stdout || "").trim().toLowerCase() : "";
  };
  const qemu = readProp("ro.kernel.qemu") === "1" || readProp("ro.boot.qemu") === "1";
  const hardware = `${readProp("ro.hardware")} ${readProp("ro.boot.hardware")}`;
  const characteristics = readProp("ro.build.characteristics");
  const architectureReady = readProp("ro.product.cpu.abi") === "arm64-v8a";
  const virtualized = qemu || /(?:goldfish|ranchu|qemu|cuttlefish)/u.test(hardware) ||
    characteristics.includes("emulator");
  return virtualized && architectureReady;
}

export function selectAndroidSimulator() {
  let adb;
  try {
    adb = findAndroidAdbTool(repoRoot, { requireApprovedToolchain: false });
  } catch {
    throw new ClosureError("android_sdk_tools_unavailable");
  }
  const listed = command(adb, ["devices"], { timeoutMs: 10_000 });
  requireValue(commandReady(listed), "android_adb_unavailable");
  const devices = parseAdbDevices(listed.stdout);
  const configured = String(process.env.LICO_CLIENT_ANDROID_EMULATOR || "").trim();
  const candidates = configured
    ? devices.filter((serial) => serial === configured && androidSimulatorProof(adb, serial))
    : devices.filter((serial) => androidSimulatorProof(adb, serial));
  requireValue(candidates.length === 1, candidates.length === 0
    ? "android_emulator_unavailable"
    : "android_emulator_selection_ambiguous");
  return { adb, device: candidates[0] };
}

export function configureAndroidSimulatedCredential(adb, device) {
  const pin = String(randomInt(100000, 999999));
  let inputFailed = false;
  let inputAttempts = 0;
  command(adb, ["-s", device, "shell", "input", "keyevent", "82"], { timeoutMs: 5_000 });
  const configured = command(adb, ["-s", device, "shell", "locksettings", "set-pin", pin], {
    timeoutMs: 10_000,
  });
  if (!commandReady(configured)) {
    const compensated = command(adb, [
      "-s",
      device,
      "shell",
      "locksettings",
      "clear",
      "--old",
      pin,
    ], { timeoutMs: 10_000 });
    requireValue(commandReady(compensated),
      "android_simulated_credential_setup_cleanup_failed");
    throw new ClosureError("android_simulated_credential_setup_failed");
  }
  return {
    tick() {
      if (inputAttempts >= 3) return;
      const windows = command(adb, ["-s", device, "shell", "dumpsys", "window", "windows"], {
        timeoutMs: 5_000,
      });
      if (!commandReady(windows) || !/(?:ConfirmDeviceCredential|ConfirmLockPassword|ConfirmLockPattern|ConfirmLockPatternPassword)/iu.test(
        String(windows.stdout || ""),
      )) return;
      inputAttempts += 1;
      const entered = command(adb, ["-s", device, "shell", "input", "text", pin], {
        timeoutMs: 5_000,
      });
      const submitted = command(adb, ["-s", device, "shell", "input", "keyevent", "66"], {
        timeoutMs: 5_000,
      });
      if (!commandReady(entered) || !commandReady(submitted)) inputFailed = true;
    },
    cleanup() {
      const cleared = command(adb, ["-s", device, "shell", "locksettings", "clear", "--old", pin], {
        timeoutMs: 10_000,
      });
      return commandReady(cleared);
    },
    healthy() {
      return inputFailed === false;
    },
  };
}
