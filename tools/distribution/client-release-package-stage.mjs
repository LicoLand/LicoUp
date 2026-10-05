#!/usr/bin/env node

// Stages each declared package's compiled native entry into that package's own
// committed source directory, before `client-release-package-index.mjs build`
// packages the directory into the released payload.
//
// A declared native package keeps a committed staged entry so a checkout
// packages deterministically and the payload contract can be tested without a
// compiler. Only an authorized release replaces that entry with the program the
// package actually serves, and this tool is that replacement step: it builds
// through the client's own native-build owner and copies the built program over
// the staged entry.
//
// Subcommands:
//   plan     report every declared native entry, the artifact that fills it and
//            the bytes currently staged there
//   stage    build the entry and replace the staged entry with the program
//   verify   refuse unless every declared native entry is a compiled program for
//            the release target's platform
//
// The tool never signs, notarizes, publishes, installs or launches anything, and
// it reaches no network. Running `stage` writes inside the checkout: it is a
// release operation with its own authorization, never part of the client build.

import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  buildNativeSidecars,
  cargoTargetDir,
  binarySuffix,
} from "../../apps/desktop/scripts/package-client/build/native.mjs";
import {
  loadPackageSet,
  resolvePackageTarget,
  validatePackageManifest,
  validatePackageRelease,
} from "../scripts/client-release-package-index.mjs";
import {
  nativeConverterEntry,
  PACKAGE_PAYLOAD_DECLARATION_NAME,
  PACKAGE_PAYLOAD_LIMITS,
  PACKAGE_PAYLOAD_MANIFEST_NAME,
  readPackageSourceDirectory,
  sha256Hex,
  sha256File,
} from "../scripts/lib/client-release-package-payload.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const defaultPackageSetPath = "tools/client-release-package-set.json";
const defaultTargetId = "macos-direct-arm64";

/** Executable headers a compiled program carries on the target platform. */
const COMPILED_MAGIC = Object.freeze({
  macos: Object.freeze([
    Object.freeze({ bytes: [0xcf, 0xfa, 0xed, 0xfe], name: "mach-o-64-little-endian" }),
    Object.freeze({ bytes: [0xce, 0xfa, 0xed, 0xfe], name: "mach-o-32-little-endian" }),
    Object.freeze({ bytes: [0xca, 0xfe, 0xba, 0xbe], name: "mach-o-universal" }),
    Object.freeze({ bytes: [0xbe, 0xba, 0xfe, 0xca], name: "mach-o-universal-swapped" }),
  ]),
  linux: Object.freeze([
    Object.freeze({ bytes: [0x7f, 0x45, 0x4c, 0x46], name: "elf" }),
  ]),
  windows: Object.freeze([
    Object.freeze({ bytes: [0x4d, 0x5a], name: "pe" }),
  ]),
});

export class PackageStageError extends Error {
  constructor(code, details = null) {
    super(code);
    this.code = code;
    this.details = details;
  }
}

function fail(code, details = null) {
  throw new PackageStageError(code, details);
}

function readJsonFile(filePath, code) {
  let text;
  try {
    text = readFileSync(filePath, "utf8");
  } catch {
    fail(code, { file: path.basename(filePath) });
  }
  try {
    return JSON.parse(text);
  } catch {
    fail(code, { file: path.basename(filePath) });
  }
}

/**
 * The compiled program a declared native entry must carry.
 *
 * A package that declares a data or interpreter runtime stages nothing, and the
 * entry name is the binary target the client's native build produces: the
 * package's own declaration is the only place the name is written, so a renamed
 * entry cannot silently stage a different program.
 */
export function describeStagedEntry(declared, target, { readFile = readFileSync } = {}) {
  const declaration = validatePackageRelease(
    readJsonFile(path.join(declared.sourceRoot, PACKAGE_PAYLOAD_DECLARATION_NAME),
      "package_stage_declaration_missing"),
  );
  const manifest = validatePackageManifest(
    readJsonFile(path.join(declared.sourceRoot, PACKAGE_PAYLOAD_MANIFEST_NAME),
      "package_stage_manifest_missing"),
  );
  if (declaration.converter.kind !== "native-executable") return null;
  const entry = declaration.converter.entry;
  if (manifest.runtimeEntry !== entry) {
    fail("package_stage_entry_disagrees_with_manifest", { packageId: declared.packageId });
  }
  const binary = entry.slice(entry.lastIndexOf("/") + 1);
  const stagedPath = path.join(declared.sourceRoot, ...entry.split("/"));
  const builtPath = path.join(
    cargoTargetDir("release", target),
    `${binary}${binarySuffix(target.platform)}`,
  );
  const staged = existsSync(stagedPath)
    ? { bytes: statSync(stagedPath).size,
        sha256: `sha256:${sha256File(stagedPath)}` }
    : null;
  return Object.freeze({
    packageId: declared.packageId,
    source: declared.source,
    sourceRoot: declared.sourceRoot,
    packageVersion: declaration.packageVersion,
    entry,
    binary,
    stagedPath,
    builtPath,
    platform: target.platform,
    staged,
  });
}

