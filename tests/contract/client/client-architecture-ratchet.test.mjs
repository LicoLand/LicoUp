import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  parseCapabilityOwnership,
  measureArchitectureRatchet as measureArchitectureOwner,
  measureDeveloperToolSites as measureDeveloperOwner,
  measureKernelOptionalCargoEdges,
  measureNativeLayerImports,
  measureNativeRustLoc,
  measureOptionalCapabilitiesInPackaging,
} from "../../../apps/desktop/scripts/client-architecture/ratchet/measure.mjs";
import {
  compareRatchetPayloads,
  formatRatchetComparison,
  loadRatchetBaseline,
  recordRatchetBaseline,
} from "../../../apps/desktop/scripts/client-architecture/ratchet/baseline.mjs";
import {
  BASELINE_PATH,
  DEVELOPER_TOOL_ALLOWLIST,
  OPTIONAL_CAPABILITY_ARTIFACTS,
  OPTIONAL_CAPABILITY_BUNDLES,
  OPTIONAL_CAPABILITY_CRATES,
} from "../../../apps/desktop/scripts/client-architecture/ratchet/definitions.mjs";
import {
  inspectDeveloperToolSites,
  stripTestItems,
} from "../../../apps/desktop/scripts/client-architecture/ratchet/developer-tools.mjs";
import {
  binaryOwners,
  collectManifestGraph,
  defaultActivatedDependencies,
} from "../../../apps/desktop/scripts/client-architecture/ratchet/cargo-manifest.mjs";
import {
  checkArchitectureRatchet as checkArchitectureOwner,
  recordArchitectureRatchet as recordArchitectureOwner,
} from "../../../apps/desktop/scripts/client-architecture/checks/ratchet.mjs";
import {
  recordArchitectureRatchetBaseline,
  runClientArchitectureVerification,
} from "../../../apps/desktop/scripts/verify-client-architecture.mjs";
import {RUNTIME_INTERFACE_REVIEWS} from "../../../apps/desktop/scripts/client-architecture/ratchet/runtime-interfaces.mjs";
import {sourceDigest} from "../../../apps/desktop/scripts/client-architecture/ratchet/runtime-review.mjs";
import {lexicalView} from "../../../apps/desktop/scripts/client-architecture/ratchet/lexical.mjs";

// Synthetic repositories supply their own reviewed interfaces. The real-source
// case below explicitly selects the maintained production inventory.
const measureArchitectureRatchet = (options) => measureArchitectureOwner({runtimeReviews: [], ...options});
const measureDeveloperToolSites = (options) => measureDeveloperOwner({runtimeReviews: [], ...options});
const recordArchitectureRatchet = (options) => recordArchitectureOwner({runtimeReviews: [], ...options});
const checkArchitectureRatchet = (options) => checkArchitectureOwner({runtimeReviews: [], ...options});

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const strategyRuntimePath = "crates/licoup-native/src/platform/strategy_runtime/mod.rs";

