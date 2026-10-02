import {
  assert,
  fs,
  path,
  test,
  CLIENT_MODULE_CATALOG,
  selectModulesForChangedPaths,
  validateClientModuleCatalog,
  main,
  repoRoot,
  ids,
  sourceFiles,
} from "./support.mjs";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { CLIENT_COMPATIBILITY_ENTRIES } from "../client-regression-entries/index.mjs";
import {
  assembleClientModuleCatalog,
  defineModule,
  node,
} from "../client-module-catalog/helpers.mjs";
import { CLIENT_MODULE_ID_ORDER } from "../client-module-catalog/order.mjs";
import { BRIDGE_PACKAGING_RELEASE_MODULES } from "../client-module-catalog/groups/bridge-packaging-release.mjs";
import { FLUTTER_MODULES } from "../client-module-catalog/groups/flutter.mjs";
import { REGRESSION_MODULES } from "../client-module-catalog/groups/regression.mjs";
import { RUST_CORE_MODULES } from "../client-module-catalog/groups/rust-core.mjs";
import { RUST_CATALOG_CONVERGENCE_MODULES } from "../client-module-catalog/groups/rust-catalog-convergence.mjs";
import { RUST_COMPONENT_MODULES } from "../client-module-catalog/groups/rust-components.mjs";
import { RUST_DOMAIN_MODULES } from "../client-module-catalog/groups/rust-domain.mjs";
import { RUST_PLATFORM_MODULES } from "../client-module-catalog/groups/rust-platform.mjs";

function trackedTestEntrypoints() {
  const result = spawnSync("git", ["ls-files", "-z"], {
    cwd: repoRoot,
    encoding: "buffer",
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
  });
  assert.equal(result.status, 0, "tracked test inventory requires git ls-files");
  return result.stdout.toString("utf8").split("\0").filter((file) =>
    file.endsWith(".test.mjs") ||
    /(?:^|\/)test\/.*_test\.dart$/u.test(file) ||
    /(?:^|\/)integration_test\/.*_test\.dart$/u.test(file) ||
    /^crates\/[^/]+\/tests\/[^/]+\.rs$/u.test(file) ||
    /\/src\/(?:test|androidTest)\/.*Test\.kt$/u.test(file));
}

function moduleSelects(module, file) {
  return module.inputs.some((input) => input.endsWith("/**")
    ? file === input.slice(0, -3) || file.startsWith(input.slice(0, -2))
    : file === input);
}

const nodeReachability = new WeakMap();

function nodeReachableFiles(module) {
  if (module.command.program !== "node") return new Set();
  const cached = nodeReachability.get(module);
  if (cached) return cached;
  const pending = module.command.args.filter((argument) =>
    argument.endsWith(".mjs") && !argument.startsWith("-") &&
    !argument.includes("*") && !argument.includes("?"));
  const found = new Set();
  while (pending.length > 0) {
    const relativePath = pending.pop();
    if (found.has(relativePath)) continue;
    const absolutePath = path.join(repoRoot, relativePath);
    try {
      const source = requireText(absolutePath);
      found.add(relativePath);
      for (const match of source.matchAll(/["']([^"']+\.mjs)["']/gmu)) {
        const reference = match[1];
        const candidate = reference.startsWith(".")
          ? path.posix.normalize(path.posix.join(path.posix.dirname(relativePath), reference))
          : reference;
        if (!candidate.startsWith("../") && !found.has(candidate)) pending.push(candidate);
      }
    } catch {
      // Non-file command arguments are not JavaScript entry points.
    }
  }
  nodeReachability.set(module, found);
  return found;
}

function requireText(absolutePath) {
  return readFileSync(absolutePath, "utf8");
}

function flutterCommandExecutes(module, file) {
  const args = module.command.args;
  const separator = args.indexOf("--");
  if (separator < 0 || args[separator + 1] !== "flutter" || args[separator + 2] !== "test") {
    return false;
  }
  const cwdIndex = args.indexOf("--cwd");
  const commandRoot = cwdIndex >= 0 ? args[cwdIndex + 1] : ".";
  if (!file.startsWith(`${commandRoot}/`)) return false;
  const localPath = file.slice(commandRoot.length + 1);
  const selections = args.slice(separator + 3).filter((argument, index, tail) =>
    !argument.startsWith("-") && tail[index - 1] !== "--name");
  return selections.length === 0
    ? localPath.startsWith("test/")
    : selections.some((selection) =>
      localPath === selection || localPath.startsWith(`${selection}/`));
}

