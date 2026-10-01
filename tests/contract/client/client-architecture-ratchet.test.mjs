import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  parseCapabilityOwnership,
  measureArchitectureRatchet,
  measureDeveloperToolSites,
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
  checkArchitectureRatchet,
  recordArchitectureRatchet,
} from "../../../apps/desktop/scripts/client-architecture/checks/ratchet.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const strategyRuntimePath = "crates/licoup-native/src/platform/strategy_runtime/mod.rs";

async function withFixtureTree(files, run) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "licoup-ratchet-"));
  try {
    for (const [relativePath, content] of Object.entries(files)) {
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

async function inspectFixture(files, allowlist = []) {
  return withFixtureTree(files, async (root) =>
    inspectDeveloperToolSites({
      repoRoot: root,
      readdir: fs.readdir,
      readFile: fs.readFile,
      allowlist,
    }));
}

test("actual-native same-line second spawn adds an unauthorized sink and regresses an in-memory baseline", async () => {
  const realSource = await fs.readFile(path.join(repoRoot, strategyRuntimePath), "utf8");
  const baseline = await inspectFixture({ [strategyRuntimePath]: realSource });
  assert.equal(baseline.executionSites.length, 2);
  assert.deepEqual(
    baseline.executionSites.map((sink) => sink.tools),
    [["node", "python", "python3"], ["node", "python", "python3"]],
  );
  assert.deepEqual(baseline.problems, []);

  const mutatedSource = realSource.replace(
    "    let mut command = Command::new(executable);",
    "    let mut command = Command::new(executable); Command::new(executable).arg(\"--version\").spawn();",
  );
  assert.notEqual(mutatedSource, realSource);
  const mutated = await inspectFixture(
    { [strategyRuntimePath]: mutatedSource },
  );
  assert.equal(mutated.executionSites.length, 3);
  assert.equal(
    mutated.unallowlisted.some((sink) =>
      sink.statement.includes("Command::new(executable).arg(\"--version\").spawn()")),
    true,
  );

  const comparison = formatRatchetComparison(compareRatchetPayloads(
    {
      developer_tool_sites: {
        execution_sites: baseline.executionSites.length,
        unallowlisted_sites: 0,
        execution_site_ids: baseline.siteIds,
        unallowlisted_site_ids: [],
      },
    },
    {
      developer_tool_sites: {
        execution_sites: mutated.executionSites.length,
        unallowlisted_sites: mutated.unallowlisted.length,
        execution_site_ids: mutated.siteIds,
        unallowlisted_site_ids: [],
      },
    },
  ));
  assert.equal(comparison.regressions.length > 0, true);
  assert.match(comparison.regressions.join("\n"), /developer_tool_sites/u);
});

test("entry-level baseline fails the actual-native second spawn", async () => {
  const realSource = await fs.readFile(path.join(repoRoot, strategyRuntimePath), "utf8");
  await withFixtureTree(completeFixture({ [strategyRuntimePath]: realSource }), async (root) => {
    const recorded = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(recorded.ok, true);
    assert.equal(recorded.record.developerToolExecutionSites, 2);
    assert.equal(recorded.record.developerToolUnallowlistedSites, 0);

    const mutatedSource = realSource.replace(
      "    let mut command = Command::new(executable);",
      "    let mut command = Command::new(executable); Command::new(executable).arg(\"--version\").spawn();",
    );
    await fs.writeFile(path.join(root, strategyRuntimePath), mutatedSource, "utf8");
    const failures = [];
    const state = await checkArchitectureRatchet({
      repoRoot: root,
      fail: (message) => failures.push(message),
    });
    assert.equal(state.ratchetReport.status, "regression");
    assert.equal(
      failures.some((message) => message.includes("sink fingerprint")),
      true,
    );
    assert.equal(
      failures.some((message) => message.includes("developer_tool_sites.execution_sites grew")),
      true,
    );
  });
});

test("a replaced reviewed sink cannot inherit its allowlist exception", async () => {
  const realSource = await fs.readFile(path.join(repoRoot, strategyRuntimePath), "utf8");
  const replaced = realSource.replace(
    "let mut command = Command::new(executable);",
    "let mut command = Command::new(executable.clone());",
  );
  assert.notEqual(replaced, realSource);
  const inspection = await inspectFixture(
    { [strategyRuntimePath]: replaced },
    DEVELOPER_TOOL_ALLOWLIST,
  );
  assert.equal(
    inspection.unallowlisted.some((sink) =>
      sink.statement.includes("Command::new(executable.clone())")),
    true,
  );
  assert.equal(
    inspection.staleAllowlist.includes(`${strategyRuntimePath}::90131efac688`),
    true,
  );
});

test("dynamic and cross-file API sinks are attributed instead of counting zero", async () => {
  const crossFile = await inspectFixture({
    "crates/demo/src/api.rs": "pub fn launch(program: &str) {\n  Command::new(program).spawn();\n}\n",
    "crates/demo/src/boot.rs": 'pub fn boot() {\n  launch("node");\n}\n',
  });
  assert.deepEqual(crossFile.executionSites.map((sink) => sink.tools), [["node"]]);

  const fileEvidence = await inspectFixture({
    "crates/demo/src/runner.rs": [
      'const CHANNEL: &str = "npm";',
      "pub fn run(program: String) {",
      "  Command::new(program).spawn();",
      "}",
      "",
    ].join("\n"),
  });
  assert.deepEqual(fileEvidence.executionSites.map((sink) => sink.tools), [["npm"]]);

  const unrelated = await inspectFixture({
    "crates/demo/src/plain.rs": "pub fn run(program: String) {\n  Command::new(program).spawn();\n}\n",
  });
  assert.deepEqual(unrelated.executionSites, []);
  assert.equal(unrelated.scannedSinkStatements > 0, true);
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
      'workflow = { package = "licoup-workflow", path = "../licoup-workflow", optional = true }',
      "",
      "[features]",
      'runtime = ["workflow"]',
      "",
    ].join("\n"),
    "crates/licoup-workflow/Cargo.toml": crateManifest("licoup-workflow"),
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["workflow.v1", "Optional", "org.licoland.feature.workflow"],
    ]),
  }, async (root) => {
    const metric = await measureKernelOptionalCargoEdges({ repoRoot: root });
    assert.deepEqual(metric.ratchet.edges, [
      "helper -> licoup-workflow (optional-active)",
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

test("ownership package-id constants are resolved and unresolved rows refuse", async () => {
  const resolved = parseCapabilityOwnership([
    'pub const CORE_PACKAGE: &str = "org.licoland.core";',
    "pub mod packages {",
    '    pub const WORKFLOW: &str = "org.licoland.feature.workflow";',
    "}",
    "const OWNERSHIP: [(&str, PackOwnership); 2] = [",
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
      "const OWNERSHIP: [(&str, PackOwnership); 1] = [",
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
    "crates/licoup-native/src/domain/inline.rs": "pub mod nested {\n  use super::super::{platform::Thing};\n}\n",
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
    await fs.chmod(locked, 0o000);
    try {
      let readable = true;
      try {
        await fs.readFile(locked, "utf8");
      } catch {
        readable = false;
      }
      if (!readable) {
        const metric = await measureNativeRustLoc({ repoRoot: root });
        assert.equal(
          metric.details.problems.some((message) => message.includes("locked.rs cannot be read")),
          true,
        );
        const measurement = await measureArchitectureRatchet({ repoRoot: root });
        assert.equal(measurement.problems.length > 0, true);
      }
    } finally {
      await fs.chmod(locked, 0o644);
    }
  });
});

test("cargo graph resolves workspace inheritance, locality, and requested activation", async () => {
  await withFixtureTree({
    "Cargo.toml": [
      "[workspace]",
      'members = ["crates/licoup-native"]',
      "",
      "[workspace.dependencies]",
      'renamed-workflow = { package = "licoup-workflow", path = "components/workflow" }',
      "",
    ].join("\n"),
    "crates/licoup-native/Cargo.toml": [
      "[package]",
      'name = "licoup-native"',
      'version = "0.0.0"',
      "",
      "[dependencies]",
      "renamed-workflow = { workspace = true }",
      'licoup-workflow = "1.0.0"',
      'licoup-mcp = { path = "../licoup-mcp", optional = true }',
      "",
      "[features]",
      'default = ["licoup-mcp"]',
      "",
    ].join("\n"),
    "components/workflow/Cargo.toml": crateManifest("licoup-workflow"),
    "crates/licoup-mcp/Cargo.toml": crateManifest("licoup-mcp"),
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["workflow.v1", "Optional", "org.licoland.feature.workflow"],
      ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
    ]),
  }, async (root) => {
    const metric = await measureKernelOptionalCargoEdges({ repoRoot: root });
    assert.deepEqual(metric.ratchet.edges, [
      "licoup-native -> licoup-mcp (optional-active)",
      "licoup-native -> licoup-workflow (dependencies)",
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
      "dotted.optional = true",
      "",
      "[dependencies.delta]",
      'package = "licoup-workflow"',
      'path = "../licoup-workflow"',
      "",
    ].join("\n"),
    "crates/licoup-mcp/Cargo.toml": crateManifest("licoup-mcp"),
    "crates/licoup-workflow/Cargo.toml": crateManifest("licoup-workflow"),
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
      ["workflow.v1", "Optional", "org.licoland.feature.workflow"],
    ]),
  }, async (root) => {
    const metric = await measureKernelOptionalCargoEdges({ repoRoot: root });
    assert.deepEqual(metric.ratchet.edges, [
      "licoup-native -> licoup-workflow (dependencies)",
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
      "licoup-workflow": "^2.0.0",
      "licoup-mcp": { git: "https://example.invalid/mcp.git" },
    }),
    "crates/licoup-workflow/Cargo.toml": crateManifest("licoup-workflow"),
    "crates/licoup-mcp/Cargo.toml": crateManifest("licoup-mcp"),
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["workflow.v1", "Optional", "org.licoland.feature.workflow"],
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
      "org.licoland.feature.mcp -> codex-plugin",
      "org.licoland.feature.mcp -> subagents-mcp",
    ]);
    assert.deepEqual(metric.details.problems, []);
  });
});