async function withFixtureTree(files, run) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "licoup-ratchet-"));
  try {
    for (const [relativePath, input] of Object.entries(files)) {
      let content = input;
      // Older small fixtures used Command as a prelude shorthand. Make that
      // intended standard type explicit; production analysis must never guess
      // it from a spelling or neighbouring tool name. Explicit imports/types
      // remain untouched, including unresolved/shadowed API negative controls.
      if (relativePath.endsWith(".rs")) {
        const masked = lexicalView(content, "rust").masked;
        const declaresCommand = /\b(?:struct|enum|type|mod)\s+Command\b/u.test(masked) ||
          [...masked.matchAll(/\buse\b[^;]+;/gu)].some((match) => /\bCommand\b/u.test(match[0]));
        if (!declaresCommand && /(?<![\w:])Command\s*::\s*new\s*\(/u.test(masked)) content = `use std::process::Command;\n${content}`;
      }
      const absolute = path.join(root, relativePath);
      await fs.mkdir(path.dirname(absolute), { recursive: true });
      await fs.writeFile(absolute, content, "utf8");
    }
    return await run(root);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

function deploymentSource(rows) {
  const entries = rows
    .map(([capability, kind, packageId]) =>
      `    ("${capability}", PackOwnership::${kind}(${JSON.stringify(packageId)})),`)
    .join("\n");
  return `pub const CAPABILITY_OWNERSHIP: [(&str, PackOwnership); ${rows.length}] = [\n${entries}\n];\n`;
}

function crateManifest(name, dependencies = {}, extra = "") {
  const lines = Object.entries(dependencies)
    .map(([alias, spec]) =>
      typeof spec === "string"
        ? `${alias} = "${spec}"`
        : `${alias} = { ${Object.entries(spec)
            .map(([key, value]) => `${key} = ${JSON.stringify(value)}`)
            .join(", ")} }`)
    .join("\n");
  return `[package]\nname = "${name}"\nversion = "0.0.0"\n\n[dependencies]\n${lines}\n${extra}`;
}

async function inspectFixture(files, allowlist = [], runtimeReviews = []) {
  return withFixtureTree(files, async (root) =>
    inspectDeveloperToolSites({
      repoRoot: root,
      readdir: fs.readdir,
      readFile: fs.readFile,
      allowlist,
      runtimeReviews,
    }));
}

async function nativeReviewFixture() {
  const supervisor = "crates/licoup-foundation/src/platform/process_supervisor.rs";
  const files = Object.fromEntries(await Promise.all([strategyRuntimePath, supervisor].map(async (file) => [file, await fs.readFile(path.join(repoRoot, file), "utf8")])));
  const reviews = RUNTIME_INTERFACE_REVIEWS.filter((review) => [strategyRuntimePath, supervisor].includes(review.id.split("::")[0]));
  return {files, reviews};
}

function refreshedFixtureReviews(reviews, files) {
  return reviews.map((review) => ({...review, provenance: review.provenance.map((proof) => ({...proof, digest: files[proof.file] === undefined ? proof.digest : sourceDigest(files[proof.file])}))}));
}

test("actual-native same-line second spawn cannot inherit an individually reviewed interface", async () => {
  const {files, reviews} = await nativeReviewFixture();
  const realSource = files[strategyRuntimePath];
  const baseline = await inspectFixture(files, [], reviews);
  assert.equal(baseline.runtimeInterfaces.length, 3);
  assert.equal(baseline.executionSites.length, 0);
  assert.deepEqual(baseline.problems, []);

  const mutatedSource = realSource.replace(
    "    let mut command = Command::new(executable);",
    "    let mut command = Command::new(executable); Command::new(executable).arg(\"--version\").spawn();",
  );
  assert.notEqual(mutatedSource, realSource);
  const mutated = await inspectFixture(
    {...files, [strategyRuntimePath]: mutatedSource}, [],
    refreshedFixtureReviews(reviews, {...files, [strategyRuntimePath]: mutatedSource}),
  );
  assert.equal(mutated.runtimeInterfaces.length, 3);
  assert.equal(
    mutated.unreviewedRuntimeInterfaces.some((sink) =>
      sink.statement.includes("Command::new(executable).arg(\"--version\").spawn()")),
    true,
  );

  const comparison = formatRatchetComparison(compareRatchetPayloads(
    {
      developer_tool_sites: {
         execution_sites: baseline.runtimeInterfaces.length,
        unallowlisted_sites: 0,
         execution_site_ids: baseline.runtimeSiteIds,
        unallowlisted_site_ids: [],
      },
    },
    {
      developer_tool_sites: {
         execution_sites: mutated.runtimeInterfaces.length + mutated.unreviewedRuntimeInterfaces.length,
         unallowlisted_sites: 0,
         execution_site_ids: mutated.runtimeSiteIds,
        unallowlisted_site_ids: [],
      },
    },
  ));
  assert.equal(comparison.regressions.length > 0, true);
  assert.match(comparison.regressions.join("\n"), /developer_tool_sites/u);
});

test("entry-level baseline refuses changed and new native interfaces before comparison", async () => {
  const {files, reviews} = await nativeReviewFixture();
  const realSource = files[strategyRuntimePath];
  await withFixtureTree(completeFixture(files), async (root) => {
    const recorded = await recordArchitectureRatchet({ repoRoot: root, runtimeReviews: reviews });
    assert.equal(recorded.ok, true);
    assert.equal(recorded.record.processExecutionBoundaries, 3);
    assert.equal(recorded.record.reviewedRuntimeSelectedInterfaces, 3);
    assert.equal(recorded.record.developerToolUnallowlistedSites, 0);

    const mutatedSource = realSource.replace(
      "    let mut command = Command::new(executable);",
      "    let mut command = Command::new(executable); Command::new(executable).arg(\"--version\").spawn();",
    );
    await fs.writeFile(path.join(root, strategyRuntimePath), mutatedSource, "utf8");
    const failures = [];
    const state = await checkArchitectureRatchet({
      repoRoot: root,
      runtimeReviews: reviews,
      fail: (message) => failures.push(message),
    });
    assert.equal(state.ratchetReport.status, "measurement-refused");
    assert.equal(
      failures.some((message) => message.includes("source changed")),
      true,
    );
    assert.equal(
      failures.some((message) => message.includes("unreviewed runtime-selected interface")),
      true,
    );
  });
});

test("a replaced reviewed interface cannot inherit its source-bound review", async () => {
  const {files, reviews} = await nativeReviewFixture();
  const realSource = files[strategyRuntimePath];
  const replaced = realSource.replace(
    "let mut command = Command::new(executable);",
    "let mut command = Command::new(executable.clone());",
  );
  assert.notEqual(replaced, realSource);
  const inspection = await inspectFixture(
    {...files, [strategyRuntimePath]: replaced}, [],
    refreshedFixtureReviews(reviews, {...files, [strategyRuntimePath]: replaced}),
  );
  assert.equal(
    inspection.unreviewedRuntimeInterfaces.some((sink) =>
      sink.statement.includes("Command::new(executable.clone())")),
    true,
  );
  assert.equal(
    inspection.problems.some((message) => message.includes(`${strategyRuntimePath}::90131efac688`) && message.includes("stale")),
    true,
  );
});

test("cross-file mentions cannot make a public runtime parameter a resolved tool", async () => {
  const crossFile = await inspectFixture({
    "crates/demo/src/api.rs": "pub fn launch(program: &str) {\n  Command::new(program).spawn();\n}\n",
    "crates/demo/src/boot.rs": 'pub fn boot() {\n  launch("node");\n}\n',
  });
  assert.deepEqual(crossFile.executionSites, []);
  assert.equal(crossFile.unreviewedRuntimeInterfaces.length, 1);

  const fileEvidence = await inspectFixture({
    "crates/demo/src/runner.rs": [
      'const CHANNEL: &str = "npm";',
      "pub fn run(program: String) {",
      "  Command::new(program).spawn();",
      "}",
      "",
    ].join("\n"),
  });
  assert.deepEqual(fileEvidence.executionSites, []);
  assert.equal(fileEvidence.unreviewedRuntimeInterfaces.length, 1);
  assert.deepEqual(fileEvidence.unreviewedRuntimeInterfaces[0].fileHints, ["npm"]);

  const unrelated = await inspectFixture({
    "crates/demo/src/plain.rs": "pub fn run(program: String) {\n  Command::new(program).spawn();\n}\n",
  });
  assert.deepEqual(unrelated.executionSites, []);
  assert.equal(unrelated.scannedSinkStatements > 0, true);
  assert.equal(unrelated.unresolved.length, 1);
  assert.match(unrelated.problems[0], /unresolved process target/u);
});

test("shell scripts passed to sh -c are attributed, including multiline raw scripts", async () => {
  const single = await inspectFixture({
    "crates/demo/src/shell.rs": [
      'const SCRIPT: &str = "node agent.js";',
      "pub fn run() {",
      '  Command::new("sh").args(["-c", SCRIPT]).status();',
      "}",
      "",
    ].join("\n"),
  });
  assert.deepEqual(single.executionSites.map((sink) => sink.tools), [["node"]]);

  const multiline = await inspectFixture({
    "crates/demo/src/shell.rs": [
      "const SCRIPT: &str = r#\"",
      "set -eu",
      "node agent.js --once",
      "\"#;",
      "pub fn run() {",
      '  Command::new("/bin/sh").arg("-c").arg(SCRIPT).status();',
      "}",
      "",
    ].join("\n"),
  });
  assert.deepEqual(multiline.executionSites.map((sink) => sink.tools), [["node"]]);
});

test("commented-out execution and commented cfg(test) never hide runtime sinks", async () => {
  const commented = await inspectFixture({
    "crates/demo/src/comment.rs": [
      "pub fn keep() {",
      '  // Command::new("node").spawn();',
      '  /* Command::new("npm").spawn(); */',
      "}",
      "",
    ].join("\n"),
  });
  assert.deepEqual(commented.executionSites, []);

  const commentedAttribute = await inspectFixture({
    "crates/demo/src/runtime.rs": [
      "// #[cfg(test)]",
      "pub fn runtime() {",
      '  Command::new("node").spawn();',
      "}",
      "",
    ].join("\n"),
  });
  assert.deepEqual(commentedAttribute.executionSites.map((sink) => sink.tools), [["node"]]);
});

test("mixed production and test files keep production sinks and drop test sinks", async () => {
  const mixed = await inspectFixture({
    "crates/demo/src/mixed.rs": [
      "pub fn production() {",
      '  Command::new("node").spawn();',
      "}",
      "#[test]",
      "fn t() {",
      '  Command::new("npm").spawn();',
      "}",
      "",
    ].join("\n"),
  });
  assert.deepEqual(mixed.executionSites.map((sink) => sink.tools), [["node"]]);
  assert.equal(stripTestItems('fn keep() {}\n#[test]\nfn t() {}\n').includes("keep"), true);
  const beforeProduction = [
    "#[cfg(test)] mod checks { fn generic<'a>() {} }",
    'fn run() { Command::new("node").spawn(); }',
    "",
  ].join("\n");
  const after = await inspectFixture({ "crates/demo/src/mixed.rs": beforeProduction });
  assert.deepEqual(after.executionSites.map((site) => site.tools), [["node"]]);
  assert.equal(after.executionSites[0].line, 3, "the explicit standard Command import precedes the preserved production line");
});

test("crate src scope excludes build.rs and other crate-root files", async () => {
  const inspection = await inspectFixture({
    "crates/demo/build.rs": 'fn main() {\n  Command::new("node").spawn();\n}\n',
    "crates/demo/benches/bench.rs": 'fn bench() {\n  Command::new("npm").spawn();\n}\n',
  });
  assert.deepEqual(inspection.executionSites, []);
  assert.equal(inspection.scannedFiles, 0);
});

test("feature requests propagate through dependency features to optional edges", async () => {
  await withFixtureTree({
    "Cargo.toml": "[workspace]\n",
    "crates/licoup-native/Cargo.toml": crateManifest("licoup-native", {
      helper: { path: "../helper", features: ["runtime"] },
    }),
    "crates/helper/Cargo.toml": [
      "[package]",
      'name = "helper"',
      'version = "0.0.0"',
      "",
      "[dependencies]",
      'analytics = { package = "licoup-analytics", path = "../licoup-analytics", optional = true }',
      "",
      "[features]",
      'runtime = ["analytics"]',
      "",
    ].join("\n"),
    "crates/licoup-analytics/Cargo.toml": crateManifest("licoup-analytics"),
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["analytics.v1", "Optional", "org.licoland.feature.analytics"],
    ]),
  }, async (root) => {
    const metric = await measureKernelOptionalCargoEdges({ repoRoot: root });
    assert.deepEqual(metric.ratchet.edges, [
      "helper -> licoup-analytics (optional-active)",
    ]);
    assert.deepEqual(metric.details.problems, []);
  });
});

test("Cargo auto-discovered binaries own their packaging artifacts", async () => {
  await withFixtureTree({
    "Cargo.toml": "[workspace]\n",
    "crates/licoup-native/Cargo.toml": crateManifest("licoup-native"),
    "crates/licoup-tool/Cargo.toml": crateManifest("licoup-tool"),
    "crates/licoup-tool/src/main.rs": "fn main() {}\n",
    "crates/licoup-tool/src/bin/licoup-cli.rs": "fn main() {}\n",
    "crates/licoup-tool/src/bin/helper/main.rs": "fn main() {}\n",
  }, async (root) => {
    const graph = await collectManifestGraph({ repoRoot: root });
    const owners = binaryOwners(graph.byPath);
    assert.equal(owners.get("licoup-tool"), "licoup-tool");
    assert.equal(owners.get("licoup-cli"), "licoup-tool");
    assert.equal(owners.get("helper"), "licoup-tool");
    assert.deepEqual(graph.problems, []);
  });
});

test("explicit binary ownership overrides automatic source names", async () => {
  await withFixtureTree({
    "Cargo.toml": "[workspace]\n",
    "crates/tool/Cargo.toml": crateManifest("tool", {}, '[[bin]]\nname = "named-tool"\npath = "src/main.rs"\n'),
    "crates/tool/src/main.rs": "fn main() {}\n",
  }, async (root) => {
    const graph = await collectManifestGraph({ repoRoot: root });
    assert.deepEqual(graph.problems, []);
    assert.deepEqual([...binaryOwners(graph.byPath)], [["named-tool", "tool"]]);
  });
});

