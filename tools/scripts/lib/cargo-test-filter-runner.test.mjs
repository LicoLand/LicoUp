import assert from "node:assert/strict";
import test from "node:test";
import { cargoTestExecutionCount } from "./cargo-test-filter-runner.mjs";

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