test("packaging rejects a new host bundle, a replaced binary, an unknown binary, and an unknown package", async () => {
  await withFixtureTree(packagingFixture({
    modules: {
      "subagents-mcp": { enabled: true, cargoBin: "lico-subagent-mcp" },
      "codex-plugin": { enabled: true, embeddedCargoBin: "lico-subagent-mcp" },
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
    assert.equal(metric.ratchet.bundled_bindings, 4);
  });

  await withFixtureTree(packagingFixture({
    modules: {
      "subagents-mcp": { enabled: true, cargoBin: "lico-other" },
      "codex-plugin": { enabled: true, embeddedCargoBin: "lico-subagent-mcp" },
      "gateway-sidecar": { enabled: true, cargoBin: "lico-gateway" },
    },
    nativeBins: ["licoup-cli", "lico-gateway", "lico-other"],
  }), async (root) => {
    const metric = await measureOptionalCapabilitiesInPackaging({ repoRoot: root });
    assert.equal(
      metric.details.problems.some((message) =>
        message.includes("subagents-mcp") && message.includes("is not produced")),
      true,
    );
  });
});

function packagingFixture({
  modules = {
    "subagents-mcp": { enabled: true, cargoBin: "lico-subagent-mcp" },
    "codex-plugin": { enabled: true, embeddedCargoBin: "lico-subagent-mcp" },
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
  };
}

test("baseline comparison fails a regression and prompts an improvement", () => {
  const baseline = {
    native_rust_loc: { non_blank_lines: 10 },
    kernel_optional_cargo_edges: {
      value: 1,
      edges: ["a -> b (dependencies)"],
      unknown_optional_packages: [],
      unknown_optional_manifests: [],
    },
  };
  const regression = formatRatchetComparison(compareRatchetPayloads(baseline, {
    native_rust_loc: { non_blank_lines: 12 },
    kernel_optional_cargo_edges: {
      value: 2,
      edges: ["a -> b (dependencies)", "a -> c (dependencies)"],
      unknown_optional_packages: [],
      unknown_optional_manifests: [],
    },
  }));
  assert.match(regression.regressions[0], /native_rust_loc\.non_blank_lines grew from 10 to 12/u);
  assert.match(regression.regressions[1], /kernel_optional_cargo_edges\.value grew from 1 to 2/u);
  assert.match(
    regression.regressions[2],
    /kernel_optional_cargo_edges\.edges gained a -> c \(dependencies\)/u,
  );

  const improvement = formatRatchetComparison(compareRatchetPayloads(baseline, {
    native_rust_loc: { non_blank_lines: 8 },
    kernel_optional_cargo_edges: {
      value: 0,
      edges: [],
      unknown_optional_packages: [],
      unknown_optional_manifests: [],
    },
  }));
  assert.equal(improvement.regressions.length, 0);
  assert.equal(improvement.improvements.length, 3);
  assert.match(improvement.improvements[0], /update the baseline/u);
});

test("every metric regresses with an actionable message", () => {
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
    native_rust_loc: { non_blank_lines: 100 },
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
    native_rust_loc: { non_blank_lines: 101 },
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
  assert.match(joined, /grew from 100 to 101/u);
});

test("recording refuses to raise a value and accepts an improvement", async () => {
  await withFixtureTree({}, async (root) => {
    const metric = (nonBlankLines) => [
      { id: "native_rust_loc", ratchet: { non_blank_lines: nonBlankLines } },
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
    assert.deepEqual(stored.metrics.native_rust_loc, { non_blank_lines: 8 });
    assert.equal(stored.schema, "licoup-architecture-ratchet-baseline.v1");
  });
});

function completeFixture(extraFiles = {}) {
  return {
    "Cargo.toml": "[workspace]\nmembers = [\"crates/licoup-native\"]\n",
    "crates/licoup-native/Cargo.toml": crateManifest("licoup-native"),
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
    "apps/desktop/packaging.modules.json": JSON.stringify({
      modules: {
        "subagents-mcp": { enabled: true, cargoBin: "lico-subagent-mcp" },
        "codex-plugin": { enabled: true, embeddedCargoBin: "lico-subagent-mcp" },
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

test("check phase fails a new hidden spawn and prompts an improving baseline update", async () => {
  await withFixtureTree(completeFixture(), async (root) => {
    const recorded = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(recorded.ok, true);

    await fs.writeFile(
      path.join(root, "crates/licoup-native/src/domain/domain_only.rs"),
      'pub fn hidden() {\n  Command::new(\n    "npm",\n  );\n}\n',
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

test("real repository metrics stay internally consistent", async () => {
  const metric = await measureDeveloperToolSites({ repoRoot });
  assert.deepEqual(metric.details.problems ?? [], []);
  assert.equal(metric.ratchet.execution_sites, 10);
  assert.equal(metric.ratchet.unallowlisted_sites, 0);
  assert.deepEqual(metric.details.unallowlisted_sites, []);
  assert.deepEqual(metric.details.invalid_allowlist, []);
  assert.equal(metric.details.stale_allowlist.length, 0);
  assert.equal(metric.ratchet.execution_site_ids.length, 17);
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