test("ownership package-id constants are resolved and unresolved rows refuse", async () => {
  const resolved = parseCapabilityOwnership([
    'pub const CORE_PACKAGE: &str = "org.licoland.core";',
    "pub mod packages {",
    '    pub const WORKFLOW: &str = "org.licoland.feature.workflow";',
    "}",
    "const CAPABILITY_OWNERSHIP: [(&str, PackOwnership); 2] = [",
    '    ("conversation.v1", PackOwnership::Core(CORE_PACKAGE)),',
    '    ("workflow.v1", PackOwnership::Optional(packages::WORKFLOW)),',
    "];",
  ].join("\n"));
  assert.deepEqual(
    resolved.filter((row) => row.set === "optional").map((row) => row.package),
    ["org.licoland.feature.workflow"],
  );

  await withFixtureTree({
    "Cargo.toml": "[workspace]\n",
    "crates/licoup-native/Cargo.toml": crateManifest("licoup-native"),
    "crates/licoup-extension-contracts/src/deployment.rs": [
      "const CAPABILITY_OWNERSHIP: [(&str, PackOwnership); 1] = [",
      '    ("workflow.v1", PackOwnership::Optional(packages::MISSING)),',
      "];",
    ].join("\n"),
  }, async (root) => {
    const metric = await measureKernelOptionalCargoEdges({ repoRoot: root });
    assert.equal(
      metric.details.problems.some((message) =>
        message.includes("packages::MISSING") && message.includes("does not resolve")),
      true,
    );
  });
});

test("inline braced super imports are counted as cross-layer files", async () => {
  await withFixtureTree({
    "crates/licoup-native/src/domain/inline.rs": "pub mod nested {\n  use super::super::super::{platform::Thing};\n}\n",
    "crates/licoup-native/src/platform/mod.rs": "pub fn platform_only() {}\n",
  }, async (root) => {
    const metric = await measureNativeLayerImports({ repoRoot: root });
    assert.deepEqual(metric.ratchet.domain_to_platform_files, [
      "crates/licoup-native/src/domain/inline.rs",
    ]);
    assert.deepEqual(metric.details.problems, []);
  });
});

test("unreadable sources refuse instead of lowering a metric", async () => {
  const files = {
    "crates/licoup-native/src/lib.rs": "pub fn x() {}\n",
    "crates/licoup-native/src/locked.rs": "pub fn locked() {}\n",
  };
  await withFixtureTree(files, async (root) => {
    const locked = path.join(root, "crates/licoup-native/src/locked.rs");
    const io = { ...fs, readFile: async (target, ...args) => {
      if (target === locked) throw Object.assign(new Error("injected read denial"), { code: "EACCES" });
      return fs.readFile(target, ...args);
    } };
    const metric = await measureNativeRustLoc({ repoRoot: root, io });
    assert.match(metric.details.problems.join("\n"), /locked.rs cannot be read/u);
    const measurement = await measureArchitectureRatchet({ repoRoot: root, io });
    assert.equal(measurement.record, null);
  });
});

test("cargo graph resolves workspace inheritance, locality, and requested activation", async () => {
  await withFixtureTree({
    "Cargo.toml": [
      "[workspace]",
      'members = ["crates/licoup-native"]',
      "",
      "[workspace.dependencies]",
      'renamed-analytics = { package = "licoup-analytics", path = "components/analytics" }',
      "",
    ].join("\n"),
    "crates/licoup-native/Cargo.toml": [
      "[package]",
      'name = "licoup-native"',
      'version = "0.0.0"',
      "",
      "[dependencies]",
      "renamed-analytics = { workspace = true }",
      'licoup-analytics = "1.0.0"',
      'licoup-mcp = { path = "../licoup-mcp", optional = true }',
      "",
      "[features]",
      'default = ["licoup-mcp"]',
      "",
    ].join("\n"),
    "components/analytics/Cargo.toml": crateManifest("licoup-analytics"),
    "crates/licoup-mcp/Cargo.toml": crateManifest("licoup-mcp"),
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["analytics.v1", "Optional", "org.licoland.feature.analytics"],
      ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
    ]),
  }, async (root) => {
    const metric = await measureKernelOptionalCargoEdges({ repoRoot: root });
    assert.deepEqual(metric.ratchet.edges, [
      "licoup-native -> licoup-analytics (dependencies)",
      "licoup-native -> licoup-mcp (optional-active)",
    ]);
    assert.deepEqual(metric.details.problems, []);
  });
});

test("cargo graph handles dotted keys, sub-tables, apostrophe comments, and inactive optional deps", async () => {
  await withFixtureTree({
    "Cargo.toml": "[workspace]\n",
    "crates/licoup-native/Cargo.toml": [
      "# don't activate the optional manager by default",
      "[package]",
      'name = "licoup-native"',
      'version = "0.0.0"',
      "",
      "[dependencies]",
      'dotted.path = "../licoup-mcp"',
      'dotted.package = "licoup-mcp"',
      "dotted.optional = true",
      "",
      "[dependencies.delta]",
      'package = "licoup-analytics"',
      'path = "../licoup-analytics"',
      "",
    ].join("\n"),
    "crates/licoup-mcp/Cargo.toml": crateManifest("licoup-mcp"),
    "crates/licoup-analytics/Cargo.toml": crateManifest("licoup-analytics"),
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
      ["analytics.v1", "Optional", "org.licoland.feature.analytics"],
    ]),
  }, async (root) => {
    const metric = await measureKernelOptionalCargoEdges({ repoRoot: root });
    assert.deepEqual(metric.ratchet.edges, [
      "licoup-native -> licoup-analytics (dependencies)",
    ]);
    assert.deepEqual(metric.details.inactive_optional_edges, [
      "licoup-native -> licoup-mcp (optional, inactive for the requested features)",
    ]);
    assert.deepEqual(metric.details.problems, []);
  });
});

test("external dependencies with local names never count as local edges", async () => {
  await withFixtureTree({
    "Cargo.toml": "[workspace]\n",
    "crates/licoup-native/Cargo.toml": crateManifest("licoup-native", {
      "licoup-analytics": "^2.0.0",
      "licoup-mcp": { git: "https://example.invalid/mcp.git" },
    }),
    "crates/licoup-analytics/Cargo.toml": crateManifest("licoup-analytics"),
    "crates/licoup-mcp/Cargo.toml": crateManifest("licoup-mcp"),
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["analytics.v1", "Optional", "org.licoland.feature.analytics"],
      ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
    ]),
  }, async (root) => {
    const metric = await measureKernelOptionalCargoEdges({ repoRoot: root });
    assert.deepEqual(metric.ratchet.edges, []);
    assert.deepEqual(metric.details.problems, []);
  });
});

test("default activation follows feature indirection and dep syntax", () => {
  const features = {
    default: ["bundle"],
    bundle: ["dep:licoup-mcp"],
    extra: ["licoup-workflow"],
    optionalOnly: ["licoup-optional?/feature"],
  };
  const dependencies = [
    { alias: "licoup-mcp", optional: true },
    { alias: "licoup-workflow", optional: true },
    { alias: "licoup-optional", optional: true },
  ];
  const activated = defaultActivatedDependencies(features, dependencies);
  assert.equal(activated.has("licoup-mcp"), true);
  assert.equal(activated.has("licoup-workflow"), false);
  assert.equal(activated.has("licoup-optional"), false);
});

test("unknown optional ownership fails the check and refuses recording, even with a seeded baseline", async () => {
  await withFixtureTree(completeFixture(), async (root) => {
    const recorded = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(recorded.ok, true);

    await fs.writeFile(
      path.join(root, "crates/licoup-extension-contracts/src/deployment.rs"),
      deploymentSource([
        ["conversation.v1", "Core", "org.licoland.core"],
        ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
        ["brand-new.v1", "Optional", "org.licoland.feature.brand-new"],
      ]),
      "utf8",
    );
    const failures = [];
    const state = await checkArchitectureRatchet({
      repoRoot: root,
      fail: (message) => failures.push(message),
    });
    assert.notEqual(state.ratchetReport.status, "pass");
    assert.equal(
      failures.some((message) => message.includes("org.licoland.feature.brand-new")),
      true,
    );
    const record = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(record.ok, false);
  });
});

test("packaging bindings derive from artifact owners including kernel-compiled implementations", async () => {
  await withFixtureTree(packagingFixture(), async (root) => {
    const metric = await measureOptionalCapabilitiesInPackaging({ repoRoot: root });
    assert.deepEqual(metric.ratchet.bindings, [
      "org.licoland.feature.gateway -> gateway-sidecar",
    ]);
    assert.deepEqual(metric.details.problems, []);
  });
});

