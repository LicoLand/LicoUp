import { spawn } from "node:child_process";
import { withClientToolchainEnv } from "../client-toolchain-env.mjs";
import { flutterRoot, maxFlutterOutputBytes, sentinel } from "./constants.mjs";
import { ClosureError, requireValue } from "./errors.mjs";
import { command, commandReady } from "./process.mjs";

export function prepareFlutterDependencies() {
  const result = command("flutter", ["pub", "get", "--enforce-lockfile", "--offline"], {
    cwd: flutterRoot,
    env: withClientToolchainEnv(),
    timeoutMs: 120_000,
  });
  requireValue(commandReady(result), "flutter_dependencies_unavailable");
}

export function runFlutterIntegration(platform, device, authenticator) {
  return new Promise((resolve, reject) => {
    const child = spawn("flutter", [
      "test",
      "integration_test/mobile_simulator_closure_test.dart",
      "-d",
      device,
      "--no-pub",
      "--no-uninstall",
    ], {
      cwd: flutterRoot,
      env: withClientToolchainEnv(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    let outputExceeded = false;
    const collect = (chunk) => {
      if (outputExceeded) return;
      output += chunk.toString();
      if (Buffer.byteLength(output, "utf8") > maxFlutterOutputBytes) {
        outputExceeded = true;
        output = "";
        child.kill("SIGKILL");
      }
    };
    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    const tick = setInterval(() => authenticator.tick(), 800);
    const timeout = setTimeout(() => child.kill("SIGKILL"), 10 * 60 * 1000);
    child.on("error", () => {
      clearInterval(tick);
      clearTimeout(timeout);
      reject(new ClosureError(`${platform}_flutter_integration_start_failed`));
    });
    child.on("close", (code) => {
      clearInterval(tick);
      clearTimeout(timeout);
      if (outputExceeded) {
        reject(new ClosureError(`${platform}_flutter_output_limit_exceeded`));
        return;
      }
      if (code !== 0) {
        reject(new ClosureError(`${platform}_simulator_integration_failed`));
        return;
      }
      if (authenticator.healthy() !== true) {
        reject(new ClosureError(`${platform}_simulated_auth_automation_failed`));
        return;
      }
      try {
        resolve(parseIntegrationSummary(output, platform));
      } catch (error) {
        reject(error);
      }
    });
  });
}

export function parseIntegrationSummary(output, expectedPlatform) {
  const encoded = String(output || "").match(
    new RegExp(`${sentinel}([A-Za-z0-9_-]+)`, "u"),
  )?.[1];
  requireValue(Boolean(encoded), `${expectedPlatform}_simulator_summary_missing`);
  let summary;
  try {
    summary = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  } catch {
    throw new ClosureError(`${expectedPlatform}_simulator_summary_invalid`);
  }
  const keys = [
    "ok",
    "platform",
    "bridgeReady",
    "nativeFfiReady",
    "runtimeStatusWritten",
    "simulatedAuthorizationReady",
    "simulatorOnlyAuthorization",
    "physicalDeviceClaimed",
    "hardwareBackedCustodyClaimed",
    "realBiometricClaimed",
    "productionReleaseClaimed",
    "rawDeviceIdentifierIncluded",
    "rawPrivateMaterialIncluded",
  ];
  requireValue(summary && typeof summary === "object" && !Array.isArray(summary) &&
    JSON.stringify(Object.keys(summary).sort()) === JSON.stringify([...keys].sort()),
  `${expectedPlatform}_simulator_summary_shape_invalid`);
  requireValue(summary.platform === expectedPlatform && summary.ok === true &&
    summary.bridgeReady === true && summary.nativeFfiReady === true &&
    summary.runtimeStatusWritten === true && summary.simulatedAuthorizationReady === true &&
    summary.simulatorOnlyAuthorization === true &&
    [
      summary.physicalDeviceClaimed,
      summary.hardwareBackedCustodyClaimed,
      summary.realBiometricClaimed,
      summary.productionReleaseClaimed,
      summary.rawDeviceIdentifierIncluded,
      summary.rawPrivateMaterialIncluded,
    ].every((value) => value === false),
  `${expectedPlatform}_simulator_summary_not_ready`);
  return summary;
}
