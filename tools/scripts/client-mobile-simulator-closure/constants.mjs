import path from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

export const flutterRoot = path.join(repoRoot, "apps", "desktop");

export const buildRoot = path.join(repoRoot, "build");

export const reportRefs = Object.freeze({
  android: "reports/android-simulator-build-closure.json",
  ios: "reports/ios-simulator-build-closure.json",
});

export const androidSimulatorArtifactRef =
  "apps/desktop/android/simulator/app-debug.apk";

export const sentinel = "LICO_MOBILE_SIMULATOR_CLOSURE_SUMMARY ";

export const packageName = "land.lico.licoup";

export const iosBundleIdentifier = "land.lico.licoup";

export const iosCoreSimulatorMachOModeNormalizationPaths = Object.freeze(new Set([
  "Frameworks/App.framework/App",
  "Frameworks/Flutter.framework/Flutter",
  "Frameworks/objective_c.framework/objective_c",
  "Runner.debug.dylib",
  "__preview.dylib",
]));

export const maxFlutterOutputBytes = 64 * 1024 * 1024;

export const iosBiometricEnrollmentNotification = "com.apple.BiometricKit.enrollmentChanged";

export const iosBiometricMatchNotifications = [
  "com.apple.BiometricKit_Sim.pearl.match",
  "com.apple.BiometricKit_Sim.fingerTouch.match",
  "com.apple.BiometricKit_Sim.oyster.match",
];