test("packaging rejects a new host bundle, a replaced binary, an unknown binary, an unknown package, and the retired MCP payload", async () => {
  await withFixtureTree(packagingFixture({
    modules: {
      "gateway-sidecar": { enabled: true, cargoBin: "lico-gateway" },
      "extra-host": { enabled: true, embeddedCargoBin: "lico-gateway" },
      "mystery-host": { enabled: true, cargoBin: "mystery-bin" },
    },
  }), async (root) => {
    const metric = await measureOptionalCapabilitiesInPackaging({ repoRoot: root });
    assert.equal(
      metric.details.problems.some((message) =>
        message.includes("extra-host") && message.includes("without a declaration")),
      true,
    );
    assert.equal(
      metric.details.problems.some((message) =>
        message.includes("mystery-host") && message.includes("no first-party manifest builds")),
      true,
    );
    assert.equal(metric.ratchet.bundled_bindings, 2);
  });

  await withFixtureTree(packagingFixture({
    modules: {
      "gateway-sidecar": { enabled: true, cargoBin: "lico-other" },
    },
    nativeBins: ["licoup-cli", "lico-other"],
  }), async (root) => {
    const metric = await measureOptionalCapabilitiesInPackaging({ repoRoot: root });
    assert.equal(
      metric.details.problems.some((message) =>
        message.includes("gateway-sidecar") && message.includes("is not produced")),
      true,
    );
  });

  // The payload the client retired cannot return as a quiet packaging edit: the
  // artifact is still built and still declared as optional, and bundling it is
  // refused until the declaration says so again.
  await withFixtureTree(packagingFixture({
    modules: {
      "subagents-mcp": { enabled: true, cargoBin: "lico-subagent-mcp" },
      "codex-plugin": { enabled: true, embeddedCargoBin: "lico-subagent-mcp" },
      "gateway-sidecar": { enabled: true, cargoBin: "lico-gateway" },
    },
  }), async (root) => {
    const metric = await measureOptionalCapabilitiesInPackaging({ repoRoot: root });
    assert.deepEqual(metric.ratchet.bindings, [
      "org.licoland.feature.gateway -> gateway-sidecar",
      "org.licoland.feature.mcp -> codex-plugin",
      "org.licoland.feature.mcp -> subagents-mcp",
    ]);
    assert.equal(
      metric.details.problems.filter((message) =>
        message.includes("org.licoland.feature.mcp") &&
        message.includes("without a declaration")).length,
      2,
      "re-bundling the retired MCP payload must be refused until it is declared",
    );
  });
});

function packagingFixture({
  modules = {
    "gateway-sidecar": { enabled: true, cargoBin: "lico-gateway" },
  },
  deploymentRows = [
    ["conversation.v1", "Core", "org.licoland.core"],
    ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
    ["gateway.v1", "Optional", "org.licoland.feature.gateway"],
  ],
  nativeBins = ["licoup-cli", "lico-gateway"],
} = {}) {
  const nativeBinTables = nativeBins
    .map((name) => `[[bin]]\nname = "${name}"\n`)
    .join("");
  return {
    "Cargo.toml": "[workspace]\n",
    "crates/licoup-native/Cargo.toml": crateManifest("licoup-native", {}, nativeBinTables),
    "crates/licoup-mcp/Cargo.toml": crateManifest(
      "licoup-mcp",
      {},
      '[[bin]]\nname = "lico-subagent-mcp"\n',
    ),
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource(deploymentRows),
    "apps/desktop/packaging.modules.json": JSON.stringify({ modules }, null, 2),
    ...Object.fromEntries(nativeBins.map((name) => [`crates/licoup-native/src/bin/${name}.rs`, "fn main() {}\n"])),
    "crates/licoup-mcp/src/main.rs": "fn main() {}\n",
  };
}

test("baseline comparison fails a regression and prompts an improvement", () => {
  const baseline = {
    kernel_optional_cargo_edges: {
      value: 1,
      edges: ["a -> b (dependencies)"],
      unknown_optional_packages: [],
      unknown_optional_manifests: [],
    },
  };
  const regression = formatRatchetComparison(compareRatchetPayloads(baseline, {
    kernel_optional_cargo_edges: {
      value: 2,
      edges: ["a -> b (dependencies)", "a -> c (dependencies)"],
      unknown_optional_packages: [],
      unknown_optional_manifests: [],
    },
  }));
  assert.match(regression.regressions[0], /kernel_optional_cargo_edges\.value grew from 1 to 2/u);
  assert.match(
    regression.regressions[1],
    /kernel_optional_cargo_edges\.edges gained a -> c \(dependencies\)/u,
  );

  const improvement = formatRatchetComparison(compareRatchetPayloads(baseline, {
    kernel_optional_cargo_edges: {
      value: 0,
      edges: [],
      unknown_optional_packages: [],
      unknown_optional_manifests: [],
    },
  }));
  assert.equal(improvement.regressions.length, 0);
  assert.equal(improvement.improvements.length, 2);
  assert.match(improvement.improvements[0], /update the baseline/u);
});

test("every constrained metric regresses with an actionable message", () => {
  const baselineMetrics = {
    kernel_optional_cargo_edges: {
      value: 1,
      edges: ["a -> b (dependencies)"],
      unknown_optional_packages: [],
      unknown_optional_manifests: [],
    },
    native_layer_imports: {
      domain_to_platform: 1,
      platform_to_domain: 0,
      domain_to_platform_files: ["domain/x.rs"],
      platform_to_domain_files: [],
    },
    optional_capabilities_in_packaging: {
      bundled_bindings: 1,
      bindings: ["pkg -> module"],
      unknown_optional_packages: [],
      undeclared_bindings: [],
    },
    developer_tool_sites: {
      execution_sites: 1,
      unallowlisted_sites: 0,
      execution_site_ids: ["file.rs::sink::npm"],
      unallowlisted_site_ids: [],
    },
  };
  const currentMetrics = {
    kernel_optional_cargo_edges: {
      value: 2,
      edges: ["a -> b (dependencies)", "a -> c (dependencies)"],
      unknown_optional_packages: ["org.licoland.feature.new"],
      unknown_optional_manifests: ["licoup-new (org.licoland.feature.new; manifest declares the optional package id)"],
    },
    native_layer_imports: {
      domain_to_platform: 2,
      platform_to_domain: 1,
      domain_to_platform_files: ["domain/x.rs", "domain/y.rs"],
      platform_to_domain_files: ["platform/z.rs"],
    },
    optional_capabilities_in_packaging: {
      bundled_bindings: 2,
      bindings: ["pkg -> module", "pkg -> module-two"],
      unknown_optional_packages: [],
      undeclared_bindings: [],
    },
    developer_tool_sites: {
      execution_sites: 2,
      unallowlisted_sites: 1,
      execution_site_ids: ["file.rs::sink::npm", "other.rs::sink2::node"],
      unallowlisted_site_ids: ["other.rs::sink2::node"],
    },
  };
  const comparison = formatRatchetComparison(
    compareRatchetPayloads(baselineMetrics, currentMetrics),
  );
  assert.equal(comparison.improvements.length, 0);
  const joined = comparison.regressions.join("\n");
  for (const metricId of Object.keys(baselineMetrics)) {
    assert.match(joined, new RegExp(metricId, "u"), metricId);
  }
  assert.match(joined, /needs removal or an explicit reviewed decision/u);
  assert.match(joined, /grew from 1 to 2/u);
});

test("recording refuses to raise a value and accepts an improvement", async () => {
  await withFixtureTree({}, async (root) => {
    const metric = (edges) => [
      { id: "kernel_optional_cargo_edges", ratchet: { value: edges } },
      { id: "native_rust_loc", observation: { non_blank_lines: 1000 } },
    ];
    const first = await recordRatchetBaseline({
      repoRoot: root,
      metrics: metric(10),
      now: () => "2026-01-01T00:00:00.000Z",
    });
    assert.equal(first.ok, true);
    const refused = await recordRatchetBaseline({ repoRoot: root, metrics: metric(12) });
    assert.equal(refused.ok, false);
    assert.match(refused.regressions[0], /grew from 10 to 12/u);
    const improved = await recordRatchetBaseline({ repoRoot: root, metrics: metric(8) });
    assert.equal(improved.ok, true);
    const stored = await loadRatchetBaseline({ repoRoot: root });
    assert.deepEqual(stored.metrics.kernel_optional_cargo_edges, { value: 8 });
    assert.equal(Object.hasOwn(stored.metrics, "native_rust_loc"), false);
    assert.equal(stored.schema, "licoup-architecture-ratchet-baseline.v1");
  });
});

