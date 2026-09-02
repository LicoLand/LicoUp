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
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";

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

function syntheticChild({ code = 0, stdout = "", stderr = "" } = {}) {
  const child = new EventEmitter();
  child.pid = 4242;
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.kill = () => {};
  process.nextTick(() => {
    child.stdout.end(stdout);
    child.stderr.end(stderr);
    child.emit("close", code, null);
  });
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
  assert.equal(JSON.stringify(safe).includes("private"), false);

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
    assert.equal(JSON.stringify(result).includes("private"), false);
    assert.equal(JSON.stringify(result).includes("node-attribution"), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Rust command uses the managed target, native concurrency, and releases on failure", async () => {
  const module = selectModulesById(["rust.domain.agent-usage"])[0];
  const [batch] = planClientRegressionBatches([module]);
  const calls = [];
  let releases = 0;
  const managedTarget = path.join(repoRoot, "build", "managed-native-target");
  const result = await runClientRegressionCommand(batch, {
    repoRoot,
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
  assert.equal(calls[0].args.includes("--jobs=4"), true);
  assert.equal(releases, 1);
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

function graphModule(id, stage) {
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
      environment: "node",
      toolchain: "node",
      weight: 1,
      resources: Object.freeze([]),
      internalParallelism: false,
      batchKey: `node:${id}`,
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

test("a core branch failure blocks only descendants and still reaches compatibility", async () => {
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
        batch.members[0] === "frontend" ? "failed" : "passed");
    },
    async compatibilityRunner() {
      compatibilityReached = true;
      return [];
    },
  });
  assert.equal(result.ok, false);
  assert.equal(compatibilityReached, true);
  const statuses = new Map(result.report.results.map((entry) => [entry.members[0], entry.status]));
  assert.equal(statuses.get("backend"), "passed");
  assert.equal(statuses.get("integration"), "blocked");
  assert.equal(statuses.get("scenarios"), "blocked");
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
