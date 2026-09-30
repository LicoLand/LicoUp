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
  OPTIONAL_CAPABILITY_ARTIFACTS,
  OPTIONAL_CAPABILITY_BUNDLES,
  OPTIONAL_CAPABILITY_CRATES,
} from "../../../apps/desktop/scripts/client-architecture/ratchet/definitions.mjs";
import {
  classifyToolOccurrences,
  inspectDeveloperToolSites,
  stripCfgTestItems,
} from "../../../apps/desktop/scripts/client-architecture/ratchet/developer-tools.mjs";
import { collectManifestGraph, defaultActivatedDependencies } from "../../../apps/desktop/scripts/client-architecture/ratchet/cargo-manifest.mjs";
import {
  checkArchitectureRatchet,
  recordArchitectureRatchet,
} from "../../../apps/desktop/scripts/client-architecture/checks/ratchet.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

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
      `    ("${capability}", PackOwnership::${kind}("${packageId}")),`)
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

function classifyRust(source, crossFileWrappers = new Set()) {
  return classifyToolOccurrences({ source, language: "rust", crossFileWrappers });
}

function summary(occurrences) {
  return occurrences.map((entry) => [entry.tool, entry.classification, entry.rule]);
}

test("developer-tool classification catches multiline, alias, shell, wrapper, and dynamic execution", () => {
  const multiline = classifyRust(
    'fn start() {\n  Command::new(\n\n\n\n\n    "node",\n  ).spawn();\n}\n',
  );
  assert.deepEqual(summary(multiline), [
    ["node", "execution", "statement-execution-token"],
  ]);

  const alias = classifyRust(
    'use std::process::Command as Cmd;\nfn start() {\n  Cmd::new("node").spawn();\n}\n',
  );
  assert.deepEqual(summary(alias), [
    ["node", "execution", "statement-execution-token"],
  ]);

  const shell = classifyRust(
    'const SCRIPT: &str = "node /tmp/agent.js";\nfn start() {\n  Command::new("sh").args(["-c", SCRIPT]).status();\n}\n',
  );
  assert.deepEqual(summary(shell), [
    ["node", "execution", "bound-program-execution"],
  ]);

  const wrapper = classifyRust([
    "fn run_tool(tool: &str) {",
    "  Command::new(tool);",
    "}",
    "// padding keeps the call outside the direct statement",
    "// padding",
    "// padding",
    "// padding",
    "fn main() {",
    '  run_tool("npx");',
    "}",
    "",
  ].join("\n"));
  assert.deepEqual(summary(wrapper), [
    ["npx", "execution", "wrapper-call-argument"],
  ]);

  const dynamic = classifyRust([
    "fn read() -> String { String::new() }",
    "fn start() {",
    "  let program = read();",
    "  Command::new(program);",
    "}",
    'const KIND: &str = "uvx";',
    "",
  ].join("\n"));
  assert.deepEqual(summary(dynamic), [
    ["uvx", "execution", "file-executes-variable-program"],
  ]);

  const reference = classifyRust('const CHANNEL: &str = "pip";\n');
  assert.deepEqual(summary(reference), [
    ["pip", "reference", "no-execution-context"],
  ]);
});

test("commented-out commands never count as execution", () => {
  const source = [
    "fn keep() {",
    '  // Command::new("node");',
    '  /* Command::new("npm");',
    '     Command::new("python3"); */',
    "}",
    "",
  ].join("\n");
  assert.deepEqual(classifyRust(source), []);
});

test("same file multiple calls are distinct sites and cannot share one allowlist entry", async () => {
  const file = "crates/demo/src/lib.rs";
  const twoCalls = [
    "pub fn a() {",
    '  Command::new("node").spawn();',
    "}",
    "pub fn b() {",
    '  Command::new("node").spawn();',
    "}",
    "",
  ].join("\n");
  await withFixtureTree({ [file]: twoCalls }, async (root) => {
    const blanket = await inspectDeveloperToolSites({
      repoRoot: root,
      readdir: fs.readdir,
      readFile: fs.readFile,
      allowlist: [{
        file,
        tool: "node",
        ordinal: 1,
        reason: "justified first call site for the fixture",
      }],
    });
    assert.deepEqual(blanket.executionSites.map((site) => site.id), [
      `${file}::node::1`,
      `${file}::node::2`,
    ]);
    assert.deepEqual(blanket.unallowlisted.map((site) => site.id), [
      `${file}::node::2`,
    ]);

    const emptyReason = await inspectDeveloperToolSites({
      repoRoot: root,
      readdir: fs.readdir,
      readFile: fs.readFile,
      allowlist: [{ file, tool: "node", ordinal: 1, reason: "   " }],
    });
    assert.equal(emptyReason.invalidAllowlist.length, 1);
    assert.match(emptyReason.invalidAllowlist[0], /meaningful justification/u);
    assert.deepEqual(emptyReason.unallowlisted.map((site) => site.id), [
      `${file}::node::1`,
      `${file}::node::2`,
    ]);

    const ordinalMissing = await inspectDeveloperToolSites({
      repoRoot: root,
      readdir: fs.readdir,
      readFile: fs.readFile,
      allowlist: [{ file, tool: "node", reason: "a file-level reason without an ordinal" }],
    });
    assert.equal(ordinalMissing.invalidAllowlist.length, 1);
    assert.match(ordinalMissing.invalidAllowlist[0], /positive ordinal/u);
  });
});