function rustCommandExecutes(module, file) {
  if (module.command.program !== "cargo" || module.command.args[0] !== "test") return false;
  const match = /^(crates\/[^/]+)\/tests\/([^/]+)\.rs$/u.exec(file);
  if (!match || module.command.args.includes("--lib") || module.command.args.includes("--bin")) {
    return false;
  }
  const [, crateRoot, target] = match;
  const manifestIndex = module.command.args.indexOf("--manifest-path");
  if (manifestIndex < 0 || module.command.args[manifestIndex + 1] !== `${crateRoot}/Cargo.toml`) {
    return false;
  }
  const targetIndex = module.command.args.indexOf("--test");
  return targetIndex < 0 || module.command.args[targetIndex + 1] === target;
}

function nodeCommandExecutesRust(module, file) {
  if (module.command.program !== "node" || !file.endsWith(".rs")) return false;
  const target = path.posix.basename(file, ".rs");
  for (const source of nodeReachableFiles(module)) {
    try {
      const text = readFileSync(path.join(repoRoot, source), "utf8");
      if (text.includes(file) || text.includes(`"${target}"`) || text.includes(`'${target}'`)) {
        return true;
      }
    } catch {
      // Non-source command arguments are ignored by the reachability scan.
    }
  }
  return false;
}

function androidCommandExecutes(module, file) {
  if (!file.endsWith("Test.kt")) return false;
  const args = module.command.args;
  if (args[0] === "tools/scripts/client-android-native-tests.mjs") return true;
  const separator = args.indexOf("--");
  if (separator < 0 || !["./gradlew", "gradlew.bat"].includes(args[separator + 1])) return false;
  if (!args.includes(":app:testDebugUnitTest")) return false;
  const className = path.posix.basename(file, ".kt");
  const filters = args.flatMap((argument, index) => args[index - 1] === "--tests" ? [argument] : []);
  return filters.length === 0 || filters.some((filter) => filter.endsWith(`.${className}`));
}

function moduleExecutes(module, file) {
  if (module.command.program === "node" && nodeReachableFiles(module).has(file)) return true;
  if (nodeCommandExecutesRust(module, file)) return true;
  if (flutterCommandExecutes(module, file)) return true;
  if (rustCommandExecutes(module, file)) return true;
  if (androidCommandExecutes(module, file)) return true;
  return module.id === "regression.continuous-assistant-ux" &&
    file.startsWith("apps/desktop/test/continuous_assistant_journeys/");
}

test("catalog declares every independently accepted client architecture family", () => {
  assert.equal(validateClientModuleCatalog(), true);
  const kinds = new Set(CLIENT_MODULE_CATALOG.map((module) => module.kind));
  for (const required of [
    "flutter-feature",
    "flutter-layer",
    "rust-domain",
    "rust-core",
    "rust-crate",
    "rust-platform",
    "rust-ffi",
    "platform-bridge",
    "packaging",
    "release",
    "regression-infrastructure",
    "architecture",
  ]) {
    assert.equal(kinds.has(required), true, `missing catalog family: ${required}`);
  }
  assert.equal(new Set(CLIENT_MODULE_CATALOG.map((module) => module.id)).size,
    CLIENT_MODULE_CATALOG.length);
  for (const module of CLIENT_MODULE_CATALOG) {
    assert.equal(Object.isFrozen(module), true);
    assert.equal(Object.isFrozen(module.inputs), true);
    assert.equal(Object.isFrozen(module.command), true);
    assert.equal(Object.isFrozen(module.command.args), true);
    assert.equal(module.inputs.length > 0, true);
    assert.equal(module.command.args.some((arg) => arg.includes("client:gate:")), false);
    assert.equal(["node", "cargo"].includes(module.command.program), true);
  }
});

test("both native protocol README languages select documentation governance", () => {
  for (const relativePath of [
    "packages/protocols/native-client/README.md",
    "packages/protocols/native-client/README.zh-CN.md",
  ]) {
    assert.equal(
      ids(selectModulesForChangedPaths([relativePath])).includes(
        "regression.documentation-governance",
      ),
      true,
      `${relativePath} must select its documentation owner`,
    );
  }
});

