import { runCargoTestFilterInOwningCrate } from "../lib/cargo-test-filter-runner.mjs";
import { repoRoot } from "./io.mjs";
import { sanitizeError } from "./privacy.mjs";

// A Secure Mesh module that moved into `licoup-secure-mesh` keeps its
// `#[cfg(test)]` items there, and a dependency's test items are not compiled into
// `licoup-native`'s test binary. Each filter therefore runs against the manifest
// that owns it instead of reporting green after executing zero tests; the donor
// manifest is tried first so a filter that never moved keeps its exact command.
const NATIVE_TEST_MANIFESTS = Object.freeze([
  "crates/licoup-native/Cargo.toml",
  "crates/licoup-secure-mesh/Cargo.toml"
]);

export function runNativeTest(filter) {
  return runCargoTestFilterInOwningCrate({
    repoRoot,
    manifestPaths: NATIVE_TEST_MANIFESTS,
    filter,
    sanitizeError
  });
}