/** Every declared native entry for one release target, in declared order. */
export function loadStagedPlan({
  setPath = path.join(repoRoot, defaultPackageSetPath),
  targetId = defaultTargetId,
} = {}) {
  const set = loadPackageSet(setPath);
  const target = resolvePackageTarget(targetId);
  return Object.freeze(set.packages
    .map((declared) => describeStagedEntry(declared, target))
    .filter(Boolean));
}

/** The header a compiled program carries on this platform, or `null`. */
export function compiledProgramHeader(bytes, platform) {
  const headers = COMPILED_MAGIC[platform];
  if (!headers) fail("package_stage_platform_unsupported", { platform });
  for (const header of headers) {
    if (header.bytes.length <= bytes.length &&
        header.bytes.every((byte, index) => bytes[index] === byte)) {
      return header.name;
    }
  }
  return null;
}

/**
 * Refuse a staged entry that is not a compiled program for the target platform.
 *
 * This is deliberately stronger than the payload contract, which accepts any
 * non-script executable so a checkout packages deterministically. A release
 * ships a program, and this is the step that proves the entry became one.
 */
export function assertCompiledEntry(entry) {
  const bytes = readFileSync(entry.stagedPath);
  if (bytes.length === 0) {
    fail("package_stage_entry_empty", { packageId: entry.packageId, entry: entry.entry });
  }
  if (bytes.length > PACKAGE_PAYLOAD_LIMITS.maxEntryBytes) {
    fail("package_stage_entry_exceeds_payload_limit", {
      packageId: entry.packageId,
      entry: entry.entry,
      bytes: bytes.length,
      limit: PACKAGE_PAYLOAD_LIMITS.maxEntryBytes,
    });
  }
  const header = compiledProgramHeader([...bytes.subarray(0, 8)], entry.platform);
  if (!header) {
    fail("package_stage_entry_not_compiled", {
      packageId: entry.packageId,
      entry: entry.entry,
      platform: entry.platform,
    });
  }
  return { bytes: bytes.length, header, sha256: `sha256:${sha256Hex(bytes)}` };
}

/** Build the declared programs through the client's own native build owner. */
export function stageEntries(plan, options = {}) {
  if (plan.length === 0) return [];
  buildNativeSidecars(
    plan.map((entry) => ({ cargoBin: entry.binary })),
    {
      platform: plan[0].platform,
      mode: "release",
      dryRun: false,
      skipNativeBuild: options.skipNativeBuild === true,
    },
    options.buildOptions || {},
  );
  const staged = [];
  for (const entry of plan) {
    if (!existsSync(entry.builtPath)) {
      fail("package_stage_built_binary_missing", {
        packageId: entry.packageId,
        binary: entry.binary,
      });
    }
    mkdirSync(path.dirname(entry.stagedPath), { recursive: true });
    copyFileSync(entry.builtPath, entry.stagedPath);
    chmodSync(entry.stagedPath, 0o755);
    staged.push(Object.freeze({ ...entry, staged: assertCompiledEntry(entry) }));
  }
  return Object.freeze(staged);
}

/**
 * Refuse unless every declared native entry passes the payload contract and is a
 * compiled program. The payload contract is asked first, so a release never
 * reaches the compiled check with an entry `build` would refuse anyway.
 */
export function verifyEntries(plan) {
  return Object.freeze(plan.map((entry) => {
    const entries = readPackageSourceDirectory(entry.sourceRoot);
    nativeConverterEntry(entries, entry.entry);
    const staged = entries.find((candidate) => candidate.name === entry.entry);
    if (!staged) fail("package_stage_entry_missing", { entry: entry.entry });
    return Object.freeze({
      packageId: entry.packageId,
      entry: entry.entry,
      platform: entry.platform,
      ...assertCompiledEntry(entry),
    });
  }));
}

// ---------------------------------------------------------------------------
// Self-test — synthetic packages only, no build, no network
// ---------------------------------------------------------------------------

