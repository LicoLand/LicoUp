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
import { RUST_DOMAIN_MODULES } from "../client-module-catalog/groups/rust-domain.mjs";
import { RUST_PLATFORM_MODULES } from "../client-module-catalog/groups/rust-platform.mjs";

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
        assert.equal(moduleCommand.args[packageIndex + 1], "licoup-native");
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
  assert.match(docs[0], /commit\s+gate never builds or publishes every platform/iu);
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
    ...await sourceFiles("crates/lico-catalog-convergence/src", ".rs"),
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

test("shared Flutter and Rust manifests select their own technology families", () => {
  const flutter = selectModulesForChangedPaths(["apps/desktop/pubspec.yaml"]);
  assert.deepEqual(ids(flutter), ["flutter.composition.dependencies"]);

  const rust = selectModulesForChangedPaths(["Cargo.lock"]);
  assert.deepEqual(ids(rust), ["rust.composition"]);
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

test("architecture and package facades retain precise source-bundle ownership", () => {
  const architectureSources = [
    "apps/desktop/scripts/verify-client-architecture.mjs",
    "apps/desktop/scripts/client-architecture/assertions.mjs",
    "apps/desktop/scripts/client-architecture/context.mjs",
    "apps/desktop/scripts/client-architecture/filesystem.mjs",
    "apps/desktop/scripts/client-architecture/checks/composition.mjs",
    "apps/desktop/scripts/client-architecture/checks/flutter.mjs",
    "apps/desktop/scripts/client-architecture/checks/flutter/mobile-relay-bridges.mjs",
    "apps/desktop/scripts/client-architecture/checks/flutter/physical-layers-and-libraries.mjs",
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
  const packageSources = [
    "apps/desktop/scripts/package-client.mjs",
    "apps/desktop/scripts/package-client/build/flutter.mjs",
    "apps/desktop/scripts/package-client/build/native.mjs",
    "apps/desktop/scripts/package-client/build/swift.mjs",
    "apps/desktop/scripts/package-client/bundle-resolver/linux.mjs",
    "apps/desktop/scripts/package-client/bundle-resolver/macos.mjs",
    "apps/desktop/scripts/package-client/bundle-resolver/windows.mjs",
    "apps/desktop/scripts/package-client/cli-policy.mjs",
    "apps/desktop/scripts/package-client/config-codec.mjs",
    "apps/desktop/scripts/package-client/macos/install.mjs",
    "apps/desktop/scripts/package-client/macos/metadata.mjs",
    "apps/desktop/scripts/package-client/macos/signing.mjs",
    "apps/desktop/scripts/package-client/module-selection.mjs",
    "apps/desktop/scripts/package-client/orchestrator.mjs",
    "apps/desktop/scripts/package-client/portable-manifest.mjs",
    "apps/desktop/scripts/package-client/process-runner.mjs",
    "apps/desktop/scripts/package-client/pub-cache.mjs",
    "apps/desktop/scripts/package-client/resource-assembly.mjs",
    "apps/desktop/scripts/package-client/source-staging.mjs",
    "apps/desktop/scripts/package-client/windows-manifest.mjs",
  ];
  const packageTest =
    "tests/contract/client/package-client/package-client-source-bundle.test.mjs";
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

  for (const relativePath of packageSources) {
    const expected = [
      "regression.package-client-source-bundle",
      "packaging.client-plan",
    ];
    if (relativePath.includes("/bundle-resolver/") ||
        relativePath.endsWith("/resource-assembly.mjs")) {
      expected.unshift("regression.subagent-mcp");
    }
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), expected);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([packageTest])), [
    "regression.package-client-source-bundle",
  ]);

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
  assert.deepEqual(packageBundle.inputs, [...packageSources, packageTest]);
  assert.deepEqual(packageBundle.command.args, ["--test", packageTest]);
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
  for (const relativePath of packageSources) {
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

test("client module regression tests retain seven ordinary owned leaves", async () => {
  const aggregatePath = "tests/contract/client/client-module-regression.test.mjs";
  const aggregate = await fs.readFile(path.join(repoRoot, aggregatePath), "utf8");
  assert.equal(aggregate.includes("test("), false);
  assert.equal(aggregate.includes("function ids("), false);

  const leafRoot = "tools/regression/client-module-regression-tests";
  const leafFiles = (await fs.readdir(path.join(repoRoot, leafRoot), {
    withFileTypes: true,
  }))
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .sort();
  assert.deepEqual(leafFiles, [
    "catalog-integrity.mjs",
    "conversation-ownership.mjs",
    "flutter-selection.mjs",
    "platform-driver-ownership.mjs",
    "runner-safety.mjs",
    "rust-selection.mjs",
    "secure-mesh-ownership.mjs",
    "support.mjs",
  ]);

  const expectedTestCounts = new Map([
    ["catalog-integrity.mjs", 14],
    ["conversation-ownership.mjs", 6],
    ["flutter-selection.mjs", 4],
    ["platform-driver-ownership.mjs", 20],
    ["runner-safety.mjs", 9],
    ["rust-selection.mjs", 10],
    ["secure-mesh-ownership.mjs", 17],
  ]);
  const registeredNames = new Set();
  for (const [leafFile, expectedCount] of expectedTestCounts) {
    const relativePath = `${leafRoot}/${leafFile}`;
    const leafSource = await fs.readFile(path.join(repoRoot, relativePath), "utf8");
    const names = [...leafSource.matchAll(/^test\("([^"]+)"/gmu)]
      .map((match) => match[1]);
    assert.equal(names.length, expectedCount, leafFile);
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
  assert.equal(registeredNames.size, 80);
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
