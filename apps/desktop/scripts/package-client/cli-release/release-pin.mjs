import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

import { packageClientRuntime, packageFailure } from "../cli-policy.mjs";

/** Repository-relative path of the tracked CLI release pin. */
export const CLI_RELEASE_PIN_REF = "tools/licoup-cli-release.json";

/**
 * The one binary every CLI release archive carries: `licoup` provides the
 * client CLI, the gateway service, the Lico Agent runtime and the migration
 * tool through its process entries.
 */
export const CLI_RELEASE_BINARIES = Object.freeze(["licoup"]);

/** The staged binary that provides `licoup migrate`, never bundled as a
 * separate migration-tool asset. */
export const CLI_RELEASE_MIGRATION_TOOL = "licoup";

const REPO_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/u;
const VERSION_PATTERN = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u;
const DIGEST_PATTERN = /^[a-f0-9]{64}$/u;
const TARGET_PATTERN = /^[a-z0-9_]+(?:-[a-z0-9_]+){2,3}$/u;

/**
 * The Rust target triple of the CLI release one packaging run consumes.
 *
 * The Desktop packages each platform on its own build host, so the host
 * architecture selects the triple. A host without a mapping has no CLI
 * release to consume.
 */
export function cliReleaseTargetFor(platform, hostArch = process.arch) {
  const target = {
    "macos:arm64": "aarch64-apple-darwin",
    "linux:arm64": "aarch64-unknown-linux-gnu",
    "linux:x64": "x86_64-unknown-linux-gnu",
    "windows:x64": "x86_64-pc-windows-msvc",
  }[`${platform}:${hostArch}`];
  if (!target) packageFailure("cli_release_target_unsupported");
  return target;
}

/** Reads and validates the tracked pin; an invalid pin fails closed. */
export function loadCliReleasePin(
  pinPath = path.join(packageClientRuntime.workspaceRoot, CLI_RELEASE_PIN_REF),
) {
  let pin;
  try {
    pin = JSON.parse(readFileSync(pinPath, "utf8"));
  } catch {
    packageFailure("cli_release_pin_invalid");
  }
  return validateCliReleasePin(pin);
}

/**
 * A pin names one CLI release (`repo`, `version`) and the SHA-256 of each
 * target archive. `null` marks a target whose digest is not pinned yet: the
 * pinned download refuses it, and only the local archive override can stage it.
 */
export function validateCliReleasePin(pin) {
  const keys = pin && typeof pin === "object" && !Array.isArray(pin)
    ? Object.keys(pin).sort().join(",")
    : "";
  if (keys !== "repo,sha256,version" ||
      !REPO_PATTERN.test(String(pin.repo)) ||
      !VERSION_PATTERN.test(String(pin.version)) ||
      !pin.sha256 || typeof pin.sha256 !== "object" || Array.isArray(pin.sha256) ||
      Object.keys(pin.sha256).length === 0) {
    packageFailure("cli_release_pin_invalid");
  }
  for (const [target, digest] of Object.entries(pin.sha256)) {
    if (!TARGET_PATTERN.test(target) ||
        (digest !== null && !DIGEST_PATTERN.test(String(digest)))) {
      packageFailure("cli_release_pin_invalid");
    }
  }
  return Object.freeze({
    repo: pin.repo,
    version: pin.version,
    sha256: Object.freeze({ ...pin.sha256 }),
  });
}

export function cliReleaseArchiveName(version, target) {
  return `licoup-${version}-${target}.tar.gz`;
}

/** The GitHub Release download location of one pinned archive. */
export function cliReleaseArchiveUrl(pin, target) {
  return `https://github.com/${pin.repo}/releases/download/v${pin.version}/` +
    cliReleaseArchiveName(pin.version, target);
}
