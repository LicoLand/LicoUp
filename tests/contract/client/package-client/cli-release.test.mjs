import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

import {
  conversationProtocolDigest,
  conversationProtocolVersion,
} from "../../../../apps/desktop/scripts/package-client/cli-release/conversation-protocol-digest.mjs";
import {
  DYNAMIC_TOKEN,
  extractInvokedCliCommands,
  invocationPatterns,
  unadmittedInvocations,
} from "../../../../apps/desktop/scripts/package-client/cli-release/invoked-commands.mjs";
import {
  CLI_RELEASE_PIN_REF,
  cliReleaseArchiveUrl,
  cliReleaseTargetFor,
  loadCliReleasePin,
  validateCliReleasePin,
} from "../../../../apps/desktop/scripts/package-client/cli-release/release-pin.mjs";
import {
  CLI_RELEASE_ARCHIVE_ENV,
  stageCliRelease,
} from "../../../../apps/desktop/scripts/package-client/cli-release/stage.mjs";
import { stageNativeSidecars } from "../../../../apps/desktop/scripts/package-client/build/native.mjs";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../..",
);
const target = "aarch64-apple-darwin";

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function tarGz(entries) {
  const blocks = [];
  for (const [name, content, type = "0"] of entries) {
    const body = Buffer.from(content);
    const header = Buffer.alloc(512);
    header.write(name, 0, "utf8");
    header.write("0000755\0", 100);
    header.write("0000000\0", 108);
    header.write("0000000\0", 116);
    header.write(`${body.length.toString(8).padStart(11, "0")}\0`, 124);
    header.write("00000000000\0", 136);
    header.write("        ", 148);
    header.write(type, 156);
    header.write("ustar\0", 257);
    header.write("00", 263);
    let checksum = 0;
    for (const byte of header) checksum += byte;
    header.write(`${checksum.toString(8).padStart(6, "0")}\0 `, 148);
    blocks.push(header, body, Buffer.alloc((512 - (body.length % 512)) % 512));
  }
  blocks.push(Buffer.alloc(1024));
  return gzipSync(Buffer.concat(blocks));
}

/** A synthetic contract that admits every command this checkout invokes. */
function admittingContract(overrides = {}) {
  const commands = extractInvokedCliCommands(repoRoot).map((pattern) => {
    const literal = [];
    for (const token of pattern) {
      if (token === DYNAMIC_TOKEN) break;
      literal.push(token);
    }
    return {
      path: literal,
      requiredPositionals: pattern.slice(literal.length).map((_, index) => ({
        name: `argument-${index}`,
        kind: "text",
      })),
    };
  });
  return {
    cliVersion: "0.3.0",
    target,
    stdioProtocol: conversationProtocolVersion(repoRoot),
    conversationProtocolDigest: conversationProtocolDigest(repoRoot),
    commands,
    ...overrides,
  };
}

function releaseArchive(contract, { prefix = "" } = {}) {
  return tarGz([
    [`${prefix}licoup`, "synthetic-licoup\n"],
    [`${prefix}contract.json`, JSON.stringify(contract)],
  ]);
}