function completeFixture(extraFiles = {}) {
  return {
    "Cargo.toml": "[workspace]\nmembers = [\"crates/licoup-native\"]\n",
    "crates/licoup-native/Cargo.toml": crateManifest(
      "licoup-native",
      {},
      '[[bin]]\nname = "licoup-cli"\n',
    ),
    "crates/licoup-native/src/bin/licoup-cli.rs": "fn main() {}\n",
    "crates/licoup-native/src/lib.rs": "pub mod domain;\npub mod platform;\n",
    "crates/licoup-native/src/domain/mod.rs": "use crate::platform::thing;\npub fn domain_only() {}\n",
    "crates/licoup-native/src/platform/mod.rs": "pub fn platform_only() {}\n",
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["conversation.v1", "Core", "org.licoland.core"],
      ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
    ]),
    "crates/licoup-mcp/Cargo.toml": crateManifest(
      "licoup-mcp",
      {},
      '[[bin]]\nname = "lico-subagent-mcp"\n',
    ),
    "crates/licoup-mcp/src/main.rs": "fn main() {}\n",
    // The released client bundles no optional payload, and neither does this
    // fixture: the retired MCP connector is not a declared bundle any more, so
    // a fixture that still carried it would be refused as undeclared. The one
    // module left bundles a kernel artifact and derives no optional binding.
    "apps/desktop/packaging.modules.json": JSON.stringify({
      modules: {
        "native-sidecar": { enabled: true, cargoBin: "licoup-cli" },
      },
    }, null, 2),
    ...extraFiles,
  };
}

test("check phase fails while the baseline is unrecorded and passes with a recorded fixture baseline", async () => {
  await withFixtureTree(completeFixture(), async (root) => {
    const failures = [];
    const context = { repoRoot: root, fail: (message) => failures.push(message) };
    const unrecordedState = await checkArchitectureRatchet(context);
    assert.equal(unrecordedState.ratchetReport.status, "baseline-unrecorded");
    assert.equal(
      failures.some((message) => message.includes("baseline is not recorded")),
      true,
    );

    const recorded = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(recorded.ok, true);
    assert.equal(recorded.metrics.kernel_optional_cargo_edges.value, 0);
    assert.equal(Number.isInteger(recorded.record.nativeRustNonBlankLines), true);
    assert.equal(recorded.record.developerToolUnallowlistedSites, 0);

    const passFailures = [];
    const passState = await checkArchitectureRatchet({
      repoRoot: root,
      fail: (message) => passFailures.push(message),
    });
    assert.deepEqual(passFailures, []);
    assert.equal(passState.ratchetReport.status, "pass");
    assert.equal(
      passState.ratchetReport.centralEvidence.some((entry) => entry.includes("Installed size")),
      true,
    );
  });
});

test("native Rust size remains observable without gating growth or baseline recording", async () => {
  await withFixtureTree(completeFixture(), async (root) => {
    const initial = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(initial.ok, true);
    const extra = path.join(root, "crates/licoup-native/src/domain/additional.rs");
    await fs.writeFile(extra, "pub fn additional_owner_behavior() {\n  let _value = 1;\n}\n");
    const grown = await checkArchitectureRatchet({ repoRoot: root, fail: assert.fail });
    assert.equal(grown.ratchetReport.status, "pass");
    assert.equal(grown.ratchetMetrics.nativeRustNonBlankLines, initial.record.nativeRustNonBlankLines + 3);
    const recorded = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(recorded.ok, true);
    assert.equal(Object.hasOwn(recorded.metrics, "native_rust_loc"), false);
    assert.equal(Object.hasOwn((await loadRatchetBaseline({ repoRoot: root })).metrics, "native_rust_loc"), false);
    await fs.rm(extra);
    const shrunk = await checkArchitectureRatchet({ repoRoot: root, fail: assert.fail });
    assert.equal(shrunk.ratchetReport.status, "pass");
    assert.deepEqual(shrunk.ratchetReport.improvements, []);
    assert.equal(shrunk.ratchetMetrics.nativeRustNonBlankLines, initial.record.nativeRustNonBlankLines);
  });
});

test("check phase fails a new hidden spawn and prompts an improving baseline update", async () => {
  await withFixtureTree(completeFixture(), async (root) => {
    const recorded = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(recorded.ok, true);

    await fs.writeFile(
      path.join(root, "crates/licoup-native/src/domain/domain_only.rs"),
      'use std::process::Command;\npub fn hidden() {\n  Command::new(\n    "npm",\n  );\n}\n',
      "utf8",
    );
    const failures = [];
    const state = await checkArchitectureRatchet({
      repoRoot: root,
      fail: (message) => failures.push(message),
    });
    assert.equal(state.ratchetReport.status, "regression");
    assert.equal(
      failures.some((message) =>
        message.includes("domain_only.rs") && message.includes("sink fingerprint")),
      true,
    );

    await fs.rm(path.join(root, "crates/licoup-native/src/domain/domain_only.rs"));
    await fs.writeFile(
      path.join(root, "crates/licoup-native/src/domain/mod.rs"),
      "pub fn domain_only() {}\n",
      "utf8",
    );
    const improvedFailures = [];
    const improvedState = await checkArchitectureRatchet({
      repoRoot: root,
      fail: (message) => improvedFailures.push(message),
    });
    assert.deepEqual(improvedFailures, []);
    assert.equal(improvedState.ratchetReport.status, "improved");
    assert.equal(
      improvedState.ratchetReport.improvements.some((message) =>
        message.includes("native_layer_imports.domain_to_platform fell")),
      true,
    );
  });
});

test("record command refuses while an unjustified execution sink exists", async () => {
  await withFixtureTree(completeFixture({
    "crates/licoup-native/src/domain/spawn.rs": 'pub fn spawn() {\n  Command::new("uvx");\n}\n',
  }), async (root) => {
    const record = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(record.ok, false);
    assert.match(record.message, /unjustified developer-tool execution sites/u);
    assert.equal(record.sites.length, 1);
    assert.deepEqual(record.sites[0].tools, ["uvx"]);
  });
});

test("invalid allowlist entries become measurement problems and leave sinks unjustified", async () => {
  const file = "crates/demo/src/lib.rs";
  await withFixtureTree({
    "Cargo.toml": "[workspace]\n",
    [file]: 'pub fn run() {\n  Command::new("node").spawn();\n}\n',
  }, async (root) => {
    const metric = await measureDeveloperToolSites({
      repoRoot: root,
      allowlist: [{ file, sink: "deadbeef", tools: ["node"], reason: "   " }],
    });
    assert.equal(metric.details.problems.length, 1);
    assert.match(metric.details.problems[0], /meaningful justification/u);
    assert.equal(metric.ratchet.unallowlisted_sites, 1);
  });
});

test("real repository retains every reviewed runtime interface as visible comparable debt", async () => {
  const metric = await measureDeveloperOwner({ repoRoot });
  assert.deepEqual(metric.details.problems, []);
  assert.deepEqual(metric.details.unresolved_sites, []);
  assert.equal(metric.ratchet.reviewed_runtime_interfaces, RUNTIME_INTERFACE_REVIEWS.length);
  assert.ok(metric.ratchet.reviewed_runtime_interfaces > 0);
  assert.equal(metric.ratchet.execution_sites, metric.ratchet.resolved_tool_sites + metric.ratchet.reviewed_runtime_interfaces);
  assert.equal(metric.ratchet.unallowlisted_sites, 0);
  assert.deepEqual(metric.details.unallowlisted_sites, []);
  assert.deepEqual(metric.details.invalid_allowlist, []);
  assert.equal(metric.details.stale_allowlist.length, 0);
  assert.equal(metric.ratchet.runtime_interface_ids.length, RUNTIME_INTERFACE_REVIEWS.length);
  assert.ok(metric.details.reviewed_runtime_interfaces.every((site) => site.purpose.length >= 40 && site.provenance.length > 0 && site.contract));
});

async function assertMeasurementRefused(root, pattern, io = fs) {
  const measurement = await measureArchitectureRatchet({ repoRoot: root, io });
  assert.equal(measurement.record, null, "partial inputs must not emit comparable numeric records");
  assert.match(measurement.problems.join("\n"), pattern);
  const failures = [];
  const state = await checkArchitectureRatchet({ repoRoot: root, io, fail: (message) => failures.push(message) });
  assert.equal(state.ratchetReport.status, "measurement-refused");
  assert.equal(state.ratchetMetrics, null);
  assert.equal(state.ratchetReport.improvements, undefined);
  assert.match(failures.join("\n"), pattern);
  const before = await fs.readFile(path.join(root, BASELINE_PATH), "utf8").catch(() => null);
  const record = await recordArchitectureRatchet({ repoRoot: root, io });
  assert.equal(record.ok, false);
  assert.equal(record.status, "measurement-refused");
  assert.match(record.message, pattern);
  const after = await fs.readFile(path.join(root, BASELINE_PATH), "utf8").catch(() => null);
  assert.equal(after, before, "refusal must preserve the existing disposable baseline");
}