test("catalog validation rejects an implicit aggregate-gate command", () => {
  const invalid = [{
    id: "invalid.full-regression",
    kind: "release",
    summary: "invalid fixture",
    inputs: ["fixture.txt"],
    command: {
      program: "node",
      args: ["client:gate:source"],
      cwd: ".",
      timeoutMs: 1,
    },
  }];
  assert.throws(() => validateClientModuleCatalog(invalid), /must not invoke/u);
});

test("catalog commands reference existing dedicated scripts and test targets", async () => {
  for (const module of CLIENT_MODULE_CATALOG) {
    const moduleCommand = module.command;
    if (moduleCommand.program === "node") {
      const scriptPath = moduleCommand.args.find((argument) =>
        !argument.startsWith("-"));
      assert.notEqual(scriptPath, undefined);
      await fs.access(path.join(repoRoot, scriptPath));
      const flutterTestIndex = moduleCommand.args.indexOf("test");
      if (flutterTestIndex >= 0 && moduleCommand.args[flutterTestIndex - 1] === "flutter") {
        const flutterArgs = moduleCommand.args.slice(flutterTestIndex + 1);
        for (let index = 0; index < flutterArgs.length; index += 1) {
          const testPath = flutterArgs[index];
          if (testPath === "--name") {
            index += 1;
            continue;
          }
          if (testPath.startsWith("--")) continue;
          await fs.access(path.join(repoRoot, "apps/desktop", testPath));
        }
      }
    } else {
      const manifestIndex = moduleCommand.args.indexOf("--manifest-path");
      if (manifestIndex >= 0) {
        await fs.access(path.join(repoRoot, moduleCommand.args[manifestIndex + 1]));
      } else {
        const packageIndex = moduleCommand.args.indexOf("-p");
        assert.equal(packageIndex >= 0, true);
        const crate = moduleCommand.args[packageIndex + 1];
        assert.equal(
          crate === "licoup-native" ||
            crate === "licoup-protocol-bindings" ||
            crate === "licoup-foundation" ||
            (crate === "licoup-conversation" &&
              module.id === "rust.domain.conversation-continuity-store"),
          true,
          `${module.id} cargo package ${crate} is not a catalog crate`,
        );
      }
    }
  }
});

test("catalog inputs exist and exclude local-only document roots", async () => {
  const checked = new Set();
  for (const module of CLIENT_MODULE_CATALOG) {
    for (const input of module.inputs) {
      const relativePath = input.endsWith("/**") ? input.slice(0, -3) : input;
      if (checked.has(relativePath)) continue;
      checked.add(relativePath);
      assert.equal(
        relativePath.startsWith("docs/plans/") ||
          relativePath.startsWith("docs/reports/") ||
          relativePath.startsWith("cache/") ||
          relativePath.startsWith("build/"),
        false,
        `catalog input is local-only: ${relativePath}`,
      );
      await fs.access(path.join(repoRoot, relativePath));
    }
  }
});

test("package aliases remain thin and cannot route to an aggregate gate", async () => {
  const packageJson = JSON.parse(await fs.readFile(path.join(repoRoot, "package.json"), "utf8"));
  assert.deepEqual({
    run: packageJson.scripts["client:regression"],
    list: packageJson.scripts["client:regression:list"],
    selfTest: packageJson.scripts["client:regression:self-test"],
  }, {
    run: "node tools/scripts/client-module-regression.mjs",
    list: "node tools/scripts/client-module-regression.mjs --list",
    selfTest: "node tools/scripts/client-module-regression-self-test.mjs",
  });
  assert.equal(Object.entries(packageJson.scripts)
    .filter(([name]) => name.startsWith("client:regression"))
    .some(([, commandValue]) => commandValue.includes("client:gate:")), false);
});