function withTemp(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "lico-cli-release-"));
  try {
    return run(root);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

function pinFor(digest) {
  return validateCliReleasePin({
    repo: "LicoLand/LicoUp-CLI",
    version: "0.3.0",
    sha256: { [target]: digest },
  });
}

test("conversation protocol digest hashes sorted path and file digest lines", () => {
  withTemp((root) => {
    const schemaRoot = path.join(root, "schemas", "conversation_protocol");
    fs.mkdirSync(path.join(schemaRoot, "nested"), { recursive: true });
    fs.writeFileSync(path.join(schemaRoot, "manifest.json"), "{\"version\":1}\n");
    fs.writeFileSync(path.join(schemaRoot, "nested", "b.json"), "{}\n");
    fs.writeFileSync(path.join(schemaRoot, "A.json"), "[]\n");
    // Fixed value, cross-checked with `shasum` over the same three files, so
    // LicoUp-CLI can assert the identical digest for the identical fixture.
    assert.equal(
      conversationProtocolDigest(root),
      "a48a410557d7a7601719de70af74c097a5e33b4da7cef278c9b29edd48683220",
    );
  });
  assert.match(conversationProtocolDigest(repoRoot), /^[a-f0-9]{64}$/u);
  assert.equal(conversationProtocolVersion(repoRoot), "licoup.stdio.v1");
});

test("the tracked pin names one LicoUp-CLI release and its per-target digests", () => {
  const pin = loadCliReleasePin(path.join(repoRoot, CLI_RELEASE_PIN_REF));
  assert.equal(pin.repo, "LicoLand/LicoUp-CLI");
  assert.match(pin.version, /^\d+\.\d+\.\d+/u);
  assert.ok(Object.hasOwn(pin.sha256, target));
  assert.equal(
    cliReleaseArchiveUrl(pin, target),
    `https://github.com/LicoLand/LicoUp-CLI/releases/download/v${pin.version}/` +
      `licoup-${pin.version}-${target}.tar.gz`,
  );
  for (const invalid of [
    { repo: "LicoLand/LicoUp-CLI", version: "0.3.0", sha256: { [target]: "abc" } },
    { repo: "LicoLand/LicoUp-CLI", version: "next", sha256: { [target]: null } },
    { repo: "LicoLand/LicoUp-CLI", version: "0.3.0", sha256: {} },
    { repo: "LicoLand/LicoUp-CLI", version: "0.3.0", sha256: { [target]: null }, extra: 1 },
  ]) {
    assert.throws(() => validateCliReleasePin(invalid), /cli_release_pin_invalid/u);
  }
  assert.equal(cliReleaseTargetFor("macos", "arm64"), target);
  assert.throws(() => cliReleaseTargetFor("macos", "x64"), /cli_release_target_unsupported/u);
});

test("invoked commands are derived from Desktop source, not a hand-kept list", () => {
  const invoked = extractInvokedCliCommands(repoRoot).map((pattern) => pattern.join(" "));
  for (const expected of [
    "rpc stdio",
    "rpc conversation",
    "rpc data-home",
    "conversations stream",
    "state admit *",
    "package enable * * *",
    "package disable * * *",
    "devices status",
    "devices enroll",
    "devices pair offer",
    "devices pair claim",
    "devices pair cancel",
    "devices unpair",
    "devices message send",
    "devices message results",
    "collaboration runner-trust import",
    "collaboration runner-trust remove",
  ]) {
    assert.ok(invoked.includes(expected), expected);
  }
  for (const retired of invoked.filter((command) =>
    /^(?:mobile|secure-mesh|catalog) /u.test(command) ||
    command.startsWith("adapter codex plugin"))) {
    assert.fail(`retired CLI command is still invoked: ${retired}`);
  }

  assert.deepEqual(invocationPatterns(`
    // runCli(['commented', 'out']);
    final keywords = ['mobile', 'relay'];
    final args = <String>['update', 'status', '--json'];
    runner.runCli(['adapter', agentId, flag ? 'install' : 'uninstall']);
    startProcess(cli, dedicated ? const ['rpc', 'data-home'] : const ['rpc', 'stdio'], env);
  `), [
    ["update", "status"],
    ["adapter", DYNAMIC_TOKEN, "install"],
    ["adapter", DYNAMIC_TOKEN, "uninstall"],
    ["rpc", "data-home"],
    ["rpc", "stdio"],
  ]);
});

test("a contract admits invocations by path prefix and positional arity", () => {
  const commands = [
    { path: ["state", "admit"], requiredPositionals: [{ name: "root", kind: "text" }] },
    { path: ["adapter", "codex", "install"] },
  ];
  assert.deepEqual(unadmittedInvocations([
    ["state", "admit", DYNAMIC_TOKEN],
    ["adapter", DYNAMIC_TOKEN, "install"],
    ["state", "admit", DYNAMIC_TOKEN, DYNAMIC_TOKEN],
    ["devices", "status"],
  ], commands), [
    ["state", "admit", DYNAMIC_TOKEN, DYNAMIC_TOKEN],
    ["devices", "status"],
  ]);
});

test("a local archive stages the licoup binary and reports the skipped digest pin", () => {
  withTemp((root) => {
    const archive = path.join(root, "local.tar.gz");
    fs.writeFileSync(archive, releaseArchive(admittingContract(), { prefix: "./" }));
    const staging = path.join(root, "staging");
    const release = stageCliRelease({
      platform: "macos",
      hostArch: "arm64",
      stagingDirectory: staging,
      environment: { [CLI_RELEASE_ARCHIVE_ENV]: archive },
      repositoryRoot: repoRoot,
      pin: pinFor(null),
      download: () => assert.fail("a local archive never downloads"),
    });
    assert.deepEqual(release, {
      cliVersion: "0.3.0",
      target,
      source: "local-archive",
      digestPinVerified: false,
      members: ["licoup"],
    });
    assert.equal(
      fs.readFileSync(path.join(staging, "licoup"), "utf8"),
      "synthetic-licoup\n",
    );
    assert.equal(fs.statSync(path.join(staging, "licoup")).mode & 0o777, 0o755);
  });
});

test("release-mode packaging refuses the local archive override", () => {
  withTemp((root) => {
    const archive = path.join(root, "local.tar.gz");
    fs.writeFileSync(archive, releaseArchive(admittingContract()));
    const staging = path.join(root, "staging");
    assert.throws(() => stageCliRelease({
      platform: "macos",
      hostArch: "arm64",
      mode: "release",
      stagingDirectory: staging,
      environment: { [CLI_RELEASE_ARCHIVE_ENV]: archive },
      repositoryRoot: repoRoot,
      pin: pinFor(null),
      download: () => assert.fail("a refused override never downloads"),
    }), /cli_release_local_archive_release_refused/u);
    assert.equal(fs.existsSync(staging), false);
    for (const mode of ["debug", "profile"]) {
      assert.equal(stageCliRelease({
        platform: "macos",
        hostArch: "arm64",
        mode,
        stagingDirectory: staging,
        environment: { [CLI_RELEASE_ARCHIVE_ENV]: archive },
        repositoryRoot: repoRoot,
        pin: pinFor(null),
      }).source, "local-archive");
    }
  });
});

test("the pinned release downloads once, verifies its digest, and caches it", () => {
  withTemp((root) => {
    fs.cpSync(path.join(repoRoot, "schemas", "conversation_protocol"),
      path.join(root, "schemas", "conversation_protocol"), { recursive: true });
    const sourceRoot = path.join(root, "apps", "desktop", "lib");
    fs.mkdirSync(sourceRoot, { recursive: true });
    fs.writeFileSync(path.join(sourceRoot, "probe.dart"),
      "void probe(r) => r.runCli(['devices', 'status']);\n");
    const contract = {
      cliVersion: "0.3.0",
      target,
      stdioProtocol: conversationProtocolVersion(root),
      conversationProtocolDigest: conversationProtocolDigest(root),
      commands: [{ path: ["devices", "status"] }],
    };
    const archive = releaseArchive(contract);
    const downloads = [];
    const download = (url, destination) => {
      downloads.push(url);
      fs.writeFileSync(destination, archive);
    };
    const stage = (pin) => stageCliRelease({
      platform: "macos",
      hostArch: "arm64",
      stagingDirectory: path.join(root, "staging"),
      environment: {},
      repositoryRoot: root,
      pin,
      download,
    });
    assert.equal(stage(pinFor(sha256(archive))).digestPinVerified, true);
    assert.equal(stage(pinFor(sha256(archive))).source, "pinned-release");
    assert.equal(downloads.length, 1);

    assert.throws(() => stage(pinFor("0".repeat(64))), /cli_release_digest_mismatch/u);
    assert.throws(() => stage(pinFor(null)), /cli_release_digest_unpinned/u);
    assert.throws(
      () => stage(validateCliReleasePin({
        repo: "LicoLand/LicoUp-CLI",
        version: "0.3.0",
        sha256: { "x86_64-unknown-linux-gnu": null },
      })),
      /cli_release_target_unpinned/u,
    );
  });
});

test("contract mismatches fail closed before any binary is staged", () => {
  const cases = [
    [{ conversationProtocolDigest: "0".repeat(64) }, /cli_release_conversation_protocol_mismatch/u],
    [{ stdioProtocol: "licoup.stdio.v0" }, /cli_release_stdio_protocol_mismatch/u],
    [{ cliVersion: "0.2.9" }, /cli_release_version_mismatch/u],
    [{ target: "x86_64-unknown-linux-gnu" }, /cli_release_target_mismatch/u],
    [{ commands: [{ path: ["rpc", "stdio"] }] }, /cli_release_command_missing/u],
    [{ commands: ["devices status"] }, /cli_release_contract_invalid/u],
  ];
  for (const [override, expected] of cases) {
    withTemp((root) => {
      const archive = path.join(root, "local.tar.gz");
      fs.writeFileSync(archive, releaseArchive(admittingContract(override)));
      const staging = path.join(root, "staging");
      assert.throws(() => stageCliRelease({
        platform: "macos",
        hostArch: "arm64",
        stagingDirectory: staging,
        environment: { [CLI_RELEASE_ARCHIVE_ENV]: archive },
        repositoryRoot: repoRoot,
        pin: pinFor(null),
      }), expected);
      assert.equal(fs.existsSync(staging), false);
    });
  }
  try {
    withTemp((root) => {
      const archive = path.join(root, "local.tar.gz");
      fs.writeFileSync(archive, releaseArchive(admittingContract({
        commands: [{ path: ["rpc", "stdio"] }],
      })));
      stageCliRelease({
        platform: "macos",
        hostArch: "arm64",
        stagingDirectory: path.join(root, "staging"),
        environment: { [CLI_RELEASE_ARCHIVE_ENV]: archive },
        repositoryRoot: repoRoot,
        pin: pinFor(null),
      });
    });
    assert.fail("expected a missing-command failure");
  } catch (error) {
    assert.ok(error.details.missingCommands.includes("devices status"));
  }
});

test("archives that omit, repeat or link a release member are refused", () => {
  const contract = JSON.stringify(admittingContract());
  for (const entries of [
    [["licoup", "x"]],
    [["contract.json", contract]],
    [["licoup", "x"], ["licoup", "y"], ["contract.json", contract]],
    [["licoup", "", "2"], ["contract.json", contract]],
  ]) {
    withTemp((root) => {
      const archive = path.join(root, "local.tar.gz");
      fs.writeFileSync(archive, tarGz(entries));
      assert.throws(() => stageCliRelease({
        platform: "macos",
        hostArch: "arm64",
        stagingDirectory: path.join(root, "staging"),
        environment: { [CLI_RELEASE_ARCHIVE_ENV]: archive },
        repositoryRoot: repoRoot,
        pin: pinFor(null),
      }), /cli_release_archive_(?:invalid|member_missing)/u);
    });
  }
});

test("packaging stages sidecars only when it builds native sidecars", () => {
  withTemp((root) => {
    const environment = { LICO_CLI_ARTIFACTS_DIR: root };
    const staged = [];
    const stage = ({ stagingDirectory, mode }) => {
      assert.equal(mode, "release");
      staged.push(stagingDirectory);
      fs.writeFileSync(path.join(stagingDirectory, "licoup"), "x");
      return { source: "pinned-release" };
    };
    const options = { mode: "release", platform: "macos" };
    assert.deepEqual(
      stageNativeSidecars([{ cargoBin: "licoup" }], options, { environment, stage }),
      { source: "pinned-release" },
    );
    assert.deepEqual(staged, [root]);
    assert.throws(
      () => stageNativeSidecars([{ cargoBin: "lico-extra" }], options, { environment, stage }),
      /native_sidecar_artifacts_missing/u,
    );
    assert.equal(stageNativeSidecars([{ cargoBin: "licoup" }],
      { ...options, dryRun: true }, { environment, stage: () => assert.fail() }), null);
    assert.equal(stageNativeSidecars([{ cargoBin: "licoup" }],
      { ...options, skipNativeBuild: true }, { environment, stage: () => assert.fail() }), null);
  });
});
