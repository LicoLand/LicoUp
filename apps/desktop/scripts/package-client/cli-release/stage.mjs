import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";

import { packageClientRuntime, packageFailure } from "../cli-policy.mjs";
import {
  conversationProtocolDigest,
  conversationProtocolVersion,
} from "./conversation-protocol-digest.mjs";
import {
  extractInvokedCliCommands,
  unadmittedInvocations,
} from "./invoked-commands.mjs";
import { readArchiveMembers } from "./release-archive.mjs";
import {
  CLI_RELEASE_BINARIES,
  CLI_RELEASE_PIN_REF,
  cliReleaseArchiveName,
  cliReleaseArchiveUrl,
  cliReleaseTargetFor,
  loadCliReleasePin,
} from "./release-pin.mjs";

/** Environment variable naming an explicit local CLI release archive. */
export const CLI_RELEASE_ARCHIVE_ENV = "LICO_CLI_RELEASE_ARCHIVE";

const CONTRACT_MEMBER = "contract.json";

/**
 * Stages the pinned LicoUp-CLI release into the sidecar staging directory.
 *
 * The archive comes from the pinned GitHub Release (verified against the
 * pinned SHA-256 and cached under `build/cli-release/`) or, for development,
 * from the explicit local archive named by [CLI_RELEASE_ARCHIVE_ENV], which
 * skips only the digest pin and is refused in release mode. Either source
 * must carry a `contract.json` whose version, target, stdio protocol and
 * conversation protocol digest match this checkout and whose command catalog
 * admits every CLI command the Desktop invokes. Only then are the release
 * binaries written into [stagingDirectory].
 */
export function stageCliRelease({
  platform,
  stagingDirectory,
  mode = "debug",
  environment = process.env,
  hostArch = process.arch,
  repositoryRoot = packageClientRuntime.workspaceRoot,
  pin = loadCliReleasePin(path.join(repositoryRoot, ...CLI_RELEASE_PIN_REF.split("/"))),
  download = downloadArchive,
} = {}) {
  const target = cliReleaseTargetFor(platform, hostArch);
  const localArchive = String(environment[CLI_RELEASE_ARCHIVE_ENV] || "").trim();
  if (localArchive && mode === "release") {
    packageFailure("cli_release_local_archive_release_refused");
  }
  const archive = localArchive
    ? readLocalArchive(localArchive)
    : pinnedArchive({ pin, target, repositoryRoot, download });
  const members = readArchiveMembers(archive, [
    ...CLI_RELEASE_BINARIES.map((name) => `${name}${binarySuffix(platform)}`),
    CONTRACT_MEMBER,
  ]);
  const contract = verifyCliReleaseContract(
    parseContract(members.get(CONTRACT_MEMBER)),
    { pin, target, repositoryRoot },
  );
  mkdirSync(stagingDirectory, { recursive: true });
  for (const [name, bytes] of members) {
    const staged = path.join(stagingDirectory, name);
    const partial = `${staged}.partial`;
    writeFileSync(partial, bytes, { mode: 0o755 });
    if (platform !== "windows") chmodSync(partial, name === CONTRACT_MEMBER ? 0o644 : 0o755);
    renameSync(partial, staged);
  }
  return Object.freeze({
    cliVersion: contract.cliVersion,
    target,
    source: localArchive ? "local-archive" : "pinned-release",
    digestPinVerified: !localArchive,
    members: Object.freeze([...CLI_RELEASE_BINARIES]),
  });
}

/**
 * Checks a release contract against this checkout; every mismatch fails
 * closed with its own code. Missing commands are reported by name.
 */
export function verifyCliReleaseContract(contract, { pin, target, repositoryRoot }) {
  if (contract.cliVersion !== pin.version) {
    packageFailure("cli_release_version_mismatch");
  }
  if (contract.target !== target) packageFailure("cli_release_target_mismatch");
  if (contract.stdioProtocol !== conversationProtocolVersion(repositoryRoot)) {
    packageFailure("cli_release_stdio_protocol_mismatch");
  }
  if (contract.conversationProtocolDigest !==
      conversationProtocolDigest(repositoryRoot)) {
    packageFailure("cli_release_conversation_protocol_mismatch");
  }
  const missing = unadmittedInvocations(
    extractInvokedCliCommands(repositoryRoot),
    contract.commands,
  );
  if (missing.length > 0) {
    packageFailure("cli_release_command_missing", {
      missingCommands: missing.map((pattern) => pattern.join(" ")),
    });
  }
  return contract;
}

function parseContract(bytes) {
  let contract;
  try {
    contract = JSON.parse(bytes.toString("utf8"));
  } catch {
    packageFailure("cli_release_contract_invalid");
  }
  const validCommands = Array.isArray(contract?.commands) &&
    contract.commands.every((entry) =>
      Array.isArray(entry?.path) && entry.path.length > 0 &&
      entry.path.every((token) => typeof token === "string" && token.length > 0));
  if (!contract || typeof contract !== "object" ||
      typeof contract.cliVersion !== "string" ||
      typeof contract.target !== "string" ||
      typeof contract.stdioProtocol !== "string" ||
      !/^[a-f0-9]{64}$/u.test(String(contract.conversationProtocolDigest)) ||
      !validCommands) {
    packageFailure("cli_release_contract_invalid");
  }
  return contract;
}

function readLocalArchive(archivePath) {
  try {
    return readFileSync(path.resolve(archivePath));
  } catch {
    packageFailure("cli_release_local_archive_unreadable");
  }
}

/**
 * The pinned archive bytes. A verified download is cached by version, so an
 * unchanged pin never downloads the same release twice.
 */
function pinnedArchive({ pin, target, repositoryRoot, download }) {
  const expected = pin.sha256[target];
  if (expected === undefined) packageFailure("cli_release_target_unpinned");
  if (expected === null) packageFailure("cli_release_digest_unpinned");
  const cached = path.join(
    repositoryRoot,
    "build",
    "cli-release",
    `v${pin.version}`,
    cliReleaseArchiveName(pin.version, target),
  );
  if (existsSync(cached)) {
    const bytes = readFileSync(cached);
    if (sha256(bytes) === expected) return bytes;
    rmSync(cached, { force: true });
  }
  mkdirSync(path.dirname(cached), { recursive: true });
  const partial = `${cached}.partial`;
  rmSync(partial, { force: true });
  download(cliReleaseArchiveUrl(pin, target), partial);
  const bytes = readFileSync(partial);
  if (sha256(bytes) !== expected) {
    rmSync(partial, { force: true });
    packageFailure("cli_release_digest_mismatch");
  }
  renameSync(partial, cached);
  return bytes;
}

function downloadArchive(url, destination) {
  const result = spawnSync(
    "curl",
    ["--fail", "--location", "--silent", "--show-error", "--output", destination, url],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  if (result.error || result.status !== 0) {
    rmSync(destination, { force: true });
    packageFailure("cli_release_download_failed");
  }
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function binarySuffix(platform) {
  return platform === "windows" ? ".exe" : "";
}