test("unknown known-process targets refuse actual measurement, check and record with and without a baseline", async () => {
  for (const source of [
    "pub fn run(program: &str) { Command::new(program).spawn(); }\n",
    "pub fn run(command: &mut std::process::Command) { command.output(); }\n",
    "use std::process::Command as Child; pub fn run(program: &str) { Child :: new (program).status(); }\n",
  ]) {
    await withFixtureTree(completeFixture(), async (root) => {
      const file = path.join(root, "crates/licoup-native/src/domain/unknown.rs");
      assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, true);
      await fs.writeFile(file, source);
      await assertMeasurementRefused(root, /unresolved process target/u);
      await fs.rm(path.join(root, BASELINE_PATH));
      await assertMeasurementRefused(root, /unresolved process target/u);
    });
  }
  await withFixtureTree(completeFixture({
    "apps/desktop/lib/launch.dart": "void launch(String program) { Process . start (program, []); }\n",
  }), async (root) => assertMeasurementRefused(root, /launch.dart.*unresolved process target/u));
});

test("known non-developer targets and unrelated thread APIs remain valid static negatives", async () => {
  await withFixtureTree(completeFixture({
    "crates/licoup-native/src/domain/known.rs": [
      'use std::process::Command;',
      'const PROGRAM: &str = "git";',
      'pub fn run() { let binary = PROGRAM; let mut command = Command :: new (binary); command.status(); }',
      'pub fn threads() { scope.spawn(move || {}); }',
    ].join("\n"),
  }), async (root) => {
    const measurement = await measureArchitectureRatchet({ repoRoot: root });
    assert.deepEqual(measurement.problems, []);
    assert.equal(measurement.record.processExecutionBoundaries, 0);
    assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, true);
  });
});

test("shared Command builders retain each spawn, output and status sink identity", async () => {
  const file = "crates/demo/src/lib.rs";
  const source = 'pub fn run() { let mut command = Command::new("node"); command.spawn(); command.output(); command.status(); }\n';
  const first = await inspectFixture({ [file]: source });
  assert.equal(first.executionSites.length, 4);
  assert.equal(new Set(first.siteIds).size, 4);
  const allowlist = first.executionSites.map((sink) => ({
    file, sink: sink.sink, tools: sink.tools, reason: "Synthetic exact identity fixture only.",
  }));
  assert.equal((await inspectFixture({ [file]: source }, allowlist)).unallowlisted.length, 0);
  const replaced = await inspectFixture({ [file]: source.replace("command.output()", "command.output().unwrap()") }, allowlist);
  assert.equal(replaced.executionSites.length, 4);
  assert.equal(replaced.unallowlisted.length, 1);
  const duplicate = await inspectFixture({ [file]: source.replace("command.spawn();", "command.spawn(); command.spawn();") }, allowlist);
  assert.equal(duplicate.executionSites.length, 5);
  assert.equal(duplicate.unallowlisted.length, 1);
  const broader = allowlist.map((entry) => ({ ...entry, tools: ["node", "npm"] }));
  assert.equal((await inspectFixture({ [file]: source }, broader)).unallowlisted.length, 4);
});

test("source-proven constructed targets retain developer-tool identity", async () => {
  for (const [expression, tool] of [
    ['format!("{}{}", "no", "de")', "node"],
    ['format!("{}{}", "py", "thon3")', "python3"],
    ['"node.exe"', "node"],
    ['"NPM.CMD"', "npm"],
  ]) {
    await withFixtureTree(completeFixture({
      "crates/licoup-native/src/domain/target.rs": `use std::process::Command; fn run() { let binary = ${expression}; Command::new(binary).spawn(); }`,
    }), async (root) => {
      const metric = await measureDeveloperToolSites({ repoRoot: root });
      assert.deepEqual(metric.details.problems, [], expression);
      assert.equal(metric.ratchet.execution_sites, 1, expression);
      assert.deepEqual(metric.details.execution_sites[0].tools, [tool], expression);
      assert.equal(metric.details.unallowlisted_sites.length, 1, expression);
    });
  }
});

test("mutated target bindings cannot retain an earlier harmless literal", async () => {
  for (const body of [
    'let mut binary = "py".to_owned(); binary.push_str("thon3"); Command::new(binary).spawn();',
    'let mut binary = "git".to_owned(); binary += suffix; Command::new(binary).spawn();',
    'let mut base = std::path::PathBuf::from("git"); base.set_file_name(name); Command::new(base).spawn();',
  ]) {
    await withFixtureTree(completeFixture({
      "crates/licoup-native/src/domain/mutated.rs": `use std::process::Command; fn run(name: &str, suffix: &str) { ${body} }`,
    }), async (root) => assertMeasurementRefused(root, /mutat|reassign/u));
  }
});

test("trait signatures are not call-site evidence for implementation parameters", async () => {
  await withFixtureTree(completeFixture({
    "crates/licoup-native/src/domain/runner.rs": [
      'use std::process::Command;',
      'trait Runner { fn spawn(&self, executable: &str); }',
      'struct Native;',
      'impl Runner for Native { fn spawn(&self, executable: &str) { Command::new(executable).spawn(); } }',
    ].join("\n"),
  }), async (root) => {
    const metric = await measureDeveloperToolSites({ repoRoot: root });
    assert.match(metric.details.problems.join("\n"), /open caller boundary/u);
    assert.doesNotMatch(metric.details.problems.join("\n"), /expression: executable: &str/u);
    await assertMeasurementRefused(root, /open caller boundary/u);
  });
});

test("private dev-only libraries are excluded by manifest ownership, not by filename", async () => {
  const helper = "crates/compile-fixtures";
  const files = completeFixture({
    "crates/licoup-native/Cargo.toml": crateManifest("licoup-native", {}, '\n[dev-dependencies]\ncompile-fixtures = { path = "../compile-fixtures" }\n'),
    [`${helper}/Cargo.toml`]: '[package]\nname = "compile-fixtures"\nversion = "0.0.0"\npublish = false\n',
    [`${helper}/src/lib.rs`]: 'use std::process::Command; pub fn compile(program: &str) { Command::new(program).status(); }',
  });
  await withFixtureTree(files, async (root) => {
    const metric = await measureDeveloperToolSites({ repoRoot: root });
    assert.deepEqual(metric.details.problems, []);
    assert.equal(metric.ratchet.execution_sites, 0);
    assert.deepEqual(metric.details.non_runtime_crates.map((entry) => entry.name), ["compile-fixtures"]);
    assert.match(metric.details.non_runtime_crates[0].reason, /dev-dependencies/u);
    assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, true);
    await fs.writeFile(path.join(root, "crates/licoup-native/Cargo.toml"), crateManifest("licoup-native", {
      "compile-fixtures": { path: "../compile-fixtures", optional: true },
    }));
    await assertMeasurementRefused(root, /unresolved process target/u);
  });
  for (const declaration of ['\n[[bin]]\nname = "fixture-tool"\n', '\n[lib]\ncrate-type = ["cdylib"]\n']) {
    await withFixtureTree({ ...files,
      [`${helper}/Cargo.toml`]: files[`${helper}/Cargo.toml`] + declaration,
      ...(declaration.includes("[[bin]]") ? { [`${helper}/src/main.rs`]: 'fn main() {}' } : {}),
    }, async (root) => assertMeasurementRefused(root, /unresolved process target/u));
  }
});

test("proven path reads and Command argument builders retain their fixed executable", async () => {
  for (const source of [
    'use std::process::Command; fn run() { let binary = std::path::PathBuf::from("git"); let _ = binary.to_str(); Command::new(binary).status(); }',
    'use std::process::Command; fn build() -> Result<Command, ()> { let mut command = Command::new("git"); command.arg("--version"); Ok(command) } fn run() { let mut command = build().unwrap(); command.status(); }',
    'use std::process::Command as Child; fn build() -> Result<Child, ()> { let mut command = Child::new("git"); command.arg("--version"); Ok(command) } fn run() { let mut command = build().unwrap(); command.status(); }',
  ]) {
    await withFixtureTree(completeFixture({
      "crates/licoup-native/src/domain/fixed.rs": source,
    }), async (root) => {
      const measurement = await measureArchitectureRatchet({ repoRoot: root });
      assert.deepEqual(measurement.problems, []);
      assert.equal(measurement.record.processExecutionBoundaries, 0);
      const detail = measurement.metrics.find((metric) => metric.id === "developer_tool_sites").details;
      assert.equal(detail.resolved_non_tool_sites.length, source.includes("fn build()") ? 2 : 1,
        "the returned builder sink must be attributed, not silently omitted");
    });
  }
});

test("open conversions and shadowed path types do not establish a harmless target", async () => {
  for (const source of [
    'use std::{process::Command, ffi::OsStr}; struct CustomProgram(String); impl From<&str> for CustomProgram { fn from(_: &str) -> Self { Self(["no", "de"].concat()) } } impl AsRef<OsStr> for CustomProgram { fn as_ref(&self) -> &OsStr { self.0.as_ref() } } fn run() { let program: CustomProgram = "git".into(); Command::new(program).spawn(); }',
    'use std::process::Command; use std::path::PathBuf; mod inner { use super::*; struct PathBuf; impl PathBuf { fn from(_: &str) -> String { ["no", "de"].concat() } } fn run() { let program = PathBuf::from("git"); Command::new(program).spawn(); } }',
  ]) {
    await withFixtureTree(completeFixture({
      "crates/licoup-native/src/domain/open.rs": source,
    }), async (root) => assertMeasurementRefused(root, /unsupported|unresolved path/u));
  }
});

