import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import {
  CLIENT_GATE_LANES,
  CLIENT_RELEASE_TARGETS,
  classifyClientGatePaths,
} from "../../../tools/scripts/client-gate-policy.mjs";
import { validateClientGateTopology } from "../../../tools/scripts/client-gate.mjs";
import {
  DocsFastPromotionError,
  assertReadmeLanguageRoles,
  classifyDocsFastEntries,
  scanRegularWorktreeFile,
  validateDocsFastManifest,
  verifyDocsFastCandidate,
} from "../../../tools/scripts/docs-fast-promotion.mjs";
import {
  mergeIncomingTarget,
  publishTargets,
} from "../../../tools/scripts/client-github-release-publish.mjs";

function selectedOptionalLanes(paths) {
  const plan = classifyClientGatePaths(paths);
  return Object.entries(plan.lanes)
    .filter(([lane, selected]) => lane !== "source" && selected)
    .map(([lane]) => lane);
}

const docsManifestFiles = Object.freeze([
  "README.md",
  "README.zh-CN.md",
  "docs/assets/brand/readme-banner.svg",
]);

function runGit(root, args) {
  const result = spawnSync("git", args, {
    cwd: root,
    encoding: "utf8",
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

test("documentation manifest is fixed, sorted, normalized, and non-empty", () => {
  assert.deepEqual(
    validateDocsFastManifest({ schemaVersion: 1, files: [...docsManifestFiles] }),
    docsManifestFiles,
  );
  for (const document of [
    { schemaVersion: 1, files: [] },
    { schemaVersion: 1, files: ["README.md", "README.md"] },
    { schemaVersion: 1, files: ["docs/a", "README.md"] },
    { schemaVersion: 1, files: ["../outside"] },
    { schemaVersion: 1, files: ["tools/scripts/config/docs-fast-promotion-manifest.json"] },
    { schemaVersion: 1, files: ["README.md"], override: true },
  ]) {
    assert.throws(() => validateDocsFastManifest(document), DocsFastPromotionError);
  }
});

test("documentation classifier selects only added or modified manifest paths", () => {
  assert.deepEqual(
    classifyDocsFastEntries(docsManifestFiles.map((file) => ({ status: "M", path: file })),
      docsManifestFiles),
    { eligible: true, changedCount: 3 },
  );
  assert.equal(classifyDocsFastEntries([], docsManifestFiles).eligible, false);
  assert.equal(classifyDocsFastEntries([
    { status: "M", path: "README.md" },
    { status: "M", path: "lib/code.dart" },
  ], docsManifestFiles).eligible, false);
  assert.equal(classifyDocsFastEntries([
    { status: "D", path: "README.md" },
  ], docsManifestFiles).eligible, false);
  assert.equal(classifyDocsFastEntries([
    { status: "D", path: "README.md" },
    { status: "A", path: "README-renamed.md" },
  ], docsManifestFiles).eligible, false);
  assert.throws(() => classifyDocsFastEntries([
    { status: "M", path: "../outside" },
  ], docsManifestFiles), DocsFastPromotionError);
});

test("documentation scanner rejects unsafe file types and chunk-split private material", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "lico-docs-fast-scan-"));
  try {
    writeFileSync(path.join(root, "regular.md"), "public documentation\n");
    await scanRegularWorktreeFile(root, "regular.md");
    symlinkSync("regular.md", path.join(root, "linked.md"));
    await assert.rejects(() => scanRegularWorktreeFile(root, "linked.md"), DocsFastPromotionError);
    await assert.rejects(() => scanRegularWorktreeFile(root, "missing.md"), DocsFastPromotionError);
    writeFileSync(path.join(root, "secret.pem"), "not even key material\n");
    await assert.rejects(() => scanRegularWorktreeFile(root, "secret.pem"), DocsFastPromotionError);
    const begin = "---" + "--BEGIN PRIVATE KEY---" + "--";
    const end = "---" + "--END PRIVATE KEY---" + "--";
    writeFileSync(
      path.join(root, "split.md"),
      `${"x".repeat(65_530)}${begin}\n${"A".repeat(64)}\n${end}\n`,
    );
    await assert.rejects(() => scanRegularWorktreeFile(root, "split.md"), DocsFastPromotionError);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("documentation verifier accepts one exact safe three-file commit", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "lico-docs-fast-git-"));
  try {
    mkdirSync(path.join(root, "tools/scripts/config"), { recursive: true });
    mkdirSync(path.join(root, "docs/assets/brand"), { recursive: true });
    writeFileSync(path.join(root, "tools/scripts/config/docs-fast-promotion-manifest.json"),
      `${JSON.stringify({ schemaVersion: 1, files: docsManifestFiles }, null, 2)}\n`);
    writeFileSync(path.join(root, "README.md"),
      "English (normative language) · [简体中文 (localized language)](README.zh-CN.md)\nold English\n");
    writeFileSync(path.join(root, "README.zh-CN.md"),
      "[English（规范语言）](README.md) · 简体中文（本地化语言）\n旧中文\n");
    writeFileSync(path.join(root, "docs/assets/brand/readme-banner.svg"), "<svg/>\n");
    runGit(root, ["init", "-b", "nightly"]);
    runGit(root, ["config", "user.name", "fixture"]);
    runGit(root, ["config", "user.email", "fixture@example.invalid"]);
    runGit(root, ["add", "."]);
    runGit(root, ["commit", "-m", "base"]);
    const base = runGit(root, ["rev-parse", "HEAD"]);
    writeFileSync(path.join(root, "README.md"),
      "English (normative language) · [简体中文 (localized language)](README.zh-CN.md)\nnew English\n");
    writeFileSync(path.join(root, "README.zh-CN.md"),
      "[English（规范语言）](README.md) · 简体中文（本地化语言）\n新中文\n");
    writeFileSync(path.join(root, "docs/assets/brand/readme-banner.svg"), "<svg>new</svg>\n");
    runGit(root, ["add", "."]);
    runGit(root, ["commit", "-m", "docs"]);
    const receipt = await verifyDocsFastCandidate({ base, head: "HEAD", root });
    assert.deepEqual(receipt, {
      ok: true,
      eligible: true,
      changedCount: 3,
      manifestCount: 3,
      sensitive: false,
      privateDataIncluded: false,
    });
    assert.deepEqual(assertReadmeLanguageRoles({ head: "HEAD", root }), {
      languageRoles: true,
    });
    writeFileSync(path.join(root, "README.md"), "new English without role\n");
    runGit(root, ["add", "README.md"]);
    runGit(root, ["commit", "-m", "remove role"]);
    assert.throws(() => assertReadmeLanguageRoles({ head: "HEAD", root }),
      DocsFastPromotionError);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("source policy is mandatory without selecting platform toolchains", () => {
  assert.deepEqual(classifyClientGatePaths([]).lanes, {
    source: true,
    flutter: false,
    rust: false,
    android: false,
    dependencies: false,
  });
  assert.deepEqual(selectedOptionalLanes(["docs/RUNBOOK.md"]), []);
  for (const forbidden of [
    "client:get",
    "client:native:fmt:check",
    "client:test:android:native",
    "client:deps:audit",
    "client:verify:release-artifact-io:self-test",
  ]) {
    assert.equal(CLIENT_GATE_LANES.source.includes(forbidden), false);
  }
});

test("changed paths select only their independent technology lanes", () => {
  assert.deepEqual(
    selectedOptionalLanes(["apps/desktop/lib/client_controller.dart"]),
    ["flutter"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["crates/licoup-native/src/lib.rs"]),
    ["rust"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["apps/desktop/android/app/build.gradle.kts"]),
    ["android"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["Cargo.lock"]),
    ["rust", "dependencies"],
  );
  assert.deepEqual(
    selectedOptionalLanes([".github/workflows/client-release.yml"]),
    [],
  );
  assert.deepEqual(
    selectedOptionalLanes(["tools/scripts/client-device-demo.mjs"]),
    [],
  );
  assert.deepEqual(
    selectedOptionalLanes(["package.json"]),
    ["dependencies"],
  );
  assert.deepEqual(
    selectedOptionalLanes(["tools/scripts/client-gate-policy.mjs"]),
    [],
  );
});

test("gate policy rejects paths that escape the repository", () => {
  assert.throws(
    () => classifyClientGatePaths(["../outside"]),
    /stay inside the repository/u,
  );
  assert.throws(
    () => classifyClientGatePaths(["/absolute"]),
    /stay inside the repository/u,
  );
});

test("CI and release workflows implement the declared topology", () => {
  const result = validateClientGateTopology();
  assert.equal(result.ok, true);
  assert.equal(result.laneCount, Object.keys(CLIENT_GATE_LANES).length);
  assert.equal(result.releaseTargetCount, Object.keys(CLIENT_RELEASE_TARGETS).length);
});

test("ordinary regression lanes never run real-device demonstrations", () => {
  for (const scripts of Object.values(CLIENT_GATE_LANES)) {
    assert.equal(
      scripts.some((script) =>
        script.startsWith("client:demo:device:") &&
        script !== "client:demo:device:self-test"),
      false,
    );
  }
  assert.equal(
    CLIENT_GATE_LANES["release-policy"].filter((script) =>
      script === "client:demo:device:self-test").length,
    1,
  );
});

test("publisher fails closed before external mutation on an invalid request", () => {
  assert.throws(
    () => publishTargets({
      targets: "unsupported-target",
      tag: "v1",
      publish: "false",
    }),
    /unknown package targets/u,
  );
  assert.throws(
    () => publishTargets({
      targets: "android-direct-arm64-v8a",
      tag: "invalid tag",
      publish: "false",
    }),
    /invalid release tag/u,
  );
});

test("publisher merges one or many exact targets and permits only identical recovery", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "lico-publisher-contract-"));
  const incoming = path.join(root, "incoming");
  const androidIncoming = path.join(root, "android-incoming");
  const assets = path.join(root, "assets");
  try {
    mkdirSync(incoming);
    mkdirSync(androidIncoming);
    mkdirSync(assets);
    for (const file of CLIENT_RELEASE_TARGETS["macos-direct-arm64"].files) {
      writeFileSync(path.join(incoming, file), `fixture:${file}`);
    }
    const first = mergeIncomingTarget({
      target: "macos-direct-arm64",
      incomingRoot: incoming,
      assetsRoot: assets,
    });
    assert.equal(
      first.upload.length,
      CLIENT_RELEASE_TARGETS["macos-direct-arm64"].files.length,
    );
    const recovery = mergeIncomingTarget({
      target: "macos-direct-arm64",
      incomingRoot: incoming,
      assetsRoot: assets,
    });
    assert.equal(recovery.upload.length, 0);
    for (const file of CLIENT_RELEASE_TARGETS["android-direct-arm64-v8a"].files) {
      writeFileSync(path.join(androidIncoming, file), `fixture:${file}`);
    }
    const secondTarget = mergeIncomingTarget({
      target: "android-direct-arm64-v8a",
      incomingRoot: androidIncoming,
      assetsRoot: assets,
    });
    assert.equal(
      secondTarget.upload.length,
      CLIENT_RELEASE_TARGETS["android-direct-arm64-v8a"].files.length,
    );
    writeFileSync(path.join(incoming, "LicoUp-macos-arm64.dmg"), "conflict");
    assert.throws(
      () => mergeIncomingTarget({
        target: "macos-direct-arm64",
        incomingRoot: incoming,
        assetsRoot: assets,
      }),
      /conflicts with an existing/u,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("change planner emits only bounded booleans, counts, and a digest", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "lico-gate-plan-"));
  try {
    const output = path.join(root, "github-output");
    writeFileSync(output, "", { mode: 0o600 });
    const result = spawnSync(process.execPath, [
      "tools/scripts/client-gate.mjs",
      "plan",
      "--base",
      "HEAD",
      "--head",
      "HEAD",
    ], {
      cwd: process.cwd(),
      env: { ...process.env, GITHUB_OUTPUT: output },
      encoding: "utf8",
      shell: false,
    });
    assert.equal(result.status, 0);
    const entries = readFileSync(output, "utf8").trim().split("\n");
    assert.deepEqual(entries.map((entry) => entry.split("=")[0]), [
      "source",
      "flutter",
      "rust",
      "android",
      "dependencies",
      "changed_count",
      "change_digest",
    ]);
    assert.equal(entries.some((entry) => entry.includes("/")), false);
    assert.match(entries.at(-1), /^change_digest=[a-f0-9]{64}$/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
