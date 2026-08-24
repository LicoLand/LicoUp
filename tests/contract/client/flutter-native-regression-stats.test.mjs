import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";

import {
  boundedFlutterTestConcurrency,
  createFlutterJsonStatsCollector,
  decorateFlutterTestCommand,
  hasFlutterTestReporter,
  isCompatibleFlutterTestCommand,
  withFlutterJsonReporter,
} from "../../../tools/regression/client-regression-toolchain-stats/flutter.mjs";

function flutterCommand(extraArgs = []) {
  return {
    program: "node",
    args: [
      "tools/scripts/client-toolchain-runner.mjs",
      "--check",
      "flutter",
      "--cwd",
      "apps/desktop",
      "--",
      "flutter",
      "test",
      "--no-pub",
      "test/assistant_test.dart",
      ...extraArgs,
    ],
    cwd: ".",
    timeoutMs: 60_000,
  };
}

test("Flutter command decoration preserves focused names and bounds native concurrency", () => {
  const command = flutterCommand([
    "--name",
    "assistant chooses workflow",
    "-r",
    "expanded",
    "-j64",
  ]);
  assert.equal(isCompatibleFlutterTestCommand(command), true);

  const decorated = decorateFlutterTestCommand(command, {
    concurrency: 12.9,
    availableParallelism: 8,
  });
  assert.equal(decorated.supported, true);
  assert.equal(decorated.concurrency, 8);
  assert.deepEqual(decorated.command.args.slice(-6), [
    "--no-pub",
    "test/assistant_test.dart",
    "--name",
    "assistant chooses workflow",
    "--reporter=json",
    "--concurrency=8",
  ]);
  assert.deepEqual(command.args.slice(-5), [
    "--name",
    "assistant chooses workflow",
    "-r",
    "expanded",
    "-j64",
  ]);
  assert.throws(
    () => boundedFlutterTestConcurrency(0),
    /positive finite number/u,
  );
});

test("non-Flutter and non-test toolchain commands remain unsupported", () => {
  const analyze = flutterCommand();
  analyze.args[analyze.args.indexOf("test")] = "analyze";
  const untouched = decorateFlutterTestCommand(analyze, { concurrency: 2 });
  assert.equal(untouched.supported, false);
  assert.equal(untouched.command, analyze);
  assert.equal(isCompatibleFlutterTestCommand({ program: "cargo", args: ["test"] }), false);
});

test("Flutter reporter arguments have one exact JSON authority", () => {
  assert.equal(hasFlutterTestReporter(["test"]), false);
  assert.equal(hasFlutterTestReporter(["test", "--reporter", "expanded"]), true);
  assert.equal(hasFlutterTestReporter(["test", "-rcompact"]), true);
  assert.deepEqual(withFlutterJsonReporter([
    "test",
    "--reporter",
    "expanded",
    "test/assistant_test.dart",
  ]), [
    "test",
    "test/assistant_test.dart",
    "--reporter=json",
  ]);
});

test("JSON collector incrementally aggregates only protocol-backed numeric facts", () => {
  const collector = createFlutterJsonStatsCollector();
  const lines = [
    "[client-toolchain-runner] apps/desktop$ flutter test --reporter=json",
    JSON.stringify({ type: "start", time: 0, protocolVersion: "0.1.1", pid: 42 }),
    "{not-json}",
    JSON.stringify({ type: "suite", time: 1, suite: { id: 1, path: "fixture-a.dart" } }),
    JSON.stringify({ type: "suite", time: 2, suite: { id: 2, path: "fixture-b.dart" } }),
    JSON.stringify({ type: "testStart", time: 10, test: { id: 11, name: "private pass name" } }),
    JSON.stringify({ type: "testStart", time: 12, test: { id: 12, name: "private failure name" } }),
    JSON.stringify({ type: "testStart", time: 14, test: { id: 13, name: "private skip name" } }),
    JSON.stringify({ type: "testStart", time: 15, test: { id: 14, name: "hidden loader" } }),
    JSON.stringify({ type: "testDone", time: 20, testID: 11, result: "success", hidden: false, skipped: false }),
    JSON.stringify({ type: "testDone", time: 42, testID: 12, result: "failure", hidden: false, skipped: false }),
    JSON.stringify({ type: "testDone", time: 19, testID: 13, result: "success", hidden: false, skipped: true }),
    JSON.stringify({ type: "testDone", time: 16, testID: 14, result: "success", hidden: true, skipped: false }),
    JSON.stringify({ type: "done", time: 43, success: false }),
  ].join("\n") + "\n";

  collector.push(lines.slice(0, 137));
  collector.push(Buffer.from(lines.slice(137, 511)));
  collector.push(lines.slice(511));
  const aggregate = collector.finish();

  assert.deepEqual(aggregate.suiteCount, { status: "measured", value: 2 });
  assert.deepEqual(aggregate.testCount, { status: "measured", value: 3 });
  assert.deepEqual(aggregate.passedCount, { status: "measured", value: 1 });
  assert.deepEqual(aggregate.failedCount, { status: "measured", value: 1 });
  assert.deepEqual(aggregate.skippedCount, { status: "measured", value: 1 });
  assert.deepEqual(aggregate.totalTestDurationMs, { status: "measured", value: 45 });
  assert.deepEqual(aggregate.longestTestDurationMs, { status: "measured", value: 30 });
  assert.equal(aggregate.directCpuMs.status, "unavailable");
  assert.equal(aggregate.descendantCpuMs.status, "unavailable");
  assert.equal(aggregate.peakResidentBytes.status, "unavailable");
  assert.equal(JSON.stringify(aggregate).includes("private"), false);
});