test("all direct sink forms regress through the actual phase and cannot be recorded", async () => {
  for (const body of [
    'Command :: new ("node").spawn();',
    'let mut c = Command::new("npm"); c.output(); c.status();',
    'let create = Command::new; create("uvx").spawn();',
  ]) {
    await withFixtureTree(completeFixture(), async (root) => {
      assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, true);
      const baseline = await fs.readFile(path.join(root, BASELINE_PATH), "utf8");
      await fs.writeFile(path.join(root, "crates/licoup-native/src/domain/sink.rs"), `use std::process::Command;\nfn run() { ${body} }\n`);
      const measured = await measureArchitectureRatchet({ repoRoot: root });
      assert.ok(measured.metrics.find((metric) => metric.id === "developer_tool_sites").ratchet.execution_sites > 0);
      const failures = [];
      const checked = await checkArchitectureRatchet({ repoRoot: root, fail: (message) => failures.push(message) });
      assert.equal(checked.ratchetReport.status, "regression");
      assert.match(failures.join("\n"), /sink fingerprint/u);
      assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, false);
      assert.equal(await fs.readFile(path.join(root, BASELINE_PATH), "utf8"), baseline);
    });
  }
});

test("unknown guest commands and malformed lexical input cannot be silently erased", async () => {
  for (const source of [
    'fn run(script: &str) { Command::new("sh").arg("-c").arg(script).status(); }',
    'fn run(script: &str) { let mut cmd = Command::new("sh"); cmd.arg("-c"); cmd.arg(script); cmd.spawn(); }',
    'fn run(program: &str) { let create = Command::new; create(program); }',
    '/* unterminated Command::new("node").spawn();',
    'const SCRIPT: &str = r#"unterminated;',
  ]) {
    await withFixtureTree(completeFixture({ "crates/licoup-native/src/domain/unknown.rs": source }), async (root) => {
      await assertMeasurementRefused(root, /unresolved process target|unterminated/u);
    });
  }
  const inspection = await inspectFixture({
    "crates/demo/src/lib.rs": [
      '/* nested /* Command::new("npm"); */ ignored */',
      '#[ cfg ( test ) ] mod checks { fn t() { Command::new("node").spawn(); } }',
      'fn run<\'a>(input: &\'a str) { let _ = input; Command::new("pip").status(); }',
    ].join("\n"),
  });
  assert.deepEqual(inspection.executionSites.map((site) => site.tools), [["pip"]]);
});

test("literal bytes and exact attributed tool sets bind exception identity", async () => {
  const file = "crates/demo/src/lib.rs";
  const source = 'fn run() { Command::new("node").arg("two  spaces").spawn(); }';
  const original = await inspectFixture({ [file]: source });
  const allowlist = original.executionSites.map((sink) => ({ file, sink: sink.sink, tools: sink.tools, reason: "Exact synthetic fingerprint only." }));
  const modified = await inspectFixture({ [file]: source.replace("two  spaces", "two spaces") }, allowlist);
  assert.equal(modified.unallowlisted.length, 1);
  assert.notEqual(modified.siteIds[0], original.siteIds[0]);
});

function forwardedFixture({ nativeFeatures = 'default = ["helper/runtime"]', optional = false, helperFeatures = 'runtime = ["dep:analytics"]' } = {}) {
  return completeFixture({
    "crates/licoup-native/Cargo.toml": crateManifest("licoup-native", {
      helper: { path: "../helper", optional, "default-features": false },
    }, `\n[features]\n${nativeFeatures}\n`),
    "crates/helper/Cargo.toml": crateManifest("helper", {
      analytics: { package: "licoup-analytics", path: "../licoup-analytics", optional: true },
    }, `\n[features]\n${helperFeatures}\n`),
    "crates/licoup-analytics/Cargo.toml": crateManifest("licoup-analytics"),
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
      ["analytics.v1", "Optional", "org.licoland.feature.analytics"],
    ]),
  });
}

test("default and weak feature forwarding keep optional debt through actual check and record", async () => {
  for (const [nativeFeatures, optional, expected] of [
    ['default = ["helper/runtime"]', false, 1],
    ['default = ["helper?/runtime", "dep:helper"]', true, 1],
    ['default = ["dep:helper", "helper?/runtime"]', true, 1],
    ['default = ["helper?/runtime"]', true, 0],
    ['default = ["helper?/runtime"]', false, 1],
  ]) {
    await withFixtureTree(forwardedFixture({ nativeFeatures, optional }), async (root) => {
      const measured = await measureArchitectureRatchet({ repoRoot: root });
      assert.deepEqual(measured.problems, [], nativeFeatures);
      assert.equal(measured.record.kernelOptionalCargoEdges, expected, nativeFeatures);
      const recorded = await recordArchitectureRatchet({ repoRoot: root });
      assert.equal(recorded.ok, true);
      assert.equal(recorded.record.kernelOptionalCargoEdges, expected);
      const checked = await checkArchitectureRatchet({ repoRoot: root, fail: assert.fail });
      assert.equal(checked.ratchetReport.status, "pass");
    });
  }
});

test("workspace feature requests remain additive through a renamed dependency", async () => {
  await withFixtureTree(forwardedFixture({
    helperFeatures: 'runtime = ["dep:analytics"]\nextra = []',
  }), async (root) => {
    await fs.writeFile(path.join(root, "Cargo.toml"), '[workspace]\n[workspace.dependencies]\nrenamed = { package = "helper", path = "crates/helper", features = ["runtime"] }\n');
    await fs.writeFile(path.join(root, "crates/licoup-native/Cargo.toml"), crateManifest("licoup-native", {
      renamed: { workspace: true, features: ["extra"], "default-features": false },
    }));
    const measured = await measureArchitectureRatchet({ repoRoot: root });
    assert.deepEqual(measured.problems, []);
    assert.equal(measured.record.kernelOptionalCargoEdges, 1);
    assert.equal((await recordArchitectureRatchet({ repoRoot: root })).record.kernelOptionalCargoEdges, 1);
  });
});

test("feature unification traverses optional implementations before deciding kernel edges", async () => {
  await withFixtureTree(forwardedFixture({ nativeFeatures: "default = []" }), async (root) => {
    await fs.writeFile(path.join(root, "crates/licoup-native/Cargo.toml"), crateManifest("licoup-native", {
      helper: { path: "../helper", "default-features": false },
      "licoup-mcp": { path: "../licoup-mcp" },
    }));
    await fs.writeFile(path.join(root, "crates/licoup-mcp/Cargo.toml"), crateManifest("licoup-mcp", {
      helper: { path: "../helper", features: ["runtime"] },
    }, '[[bin]]\nname = "lico-subagent-mcp"\n'));
    const measurement = await measureArchitectureRatchet({ repoRoot: root });
    assert.deepEqual(measurement.problems, []);
    const metric = measurement.metrics.find((entry) => entry.id === "kernel_optional_cargo_edges");
    assert.deepEqual(metric.ratchet.edges, [
      "helper -> licoup-analytics (optional-active)",
      "licoup-native -> licoup-mcp (dependencies)",
    ]);
    assert.deepEqual(metric.details.inactive_optional_edges, []);
    assert.equal((await recordArchitectureRatchet({ repoRoot: root })).record.kernelOptionalCargoEdges, 2);
    assert.equal((await checkArchitectureRatchet({ repoRoot: root, fail: assert.fail })).ratchetReport.status, "pass");
  });
});

test("invalid feature requests, unknown local overrides and ambiguous binary owners refuse", async () => {
  await withFixtureTree(forwardedFixture({ nativeFeatures: 'default = ["helper/missing"]' }), async (root) => {
    await assertMeasurementRefused(root, /feature missing is not declared/u);
  });
  await withFixtureTree(forwardedFixture(), async (root) => {
    await fs.appendFile(path.join(root, "Cargo.toml"), '\n[patch.crates-io]\nanalytics = { path = "crates/licoup-analytics" }\n');
    await assertMeasurementRefused(root, /local dependency overrides/u);
  });
  await withFixtureTree(completeFixture({
    "crates/other/Cargo.toml": crateManifest("other", {}, '[[bin]]\nname = "lico-subagent-mcp"\n'),
    "crates/other/src/main.rs": "fn main() {}\n",
  }), async (root) => assertMeasurementRefused(root, /ambiguous first-party owners/u));
});