test("tracked contribution guides require targeted closure and independent gates", async () => {
  const docs = await Promise.all([
    "CONTRIBUTING.md",
    "CONTRIBUTING.zh-CN.md",
  ].map((relativePath) => fs.readFile(path.join(repoRoot, relativePath), "utf8")));
  assert.match(docs[0], /run the smallest relevant checks/u);
  assert.match(docs[0], /mandatory Node-only source policy once/u);
  assert.match(docs[0], /commit\s+gate\s+never\s+builds\s+or\s+publishes\s+every\s+platform/iu);
  assert.match(docs[1], /开发过程中只运行与改动直接相关的最小检查/u);
  assert.match(docs[1], /只运行一次必需的 Node 源码策略/u);
  assert.match(docs[1], /提交门禁不会构建或发布所有平台/u);
  assert.deepEqual(ids(selectModulesForChangedPaths(["CONTRIBUTING.md"])),
    [
      "regression.infrastructure",
      "regression.public-client-docs",
      "regression.documentation-governance",
      "architecture.client-boundaries",
    ]);
});

test("catalog maps every Flutter, Rust, and platform-host source file", async () => {
  const candidates = [
    ...await sourceFiles("apps/desktop/lib", ".dart"),
    ...await sourceFiles("apps/desktop/test", ".dart"),
    ...await sourceFiles("apps/desktop/assets", ".json"),
    ...await sourceFiles("apps/desktop/assets", ".png"),
    ...await sourceFiles("apps/desktop/assets", ".svg"),
    ...await sourceFiles("crates/licoup-native/src", ".rs"),
    ...await sourceFiles("crates/licoup-native/tests", ".rs"),
    ...await sourceFiles("crates/licoup-protocol-bindings/src", ".rs"),
    ...await sourceFiles("crates/licoup-protocol-bindings/tests", ".rs"),
    ...await sourceFiles("crates/licoup-foundation/src", ".rs"),
    ...await sourceFiles("crates/lico-catalog-convergence/src", ".rs"),
    ...await sourceFiles("crates/licoup-mcp/src", ".rs"),
    ...await sourceFiles("apps/desktop/android/app/src/main", ".kt"),
    ...await sourceFiles("apps/desktop/ios/Runner", ".swift"),
    ...await sourceFiles("apps/desktop/macos", ".swift"),
    ...await sourceFiles("apps/desktop/linux/runner", ".cc"),
    ...await sourceFiles("apps/desktop/windows/runner", ".cpp"),
  ];
  const unmatched = candidates.filter((candidate) =>
    selectModulesForChangedPaths([candidate]).every((module) =>
      module.id === "architecture.client-boundaries"));
  assert.deepEqual(unmatched, []);
});

test("every tracked test entry has an executing engineering owner or explicit live classification", () => {
  const live = new Map();
  for (const entry of CLIENT_COMPATIBILITY_ENTRIES) {
    for (const input of entry.inputs) live.set(input, `${entry.kind}:${entry.id}:live`);
    for (const input of entry.unverifiedInputs) {
      live.set(input, `${entry.kind}:${entry.id}:unverified`);
    }
  }
  const missingSelection = [];
  const selectorOnly = [];
  const unclassified = [];
  for (const file of trackedTestEntrypoints()) {
    const selected = CLIENT_MODULE_CATALOG.filter((module) => moduleSelects(module, file));
    const executing = CLIENT_MODULE_CATALOG.filter((module) => moduleExecutes(module, file));
    if (executing.length > 0 && selected.length === 0 && !live.has(file)) missingSelection.push(file);
    if (selected.length > 0 && executing.length === 0 && !live.has(file)) selectorOnly.push(file);
    if (selected.length === 0 && executing.length === 0 && !live.has(file)) unclassified.push(file);
  }
  assert.deepEqual({ missingSelection, selectorOnly, unclassified }, {
    missingSelection: [],
    selectorOnly: [],
    unclassified: [],
  });
});

test("shared Flutter and Rust manifests select their own technology families", () => {
  const flutter = selectModulesForChangedPaths(["apps/desktop/pubspec.yaml"]);
  assert.deepEqual(ids(flutter), ["flutter.composition.dependencies"]);

  const rust = selectModulesForChangedPaths(["Cargo.lock"]);
  assert.deepEqual(ids(rust), ["rust.composition"]);
});