test("incomplete or duration-incomplete reporter streams never manufacture measurements", () => {
  const incomplete = createFlutterJsonStatsCollector();
  incomplete.push(`${JSON.stringify({
    type: "start",
    time: 0,
    protocolVersion: "0.1.1",
    pid: 9,
  })}\n`);
  assert.equal(incomplete.finish().testCount.status, "unavailable");

  const missingStart = createFlutterJsonStatsCollector();
  for (const event of [
    { type: "start", time: 0, protocolVersion: "0.1.1", pid: 9 },
    { type: "testDone", time: 5, testID: 1, result: "success", hidden: false, skipped: false },
    { type: "done", time: 6, success: true },
  ]) missingStart.push(`${JSON.stringify(event)}\n`);
  const aggregate = missingStart.finish();
  assert.deepEqual(aggregate.testCount, { status: "measured", value: 1 });
  assert.equal(aggregate.totalTestDurationMs.status, "unavailable");
  assert.equal(aggregate.longestTestDurationMs.status, "unavailable");
});

test("oversized wrapper lines are discarded without retaining or parsing their contents", () => {
  const collector = createFlutterJsonStatsCollector({ lineLimit: 128 });
  collector.push(`${"sensitive".repeat(20)}\n`);
  collector.push('{"type":"start","time":0,"protocolVersion":"0.1.1"}\n');
  collector.push('{"type":"done","time":1,"success":true}\n');
  assert.deepEqual(collector.finish().suiteCount, { status: "measured", value: 0 });
});

test("failure diagnostics retain only repository-relative, bounded, redacted facts", () => {
  const repoRoot = path.resolve("fixture-repository");
  const collector = createFlutterJsonStatsCollector({
    repoRoot,
    commandCwd: path.join(repoRoot, "apps/desktop"),
  });
  const testFile = path.join(repoRoot, "apps/desktop/test/safe_fixture_test.dart");
  for (const event of [
    { type: "start", time: 0, protocolVersion: "0.1.1", pid: 7 },
    { type: "suite", time: 1, suite: { id: 2, path: testFile } },
    {
      type: "testStart",
      time: 2,
      test: {
        id: 3,
        suiteID: 2,
        name: "widget assertion keeps Bearer synthetic-token private",
        url: `file://${testFile}`,
      },
    },
    {
      type: "error",
      time: 3,
      testID: 3,
      error: `Expected one widget at ${testFile}\nActual endpoint: https://runtime.invalid/private`,
      stackTrace: `#0 ${testFile}:10:2`,
      isFailure: true,
    },
    { type: "testDone", time: 4, testID: 3, result: "failure", hidden: false, skipped: false },
    { type: "done", time: 5, success: false },
  ]) collector.push(`${JSON.stringify(event)}\n`);

  collector.finish();
  assert.deepEqual(collector.failureDiagnostics(), [{
    file: "apps/desktop/test/safe_fixture_test.dart",
    name: "widget assertion keeps Bearer [redacted] private",
    error: "Expected one widget at <local-path> | Actual endpoint: <endpoint> @ apps/desktop/test/safe_fixture_test.dart:10:2",
  }]);
});