test("ownership constants and qualified constructors cannot turn one optional edge into an improvement", async () => {
  await withFixtureTree(forwardedFixture(), async (root) => {
    assert.equal((await recordArchitectureRatchet({ repoRoot: root })).record.kernelOptionalCargoEdges, 1);
    const ownerPath = path.join(root, "crates/licoup-extension-contracts/src/deployment.rs");
    await fs.writeFile(ownerPath, [
      'const ANALYTICS: &str = "analytics.v1";',
      'mod packages { pub const PACKAGE: &str = "org.licoland.feature.analytics"; pub const OWNER: PackOwnership = PackOwnership::Optional(PACKAGE); }',
      'mod unrelated { pub const PACKAGE: &str = "org.licoland.feature.mcp"; }',
      'pub const CAPABILITY_OWNERSHIP: [(&str, PackOwnership); 2] = [',
      ' (ANALYTICS, packages::OWNER),',
      ' ("mcp-server.v1", crate::deployment::PackOwnership :: Optional (unrelated::PACKAGE)),',
      '];',
    ].join("\n"));
    const checked = await checkArchitectureRatchet({ repoRoot: root, fail: assert.fail });
    assert.equal(checked.ratchetMetrics.kernelOptionalCargoEdges, 1);
    assert.equal(checked.ratchetReport.status, "pass");
    const recorded = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(recorded.ok, true);
    assert.equal(recorded.record.kernelOptionalCargoEdges, 1);
    for (const unsupported of [
      'pub const CAPABILITY_OWNERSHIP: [(&str, PackOwnership); 2] = generated_ownership!();',
      'pub const CAPABILITY_OWNERSHIP: [(&str, PackOwnership); 1] = [("analytics.v1", select_owner())];',
      '// pub const CAPABILITY_OWNERSHIP: [(&str, PackOwnership); 0] = [];',
    ]) {
      await fs.writeFile(ownerPath, unsupported);
      await assertMeasurementRefused(root, /CAPABILITY_OWNERSHIP/u);
    }
  });
});

test("required enumerated source or manifest loss is never a lower-debt success", async () => {
  await withFixtureTree(completeFixture({
    "crates/licoup-native/src/domain/child/source.rs": "pub fn retained() {}\n",
  }), async (root) => {
    assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, true);
    for (const [method, relative, code] of [
      ["readdir", "crates/licoup-native/src/domain/child", "ENOENT"],
      ["readdir", "crates/licoup-native/src/domain/child", "EACCES"],
      ["readFile", "crates/licoup-native/src/domain/child/source.rs", "ENOENT"],
      ["readFile", "crates/licoup-native/src/domain/child/source.rs", "EACCES"],
      ["readFile", "crates/licoup-mcp/Cargo.toml", "ENOENT"],
      ["readdir", "crates/licoup-mcp", "ENOENT"],
    ]) {
      const io = { ...fs, [method]: async (target, ...args) => {
        if (target === path.join(root, relative)) throw Object.assign(new Error("injected input failure"), { code });
        return fs[method](target, ...args);
      } };
      await assertMeasurementRefused(root, /cannot be read/u, io);
    }
  });
});

test("Cargo automatic target removal and missing explicit sources refuse both entry paths", async () => {
  await withFixtureTree(completeFixture({
    "crates/licoup-mcp/Cargo.toml": crateManifest("licoup-mcp"),
    "crates/licoup-mcp/src/bin/lico-subagent-mcp.rs": "fn main() {}\n",
  }), async (root) => {
    assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, true);
    await fs.writeFile(path.join(root, "crates/licoup-mcp/Cargo.toml"), '[package]\nname = "licoup-mcp"\nversion = "0.0.0"\nautobins = false\n');
    await assertMeasurementRefused(root, /lico-subagent-mcp.*not built|no first-party manifest builds/u);
    await fs.writeFile(path.join(root, "crates/licoup-mcp/Cargo.toml"), crateManifest("licoup-mcp", {}, '[[bin]]\nname = "lico-subagent-mcp"\npath = "missing.rs"\n'));
    await assertMeasurementRefused(root, /binary target lico-subagent-mcp has no source/u);
  });
});

test("actual report and record wrappers preserve refusal and exit semantics", async () => {
  await withFixtureTree(completeFixture({
    "crates/licoup-native/src/domain/unknown.rs": "fn launch(program: &str) { Command::new(program).status(); }\n",
  }), async (root) => {
    const events = [];
    const output = { stdout: (text) => events.push(["stdout", text]), stderr: (text) => events.push(["stderr", text]), exit: (code) => events.push(["exit", code]) };
    const checks = new Proxy({ checkArchitectureRatchet }, { get: (target, key) => target[key] ?? (async () => ({})) });
    const checked = await runClientArchitectureVerification({ repoRoot: root, checks, output });
    assert.equal(checked.ok, false);
    const report = JSON.parse(checked.text);
    assert.equal(report.ratchet.status, "measurement-refused");
    assert.equal(report.ratchet.record, null);
    assert.equal(report.ratchet.improvements, undefined);
    assert.deepEqual(events.map(([kind, value]) => kind === "exit" ? value : kind), ["stderr", 1]);
    events.length = 0;
    assert.equal((await recordArchitectureRatchetBaseline({ repoRoot: root, output })).ok, false);
    assert.deepEqual(events.map(([kind, value]) => kind === "exit" ? value : kind), ["stderr", 1]);
    await assert.rejects(fs.access(path.join(root, BASELINE_PATH)), { code: "ENOENT" });
  });
});

test("invalid and unreadable disposable baselines are refused rather than replaced", async (t) => {
  await withFixtureTree(completeFixture(), async (root) => {
    assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, true);
    const target = path.join(root, BASELINE_PATH);
    const valid = await fs.readFile(target, "utf8");
    for (const content of ["{", JSON.stringify({ ...JSON.parse(valid), metrics: [] })]) {
      await fs.writeFile(target, content);
      const failures = [];
      const checked = await checkArchitectureRatchet({ repoRoot: root, fail: (message) => failures.push(message) });
      assert.equal(checked.ratchetReport.status, "baseline-invalid");
      assert.ok(failures.length > 0);
      assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, false);
      assert.equal(await fs.readFile(target, "utf8"), content);
    }
    await fs.writeFile(target, valid);
    const readFile = fs.readFile;
    const mock = t.mock.method(fs, "readFile", async (file, ...args) => {
      if (file === target) throw Object.assign(new Error("injected baseline read denial"), { code: "EACCES" });
      return readFile(file, ...args);
    });
    try {
      const failures = [];
      assert.equal((await checkArchitectureRatchet({ repoRoot: root, fail: (message) => failures.push(message) })).ratchetReport.status, "baseline-invalid");
      assert.match(failures.join("\n"), /EACCES/u);
      assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, false);
    } finally {
      mock.mock.restore();
    }
    assert.equal(await fs.readFile(target, "utf8"), valid);
  });
});

test("layer imports respect lexical regions, grouped path ownership and inline module depth", async () => {
  await withFixtureTree(completeFixture({
    "crates/licoup-native/src/domain/mod.rs": [
      '/* outer /* crate::platform */ comment */',
      'const TEXT: &str = r###"crate::platform"###;',
      'fn lifetime<\'a>(text: &\'a str) { let _ = text; }',
      'use crate::{unrelated::{platform::Thing}};',
    ].join("\n"),
    "crates/licoup-native/src/domain/inline.rs": 'pub mod nested { use super::super::super::{platform::Thing}; }\n',
    "crates/licoup-native/src/domain/wildcard.rs": 'use crate::{*};\n',
    "crates/licoup-native/src/platform/mod.rs": 'use crate::{domain::{Thing}};\n',
  }), async (root) => {
    const metric = await measureNativeLayerImports({ repoRoot: root });
    assert.deepEqual(metric.details.problems, []);
    assert.deepEqual(metric.ratchet.domain_to_platform_files, ["crates/licoup-native/src/domain/inline.rs", "crates/licoup-native/src/domain/wildcard.rs"]);
    assert.deepEqual(metric.ratchet.platform_to_domain_files, ["crates/licoup-native/src/platform/mod.rs"]);
    assert.equal((await recordArchitectureRatchet({ repoRoot: root })).ok, true);
  });
});

test("declared optional ownership covers every optional capability in the contract", async () => {
  const source = await fs.readFile(
    path.join(repoRoot, "crates/licoup-extension-contracts/src/deployment.rs"),
    "utf8",
  );
  const ids = parseCapabilityOwnership(source)
    .filter((row) => row.set === "optional")
    .map((row) => row.package)
    .sort();
  assert.deepEqual(ids, Object.keys(OPTIONAL_CAPABILITY_CRATES).sort());
  assert.deepEqual(ids, Object.keys(OPTIONAL_CAPABILITY_ARTIFACTS).sort());
  assert.deepEqual(ids, Object.keys(OPTIONAL_CAPABILITY_BUNDLES).sort());
});
