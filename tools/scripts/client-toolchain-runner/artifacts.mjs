import path from "node:path";
import {
  acquireTestArtifactLease,
} from "../lib/test-artifact-lifecycle.mjs";
import { ROOT } from "./constants.mjs";

const FLUTTER_TEST_OUTPUT = "apps/desktop/build";

function workspaceRelative(cwd) {
  return path.relative(ROOT, path.resolve(cwd)).split(path.sep).join("/");
}

function commandName(command) {
  return path.basename(command).toLowerCase();
}

function isFlutterTest(command, args, cwd) {
  return ["flutter", "flutter.bat", "flutter.cmd", "flutter.exe"]
    .includes(commandName(command)) &&
    workspaceRelative(cwd) === "apps/desktop" &&
    args[0] === "test";
}

export function toolchainTestArtifactTargets({ command, args, cwd }) {
  if (isFlutterTest(command, args, cwd)) return Object.freeze([FLUTTER_TEST_OUTPUT]);
  return Object.freeze([]);
}

export async function withToolchainTestArtifactLeases({
  command,
  args,
  cwd,
  leaseFactory = acquireTestArtifactLease,
}, action) {
  const leases = toolchainTestArtifactTargets({ command, args, cwd })
    .map((targetPath) => leaseFactory({
      repoRoot: ROOT,
      scope: "client-toolchain-test",
      targetPath,
    }));
  try {
    return await action();
  } finally {
    for (const lease of leases.reverse()) lease.release();
  }
}
