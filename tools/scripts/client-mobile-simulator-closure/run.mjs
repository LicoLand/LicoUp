import process from "node:process";
import { verifyAndroid } from "./android/verify.mjs";
import { parseArgs, selectedPlatforms } from "./cli.mjs";
import { prepareFlutterDependencies } from "./flutter.mjs";
import { verifyIos } from "./ios/verify.mjs";
import { runSelfTest } from "./self-test.mjs";

export async function main() {
  const options = parseArgs();
  if (options.selfTest) {
    console.log(JSON.stringify(runSelfTest()));
    return;
  }
  prepareFlutterDependencies();
  const results = [];
  for (const platform of selectedPlatforms(options.platform)) {
    results.push(platform === "android" ? await verifyAndroid() : await verifyIos());
  }
  console.log(JSON.stringify({
    ok: results.every((result) => result.ok === true),
    results,
    physicalDeviceClaimsReady: false,
    productionReleaseReady: false,
    privatePathsIncluded: false,
    deviceIdentifiersIncluded: false,
  }));
}
