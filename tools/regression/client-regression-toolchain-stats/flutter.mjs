import os from "node:os";
import path from "node:path";

const TOOLCHAIN_RUNNER = "tools/scripts/client-toolchain-runner.mjs";
const FLUTTER_EXECUTABLES = new Set([
  "flutter",
  "flutter.bat",
  "flutter.cmd",
  "flutter.exe",
]);
const RESULT_VALUES = new Set(["success", "failure", "error"]);

export const FLUTTER_JSON_REPORTER_LINE_LIMIT = 1024 * 1024;

function measured(value) {
  return Object.freeze({ status: "measured", value });
}

function unavailable(reason) {
  return Object.freeze({ status: "unavailable", reason });
}

function normalizedScript(value) {
  return String(value || "").replaceAll("\\", "/");
}

function commandParts(command) {
  if (!command || command.program !== "node" || !Array.isArray(command.args)) {
    return null;
  }
  if (normalizedScript(command.args[0]) !== TOOLCHAIN_RUNNER) return null;
  const separator = command.args.indexOf("--");
  if (separator < 0) return null;
  const executable = path.basename(String(command.args[separator + 1] || "")).toLowerCase();
  const flutterArgs = command.args.slice(separator + 2);
  if (!FLUTTER_EXECUTABLES.has(executable) || flutterArgs[0] !== "test") return null;
  return { separator, flutterArgs };
}

export function isCompatibleFlutterTestCommand(command) {
  return commandParts(command) !== null;
}

function withoutValueOption(args, longName, shortName) {
  const output = [];
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (value === longName || value === shortName) {
      index += 1;
      continue;
    }
    if (value.startsWith(`${longName}=`) ||
        (shortName && (value.startsWith(`${shortName}=`) ||
          (value.startsWith(shortName) && value.length > shortName.length)))) {
      continue;
    }
    output.push(value);
  }
  return output;
}

export function boundedFlutterTestConcurrency(value, {
  availableParallelism = os.availableParallelism(),
} = {}) {
  const requested = Number(value);
  const available = Number(availableParallelism);
  if (!Number.isFinite(requested) || requested < 1) {
    throw new Error("Flutter test concurrency must be a positive finite number");
  }
  if (!Number.isFinite(available) || available < 1) {
    throw new Error("Available parallelism must be a positive finite number");
  }
  return Math.max(1, Math.min(Math.floor(requested), Math.floor(available)));
}

export function decorateFlutterTestCommand(command, {
  concurrency,
  availableParallelism = os.availableParallelism(),
} = {}) {
  const parts = commandParts(command);
  if (!parts) return Object.freeze({ supported: false, command });

  const boundedConcurrency = boundedFlutterTestConcurrency(concurrency, {
    availableParallelism,
  });
  let flutterArgs = withoutValueOption(parts.flutterArgs, "--reporter", "-r");
  flutterArgs = withoutValueOption(flutterArgs, "--concurrency", "-j");
  flutterArgs = [
    ...flutterArgs,
    "--reporter=json",
    `--concurrency=${boundedConcurrency}`,
  ];

  return Object.freeze({
    supported: true,
    concurrency: boundedConcurrency,
    command: Object.freeze({
      ...command,
      args: Object.freeze([
        ...command.args.slice(0, parts.separator + 2),
        ...flutterArgs,
      ]),
    }),
  });
}

function validNonNegativeInteger(value) {
  return Number.isInteger(value) && value >= 0;
}

function validEvent(value) {
  return value &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    typeof value.type === "string" &&
    validNonNegativeInteger(value.time);
}

function unavailableAggregate(reason) {
  return Object.freeze({
    suiteCount: unavailable(reason),
    testCount: unavailable(reason),
    passedCount: unavailable(reason),
    failedCount: unavailable(reason),
    skippedCount: unavailable(reason),
    totalTestDurationMs: unavailable(reason),
    longestTestDurationMs: unavailable(reason),
    directCpuMs: unavailable("flutter_test_reporter_metric_unavailable"),
    descendantCpuMs: unavailable("flutter_test_reporter_metric_unavailable"),
    peakResidentBytes: unavailable("flutter_test_reporter_metric_unavailable"),
  });
}