test("target-owned changes retain runnable hosts and exact target evidence obligations", () => {
  const cases = [
    [
      "crates/licoup-native/src/platform/secure_mesh_secret_store/platform_backends/linux.rs",
      "rust.platform.secure-mesh-secret-store.backend-linux",
      ["linux"],
    ],
    [
      "crates/licoup-native/src/platform/secure_mesh_secret_store/platform_backends/macos.rs",
      "rust.platform.secure-mesh-secret-store.backend-macos",
      ["darwin"],
    ],
    [
      "crates/licoup-foundation/src/platform/file_security/windows_acl.rs",
      "rust.platform.file-security.windows-acl",
      ["win32"],
    ],
    [
      "crates/licoup-native/src/domain/targets/platform_paths.rs",
      "rust.domain.targets.platform-paths",
      ["darwin", "linux", "win32"],
    ],
  ];
  for (const [input, moduleId, targetEvidenceHosts] of cases) {
    const module = selectModulesForChangedPaths([input])
      .find(({ id }) => id === moduleId);
    assert.ok(module, `${input} must select ${moduleId}`);
    assert.deepEqual(module.regression.runnableHosts, ["darwin", "linux", "win32"]);
    assert.deepEqual(module.regression.targetEvidenceHosts, targetEvidenceHosts);
  }
  const portable = CLIENT_MODULE_CATALOG.find(({ id }) =>
    id === "regression.repository-local-info-hygiene");
  assert.deepEqual(portable.regression.targetEvidenceHosts, []);
});

test("shared module roots select composition without leaf-regression fanout", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/mod.rs",
  ])), ["architecture.client-boundaries", "rust.composition"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mod.rs",
  ])), ["architecture.client-boundaries", "rust.composition"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/analysis_options.yaml",
  ])), ["flutter.composition.dependencies"]);
});

test("source-bundle contract keeps an independent regression leaf", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "tests/contract/client/secure-mesh-source-bundles.test.mjs",
  ])), ["regression.secure-mesh-source-bundles"]);
  const module = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.secure-mesh-source-bundles");
  assert.deepEqual(module.command.args, [
    "--test",
    "tests/contract/client/secure-mesh-source-bundles.test.mjs",
  ]);
});

test("agent-usage routing sources select the dedicated evidence verifier", () => {
  const module = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.client-agent-usage");
  assert.ok(module);
  for (const relativePath of [
    "apps/desktop/lib/src/composition/binding_shell_renderer.dart",
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_panel.dart",
    "apps/desktop/lib/src/frontend/shell/client_shell.dart",
  ]) {
    assert.equal(module.inputs.includes(relativePath), true);
    assert.equal(
      ids(selectModulesForChangedPaths([relativePath])).includes(
        "regression.client-agent-usage",
      ),
      true,
    );
  }
});