function syntheticPackage(root, { entry, bytes, executable = true }) {
  const sourceRoot = path.join(root, path.basename(entry));
  mkdirSync(path.join(sourceRoot, path.dirname(entry)), { recursive: true });
  writeFileSync(path.join(sourceRoot, PACKAGE_PAYLOAD_MANIFEST_NAME),
    `${JSON.stringify({
      schema: "licoup.extension-package.v1",
      id: "org.licoland.fixture.stage",
      version: "1.0.0",
      displayName: "Synthetic stage fixture",
      hostProtocol: { major: 1, minimumMinor: 0 },
      compatibility: { clientVersions: [">=0.1.0, <1.0.0"] },
      profiles: [],
      runtime: { mode: "process", entry },
      activation: "on-demand",
      requires: [],
      optionalRequires: [],
      permissions: [],
      contributions: [],
    })}\n`);
  writeFileSync(path.join(sourceRoot, PACKAGE_PAYLOAD_DECLARATION_NAME),
    `${JSON.stringify({
      schemaVersion: "licoup.package-release.v1",
      packageId: "org.licoland.fixture.stage",
      packageVersion: "1.0.0",
      clientCompatibility: { kind: "range", range: ">=0.1.0, <1.0.0" },
      converter: { kind: "native-executable", entry, sourceFormat: "mcp.2025-06-18",
        targetFormat: "licoup.conversation.v1" },
    })}\n`);
  const stagedPath = path.join(sourceRoot, ...entry.split("/"));
  writeFileSync(stagedPath, bytes);
  chmodSync(stagedPath, executable ? 0o755 : 0o644);
  return Object.freeze({
    packageId: "org.licoland.fixture.stage",
    source: "fixture",
    sourceRoot,
    entry,
    stagedPath,
    platform: "macos",
  });
}

// The payload contract refuses with its own error type, and this tool with
// `PackageStageError`; a case asserts the code either owner uses.
function expectRefusal(code, operation) {
  try {
    operation();
  } catch (error) {
    if (error?.code === code) return;
    throw new Error(`expected ${code}, received ${error?.code ?? error?.message}`);
  }
  throw new Error(`expected ${code}, and the operation succeeded`);
}

export function selfTest() {
  // The package reader compares a directory with its own real path, so the
  // disposable tree is created under the real temporary root, not a symlink.
  const root = mkdtempSync(path.join(realpathSync(os.tmpdir()), "licoup-package-stage-"));
  try {
    const macho = Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01, 0x00, 0x00]);
    const elf = Buffer.from([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00]);
    const pe = Buffer.from([0x4d, 0x5a, 0x90, 0x00]);
    const script = Buffer.from("#!/bin/sh\nexec true\n", "utf8");
    const placeholder = Buffer.from("LicoUp release source: staged entry.\n", "utf8");

    const compiled = syntheticPackage(path.join(root, "compiled"), {
      entry: "bin/lico-subagent-mcp", bytes: macho,
    });
    const verified = verifyEntries([compiled]);
    if (verified.length !== 1 || verified[0].header !== "mach-o-64-little-endian" ||
        verified[0].bytes !== macho.length) {
      throw new Error("a compiled staged entry must verify");
    }

    for (const [platform, bytes, header] of [
      ["macos", macho, "mach-o-64-little-endian"],
      ["linux", elf, "elf"],
      ["windows", pe, "pe"],
    ]) {
      if (compiledProgramHeader([...bytes], platform) !== header) {
        throw new Error(`${platform} header was not recognised`);
      }
    }
    if (compiledProgramHeader([...placeholder], "macos") !== null) {
      throw new Error("a text entry must not look compiled");
    }
    expectRefusal("package_stage_platform_unsupported",
      () => compiledProgramHeader([...macho], "plan9"));

    // The payload contract refuses a script before this tool looks at magic.
    const shebang = syntheticPackage(path.join(root, "shebang"), {
      entry: "bin/lico-subagent-mcp", bytes: script,
    });
    expectRefusal("package_payload_converter_not_native", () => verifyEntries([shebang]));

    // A non-executable entry is refused by the payload contract too.
    const notExecutable = syntheticPackage(path.join(root, "not-executable"), {
      entry: "bin/lico-subagent-mcp", bytes: macho, executable: false,
    });
    expectRefusal("package_payload_converter_not_executable",
      () => verifyEntries([notExecutable]));

    // The committed staged placeholder is a real, non-script executable entry —
    // and it is exactly what a release must replace.
    const staged = syntheticPackage(path.join(root, "staged"), {
      entry: "bin/lico-subagent-mcp", bytes: placeholder,
    });
    expectRefusal("package_stage_entry_not_compiled", () => verifyEntries([staged]));

    const empty = syntheticPackage(path.join(root, "empty"), {
      entry: "bin/lico-subagent-mcp", bytes: Buffer.alloc(0),
    });
    expectRefusal("package_stage_entry_empty", () => assertCompiledEntry(empty));

    const oversized = syntheticPackage(path.join(root, "oversized"), {
      entry: "bin/lico-subagent-mcp",
      bytes: Buffer.concat([macho, Buffer.alloc(PACKAGE_PAYLOAD_LIMITS.maxEntryBytes)]),
    });
    expectRefusal("package_stage_entry_exceeds_payload_limit",
      () => assertCompiledEntry(oversized));

    // The declaration and the manifest must name the same entry.
    const disagreeing = syntheticPackage(path.join(root, "disagreeing"), {
      entry: "bin/lico-subagent-mcp", bytes: macho,
    });
    writeFileSync(path.join(disagreeing.sourceRoot, PACKAGE_PAYLOAD_DECLARATION_NAME),
      `${JSON.stringify({
        schemaVersion: "licoup.package-release.v1",
        packageId: "org.licoland.fixture.stage",
        packageVersion: "1.0.0",
        clientCompatibility: { kind: "range", range: ">=0.1.0, <1.0.0" },
        converter: { kind: "native-executable", entry: "bin/other-program",
          sourceFormat: "mcp.2025-06-18", targetFormat: "licoup.conversation.v1" },
      })}\n`);
    expectRefusal("package_stage_entry_disagrees_with_manifest",
      () => describeStagedEntry({ ...disagreeing, sourceRoot: disagreeing.sourceRoot },
        { platform: "macos" }));

    return Object.freeze({ ok: true, caseCount: 9, wroteFiles: false });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/** One positional subcommand plus `--flag value` pairs; anything else refuses. */
