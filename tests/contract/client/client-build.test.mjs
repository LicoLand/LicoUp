import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  acquireTestArtifactLease,
  FLUTTER_TEST_TARGET,
} from "../../../tools/scripts/lib/test-artifact-lifecycle.mjs";
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
      "windows",
      "--mode",
      "debug",
      "--dart-define=FIXTURE=true",
    ]),
    {
      mode: "debug",
      passthrough: ["--dart-define=FIXTURE=true"],
      platform: "windows",
    },
  );
  assert.throws(() => parseClientBuildArgs([]), /client_build_platform_invalid/u);
  assert.throws(
    () => parseClientBuildArgs(["--platform", "macos", "--platform", "linux"]),
    /client_build_platform_invalid/u,
  );
});

test("desktop builds route through their existing package owner", () => {
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
      parseClientBuildArgs(["--platform", "windows", "--mode", "debug"]),
    ).args,
    [
      path.join("apps", "desktop", "scripts", "package-client.mjs"),
      "--platform",
      "windows",
      "--mode",
      "debug",
    ],
  );
  assert.throws(
    () => parseClientBuildArgs(["--platform", "android"]),
    /client_build_platform_invalid/u,
  );
  assert.throws(
    () => parseClientBuildArgs(["--platform", "ios"]),
    /client_build_platform_invalid/u,
  );
});

test("builds retain the registered build cache across success and failure", (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), "licoup-client-build-cache-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const lease = acquireTestArtifactLease({
    repoRoot: root,
    scope: "client-build-contract",
    targetPath: FLUTTER_TEST_TARGET,
  });
  const cacheMarker = path.join(lease.targetPath, "test", "cache-marker");
  mkdirSync(path.dirname(cacheMarker), { recursive: true });
  writeFileSync(cacheMarker, "reusable compiler output");
  assert.deepEqual(lease.release(), { state: "reclaimable" });

  for (const status of [0, 0, 1]) {
    const result = runClientBuild(
      parseClientBuildArgs(["--platform", "macos"]),
      {
        root,
        spawnBuild: () => ({ status }),
      },
    );
    assert.deepEqual(result, {
      ok: status === 0,
      platform: "macos",
      mode: "release",
      buildSucceeded: status === 0,
      privatePathsIncluded: false,
    });
    assert.equal(existsSync(cacheMarker), true);
  }
});