test("architecture and package facades retain precise source-bundle ownership", async () => {
  const architectureSources = [
    "tools/verify-client-boundary.mjs",
    "apps/desktop/scripts/verify-client-architecture.mjs",
    "apps/desktop/scripts/client-architecture/assertions.mjs",
    "apps/desktop/scripts/client-architecture/context.mjs",
    "apps/desktop/scripts/client-architecture/filesystem.mjs",
    "apps/desktop/scripts/client-architecture/checks/composition.mjs",
    "apps/desktop/scripts/client-architecture/checks/flutter.mjs",
    "apps/desktop/scripts/client-architecture/checks/flutter/mobile-relay-bridges.mjs",
    "apps/desktop/scripts/client-architecture/checks/flutter/physical-layers-and-libraries.mjs",
    "apps/desktop/scripts/client-architecture/checks/flutter/presentation-boundary.mjs",
    "apps/desktop/scripts/client-architecture/checks/flutter/shell-isolation-and-native-stdio.mjs",
    "apps/desktop/scripts/client-architecture/checks/foundations.mjs",
    "apps/desktop/scripts/client-architecture/checks/native.mjs",
    "apps/desktop/scripts/client-architecture/checks/native/command-and-file-transport.mjs",
    "apps/desktop/scripts/client-architecture/checks/native/conversation-domain.mjs",
    "apps/desktop/scripts/client-architecture/checks/native/crate-core-and-facade-bounds.mjs",
    "apps/desktop/scripts/client-architecture/checks/native/domain-and-crypto-boundaries.mjs",
    "apps/desktop/scripts/client-architecture/checks/native/secure-mesh-authority-and-custody.mjs",
    "apps/desktop/scripts/client-architecture/checks/native/secure-mesh-foundations-and-local-archive.mjs",
    "apps/desktop/scripts/client-architecture/checks/native/target-readiness-reducer.mjs",
    "apps/desktop/scripts/client-architecture/checks/platform.mjs",
    "apps/desktop/scripts/client-architecture/checks/platform/android-secure-mesh.mjs",
    "apps/desktop/scripts/client-architecture/checks/platform/ios-secure-mesh.mjs",
    "apps/desktop/scripts/client-architecture/checks/platform/runtime-drivers-and-local-service.mjs",
    "apps/desktop/scripts/client-architecture/checks/platform/target-serve-and-gateway.mjs",
    "apps/desktop/scripts/client-architecture/checks/privacy.mjs",
  ];
  const architectureTest =
    "tests/contract/client/client-architecture-modules.test.mjs";
  const packageAssets = [
    "apps/desktop/macos/CustodyHelper/Info.plist",
    "apps/desktop/macos/CustodyHelper/ProductionRelease.entitlements",
  ];
  const packageSources = [
    "apps/desktop/scripts/package-client.mjs",
    ...await sourceFiles("apps/desktop/scripts/package-client", ".mjs"),
  ];
  const packageTests = [
    "tests/contract/client/package-client/package-client-source-bundle.test.mjs",
    "tests/contract/client/package-client/macos-custody-helper.test.mjs",
  ];
  const planSources = [
    "apps/desktop/scripts/verify-client-plan.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/android-ios.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/client-boundary.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/crypto-redaction-handoff.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/docs-readiness.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/evidence-routing.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/linux-windows.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/package-and-runner.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/physical-evidence.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/secret-store.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/trust-release.mjs",
    "apps/desktop/scripts/verify-client-plan/dynamic-self-tests.mjs",
    "apps/desktop/scripts/verify-client-plan/shared/assert.mjs",
    "apps/desktop/scripts/verify-client-plan/shared/context.mjs",
    "apps/desktop/scripts/verify-client-plan/shared/fs.mjs",
    "apps/desktop/scripts/verify-client-plan/shared/sanitize.mjs",
  ];
  const planTests = [
    "tests/contract/client/verify-client-plan/verify-client-plan-leaf-fixtures.test.mjs",
    "tests/contract/client/verify-client-plan/verify-client-plan-ordering.test.mjs",
    "tests/contract/client/verify-client-plan/verify-client-plan-privacy.test.mjs",
    "tests/contract/client/verify-client-plan/verify-client-plan-source-bundle.test.mjs",
  ];

  for (const relativePath of architectureSources) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "regression.client-architecture-modules",
      "architecture.client-boundaries",
    ]);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([architectureTest])), [
    "regression.client-architecture-modules",
  ]);

  for (const relativePath of [...packageAssets, ...packageSources]) {
    const expected = [
      "regression.package-client-source-bundle",
      "packaging.client-plan",
    ];
    if (packageAssets.includes(relativePath)) {
      expected.unshift("bridge.macos");
    }
    if (relativePath.includes("/bundle-resolver/") ||
        relativePath.endsWith("/resource-assembly.mjs")) {
      expected.unshift("regression.subagent-mcp-common");
    }
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), expected);
  }
  for (const packageTest of packageTests) {
    assert.deepEqual(ids(selectModulesForChangedPaths([packageTest])), [
      "regression.package-client-source-bundle",
    ]);
  }

  for (const relativePath of planSources) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "regression.verify-client-plan-source-bundle",
      "packaging.verify-client-plan",
    ]);
  }
  for (const relativePath of planTests) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "regression.verify-client-plan-source-bundle",
    ]);
  }

  const architectureBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.client-architecture-modules");
  const packageBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.package-client-source-bundle");
  const planBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.verify-client-plan-source-bundle");
  assert.deepEqual(architectureBundle.inputs, [
    ...architectureSources,
    architectureTest,
  ]);
  assert.deepEqual(architectureBundle.command.args, ["--test", architectureTest]);
  assert.deepEqual(packageBundle.inputs, [...packageAssets, ...packageSources, ...packageTests]);
  assert.deepEqual(packageBundle.command.args, ["--test", ...packageTests]);
  assert.deepEqual(planBundle.inputs, [...planSources, ...planTests]);
  assert.deepEqual(planBundle.command.args, [
    "--test",
    "tests/contract/client/verify-client-plan/verify-client-plan-leaf-fixtures.test.mjs",
    "tests/contract/client/verify-client-plan/verify-client-plan-ordering.test.mjs",
    "tests/contract/client/verify-client-plan/verify-client-plan-privacy.test.mjs",
    "tests/contract/client/verify-client-plan/verify-client-plan-source-bundle.test.mjs",
  ]);
  assert.equal([...architectureBundle.inputs, ...packageBundle.inputs, ...planBundle.inputs]
    .some((relativePath) => relativePath.includes("*")), false);

  const architectureOwner = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "architecture.client-boundaries");
  const packageOwner = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "packaging.client-plan");
  const planOwner = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "packaging.verify-client-plan");
  for (const relativePath of architectureSources) {
    assert.equal(architectureOwner.inputs.includes(relativePath), true);
  }
  for (const relativePath of [...packageAssets, ...packageSources]) {
    assert.equal(packageOwner.inputs.includes(relativePath), true);
  }
  for (const relativePath of planSources) {
    assert.equal(planOwner.inputs.includes(relativePath), true);
  }
});

