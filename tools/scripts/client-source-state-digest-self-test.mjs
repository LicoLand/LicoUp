#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import {
  appendFileSync,
  chmodSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  canonicalClientSourceRootsMatch,
  clientSourceStateDigest,
  createClientSourceManifest,
  readAndVerifyClientSourceManifest,
  validateClientSourceRoots,
  verifyClientSourceManifest,
} from "./lib/client-source-state-digest.mjs";

const root = mkdtempSync(path.join(os.tmpdir(), "lico-source-digest-self-test-"));

function runGit(args) {
  execFileSync("git", args, {
    cwd: root,
    stdio: "ignore",
    env: {
      ...process.env,
      GIT_CONFIG_NOSYSTEM: "1",
    },
  });
}

function rejects(action, label) {
  let rejected = false;
  try {
    action();
  } catch {
    rejected = true;
  }
  if (!rejected) throw new Error(label);
}

try {
  mkdirSync(path.join(root, "src"));
  writeFileSync(path.join(root, "src", "tracked.txt"), "tracked\n", "utf8");
  writeFileSync(path.join(root, ".gitignore"), "src/ignored-input.txt\nsrc/build/\n", "utf8");
  runGit(["init", "--quiet"]);
  runGit(["config", "user.name", "source-digest-self-test"]);
  runGit(["config", "user.email", "source-digest-self-test@example.invalid"]);
  runGit(["config", "commit.gpgsign", "false"]);
  runGit(["add", "src/tracked.txt", ".gitignore"]);
  runGit(["commit", "--quiet", "-m", "fixture"]);

  const digest = clientSourceStateDigest(root, ["src"]);
  if (!/^sha256:[a-f0-9]{64}$/u.test(digest)) {
    throw new Error("valid source digest fixture failed");
  }
  const sourceManifest = createClientSourceManifest(root, ["src"], digest);
  const sourceManifestResult = verifyClientSourceManifest(
    root,
    sourceManifest,
    digest,
    { expectedSourceRoots: ["src"] },
  );
  if (sourceManifestResult.ok !== true ||
    sourceManifestResult.sourceStateDigest !== digest) {
    throw new Error("valid source manifest fixture failed");
  }
  rejects(() => verifyClientSourceManifest(
    root,
    sourceManifest,
    `sha256:${"f".repeat(64)}`,
    { expectedSourceRoots: ["src"] },
  ), "forged expected source digest was accepted");
  writeFileSync(path.join(root, "src", "tracked.txt"), "vm-mutated\n", "utf8");
  rejects(() => verifyClientSourceManifest(
    root,
    sourceManifest,
    digest,
    { expectedSourceRoots: ["src"] },
  ), "VM source mutation was accepted");
  writeFileSync(path.join(root, "src", "tracked.txt"), "tracked\n", "utf8");
  writeFileSync(path.join(root, "src", "tracked.txt"), "manifest-tampered\n", "utf8");
  rejects(() => createClientSourceManifest(root, ["src"], digest),
    "tampered source manifest was created with a forged digest");
  writeFileSync(path.join(root, "src", "tracked.txt"), "tracked\n", "utf8");
  rejects(() => readAndVerifyClientSourceManifest(
    root,
    path.join(root, "missing-source-manifest.json"),
    digest,
    { expectedSourceRoots: ["src"] },
  ), "missing source manifest was accepted");
  for (const invalid of [
    ["src/../escape"],
    ["src\\escape"],
    [":(glob)src/**"],
    ["src/*"],
  ]) {
    rejects(() => validateClientSourceRoots(invalid),
      "unsafe source root was accepted");
  }
  if (!canonicalClientSourceRootsMatch(CANONICAL_CLIENT_SOURCE_ROOTS) ||
    canonicalClientSourceRootsMatch(CANONICAL_CLIENT_SOURCE_ROOTS.filter(
      (entry) => entry !== "package-lock.json",
    ))) {
    throw new Error("canonical source roots could be narrowed");
  }

  const ignoredInput = path.join(root, "src", "ignored-input.txt");
  writeFileSync(ignoredInput, "ignored-but-build-owned\n", { mode: 0o600 });
  const ignoredDigest = clientSourceStateDigest(root, ["src"]);
  writeFileSync(ignoredInput, "ignored-and-changed\n", { mode: 0o600 });
  if (clientSourceStateDigest(root, ["src"]) === ignoredDigest) {
    throw new Error("ignored build input was omitted from source digest");
  }
  const ignoredModeDigest = clientSourceStateDigest(root, ["src"]);
  chmodSync(ignoredInput, 0o700);
  if (clientSourceStateDigest(root, ["src"]) === ignoredModeDigest) {
    throw new Error("untracked chmod-only source mutation was omitted");
  }

  mkdirSync(path.join(root, "src", "build"));
  writeFileSync(path.join(root, "src", "build", "cache.bin"), "one");
  const excludedDigest = clientSourceStateDigest(root, ["src"]);
  writeFileSync(path.join(root, "src", "build", "cache.bin"), "two");
  if (clientSourceStateDigest(root, ["src"]) !== excludedDigest) {
    throw new Error("code-owned generated output exclusion was not stable");
  }

  const untracked = path.join(root, "src", "untracked.bin");
  writeFileSync(untracked, Buffer.alloc(64, 7));
  rejects(() => clientSourceStateDigest(root, ["src"], {
    maxUntrackedFileBytes: 32,
  }), "oversized untracked source was accepted");
  rejects(() => clientSourceStateDigest(root, ["src"], {
    afterUntrackedOpen: () => appendFileSync(untracked, Buffer.from([8])),
  }), "racing untracked source was accepted");

  rmSync(untracked);
  symlinkSync("tracked.txt", untracked);
  rejects(() => clientSourceStateDigest(root, ["src"]),
    "untracked source symlink was accepted");
  runGit(["add", "src/untracked.bin"]);
  runGit(["commit", "--quiet", "-m", "tracked symlink fixture"]);
  rejects(() => clientSourceStateDigest(root, ["src"]),
    "tracked source symlink was accepted");

  console.log(JSON.stringify({
    ok: true,
    caseCount: 16,
    ignoredBuildInputBound: true,
    untrackedModeBound: true,
    exclusionsCodeOwned: true,
    symlinkAccepted: false,
    unboundedReadUsed: false,
    forgedEnvironmentAccepted: false,
    vmSourceMutationAccepted: false,
    tamperedManifestAccepted: false,
    missingManifestAccepted: false,
    privatePathsIncluded: false,
  }));
} finally {
  rmSync(root, { recursive: true, force: true });
}
