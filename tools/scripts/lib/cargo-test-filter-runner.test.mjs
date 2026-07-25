import assert from "node:assert/strict";
import test from "node:test";
import {
  cargoFailureDiagnostic,
  cargoTestExecutionCount,
} from "./cargo-test-filter-runner.mjs";

test("cargo test filter execution count rejects zero-match output", () => {
  const output = [
    "running 0 tests",
    "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 12 filtered out"
  ].join("\n");
  assert.equal(cargoTestExecutionCount(output), 0);
});

test("cargo test filter execution count sums executed tests across harnesses", () => {
  const output = [
    "test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 20 filtered out",
    "test result: FAILED. 2 passed; 1 failed; 1 ignored; 0 measured; 0 filtered out"
  ].join("\n");
  assert.equal(cargoTestExecutionCount(output), 4);
});

test("cargo failure diagnostic keeps only redacted summary lines", () => {
  const unixPath = ["", ["ho", "me"].join(""), "runner", "work", "example", "src", "main.rs"].join("/");
  const windowsSeparator = String.fromCharCode(92);
  const windowsPath = ["C", ["", "runner", "target"].join(windowsSeparator)].join(":");
  const output = [
    "Compiling example v1.0.0",
    `  --> ${unixPath}:12:4`,
    `error[E0432]: unresolved import at ${unixPath}`,
    "12 | let token = \"github_pat_sensitive\";",
    `Caused by: No space left on device at ${windowsPath}`,
  ].join("\n");
  assert.equal(
    cargoFailureDiagnostic(output, (value) => value),
    [
      "error[E0432]: unresolved import at <local-path>",
      "Caused by: No space left on device at <local-path>",
    ].join("\n"),
  );
});