export function parseArgs(argv) {
  const args = { command: null };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      if (args.command !== null) fail("package_stage_argument_invalid", { argument: token });
      args.command = token;
      continue;
    }
    const next = argv[index + 1];
    if (next === undefined || next.startsWith("--")) {
      args[token.slice(2)] = true;
    } else {
      args[token.slice(2)] = next;
      index += 1;
    }
  }
  if (args.command !== null &&
      !["plan", "stage", "verify"].includes(args.command)) {
    fail("package_stage_command_invalid", { command: args.command });
  }
  return args;
}

function emit(record) {
  process.stdout.write(`${JSON.stringify(record, null, 2)}\n`);
}

export function runClientReleasePackageStage(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const selfTestRequested = args["self-test"] === true || args["self-test"] === "true";
  const command = args.command || "plan";
  if (selfTestRequested) {
    emit(selfTest());
    return;
  }
  const plan = loadStagedPlan({
    setPath: path.resolve(repoRoot, args.set || defaultPackageSetPath),
    targetId: args.target || defaultTargetId,
  });
  if (command === "plan") {
    emit({
      ok: true,
      platform: plan.length > 0 ? plan[0].platform : null,
      entries: plan.map((entry) => ({
        packageId: entry.packageId,
        source: entry.source,
        entry: entry.entry,
        binary: entry.binary,
        staged: entry.staged,
      })),
      rebuilds: false,
      wroteFiles: false,
      privatePathsIncluded: false,
    });
    return;
  }
  if (command === "verify") {
    const verified = verifyEntries(plan);
    emit({ ok: true, verified, wroteFiles: false, privatePathsIncluded: false });
    return;
  }
  if (command === "stage") {
    const staged = stageEntries(plan, { skipNativeBuild: args["skip-native-build"] === true });
    emit({
      ok: true,
      staged: staged.map((entry) => ({
        packageId: entry.packageId,
        entry: entry.entry,
        ...entry.staged,
      })),
      wroteFiles: true,
      privatePathsIncluded: false,
    });
    return;
  }
  fail("package_stage_command_invalid");
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    runClientReleasePackageStage();
  } catch (error) {
    const known = error instanceof PackageStageError;
    process.stderr.write(`${JSON.stringify({
      ok: false,
      code: known ? error.code : "package_stage_failed",
      ...(known && error.details ? error.details : {}),
      privatePathsIncluded: false,
    })}\n`);
    process.exitCode = 1;
  }
}
