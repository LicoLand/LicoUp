import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  clientBuildInvocation,
  parseClientBuildArgs,
  runClientBuild,
} from "../../../tools/scripts/client-build.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

test("one package script owns every platform build", () => {
  const scripts = JSON.parse(
    readFileSync(path.join(repoRoot, "package.json"), "utf8"),
  ).scripts;
  assert.equal(
    scripts["client:build"],
    "node tools/scripts/client-build.mjs",
  );
  assert.equal(
    Object.keys(scripts).filter((name) => /^client:build(?::|$)/u.test(name))
      .length,
    1,
  );
});

test("the build entry requires one explicit platform and always defaults to release", () => {
  assert.deepEqual(parseClientBuildArgs(["--platform", "macos"]), {
    mode: "release",
    passthrough: [],
    platform: "macos",
  });
  assert.deepEqual(
    parseClientBuildArgs([
      "--platform",
      "android",
      "--mode",
      "debug",
      "--dart-define=FIXTURE=true",
    ]),
    {
      mode: "debug",
      passthrough: ["--dart-define=FIXTURE=true"],
      platform: "android",
    },
  );
  assert.throws(() => parseClientBuildArgs([]), /client_build_platform_invalid/u);
  assert.throws(
    () => parseClientBuildArgs(["--platform", "macos", "--platform", "linux"]),
    /client_build_platform_invalid/u,
  );
});

test("desktop and Android builds route through their existing package owners", () => {
  assert.deepEqual(
    clientBuildInvocation(parseClientBuildArgs(["--platform", "linux"])).args,
    [
      path.join("apps", "desktop", "scripts", "package-client.mjs"),
      "--platform",
      "linux",
      "--mode",
      "release",
    ],
  );
  assert.deepEqual(
    clientBuildInvocation(
      parseClientBuildArgs(["--platform", "android", "--mode", "debug"]),
    ).args,
    [
      path.join("apps", "desktop", "scripts", "build-android-apk.mjs"),
      "--debug",
    ],
  );
});

test("compiler cache cleanup runs after successful and failed builds", () => {
  for (const status of [0, 1]) {
    const events = [];
    const result = runClientBuild(
      parseClientBuildArgs(["--platform", "macos"]),
      {
        root: repoRoot,
        spawnBuild: () => {
          events.push("build");
          return { status };
        },
        pruneArtifacts: () => {
          events.push("cleanup");
          return { active: 0, failed: 0, removed: 2 };
        },
      },
    );
    assert.deepEqual(events, ["build", "cleanup"]);
    assert.equal(result.buildSucceeded, status === 0);
    assert.equal(result.cleanupSucceeded, true);
    assert.equal(result.ok, status === 0);
    assert.equal(result.removedCompilerCaches, 2);
  }
});

test("a cleanup failure fails an otherwise successful build closure", () => {
  let cleanupAttempts = 0;
  const result = runClientBuild(
    parseClientBuildArgs(["--platform", "windows"]),
    {
      root: repoRoot,
      spawnBuild: () => ({ status: 0 }),
      pruneArtifacts: () => {
        cleanupAttempts += 1;
        return { active: 0, failed: 1, removed: 0 };
      },
    },
  );
  assert.equal(result.buildSucceeded, true);
  assert.equal(result.cleanupSucceeded, false);
  assert.equal(result.ok, false);
  assert.equal(cleanupAttempts, 2);
});

test("one bounded retry closes a transient compiler cleanup failure", () => {
  let cleanupAttempts = 0;
  const result = runClientBuild(
    parseClientBuildArgs(["--platform", "macos"]),
    {
      root: repoRoot,
      spawnBuild: () => ({ status: 0 }),
      pruneArtifacts: () => {
        cleanupAttempts += 1;
        return cleanupAttempts === 1
          ? { active: 0, failed: 1, removed: 2 }
          : { active: 0, failed: 0, removed: 1 };
      },
    },
  );
  assert.equal(result.ok, true);
  assert.equal(result.cleanupSucceeded, true);
  assert.equal(result.removedCompilerCaches, 3);
  assert.equal(cleanupAttempts, 2);
});
