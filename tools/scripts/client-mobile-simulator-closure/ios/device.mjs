import process from "node:process";
import { iosBiometricEnrollmentNotification, iosBiometricMatchNotifications } from "../constants.mjs";
import { requireValue } from "../errors.mjs";
import { command, commandReady } from "../process.mjs";

export function parseBootedIosSimulators(output) {
  let payload;
  try {
    payload = JSON.parse(String(output || "{}"));
  } catch {
    return [];
  }
  return Object.values(payload.devices || {})
    .flatMap((devices) => Array.isArray(devices) ? devices : [])
    .filter((device) => device?.state === "Booted" && device?.isAvailable !== false)
    .map((device) => String(device.udid || "").trim())
    .filter(Boolean);
}

export function iosSimulatorArm64Ready(output) {
  return String(output || "")
    .trim()
    .split(/\s+/u)
    .includes("arm64");
}

export function selectIosSimulator() {
  requireValue(process.platform === "darwin", "ios_simulator_requires_macos");
  const listed = command("xcrun", ["simctl", "list", "devices", "booted", "--json"], {
    timeoutMs: 20_000,
  });
  requireValue(commandReady(listed), "ios_simctl_unavailable");
  const booted = parseBootedIosSimulators(listed.stdout);
  const configured = String(process.env.LICO_CLIENT_IOS_SIMULATOR || "").trim();
  const candidates = configured ? booted.filter((device) => device === configured) : booted;
  requireValue(candidates.length === 1, candidates.length === 0
    ? "ios_simulator_unavailable"
    : "ios_simulator_selection_ambiguous");
  const architecture = command("xcrun", [
    "simctl",
    "getenv",
    candidates[0],
    "SIMULATOR_ARCHS",
  ], {
    timeoutMs: 10_000,
  });
  requireValue(commandReady(architecture) &&
    iosSimulatorArm64Ready(architecture.stdout),
  "ios_simulator_architecture_unavailable");
  return { device: candidates[0] };
}

export function notifyCommandReady(result) {
  return commandReady(result) &&
    !/failed with code/iu.test(`${result.stdout || ""}\n${result.stderr || ""}`);
}

export function parseNotifyState(output) {
  const match = String(output || "").trim().match(/(?:^|\s)([01])$/u);
  return match ? Number.parseInt(match[1], 10) : undefined;
}

export function readIosSimulatorBiometricEnrollment() {
  const result = command("/usr/bin/notifyutil", [
    "-z",
    "0",
    "-g",
    iosBiometricEnrollmentNotification,
  ], { timeoutMs: 10_000 });
  return notifyCommandReady(result) ? parseNotifyState(result.stdout) : undefined;
}

export function setIosSimulatorBiometricEnrollment(state) {
  const value = state === 1 ? "1" : "0";
  const updated = command("/usr/bin/notifyutil", [
    "-z",
    "0",
    "-s",
    iosBiometricEnrollmentNotification,
    value,
  ], { timeoutMs: 10_000 });
  const posted = command("/usr/bin/notifyutil", [
    "-z",
    "0",
    "-p",
    iosBiometricEnrollmentNotification,
  ], { timeoutMs: 10_000 });
  return notifyCommandReady(updated) && notifyCommandReady(posted);
}

export function configureIosSimulatedBiometric(device) {
  const enrolled = command("xcrun", ["simctl", "biometric", device, "enroll"], {
    timeoutMs: 10_000,
  });
  if (commandReady(enrolled)) {
    return {
      tick() {
        command("xcrun", ["simctl", "biometric", device, "match", "face"], {
          timeoutMs: 5_000,
        });
        command("xcrun", ["simctl", "biometric", device, "match", "finger"], {
          timeoutMs: 5_000,
        });
      },
      cleanup() {
        const cleared = command("xcrun", ["simctl", "biometric", device, "unenroll"], {
          timeoutMs: 10_000,
        });
        return commandReady(cleared);
      },
      healthy() {
        return true;
      },
    };
  }

  const previousEnrollment = readIosSimulatorBiometricEnrollment() ?? 0;
  requireValue(setIosSimulatorBiometricEnrollment(1),
    "ios_simulated_biometric_setup_failed");
  let matchFailed = false;
  return {
    tick() {
      for (const notification of iosBiometricMatchNotifications) {
        const matched = command("/usr/bin/notifyutil", [
          "-z",
          "0",
          "-p",
          notification,
        ], { timeoutMs: 5_000 });
        if (!notifyCommandReady(matched)) matchFailed = true;
      }
    },
    cleanup() {
      return setIosSimulatorBiometricEnrollment(previousEnrollment);
    },
    healthy() {
      return matchFailed === false;
    },
  };
}
