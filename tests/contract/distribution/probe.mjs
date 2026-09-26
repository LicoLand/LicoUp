import { spawnSync } from "node:child_process";
import path from "node:path";

import { REPOSITORY_ROOT } from "./fixtures.mjs";

/**
 * Runs the product's real closure implementation through the minimal Rust probe
 * beside this file, so the differential against `install_closure` executes
 * product code instead of comparing source text.
 *
 * The probe is its own Cargo workspace (it must not become a product member or
 * touch the root manifests). Its build output lives under the ignored `cache/`
 * directory, so the repository tree stays clean.
 *
 * A machine without `cargo` records the differential as not run with an explicit
 * skip; a machine with `cargo` runs it and a failure is a failure, never a skip.
 */

export const PROBE_MANIFEST = "tests/contract/distribution/rust-probe/Cargo.toml";
export const PROBE_TARGET_DIRECTORY = "cache/u10-distribution-probe-target";
export const PROBE_TIMEOUT_MS = 1_200_000;

export function cargoAvailable() {
  const probe = spawnSync("cargo", ["--version"], { encoding: "utf8" });
  return !probe.error && probe.status === 0;
}

export function runProbe(t, args, { timeout = PROBE_TIMEOUT_MS } = {}) {
  if (!cargoAvailable()) {
    t.skip("cargo is not available on this machine; the product resolver could not be executed");
    return null;
  }
  const result = spawnSync("cargo", [
    "run", "--quiet", "--offline", "--locked",
    "--manifest-path", PROBE_MANIFEST,
    "--", ...args,
  ], {
    cwd: REPOSITORY_ROOT,
    encoding: "utf8",
    timeout,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, CARGO_TARGET_DIR: path.join(REPOSITORY_ROOT, PROBE_TARGET_DIRECTORY) },
  });
  if (result.error) {
    throw new Error(`the product probe could not run: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const diagnostics = (result.stderr || result.stdout).trim().split("\n").slice(-3).join(" ");
    throw new Error(`the product probe failed with status ${result.status}: ${diagnostics}`);
  }
  return result.stdout.trim().split("\n").filter((line) => line.length > 0).map((line) => JSON.parse(line));
}

/**
 * The comparison both sides must satisfy: a pass reports the selected set and
 * the declined optional set; a refusal reports the code, the offending field,
 * the package and the dependent when the product publishes one. Anything else
 * both sides carry is not compared, and a field that either side omits compares
 * as null.
 */
export function decisionShape(decision) {
  if (decision.ok) {
    return {
      ok: true,
      selected: [...decision.selected].sort(),
      declined_optional: [...decision.declined_optional].sort(),
    };
  }
  return {
    ok: false,
    code: decision.code,
    package: decision.package ?? null,
    required_by: decision.required_by ?? null,
    field: decision.field ?? null,
  };
}

export function decisionsAgree(planDecision, productDecision) {
  const plan = JSON.stringify(decisionShape(planDecision));
  const product = JSON.stringify(decisionShape(productDecision));
  return { agree: plan === product, plan, product };
}