test("catalog physical groups retain a thin barrel and complete source ownership", async () => {
  const barrelPath = "tools/regression/client-module-catalog.mjs";
  const barrel = await fs.readFile(path.join(repoRoot, barrelPath), "utf8");
  assert.equal(barrel.includes("defineModule({"), false);
  assert.equal(barrel.includes("rustLayer("), false);

  const groupRoot = "tools/regression/client-module-catalog/groups";
  const groupFiles = (await fs.readdir(path.join(repoRoot, groupRoot), {
    withFileTypes: true,
  }))
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .sort();
  assert.deepEqual(groupFiles, [
    "bridge-packaging-release.mjs",
    "flutter.mjs",
    "regression.mjs",
    "rust-catalog-convergence.mjs",
    "rust-components.mjs",
    "rust-core.mjs",
    "rust-domain.mjs",
    "rust-platform.mjs",
  ]);

  const groups = [
    [REGRESSION_MODULES, new Set(["regression-infrastructure", "architecture"])],
    [FLUTTER_MODULES, new Set([
      "flutter-composition",
      "flutter-contract",
      "flutter-feature",
      "flutter-layer",
      "flutter-controller",
    ])],
    [RUST_DOMAIN_MODULES, new Set(["rust-domain"])],
    [RUST_CORE_MODULES, new Set(["rust-core"])],
    [RUST_CATALOG_CONVERGENCE_MODULES, new Set([
      "rust-crate",
      "rust-domain",
      "rust-platform",
      "rust-ffi",
    ])],
    [RUST_COMPONENT_MODULES, new Set(["rust-crate"])],
    [RUST_PLATFORM_MODULES, new Set([
      "rust-composition",
      "rust-platform",
      "rust-ffi",
    ])],
    [BRIDGE_PACKAGING_RELEASE_MODULES, new Set([
      "platform-bridge",
      "packaging",
      "release",
    ])],
  ];
  const groupedModules = groups.flatMap(([modules, allowedKinds]) => {
    assert.equal(Object.isFrozen(modules), true);
    for (const module of modules) {
      assert.equal(allowedKinds.has(module.kind), true, module.id);
    }
    return modules;
  });
  assert.equal(Object.isFrozen(CLIENT_MODULE_ID_ORDER), true);
  assert.deepEqual(
    CLIENT_MODULE_ID_ORDER,
    CLIENT_MODULE_CATALOG.map((module) => module.id),
  );
  assert.deepEqual(
    groupedModules.map((module) => module.id).sort(),
    CLIENT_MODULE_CATALOG.map((module) => module.id).sort(),
  );
  const groupedById = new Map(groupedModules.map((module) => [module.id, module]));
  for (const module of CLIENT_MODULE_CATALOG) {
    assert.strictEqual(groupedById.get(module.id), module);
  }

  for (const ownedPath of [
    "tools/regression/client-module-catalog/helpers.mjs",
    "tools/regression/client-module-catalog/order.mjs",
    "tools/regression/client-module-catalog/groups/rust-core.mjs",
    "tools/regression/client-module-catalog/groups/rust-catalog-convergence.mjs",
    "tools/regression/client-module-regression-tests/catalog-integrity.mjs",
  ]) {
    assert.deepEqual(ids(selectModulesForChangedPaths([ownedPath])), [
      "regression.infrastructure",
    ]);
  }
});

