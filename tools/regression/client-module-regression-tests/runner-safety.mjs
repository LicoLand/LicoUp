import {
  assert,
  path,
  spawnSync,
  process,
  test,
  executeClientModules,
  changedPathsSince,
  normalizeRepoPath,
  parseNulDelimitedPaths,
  selectModulesById,
  selectModulesForChangedPaths,
  validateChangedFromRevision,
  main,
  parseClientModuleRegressionArgs,
  repoRoot,
  runnerPath,
  ids,
  stringSink,
} from "./support.mjs";

test("selection normalizes separators, deduplicates paths, and never falls back", () => {
  const windowsRunnerPath = [
    ".",
    "apps",
    "desktop",
    "windows",
    "runner",
    "main.cpp",
  ].join(String.fromCharCode(92));
  assert.equal(normalizeRepoPath(windowsRunnerPath),
    "apps/desktop/windows/runner/main.cpp");
  assert.deepEqual(ids(selectModulesForChangedPaths([
    windowsRunnerPath,
    "apps/desktop/windows/runner/main.cpp",
  ])), ["bridge.windows"]);
  assert.deepEqual(ids(selectModulesForChangedPaths(["README.md"])), [
    "regression.public-client-docs",
  ]);
  assert.throws(() => normalizeRepoPath("../outside"), /inside/u);
});

test("explicit module selection rejects unknown ids and keeps catalog order", () => {
  assert.deepEqual(ids(selectModulesById([
    "release.workflows",
    "flutter.feature.agents",
    "flutter.feature.agents",
  ])), ["flutter.feature.agents", "release.workflows"]);
  assert.throws(() => selectModulesById(["unknown.module"]), /unknown client module/u);
});

test("changed-from collection uses argv-safe git calls and includes untracked paths", () => {
  const calls = [];
  const spawnSyncImpl = (program, args, options) => {
    calls.push({ program, args, options });
    return calls.length === 1
      ? { status: 0, stdout: Buffer.from("apps/desktop/lib/app.dart\0README.md\0") }
      : { status: 0, stdout: Buffer.from("tools/regression/new-file.mjs\0README.md\0") };
  };
  const paths = changedPathsSince({ revision: "HEAD~1", repoRoot, spawnSyncImpl });
  assert.deepEqual(paths, [
    "apps/desktop/lib/app.dart",
    "README.md",
    "tools/regression/new-file.mjs",
  ]);
  assert.deepEqual(calls.map((call) => call.program), ["git", "git"]);
  assert.deepEqual(calls[0].args,
    ["diff", "--no-renames", "--name-only", "-z", "HEAD~1", "--"]);
  assert.deepEqual(calls[1].args,
    ["ls-files", "--others", "--exclude-standard", "-z", "--"]);
  assert.equal(calls.every((call) => call.options.shell === false), true);
  assert.throws(() => validateChangedFromRevision("--output=private"), /invalid/u);
  assert.deepEqual(parseNulDelimitedPaths(Buffer.from("a/b\0a/b\0")), ["a/b", "a/b"]);
});

test("executor passes a static argv without a shell and stops at first failure", () => {
  const selected = selectModulesById([
    "flutter.feature.agents",
    "release.workflows",
    "packaging.windows",
  ]);
  const calls = [];
  const output = stringSink();
  const result = executeClientModules(selected, {
    repoRoot,
    output,
    spawnSyncImpl(program, args, options) {
      calls.push({ program, args, options });
      return {
        status: calls.length === 2 ? 7 : 0,
        stdout: "sensitive-child-output",
        stderr: "sensitive-child-error",
      };
    },
  });
  assert.equal(result.ok, false);
  assert.equal(result.failedModuleId, "packaging.windows");
  assert.equal(result.exitCode, 7);
  assert.deepEqual(result.completed, ["flutter.feature.agents"]);
  assert.equal(calls.length, 2);
  assert.equal(calls.every((call) => call.options.shell === false), true);
  assert.equal(calls.every((call) =>
    JSON.stringify(call.options.stdio) === JSON.stringify(["ignore", "pipe", "pipe"])), true);
  assert.equal(calls.every((call) => Array.isArray(call.args)), true);
  assert.match(output.value(), /flutter\.feature\.agents/u);
  assert.match(output.value(), /packaging\.windows/u);
  assert.doesNotMatch(output.value(), /release\.workflows/u);
  assert.doesNotMatch(output.value(), /sensitive-child/u);
});