test("cfg(test) fixtures and test files do not count as runtime code", async () => {
  assert.equal(
    stripCfgTestItems('fn keep() {}\n#[cfg(test)]\nmod tests {\n  fn t() { Command::new("node"); }\n}\nfn tail() {}\n'),
    "fn keep() {}\n\nfn tail() {}\n",
  );
  await withFixtureTree({
    "crates/demo/src/lib.rs": '#[cfg(test)]\nmod tests {\n  fn t() { Command::new("node"); }\n}\n',
    "crates/demo/src/tests.rs": 'fn t() { Command::new("npm"); }\n',
    "crates/demo/tests/integration.rs": 'fn t() { Command::new("python3"); }\n',
  }, async (root) => {
    const inspection = await inspectDeveloperToolSites({
      repoRoot: root,
      readdir: fs.readdir,
      readFile: fs.readFile,
      allowlist: [],
    });
    assert.deepEqual(inspection.executionSites, []);
  });
});

test("layer imports use lexical source: lifetimes, braced uses, nested comments, raw strings", async () => {
  await withFixtureTree({
    "crates/licoup-native/src/domain/life.rs": "pub static R: &'static str = \"x\";\nuse crate::platform::Thing;\n",
    "crates/licoup-native/src/domain/braced.rs": "use crate::{platform::Thing, shared::Other};\n",
    "crates/licoup-native/src/domain/nested_comment.rs":
      "/* outer /* crate::platform */ still a comment */\npub fn x() {}\n",
    "crates/licoup-native/src/domain/raw.rs": 'pub const NOTE: &str = r#"crate::platform::x"#;\n',
    "crates/licoup-native/src/domain/a/b/c.rs":
      "use super::super::super::super::platform::x;\n",
    "crates/licoup-native/src/platform/mod.rs": "use crate::{domain::Thing};\n",
    "crates/licoup-native/src/platform/comment.rs": "// crate::domain\n",
  }, async (root) => {
    const metric = await measureNativeLayerImports({ repoRoot: root });
    assert.deepEqual(metric.ratchet.domain_to_platform_files, [
      "crates/licoup-native/src/domain/a/b/c.rs",
      "crates/licoup-native/src/domain/braced.rs",
      "crates/licoup-native/src/domain/life.rs",
    ]);
    assert.deepEqual(metric.ratchet.platform_to_domain_files, [
      "crates/licoup-native/src/platform/mod.rs",
    ]);
    assert.deepEqual(metric.details.problems, []);
  });
});

test("native size counts non-blank lines under src only", async () => {
  await withFixtureTree({
    "crates/licoup-native/src/lib.rs": "pub mod a;\n\n// comment\n\nfn x() {}\n",
    "crates/licoup-native/src/a.rs": "use x;\r\n\r\n",
    "crates/licoup-native/build.rs": "fn ignored() {}\n",
    "crates/licoup-native/benches/native.rs": "fn ignored() {}\n",
  }, async (root) => {
    const metric = await measureNativeRustLoc({ repoRoot: root });
    assert.equal(metric.ratchet.non_blank_lines, 4);
    assert.equal(metric.details.files, 2);
  });
});

test("missing native sources are a problem, never an improvement to zero", async () => {
  await withFixtureTree({
    "Cargo.toml": "[workspace]\n",
    "crates/licoup-native/Cargo.toml": crateManifest("licoup-native"),
  }, async (root) => {
    const metric = await measureNativeRustLoc({ repoRoot: root });
    assert.equal(metric.ratchet.non_blank_lines, 0);
    assert.equal(metric.details.problems.length > 0, true);
    assert.match(metric.details.problems.join("\n"), /crates\/licoup-native\/src is missing/u);

    const measurement = await measureArchitectureRatchet({ repoRoot: root });
    assert.equal(measurement.problems.length > 0, true);
  });
});