test("client module regression aggregate includes every owned test leaf", async () => {
  const aggregatePath = "tests/contract/client/client-module-regression.test.mjs";
  const aggregate = await fs.readFile(path.join(repoRoot, aggregatePath), "utf8");
  const leafRoot = "tools/regression/client-module-regression-tests";
  const leafFiles = (await fs.readdir(path.join(repoRoot, leafRoot), {
    withFileTypes: true,
  }))
    .filter((entry) => entry.isFile() && entry.name.endsWith(".mjs") &&
      entry.name !== "support.mjs")
    .map((entry) => entry.name)
    .sort();
  const importedLeaves = [...aggregate.matchAll(
    /import "\.\.\/\.\.\/\.\.\/tools\/regression\/client-module-regression-tests\/([^"/]+)";/gu,
  )].map((match) => match[1]).sort();
  assert.deepEqual(importedLeaves, leafFiles);
  const registeredNames = new Set();
  for (const leafFile of leafFiles) {
    const relativePath = `${leafRoot}/${leafFile}`;
    const leafSource = await fs.readFile(path.join(repoRoot, relativePath), "utf8");
    const names = [...leafSource.matchAll(/^test\("([^"]+)"/gmu)]
      .map((match) => match[1]);
    assert.ok(names.length > 0, leafFile);
    for (const name of names) {
      assert.equal(registeredNames.has(name), false, name);
      registeredNames.add(name);
    }
    assert.deepEqual(
      ids(selectModulesForChangedPaths([relativePath])),
      leafFile === "runner-safety.mjs"
        ? ["regression.infrastructure", "regression.test-artifact-lifecycle"]
        : ["regression.infrastructure"],
    );
  }
});

test("catalog assembly fails fast on duplicate missing and unexpected definitions", () => {
  const fixture = (id) => defineModule({
    id,
    kind: "rust-core",
    summary: "catalog assembly fixture",
    inputs: ["fixtures/" + id + ".txt"],
    command: node("fixtures/catalog-assembly.mjs"),
  });
  const first = fixture("fixture.one");
  const second = fixture("fixture.two");

  assert.throws(
    () => assembleClientModuleCatalog(["fixture.one", "fixture.one"], [[first]]),
    /duplicate client module order id/u,
  );
  assert.throws(
    () => assembleClientModuleCatalog(["fixture.one"], [[first, first]]),
    /duplicate client module definition/u,
  );
  assert.throws(
    () => assembleClientModuleCatalog(["fixture.one", "fixture.two"], [[first]]),
    /missing client module definitions/u,
  );
  assert.throws(
    () => assembleClientModuleCatalog(["fixture.one"], [[first, second]]),
    /unexpected client module definitions/u,
  );
});

test("Subagent MCP route sources select one hermetic verification module", () => {
  for (const relativePath of [
    "tests/product-e2e/cli/subagent-mcp/upstream.mjs",
    "tests/product-e2e/cli/subagent-mcp/upstream/codex-startup-recognition.mjs",
    "tests/product-e2e/cli/subagent-mcp/downstream.mjs",
    "tests/product-e2e/cli/subagent-mcp/interop-manifest.mjs",
    "tests/product-e2e/cli/subagent-mcp/common-authority.test.mjs",
    "tests/product-e2e/cli/subagent-mcp/security.test.mjs",
  ]) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "regression.subagent-mcp-verification-routes",
    ]);
  }
  const module = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.subagent-mcp-verification-routes");
  assert.ok(module);
  assert.doesNotMatch(JSON.stringify(module.command.args), /--live/u);
  for (const relativePath of [
    "tools/scripts/lib/agent-conversation-verification-models.mjs",
    "tools/scripts/lib/agent-conversation-verification-models.test.mjs",
    "tools/scripts/config/agent-conversation-verification-models.toml",
  ]) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "regression.subagent-mcp-verification-routes",
      "architecture.client-boundaries",
    ]);
  }
});
