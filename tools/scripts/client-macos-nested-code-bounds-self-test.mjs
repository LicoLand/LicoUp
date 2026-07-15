#!/usr/bin/env node

import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  CLIENT_RELEASE_ARTIFACT_TREE_LIMITS,
} from "./lib/client-release-artifact-digest.mjs";
import { inspectBoundedMacosCodePolicy } from "./lib/macos-code-signature.mjs";

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

function expectPreflightRejected(appPath, options, code) {
  let inspectCalls = 0;
  let rejected = false;
  try {
    inspectBoundedMacosCodePolicy(appPath, "main", "", {
      ...options,
      inspectSignature: () => {
        inspectCalls += 1;
        return readySignature();
      },
    });
  } catch {
    rejected = true;
  }
  requireValue(rejected && inspectCalls === 0, code);
}

function readySignature() {
  return {
    verified: true,
    signatureKind: "local-identity-codesign",
    hardenedRuntime: true,
    entitlementsMatch: true,
    entitlementsEmpty: true,
    entitlementsDigest: `sha256:${"a".repeat(64)}`,
  };
}

const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "lico-macos-code-bounds-"));
try {
  const appPath = path.join(temporaryRoot, "Fixture.app");
  const macosPath = path.join(appPath, "Contents", "MacOS");
  const frameworkPath = path.join(
    appPath,
    "Contents",
    "Frameworks",
    "Fixture.framework",
    "Versions",
    "A",
  );
  mkdirSync(macosPath, { recursive: true, mode: 0o700 });
  mkdirSync(frameworkPath, { recursive: true, mode: 0o700 });
  const mainPath = path.join(macosPath, "main");
  const nestedPath = path.join(frameworkPath, "Fixture");
  writeFileSync(mainPath, "main", { mode: 0o700 });
  writeFileSync(nestedPath, "nested", { mode: 0o700 });
  chmodSync(mainPath, 0o700);
  chmodSync(nestedPath, 0o700);

  let positiveCalls = 0;
  const positive = inspectBoundedMacosCodePolicy(appPath, "main", "", {
    inspectSignature: () => {
      positiveCalls += 1;
      return readySignature();
    },
  });
  requireValue(positive.nestedCodePaths.length > 0 &&
    positiveCalls === positive.nestedCodePaths.length + 1,
  "bounded_macos_code_inventory_positive_failed");

  expectPreflightRejected(appPath, {
    limits: {
      ...CLIENT_RELEASE_ARTIFACT_TREE_LIMITS,
      maxEntries: 2,
      maxFiles: 1,
      maxDirectories: 1,
    },
  }, "entry_bound_ran_codesign_before_rejection");
  expectPreflightRejected(appPath, {
    limits: {
      ...CLIENT_RELEASE_ARTIFACT_TREE_LIMITS,
      maxDepth: 1,
    },
  }, "depth_bound_ran_codesign_before_rejection");
  expectPreflightRejected(appPath, {
    limits: {
      ...CLIENT_RELEASE_ARTIFACT_TREE_LIMITS,
      maxFileBytes: 2,
      maxTotalFileBytes: 16,
    },
  }, "size_bound_ran_codesign_before_rejection");
  expectPreflightRejected(appPath, {
    deadlineMs: Date.now() - 1,
  }, "expired_deadline_ran_codesign_before_rejection");
  expectPreflightRejected(appPath, {
    maxNestedCodePaths: 1,
  }, "nested_code_count_bound_ran_codesign_before_rejection");

  let cumulativeCalls = 0;
  let cumulativeRejected = false;
  try {
    inspectBoundedMacosCodePolicy(appPath, "main", "", {
      deadlineMs: Date.now() + 100,
      inspectSignature: () => {
        cumulativeCalls += 1;
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 150);
        return readySignature();
      },
    });
  } catch {
    cumulativeRejected = true;
  }
  requireValue(cumulativeRejected && cumulativeCalls === 1,
    "macos_codesign_deadline_was_not_cumulative");

  console.log(JSON.stringify({
    ok: true,
    caseCount: 7,
    realCodesignExecuted: false,
    privatePathsIncluded: false,
  }));
} finally {
  rmSync(temporaryRoot, { recursive: true, force: true });
}
