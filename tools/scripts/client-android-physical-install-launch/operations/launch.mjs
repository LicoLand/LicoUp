import {
  androidReleaseAcceptanceAuthorizationBroadcastArgs,
  androidReleaseAcceptanceBroadcastAccepted,
} from "../../lib/android-release-acceptance-binding.mjs";
import { runAdb } from "../device/adb.mjs";

export function normalizeLaunchComponent(component) {
  if (!component || !component.includes("/")) return "";
  const [componentPackage, activity] = component.split("/", 2);
  return `${componentPackage}/${activity.startsWith(".") ? `${componentPackage}${activity}` : activity}`;
}

export function resolveLaunchComponent(adb, serial, packageName) {
  const result = runAdb(adb, serial, [
    "shell",
    "cmd",
    "package",
    "resolve-activity",
    "--brief",
    packageName
  ]);
  if (!result.ok) return "";
  const component = String(result.stdout || "")
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .find((line) => line.startsWith(`${packageName}/`)) || "";
  return normalizeLaunchComponent(component);
}

export function parseAmStartResult(output, expectedComponent) {
  const source = String(output || "");
  const statusReady = /(?:^|\n)Status:\s*ok(?:\r?\n|$)/iu.test(source);
  const activity = source.match(/(?:^|\n)Activity:\s*([^\s]+)/iu)?.[1] || "";
  const activityReady = normalizeLaunchComponent(activity) === expectedComponent;
  return { ready: statusReady && activityReady };
}

export function launchApp(
  adb,
  serial,
  packageName,
  launchComponent,
  closureChallenge,
  invocationNonce,
  timeoutMs
) {
  runAdb(adb, serial, ["shell", "am", "force-stop", packageName], { timeoutMs: 5_000 });
  const staged = runAdb(adb, serial, [
    ...androidReleaseAcceptanceAuthorizationBroadcastArgs({
      closureChallenge,
      invocationNonce,
    }),
  ], { timeoutMs: 5_000 });
  if (!staged.ok || !androidReleaseAcceptanceBroadcastAccepted(staged.stdout)) {
    return { attempted: true, launchedViaVerifier: false, ok: false };
  }
  const result = runAdb(adb, serial, [
    "shell",
    "am",
    "start",
    "-S",
    "-W",
    "-n",
    launchComponent,
  ], { timeoutMs });
  const parsed = parseAmStartResult(result.stdout, launchComponent);
  return {
    attempted: true,
    launchedViaVerifier: result.ok && parsed.ready,
    ok: result.ok && parsed.ready
  };
}
