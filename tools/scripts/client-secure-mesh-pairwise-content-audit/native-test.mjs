import { runCargoTestFilter } from "../lib/cargo-test-filter-runner.mjs";
import { repoRoot } from "./constants.mjs";
import { sanitizeError } from "./privacy.mjs";

export function runNativeTest(filter) {
  return runCargoTestFilter({
    repoRoot,
    manifestPath: "crates/lico-client-native/Cargo.toml",
    filter,
    sanitizeError
  });
}