test("Rust modules share the managed target and release it after failure", () => {
  const selected = selectModulesById(["rust.domain.agent-usage"]);
  const calls = [];
  let releases = 0;
  const managedTarget = path.join(repoRoot, "build", "managed-native-target");
  const result = executeClientModules(selected, {
    repoRoot,
    output: stringSink(),
    leaseFactory(options) {
      assert.equal(options.scope, "rust.domain.agent-usage");
      assert.equal(options.targetPath, "build/crates/licoup-native/target");
      return {
        targetPath: managedTarget,
        release() { releases += 1; },
      };
    },
    spawnSyncImpl(program, args, options) {
      calls.push({ program, args, options });
      return { status: 9, stdout: "", stderr: "" };
    },
  });
  assert.equal(result.ok, false);
  assert.equal(result.failedModuleId, "rust.domain.agent-usage");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.env.CARGO_TARGET_DIR, managedTarget);
  assert.equal(releases, 1);
});

test("Rust module leases release when process launch throws", () => {
  const selected = selectModulesById(["rust.domain.agent-usage"]);
  let releases = 0;
  assert.throws(() => executeClientModules(selected, {
    repoRoot,
    output: stringSink(),
    leaseFactory() {
      return {
        targetPath: path.join(repoRoot, "build", "managed-native-target"),
        release() { releases += 1; },
      };
    },
    spawnSyncImpl() { throw new Error("synthetic launch failure"); },
  }), /synthetic launch failure/u);
  assert.equal(releases, 1);
});

test("argument parser requires one bounded selector", () => {
  assert.deepEqual(
    parseClientModuleRegressionArgs([
      "--module", "flutter.feature.agents,release.workflows",
      "--module=rust.domain.agent-usage",
      "--dry-run",
    ]).moduleIds,
    ["flutter.feature.agents", "release.workflows", "rust.domain.agent-usage"],
  );
  assert.equal(parseClientModuleRegressionArgs(["--changed-from=HEAD~1"]).changedFrom,
    "HEAD~1");
  assert.throws(() => parseClientModuleRegressionArgs([]), /choose exactly one/u);
  assert.throws(() => parseClientModuleRegressionArgs([
    "--module", "rust.domain.agent-usage", "--changed-from", "HEAD",
  ]), /choose exactly one/u);
});

test("changed-from dry-run selects paths without executing module commands", () => {
  const output = stringSink();
  const errors = stringSink();
  let executed = false;
  const exitCode = main(["--changed-from", "HEAD", "--dry-run"], {
    output,
    errorOutput: errors,
    changedPathLoader: () => [
      "apps/desktop/lib/src/application/features/agents/controller/agent_usage_controller.dart",
    ],
    executor: () => { executed = true; },
  });
  assert.equal(exitCode, 0);
  assert.equal(executed, false);
  assert.equal(errors.value(), "");
  assert.equal(output.value(),
    "architecture.client-boundaries\nflutter.feature.agent-usage\n");
});

test("CLI list is side-effect free and no-argument invocation does not run all tests", () => {
  const listed = spawnSync(process.execPath, [runnerPath, "--list"], {
    cwd: repoRoot,
    encoding: "utf8",
    shell: false,
    timeout: 10_000,
  });
  assert.equal(listed.status, 0);
  assert.match(listed.stdout, /flutter\.feature\.agents/u);
  assert.match(listed.stdout, /rust\.ffi/u);
  assert.match(listed.stdout, /release\.workflows/u);
  assert.doesNotMatch(listed.stdout, /client:gate:/u);

  const unselected = spawnSync(process.execPath, [runnerPath], {
    cwd: repoRoot,
    encoding: "utf8",
    shell: false,
    timeout: 10_000,
  });
  assert.equal(unselected.status, 2);
  assert.match(unselected.stderr, /choose exactly one/u);
});