export function createFlutterJsonStatsCollector({
  lineLimit = FLUTTER_JSON_REPORTER_LINE_LIMIT,
} = {}) {
  if (!Number.isInteger(lineLimit) || lineLimit < 1) {
    throw new Error("Flutter JSON reporter line limit must be a positive integer");
  }

  let pending = "";
  let discardingOversizedLine = false;
  let sawStart = false;
  let sawDone = false;
  const suiteIds = new Set();
  const testStarts = new Map();
  const completedTests = new Set();
  let testCount = 0;
  let passedCount = 0;
  let failedCount = 0;
  let skippedCount = 0;
  let durationCount = 0;
  let totalTestDurationMs = 0;
  let longestTestDurationMs = 0;

  const accept = (event) => {
    if (!validEvent(event)) return;
    if (event.type === "start") {
      if (typeof event.protocolVersion !== "string" ||
          !/^0\.1\.\d+$/u.test(event.protocolVersion)) return;
      sawStart = true;
      return;
    }
    if (!sawStart) return;
    if (event.type === "suite") {
      if (validNonNegativeInteger(event.suite?.id)) suiteIds.add(event.suite.id);
      return;
    }
    if (event.type === "testStart") {
      if (validNonNegativeInteger(event.test?.id) && !testStarts.has(event.test.id)) {
        testStarts.set(event.test.id, event.time);
      }
      return;
    }
    if (event.type === "testDone") {
      if (!validNonNegativeInteger(event.testID) ||
          typeof event.hidden !== "boolean" ||
          typeof event.skipped !== "boolean" ||
          !RESULT_VALUES.has(event.result) ||
          completedTests.has(event.testID)) return;
      completedTests.add(event.testID);
      const startedAt = testStarts.get(event.testID);
      testStarts.delete(event.testID);
      if (event.hidden) return;
      testCount += 1;
      if (event.skipped) skippedCount += 1;
      else if (event.result === "success") passedCount += 1;
      else failedCount += 1;
      if (validNonNegativeInteger(startedAt) && event.time >= startedAt) {
        const duration = event.time - startedAt;
        durationCount += 1;
        totalTestDurationMs += duration;
        longestTestDurationMs = Math.max(longestTestDurationMs, duration);
      }
      return;
    }
    if (event.type === "done" && typeof event.success === "boolean") {
      sawDone = true;
    }
  };

  const acceptLine = (line) => {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) return;
    try {
      accept(JSON.parse(trimmed));
    } catch {
      // Wrapper chatter and malformed JSON are not reporter evidence.
    }
  };

  const push = (chunk) => {
    const text = Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk ?? "");
    const fragments = text.split("\n");
    for (const [index, fragment] of fragments.entries()) {
      const terminated = index < fragments.length - 1;
      if (discardingOversizedLine) {
        if (terminated) discardingOversizedLine = false;
        continue;
      }
      const candidate = pending + fragment;
      if (candidate.length > lineLimit) {
        pending = "";
        discardingOversizedLine = !terminated;
        continue;
      }
      pending = candidate;
      if (terminated) {
        acceptLine(pending.endsWith("\r") ? pending.slice(0, -1) : pending);
        pending = "";
      }
    }
  };

  const finish = () => {
    if (pending && !discardingOversizedLine) acceptLine(pending);
    pending = "";
    if (!sawStart || !sawDone) return unavailableAggregate("flutter_json_reporter_incomplete");
    const durationsComplete = durationCount === testCount;
    return Object.freeze({
      suiteCount: measured(suiteIds.size),
      testCount: measured(testCount),
      passedCount: measured(passedCount),
      failedCount: measured(failedCount),
      skippedCount: measured(skippedCount),
      totalTestDurationMs: durationsComplete
        ? measured(totalTestDurationMs)
        : unavailable("flutter_test_duration_incomplete"),
      longestTestDurationMs: durationsComplete
        ? measured(longestTestDurationMs)
        : unavailable("flutter_test_duration_incomplete"),
      directCpuMs: unavailable("flutter_test_reporter_metric_unavailable"),
      descendantCpuMs: unavailable("flutter_test_reporter_metric_unavailable"),
      peakResidentBytes: unavailable("flutter_test_reporter_metric_unavailable"),
    });
  };

  return Object.freeze({ push, finish });
}