test("cargo graph resolves workspace inheritance, locality, and default activation", async () => {
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
    assert.deepEqual(metric.ratchet.unknown_optional_packages, []);
    assert.deepEqual(metric.ratchet.unknown_optional_manifests, []);
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
      "licoup-native -> licoup-mcp (optional, inactive by default features)",
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

test("unknown optional ownership fails the check and refuses recording", async () => {
  await withFixtureTree(completeFixture({
    "crates/licoup-extension-contracts/src/deployment.rs": deploymentSource([
      ["conversation.v1", "Core", "org.licoland.core"],
      ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
      ["brand-new.v1", "Optional", "org.licoland.feature.brand-new"],
    ]),
  }), async (root) => {
    const measurement = await measureArchitectureRatchet({ repoRoot: root });
    assert.equal(
      measurement.problems.some((message) =>
        message.includes("org.licoland.feature.brand-new")),
      true,
    );

    const record = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(record.ok, false);
    assert.match(record.message, /refusing to record/u);

    const failures = [];
    const state = await checkArchitectureRatchet({
      repoRoot: root,
      fail: (message) => failures.push(message),
    });
    assert.equal(state.ratchetReport.status, "baseline-unrecorded");
    assert.equal(
      failures.some((message) => message.includes("org.licoland.feature.brand-new")),
      true,
    );
  });
});

test("unknown optional ownership fails even with a seeded baseline", async () => {
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

  await withFixtureTree(packagingFixture({
    deploymentRows: [
      ["conversation.v1", "Core", "org.licoland.core"],
      ["mcp-server.v1", "Optional", "org.licoland.feature.mcp"],
      ["brand-new.v1", "Optional", "org.licoland.feature.brand-new"],
    ],
  }), async (root) => {
    const metric = await measureOptionalCapabilitiesInPackaging({ repoRoot: root });
    assert.equal(
      metric.details.problems.some((message) =>
        message.includes("org.licoland.feature.brand-new")),
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
  assert.match(
    regression.regressions[1],
    /kernel_optional_cargo_edges\.value grew from 1 to 2/u,
  );
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
      execution_site_ids: ["file.rs::npm::1"],
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
      execution_site_ids: ["file.rs::npm::1", "other.rs::node::1"],
      unallowlisted_site_ids: ["other.rs::node::1"],
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
    const unchanged = await recordRatchetBaseline({ repoRoot: root, metrics: metric(10) });
    assert.equal(unchanged.ok, true);
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
    assert.equal(passState.ratchetMetrics.developerToolUnallowlistedSites, 0);
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
        message.includes("domain_only.rs") &&
        message.includes("without a justified allowlist entry")),
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

test("record command refuses while an unjustified execution site exists", async () => {
  await withFixtureTree(completeFixture({
    "crates/licoup-native/src/domain/spawn.rs": 'pub fn spawn() {\n  Command::new("uvx");\n}\n',
  }), async (root) => {
    const record = await recordArchitectureRatchet({ repoRoot: root });
    assert.equal(record.ok, false);
    assert.match(record.message, /unjustified developer-tool execution sites/u);
    assert.deepEqual(record.sites.map((site) => site.id), [
      "crates/licoup-native/src/domain/spawn.rs::uvx::1",
    ]);
  });
});

test("invalid allowlist entries become measurement problems and leave sites unjustified", async () => {
  const file = "crates/demo/src/lib.rs";
  await withFixtureTree({
    [file]: 'pub fn run() {\n  Command::new("node").spawn();\n}\n',
  }, async (root) => {
    const metric = await measureDeveloperToolSites({
      repoRoot: root,
      allowlist: [{ file, tool: "node", ordinal: 1, reason: "   " }],
    });
    assert.equal(metric.details.problems.length, 1);
    assert.match(metric.details.problems[0], /meaningful justification/u);
    assert.equal(metric.ratchet.unallowlisted_sites, 1);
    assert.deepEqual(metric.details.unallowlisted_sites.map((site) => site.id), [
      `${file}::node::1`,
    ]);
  });
});

test("real repository metrics stay internally consistent", async () => {
  const metric = await measureDeveloperToolSites({ repoRoot });
  assert.deepEqual(metric.details.problems ?? [], []);
  assert.equal(metric.ratchet.unallowlisted_sites, 0);
  assert.deepEqual(metric.details.unallowlisted_sites, []);
  assert.deepEqual(metric.details.invalid_allowlist, []);
  assert.equal(metric.details.stale_allowlist.length, 0);
  assert.equal(metric.ratchet.execution_sites > 0, true);
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
  for (const [packageId, declaration] of Object.entries(OPTIONAL_CAPABILITY_ARTIFACTS)) {
    assert.equal(declaration.evidence.length > 0, true, packageId);
  }
});
