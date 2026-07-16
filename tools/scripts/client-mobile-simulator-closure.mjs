#!/usr/bin/env node

import { ClosureError } from "./client-mobile-simulator-closure/errors.mjs";
import { main } from "./client-mobile-simulator-closure/run.mjs";

try {
  await main();
} catch (error) {
  const category = error instanceof ClosureError
    ? error.category
    : "mobile_simulator_closure_failed";
  console.error(JSON.stringify({
    ok: false,
    reason: category,
    physicalDeviceClaimsReady: false,
    productionReleaseReady: false,
    privatePathsIncluded: false,
    deviceIdentifiersIncluded: false,
  }));
  process.exitCode = 1;
}
