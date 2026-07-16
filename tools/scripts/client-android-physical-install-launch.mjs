#!/usr/bin/env node

import { run } from "./client-android-physical-install-launch/run.mjs";

try {
  await run();
} catch {
  console.error(JSON.stringify({
    ok: false,
    reason: "android_physical_install_launch_failed",
    privatePathsIncluded: false
  }));
  process.exitCode = 1;
}
