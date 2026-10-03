import {
  assert,
  CLIENT_MODULE_CATALOG,
  EventEmitter,
  PassThrough,
  path,
  spawn,
  process,
  test,
  executeClientModules,
  executeClientRegressionBatches,
  runClientRegressionCommand,
  planClientRegressionBatches,
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
import { access, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createClientRegressionReport } from "../client-regression-report.mjs";
import { runClientModuleRegressionSelfTest } from
  "../../scripts/client-module-regression-self-test.mjs";

test("infrastructure wrapper preserves failed assertions for private diagnostics", async () => {
  const output = new PassThrough();
  const errorOutput = new PassThrough();
  let publicOutput = "";
  let privateOutput = "";
  output.on("data", (chunk) => {
    publicOutput += chunk.toString("utf8");
  });
  errorOutput.on("data", (chunk) => {
    privateOutput += chunk.toString("utf8");
  });
  const exitCode = await runClientModuleRegressionSelfTest({
    output,
    errorOutput,
    spawnImpl() {
      const child = new EventEmitter();
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      queueMicrotask(() => {
        child.stdout.write("private failing assertion\n");
        child.stderr.write("private stack detail\n");
        child.emit("close", 1);
      });
      return child;
    },
  });
  assert.equal(exitCode, 1);
  assert.equal(publicOutput, "");
  assert.match(privateOutput, /private failing assertion/u);
  assert.match(privateOutput, /private stack detail/u);
  assert.match(privateOutput, /"reason":"contract_test_failed"/u);
});

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
    "regression.documentation-governance",
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

test("changed-from collection uses parallel argv-safe git calls and includes untracked paths", async () => {
  const calls = [];
  const spawnImpl = (program, args, options) => {
    calls.push({ program, args, options });
    return syntheticChild({
      stdout: args[0] === "diff"
        ? "apps/desktop/lib/app.dart\0README.md\0"
        : "tools/regression/new-file.mjs\0README.md\0",
    });
  };
  const paths = await changedPathsSince({ revision: "HEAD~1", repoRoot, spawnImpl });
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

function syntheticChild({
  code = 0,
  stdout = "",
  stderr = "",
  closeDelayMs = 0,
  onKill = () => {},
} = {}) {
  const child = new EventEmitter();
  child.pid = 4242;
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.kill = onKill;
  const close = () => {
    child.stdout.end(stdout);
    child.stderr.end(stderr);
    child.emit("close", code, null);
  };
  if (closeDelayMs > 0) setTimeout(close, closeDelayMs);
  else process.nextTick(close);
  return child;
}

function syntheticBatch(overrides = {}) {
  return Object.freeze({
    id: "synthetic-node",
    stage: "foundation",
    lane: "foundation",
    toolchain: "node",
    weight: 1,
    internalConcurrency: null,
    resources: Object.freeze([]),
    members: Object.freeze(["synthetic.node"]),
    command: Object.freeze({
      program: "node",
      args: Object.freeze(["--version"]),
      cwd: ".",
      timeoutMs: 5_000,
    }),
    ...overrides,
  });
}

test("async command runner uses static argv, drains private output, and records honest metrics", async () => {
  const calls = [];
  const result = await runClientRegressionCommand(syntheticBatch(), {
    repoRoot,
    metricsAdapter: {
      async measure() {
        return {
          directCpuMs: { status: "measured", value: 5 },
          descendantCpuMs: { status: "measured", value: 8 },
          peakResidentBytes: { status: "measured", value: 1024 },
        };
      },
    },
    spawnImpl(program, args, options) {
      calls.push({ program, args, options });
      return syntheticChild({
        stdout: "private stdout that must not enter the result",
        stderr: "private stderr that must not enter the result",
      });
    },
  });
  assert.equal(result.status, "passed");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].program, process.execPath);
  assert.deepEqual(calls[0].args, ["--version"]);
  assert.equal(calls[0].options.shell, false);
  assert.deepEqual(calls[0].options.stdio, ["ignore", "pipe", "pipe"]);
  assert.equal(result.metrics.wallTimeMs.status, "measured");
  assert.deepEqual(result.metrics.directCpuMs, { status: "measured", value: 5 });
  assert.deepEqual(result.metrics.descendantCpuMs, { status: "measured", value: 8 });
  assert.deepEqual(result.metrics.peakResidentBytes, { status: "measured", value: 1024 });
  assert.equal(JSON.stringify(result).includes("private"), false);
});

test("failed commands keep private diagnostics outside the public report and successes retain none", async () => {
  await mkdir(path.join(repoRoot, "build"), { recursive: true });
  const isolatedRoot = await mkdtemp(path.join(repoRoot, "build", "private-diagnostic-"));
  const batch = syntheticBatch({ id: "synthetic-private-diagnostic" });
  try {
    const failed = await runClientRegressionCommand(batch, {
      repoRoot: isolatedRoot,
      spawnImpl() {
        return syntheticChild({
          code: 7,
          stdout: "private stdout marker",
          stderr: "private stderr marker",
        });
      },
    });
    assert.equal(failed.status, "failed");
    assert.equal(failed.reason, "command_failed");
    assert.equal(failed.diagnosticLog,
      "build/private/client-regression/synthetic.node.log");
    assert.equal(JSON.stringify(failed).includes("private stdout marker"), false);
    const diagnosticPath = path.join(isolatedRoot, failed.diagnosticLog);
    const diagnostic = await readFile(diagnosticPath, "utf8");
    assert.match(diagnostic, /private stdout marker/u);
    assert.match(diagnostic, /private stderr marker/u);
    assert.equal((await stat(diagnosticPath)).mode & 0o777, 0o600);

    const report = createClientRegressionReport({
      runKind: "complete",
      startedAt: "2026-01-01T00:00:00.000Z",
      completedAt: "2026-01-01T00:00:01.000Z",
      durationMs: 1,
      results: [failed],
      concurrency: {},
    });
    assert.equal(report.results[0].diagnosticLog, failed.diagnosticLog);
    assert.equal(report.failures[0].diagnosticLog, failed.diagnosticLog);
    assert.equal(JSON.stringify(report).includes("private stdout marker"), false);
    assert.equal(JSON.stringify(report).includes(isolatedRoot), false);

    const passed = await runClientRegressionCommand(batch, {
      repoRoot: isolatedRoot,
      spawnImpl() { return syntheticChild(); },
    });
    assert.equal(passed.status, "passed");
    assert.equal(Object.hasOwn(passed, "diagnosticLog"), false);
    await assert.rejects(access(diagnosticPath), { code: "ENOENT" });
  } finally {
    await rm(isolatedRoot, { recursive: true, force: true });
  }
});

test("focused failures retain diagnostics by stable member instead of reused batch id", async () => {
  await mkdir(path.join(repoRoot, "build"), { recursive: true });
  const isolatedRoot = await mkdtemp(path.join(repoRoot, "build", "focused-diagnostic-"));
  try {
    const run = (member, marker) => runClientRegressionCommand(syntheticBatch({
      id: "exact-1",
      members: Object.freeze([member]),
    }), {
      repoRoot: isolatedRoot,
      spawnImpl() { return syntheticChild({ code: 1, stderr: marker }); },
    });
    const first = await run("owner.one", "first private failure");
    const second = await run("owner.two", "second private failure");
    assert.equal(first.diagnosticLog,
      "build/private/client-regression/owner.one.log");
    assert.equal(second.diagnosticLog,
      "build/private/client-regression/owner.two.log");
    assert.match(await readFile(path.join(isolatedRoot, first.diagnosticLog), "utf8"),
      /first private failure/u);
    assert.match(await readFile(path.join(isolatedRoot, second.diagnosticLog), "utf8"),
      /second private failure/u);
  } finally {
    await rm(isolatedRoot, { recursive: true, force: true });
  }
});

test("public reports reject unsafe or non-failure diagnostic references", () => {
  const result = {
    id: "synthetic",
    stage: "foundation",
    lane: "foundation",
    toolchain: "node",
    status: "failed",
    reason: "command_failed",
    durationMs: 1,
    members: ["synthetic.node"],
    metrics: {},
  };
  const create = (entry) => createClientRegressionReport({
    runKind: "complete",
    startedAt: "2026-01-01T00:00:00.000Z",
    completedAt: "2026-01-01T00:00:01.000Z",
    durationMs: 1,
    results: [entry],
    concurrency: {},
  });
  for (const diagnosticLog of [
    "/tmp/private.log",
    "../private.log",
    "build/private/client-regression/../private.log",
  ]) {
    assert.throws(() => create({ ...result, diagnosticLog }), /reference is invalid/u);
  }
  assert.throws(() => create({
    ...result,
    status: "passed",
    reason: null,
    diagnosticLog: "build/private/client-regression/synthetic.log",
  }), /reference is invalid/u);
  const blocked = create({ ...result, status: "blocked", diagnosticLog: null });
  assert.equal(Object.hasOwn(blocked.results[0], "diagnosticLog"), false);
  assert.equal(Object.hasOwn(blocked.failures[0], "diagnosticLog"), false);
});

test("runner does not terminate long commands or create the parent-kill orphan path", async () => {
  let killCount = 0;
  const result = await runClientRegressionCommand(syntheticBatch({
    command: Object.freeze({
      program: "node",
      args: Object.freeze(["--version"]),
      cwd: ".",
      timeoutMs: 1,
    }),
  }), {
    repoRoot,
    spawnImpl() {
      return syntheticChild({
        closeDelayMs: 25,
        onKill() { killCount += 1; },
      });
    },
  });
  assert.equal(result.status, "passed");
  assert.equal(killCount, 0);
  assert.equal(Object.hasOwn(result, "diagnosticLog"), false);
});

test("compatibility commands retain only a bounded safe receipt error code", async () => {
  const batch = syntheticBatch({
    toolchain: "compatibility",
    members: Object.freeze(["synthetic.compatibility"]),
  });
  const safe = await runClientRegressionCommand(batch, {
    repoRoot,
    spawnImpl() {
      return syntheticChild({
        code: 1,
        stdout: '{"status":"failed","errorCode":"adapter_contract_failed"}\n',
        stderr: "private diagnostic output",
      });
    },
  });
  assert.equal(safe.status, "failed");
  assert.equal(safe.reason, "adapter_contract_failed");
  assert.equal(JSON.stringify(safe).includes("private diagnostic output"), false);

  const unsafe = await runClientRegressionCommand(batch, {
    repoRoot,
    spawnImpl() {
      return syntheticChild({
        code: 1,
        stdout: '{"status":"failed","errorCode":"unsafe reason"}\n',
      });
    },
  });
  assert.equal(unsafe.reason, "command_failed");
});

test("aggregated Node tests attribute failure to module ids without retaining file details", async () => {
  await mkdir(path.join(repoRoot, "build"), { recursive: true });
  const directory = await mkdtemp(path.join(repoRoot, "build", "node-attribution-"));
  try {
    const passing = path.join(directory, "passing.test.mjs");
    const failing = path.join(directory, "failing.test.mjs");
    await Promise.all([
      writeFile(passing, 'import test from "node:test"; test("private pass", () => {});\n'),
      writeFile(failing, 'import test from "node:test"; test("private fail", () => { throw new Error("private stack"); });\n'),
    ]);
    const inputs = [passing, failing].map((file) =>
      path.relative(repoRoot, file).replaceAll("\\", "/"));
    const result = await runClientRegressionCommand(syntheticBatch({
      id: "synthetic-node-test-attribution",
      toolchain: "node-test",
      weight: 2,
      internalConcurrency: 2,
      members: Object.freeze(["module.passing", "module.failing"]),
      inputOwners: Object.freeze([
        Object.freeze({ member: "module.passing", indexes: Object.freeze([0]) }),
        Object.freeze({ member: "module.failing", indexes: Object.freeze([1]) }),
      ]),
      command: Object.freeze({
        program: "node",
        args: Object.freeze(["--test", "--test-concurrency=2", ...inputs]),
        cwd: ".",
        timeoutMs: 5_000,
      }),
    }), {
      repoRoot,
      spawnImpl(program, args, options) {
        const environment = { ...options.env };
        delete environment.NODE_TEST_CONTEXT;
        return spawn(program, args, { ...options, env: environment });
      },
    });
    assert.equal(result.status, "failed");
    assert.deepEqual(result.members, ["module.failing"]);
    assert.deepEqual(result.attributedPassedMembers, ["module.passing"]);
    assert.equal(JSON.stringify(result).includes("private stack"), false);
    assert.equal(JSON.stringify(result).includes(directory), false);
    const diagnostic = await readFile(path.join(repoRoot, result.diagnosticLog), "utf8");
    assert.match(diagnostic, /node-test-private-diagnostic input=1 category=err_test_failure/u);
    assert.match(diagnostic, /private stack/u);
    assert.equal((await stat(path.join(repoRoot, result.diagnosticLog))).mode & 0o777, 0o600);
    const report = createClientRegressionReport({
      runKind: "focused",
      startedAt: "2026-01-01T00:00:00.000Z",
      completedAt: "2026-01-01T00:00:01.000Z",
      durationMs: 1,
      results: [result],
      concurrency: {},
    });
    assert.equal(JSON.stringify(report).includes("private stack"), false);
    assert.equal(JSON.stringify(report).includes(directory), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("complete Node attribution retains independently passed members in the summary", async () => {
  const modules = selectModulesById([
    "regression.release-workflow-contracts",
    "regression.client-state-contracts",
  ]);
  const passing = "regression.release-workflow-contracts";
  const failing = "regression.client-state-contracts";
  const result = await executeClientModules(modules, {
    repoRoot,
    catalog: modules,
    output: stringSink(),
    async commandRunner(batch) {
      assert.deepEqual(batch.members, [passing, failing]);
      return Object.freeze({
        ...graphResult(batch, "failed"),
        members: Object.freeze([failing]),
        attributedPassedMembers: Object.freeze([passing]),
      });
    },
  });
  const statuses = new Map(result.report.results.flatMap((entry) =>
    entry.members.map((member) => [member, entry.status])));
  assert.equal(statuses.get(passing), "passed");
  assert.equal(statuses.get(failing), "failed");
  assert.deepEqual(result.completed, [passing]);
  assert.deepEqual(result.failures.map((failure) => failure.members), [[failing]]);
});

test("complete Flutter JSON attribution retains only actually completed passing inputs", async () => {
  const files = ["test/startup_test.dart", "test/dock_test.dart"];
  const batch = syntheticBatch({
    id: "synthetic-flutter-attribution",
    toolchain: "flutter",
    weight: 2,
    internalConcurrency: 2,
    members: Object.freeze(["module.startup", "module.dock"]),
    inputOwners: Object.freeze([
      Object.freeze({ member: "module.startup", indexes: Object.freeze([0]) }),
      Object.freeze({ member: "module.dock", indexes: Object.freeze([1]) }),
    ]),
    command: Object.freeze({
      program: "node",
      args: Object.freeze([
        "tools/scripts/client-toolchain-runner.mjs",
        "--cwd", "apps/desktop",
        "--", "flutter", "test", ...files,
      ]),
      cwd: ".",
      timeoutMs: 5_000,
    }),
  });
  const absolute = files.map((file) => path.join(repoRoot, "apps/desktop", file));
  const events = [
    { type: "start", time: 0, protocolVersion: "0.1.1", pid: 7 },
    { type: "suite", time: 1, suite: { id: 1, path: absolute[0] } },
    { type: "suite", time: 2, suite: { id: 2, path: absolute[1] } },
    { type: "testStart", time: 3, test: { id: 10, suiteID: 1, name: "startup passes" } },
    { type: "testDone", time: 4, testID: 10, result: "success", hidden: false, skipped: false },
    { type: "testStart", time: 5, test: { id: 20, suiteID: 2, name: "dock fails" } },
    { type: "testDone", time: 6, testID: 20, result: "failure", hidden: false, skipped: false },
    { type: "done", time: 7, success: false },
  ];
  const result = await runClientRegressionCommand(batch, {
    repoRoot,
    spawnImpl() {
      return syntheticChild({
        code: 1,
        stdout: `${events.map((event) => JSON.stringify(event)).join("\n")}\n`,
      });
    },
  });
  assert.equal(result.status, "failed");
  assert.deepEqual(result.members, ["module.dock"]);
  assert.deepEqual(result.attributedPassedMembers, ["module.startup"]);
  assert.equal(JSON.stringify(result).includes(absolute[0]), false);

  const interrupted = await runClientRegressionCommand(batch, {
    repoRoot,
    spawnImpl() {
      return syntheticChild({
        code: 1,
        stdout: `${events.slice(0, -1).map((event) => JSON.stringify(event)).join("\n")}\n`,
      });
    },
  });
  assert.equal(interrupted.status, "attribution-pending");
  assert.deepEqual(interrupted.members, ["module.startup", "module.dock"]);
  assert.equal(Object.hasOwn(interrupted, "attributedPassedMembers"), false);
});

test("an explicit module on the wrong host is blocked without executing", async () => {
  const [module] = selectModulesById([
    "rust.platform.secure-mesh-secret-store.backend-windows",
  ]);
  let commandRuns = 0;
  const result = await executeClientModules([module], {
    repoRoot,
    catalog: [module],
    host: "linux",
    output: stringSink(),
    async commandRunner() {
      commandRuns += 1;
      throw new Error("unsupported module must not execute");
    },
  });
  assert.equal(commandRuns, 0);
  assert.equal(result.exitCode, 1);
  assert.deepEqual(result.report.results.map(({ status, reason, members }) =>
    ({ status, reason, members })), [{
    status: "blocked",
    reason: "unsupported_host",
    members: [module.id],
  }]);
});

test("Rust command uses the managed target, native concurrency, and releases on failure", async () => {
  const module = selectModulesById(["rust.domain.agent-usage"])[0];
  const [batch] = planClientRegressionBatches([module]);
  const calls = [];
  let releases = 0;
  const managedTarget = path.join(repoRoot, "build", "managed-native-target");
  const environment = { ...process.env };
  delete environment.RUST_TEST_THREADS;
  delete environment.CARGO_BUILD_JOBS;
  const result = await runClientRegressionCommand(batch, {
    repoRoot,
    environment,
    leaseFactory(options) {
      assert.equal(options.scope, batch.id);
      return {
        targetPath: managedTarget,
        release() { releases += 1; },
      };
    },
    spawnImpl(program, args, options) {
      calls.push({ program, args, options });
      return syntheticChild({ code: 9 });
    },
  });
  assert.equal(result.status, "failed");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.env.CARGO_TARGET_DIR, managedTarget);
  assert.equal(calls[0].args.includes("--timings"), true);
  assert.equal(calls[0].args.includes("--jobs=3"), true);
  assert.equal(releases, 1);
});

test("Rust command caps module concurrency to the shared runner budget", async () => {
  const module = selectModulesById(["rust.domain.agent-usage"])[0];
  const [batch] = planClientRegressionBatches([module]);
  const calls = [];
  await runClientRegressionCommand(batch, {
    repoRoot,
    environment: { ...process.env, CARGO_BUILD_JOBS: "2" },
    leaseFactory() {
      return {
        targetPath: path.join(repoRoot, "build", "managed-native-target"),
        release() {},
      };
    },
    spawnImpl(program, args, options) {
      calls.push({ program, args, options });
      return syntheticChild();
    },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].args.includes("--jobs=2"), true);
  assert.equal(calls[0].args.some((argument) => argument === "--jobs=3"), false);
});

test("Rust command rejects an invalid shared runner budget before launch", async () => {
  const module = selectModulesById(["rust.domain.agent-usage"])[0];
  const [batch] = planClientRegressionBatches([module]);
  let launched = false;
  await assert.rejects(
    runClientRegressionCommand(batch, {
      repoRoot,
      environment: { ...process.env, CARGO_BUILD_JOBS: "unbounded" },
      spawnImpl() {
        launched = true;
        return syntheticChild();
      },
    }),
    /CARGO_BUILD_JOBS must be a positive integer/u,
  );
  assert.equal(launched, false);
});

test("test child processes exempt loopback from inherited proxies", async () => {
  const calls = [];
  await runClientRegressionCommand(syntheticBatch(), {
    repoRoot,
    environment: {
      ...process.env,
      HTTP_PROXY: "http://proxy.example.test:8080",
      HTTPS_PROXY: "http://proxy.example.test:8080",
      NO_PROXY: "example.test",
      no_proxy: "example.test",
    },
    spawnImpl(program, args, options) {
      calls.push({ program, args, options });
      return syntheticChild();
    },
  });
  assert.equal(calls.length, 1);
  const env = calls[0].options.env;
  assert.equal(env.HTTP_PROXY, "http://proxy.example.test:8080");
  assert.equal(env.HTTPS_PROXY, "http://proxy.example.test:8080");
  for (const key of ["NO_PROXY", "no_proxy"]) {
    assert.match(env[key], /example\.test/u);
    assert.match(env[key], /localhost/u);
    assert.match(env[key], /127\.0\.0\.1/u);
    assert.match(env[key], /::1/u);
  }

  const loopback = "localhost,127.0.0.1,::1";
  const matrix = [
    {
      input: { NO_PROXY: "corp.internal" },
      omit: ["no_proxy"],
      expected: {
        NO_PROXY: `corp.internal,${loopback}`,
        no_proxy: `corp.internal,${loopback}`,
      },
    },
    {
      input: { no_proxy: "corp.internal" },
      omit: ["NO_PROXY"],
      expected: {
        NO_PROXY: `corp.internal,${loopback}`,
        no_proxy: `corp.internal,${loopback}`,
      },
    },
    {
      input: { NO_PROXY: "upper.example", no_proxy: "lower.example" },
      omit: [],
      expected: {
        NO_PROXY: `upper.example,${loopback}`,
        no_proxy: `lower.example,${loopback}`,
      },
    },
  ];
  for (const row of matrix) {
    const rowCalls = [];
    const environment = {
      ...process.env,
      HTTP_PROXY: "http://proxy.example.test:8080",
      HTTPS_PROXY: "http://proxy.example.test:8080",
      ...row.input,
    };
    for (const key of row.omit) {
      delete environment[key];
    }
    await runClientRegressionCommand(syntheticBatch(), {
      repoRoot,
      environment,
      spawnImpl(program, args, options) {
        rowCalls.push({ program, args, options });
        return syntheticChild();
      },
    });
    assert.equal(rowCalls.length, 1);
    const rowEnv = rowCalls[0].options.env;
    assert.equal(rowEnv.HTTP_PROXY, "http://proxy.example.test:8080");
    assert.equal(rowEnv.HTTPS_PROXY, "http://proxy.example.test:8080");
    assert.equal(rowEnv.NO_PROXY, row.expected.NO_PROXY);
    assert.equal(rowEnv.no_proxy, row.expected.no_proxy);
  }
});

test("explicit serial libtest is prepared independently of Cargo jobs", async () => {
  const module = selectModulesById(["rust.domain.agent-usage"])[0];
  const [batch] = planClientRegressionBatches([module]);
  const calls = [];
  await runClientRegressionCommand(batch, {
    repoRoot,
    environment: {
      ...process.env,
      RUST_TEST_THREADS: "1",
      CARGO_BUILD_JOBS: "3",
    },
    leaseFactory() {
      return {
        targetPath: path.join(repoRoot, "build", "managed-native-target"),
        release() {},
      };
    },
    spawnImpl(program, args, options) {
      calls.push({ program, args, options });
      return syntheticChild();
    },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].args.includes("--jobs=3"), true);
  assert.equal(calls[0].args.includes("--test-threads=1"), true);
  assert.equal(calls[0].args.includes("--test-threads=4"), false);
});

test("Rust leases release and launch failures become reportable results", async () => {
  const module = selectModulesById(["rust.domain.agent-usage"])[0];
  const [batch] = planClientRegressionBatches([module]);
  let releases = 0;
  const result = await runClientRegressionCommand(batch, {
    repoRoot,
    leaseFactory() {
      return {
        targetPath: path.join(repoRoot, "build", "managed-native-target"),
        release() { releases += 1; },
      };
    },
    spawnImpl() { throw new Error("synthetic launch failure"); },
  });
  assert.equal(result.status, "failed");
  assert.equal(result.reason, "process_start_failed");
  assert.equal(releases, 1);
});

test("bounded scheduler settles siblings after a failure and admits work concurrently", async () => {
  const batches = [1, 2, 3].map((number) => syntheticBatch({
    id: `batch-${number}`,
    members: Object.freeze([`module-${number}`]),
  }));
  let active = 0;
  let peak = 0;
  const started = [];
  const execution = await executeClientRegressionBatches(batches, {
    capacities: {
      global: 2,
      pools: { node: 2 },
      resources: {},
    },
    async commandRunner(batch) {
      active += 1;
      peak = Math.max(peak, active);
      started.push(batch.id);
      await new Promise((resolve) => setImmediate(resolve));
      active -= 1;
      return {
        ...batch,
        status: batch.id === "batch-1" ? "failed" : "passed",
        reason: batch.id === "batch-1" ? "synthetic_failure" : null,
        durationMs: 1,
        metrics: {},
      };
    },
  });
  assert.equal(peak, 2);
  assert.deepEqual(started, ["batch-1", "batch-2", "batch-3"]);
  assert.deepEqual(execution.results.map((result) => result.status), [
    "failed", "passed", "passed",
  ]);
});

function graphModule(id, stage, {
  toolchain = "node",
  resources = [],
} = {}) {
  return Object.freeze({
    id,
    kind: "synthetic",
    summary: id,
    inputs: Object.freeze([]),
    command: Object.freeze({
      program: "node",
      args: Object.freeze([id]),
      cwd: ".",
      timeoutMs: 5_000,
    }),
    regression: Object.freeze({
      stage,
      lane: stage,
      environment: toolchain,
      toolchain,
      weight: 1,
      resources: Object.freeze(resources),
      internalParallelism: false,
      batchKey: `node:${id}`,
      runnableHosts: Object.freeze(["darwin", "linux", "win32"]),
      targetEvidenceHosts: Object.freeze([]),
    }),
  });
}

function graphResult(batch, status = "passed") {
  return {
    id: batch.id,
    stage: batch.stage,
    lane: batch.lane,
    toolchain: batch.toolchain,
    status,
    reason: status === "passed" ? null : "synthetic_failure",
    durationMs: 1,
    members: batch.members,
    metrics: {},
  };
}

test("staged graph overlaps frontend/backend and preserves dependency order", async () => {
  const modules = [
    graphModule("foundation", "foundation"),
    graphModule("frontend", "frontend"),
    graphModule("backend", "backend"),
    graphModule("integration", "integration"),
    graphModule("scenarios", "scenarios"),
  ];
  const events = [];
  const result = await executeClientModules(modules, {
    repoRoot,
    catalog: modules,
    output: stringSink(),
    capacities: { global: 2, pools: { node: 2 }, resources: {} },
    async commandRunner(batch) {
      const member = batch.members[0];
      events.push(`${member}:start`);
      await new Promise((resolve) => setImmediate(resolve));
      events.push(`${member}:end`);
      return graphResult(batch);
    },
  });
  assert.equal(result.ok, true);
  assert.ok(events.indexOf("foundation:end") < events.indexOf("frontend:start"));
  assert.ok(events.indexOf("foundation:end") < events.indexOf("backend:start"));
  assert.ok(events.indexOf("frontend:start") < events.indexOf("backend:end"));
  assert.ok(events.indexOf("backend:start") < events.indexOf("frontend:end"));
  assert.ok(events.indexOf("frontend:end") < events.indexOf("integration:start"));
  assert.ok(events.indexOf("backend:end") < events.indexOf("integration:start"));
  assert.ok(events.indexOf("integration:end") < events.indexOf("scenarios:start"));
});

test("independent cross-stage failures settle together and still reach compatibility", async () => {
  const modules = [
    graphModule("foundation", "foundation"),
    graphModule("frontend", "frontend"),
    graphModule("backend", "backend"),
    graphModule("integration", "integration"),
    graphModule("scenarios", "scenarios"),
  ];
  let compatibilityReached = false;
  const result = await executeClientModules(modules, {
    repoRoot,
    catalog: modules,
    output: stringSink(),
    capacities: { global: 2, pools: { node: 2 }, resources: {} },
    async commandRunner(batch) {
      return graphResult(batch,
        ["foundation", "integration"].includes(batch.members[0]) ? "failed" : "passed");
    },
    async compatibilityRunner() {
      compatibilityReached = true;
      return [];
    },
  });
  assert.equal(result.ok, false);
  assert.equal(compatibilityReached, true);
  const statuses = new Map(result.report.results.map((entry) => [entry.members[0], entry.status]));
  assert.equal(statuses.get("foundation"), "failed");
  assert.equal(statuses.get("frontend"), "passed");
  assert.equal(statuses.get("backend"), "passed");
  assert.equal(statuses.get("integration"), "failed");
  assert.equal(statuses.get("scenarios"), "passed");
  assert.deepEqual(result.report.failures.map((failure) => failure.members[0]), [
    "foundation",
    "integration",
  ]);
});

test("batch progress is emitted at settlement before its concurrent stage completes", async () => {
  const modules = [
    graphModule("foundation.fast-failure", "foundation"),
    graphModule("foundation.slow-pass", "foundation"),
  ];
  let releaseSlow;
  const slow = new Promise((resolve) => { releaseSlow = resolve; });
  let observeSettlement;
  const firstSettlement = new Promise((resolve) => { observeSettlement = resolve; });
  let outputValue = "";
  const output = {
    write(chunk) {
      outputValue += String(chunk);
      if (/\[client-regression\] exact-[0-9]+: failed\n/u.test(outputValue)) {
        observeSettlement();
      }
    },
  };
  let stageCompleted = false;
  const execution = executeClientModules(modules, {
    repoRoot,
    catalog: modules,
    output,
    capacities: { global: 2, pools: { node: 2 }, resources: {} },
    async commandRunner(batch) {
      if (batch.members[0] === "foundation.slow-pass") await slow;
      return graphResult(batch,
        batch.members[0] === "foundation.fast-failure" ? "failed" : "passed");
    },
  }).then((result) => {
    stageCompleted = true;
    return result;
  });

  await firstSettlement;
  assert.equal(stageCompleted, false);
  assert.match(outputValue, /\[client-regression\] exact-[0-9]+: failed\n/u);
  assert.equal(outputValue.includes("foundation.fast-failure: failed"), false);
  releaseSlow();
  const result = await execution;
  assert.equal(result.ok, false);
  assert.match(outputValue, /\[client-regression\] exact-[0-9]+: passed\n/u);
});

test("Flutter dependency failure blocks only its consumers and remains nonzero", async () => {
  const modules = [
    graphModule("regression.flutter-dependencies", "foundation", {
      toolchain: "flutter",
      resources: ["flutter-cache"],
    }),
    graphModule("foundation.node", "foundation"),
    graphModule("frontend.flutter", "frontend", {
      toolchain: "flutter",
      resources: ["flutter-cache"],
    }),
    graphModule("backend.rust", "backend", {
      toolchain: "rust",
      resources: ["cargo-target"],
    }),
    graphModule("integration.gradle-wrapper", "integration", {
      resources: ["flutter-cache", "gradle-cache"],
    }),
    graphModule("integration.node", "integration"),
    graphModule("scenarios.node", "scenarios"),
  ];
  const executed = [];
  const output = stringSink();
  const result = await executeClientModules(modules, {
    repoRoot,
    catalog: modules,
    output,
    capacities: {
      global: 3,
      pools: { node: 2, flutter: 3, rust: 3 },
      resources: { "flutter-cache": 1, "gradle-cache": 1, "cargo-target": 1 },
    },
    async commandRunner(batch) {
      executed.push(batch.members[0]);
      return graphResult(batch,
        batch.members[0] === "regression.flutter-dependencies" ? "failed" : "passed");
    },
  });
  assert.equal(result.ok, false);
  assert.equal(result.exitCode, 1);
  assert.deepEqual(executed, [
    "regression.flutter-dependencies",
    "foundation.node",
    "backend.rust",
    "integration.node",
    "scenarios.node",
  ]);
  const rows = new Map(result.report.results.map((entry) => [entry.members[0], entry]));
  for (const id of ["frontend.flutter", "integration.gradle-wrapper"]) {
    assert.equal(rows.get(id).status, "blocked");
    assert.equal(rows.get(id).reason, "flutter_dependencies_failed");
  }
  assert.equal(rows.get("integration.node").status, "passed");
  assert.equal(rows.get("scenarios.node").status, "passed");
  assert.match(output.value(), new RegExp(`${rows.get("regression.flutter-dependencies").id}: failed`, "u"));
  assert.match(output.value(), new RegExp(`${rows.get("foundation.node").id}: passed`, "u"));
  assert.match(output.value(), new RegExp(`${rows.get("frontend.flutter").id}: blocked`, "u"));
  assert.equal(output.value().includes("regression.flutter-dependencies: failed"), false);
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
  assert.equal(parseClientModuleRegressionArgs([]).all, true);
  assert.deepEqual(
    parseClientModuleRegressionArgs([
      "--agent", "codex,claude-code",
      "--platform", "macos",
      "--dry-run",
    ]).agentIds,
    ["codex", "claude-code"],
  );
  assert.throws(() => parseClientModuleRegressionArgs([
    "--module", "rust.domain.agent-usage", "--changed-from", "HEAD",
  ]), /choose exactly one/u);
  assert.throws(() => parseClientModuleRegressionArgs(["--dry-run"]),
    /requires a focused selector/u);
});

test("changed-from dry-run selects paths without executing module commands", async () => {
  const output = stringSink();
  const errors = stringSink();
  let executed = false;
  const exitCode = await main(["--changed-from", "HEAD", "--dry-run"], {
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
    "architecture.client-boundaries\tfoundation\tnode\n" +
    "flutter.feature.agent-usage\tfrontend\tflutter\n");
});

test("CLI list is side-effect free and no-argument invocation selects the complete catalog", async () => {
  const listed = await new Promise((resolve) => {
    const child = spawn(process.execPath, [runnerPath, "--list"], {
      cwd: repoRoot,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    child.stdout.on("data", (chunk) => { stdout += chunk.toString("utf8"); });
    child.stderr.resume();
    child.once("error", () => resolve({ status: null, stdout: "" }));
    child.once("close", (status) => resolve({ status, stdout }));
  });
  assert.equal(listed.status, 0);
  assert.match(listed.stdout, /flutter\.feature\.agents/u);
  assert.match(listed.stdout, /rust\.ffi/u);
  assert.match(listed.stdout, /release\.workflows/u);
  assert.doesNotMatch(listed.stdout, /client:gate:/u);

  let selected = [];
  const exitCode = await main([], {
    output: stringSink(),
    errorOutput: stringSink(),
    async executor(modules) {
      selected = modules;
      return { exitCode: 0 };
    },
  });
  assert.equal(exitCode, 0);
  assert.deepEqual(ids(selected), ids(CLIENT_MODULE_CATALOG));
});
