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
import { migrationCrateTestArgs } from "../../scripts/migration-crate-tests.mjs";
import { readFileSync } from "node:fs";
import { CLIENT_COMPATIBILITY_ENTRIES } from "../client-regression-entries/index.mjs";
import { CLIENT_GATE_LANES } from "../../scripts/client-gate-policy.mjs";
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

test("archive transport changes select owner and real extractor consumers", () => {
  for (const relativePath of [
    "crates/licoup-foundation/src/core/safe_archive.rs",
    "crates/licoup-foundation/src/core/safe_archive/zip_structure.rs",
  ]) {
    const selected = ids(selectModulesForChangedPaths([relativePath]));
    for (const owner of [
      "rust.core.safe-archive", "rust.core.full-data-root-archive",
      "rust.domain.adaptive-flywheel", "rust.domain.optional-collaboration",
      "rust.platform.extension-packages.artifact",
    ]) assert.ok(selected.includes(owner), `${relativePath} must select ${owner}`);
  }
  assert.ok(ids(selectModulesForChangedPaths([
    "crates/licoup-foundation/tests/full_data_root_archive/transport_integrity.rs",
  ])).includes("rust.core.full-data-root-archive"));
  const artifact = CLIENT_MODULE_CATALOG.find((module) => module.id === "rust.platform.extension-packages.artifact");
  assert.ok(artifact.command.args.includes("platform::extension_packages::artifact::tests::"));
});

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

function explicitCargoJobs(command) {
  if (command.program !== "cargo") return null;
  const boundary = command.args.indexOf("--");
  const args = command.args.slice(0, boundary < 0 ? command.args.length : boundary);
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (["-j", "--jobs"].includes(argument)) return Number(args[index + 1]);
    const compact = argument.match(/^-j([0-9]+)$/u);
    if (compact) return Number(compact[1]);
    const long = argument.match(/^--jobs=([0-9]+)$/u);
    if (long) return Number(long[1]);
  }
  return null;
}

test("complete catalog delegates valid Cargo concurrency to the shared runner budget", () => {
  for (const module of CLIENT_MODULE_CATALOG) {
    assert.equal(explicitCargoJobs(module.command), null, module.id);
    if (module.regression.toolchain === "rust" && module.regression.internalParallelism) {
      assert.ok(Number.isInteger(module.regression.weight), module.id);
      assert.ok(module.regression.weight > 0, module.id);
    }
  }
});

test("merge-readiness target runners execute their own registered self-tests", () => {
  const expected = new Map([
    ["regression.local-linux-runner-self-test", {
      args: ["tools/scripts/client-local-linux-runner.mjs", "self-test"],
      inputs: [
        ".github/workflows/client-ci.yml",
        "apps/desktop/docker/ubuntu-client.Dockerfile",
        "tools/scripts/client-android-sdk-bootstrap.mjs",
        "tools/scripts/client-local-linux-runner.mjs",
        "tools/scripts/client-local-linux-runner/**",
      ],
    }],
    ["regression.windows-target-runner-self-test", {
      args: ["tools/scripts/client-windows-target-runner.mjs", "self-test"],
      inputs: ["tools/scripts/client-windows-target-runner.mjs"],
    }],
    ["regression.android-sdk-bootstrap-self-test", {
      args: ["tools/scripts/client-android-sdk-bootstrap.mjs", "self-test"],
      inputs: [
        ".github/workflows/client-ci.yml",
        "apps/desktop/docker/ubuntu-client.Dockerfile",
        "tools/scripts/client-android-sdk-bootstrap.mjs",
      ],
    }],
  ]);
  for (const [id, contract] of expected) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.ok(module, id);
    assert.equal(module.command.program, "node", id);
    assert.deepEqual(module.command.args, contract.args, id);
    assert.deepEqual(module.inputs, contract.inputs, id);
  }
});

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

function cargoTestExecutes(args, file) {
  if (args[0] !== "test") return false;
  const match = /^(crates\/[^/]+)\/tests\/([^/]+)\.rs$/u.exec(file);
  if (!match || args.includes("--lib") || args.includes("--bin")) return false;
  const [, crateRoot, target] = match;
  const manifest = `${crateRoot}/Cargo.toml`;
  const manifestIndex = args.indexOf("--manifest-path");
  const packages = args.flatMap((arg, index) =>
    ["-p", "--package"].includes(arg) ? [args[index + 1]] : []);
  if (manifestIndex >= 0 && args[manifestIndex + 1] !== manifest) return false;
  if (packages.length > 0) {
    const source = readFileSync(path.join(repoRoot, manifest), "utf8");
    const packageSection = source.match(/\[package\]([\s\S]*?)(?:\n\[|$)/u)?.[1] || "";
    const packageName = packageSection.match(/^name\s*=\s*"([^"]+)"/mu)?.[1];
    if (!packages.includes(packageName)) return false;
  } else if (manifestIndex < 0) return false;
  const targets = args.flatMap((arg, index) => arg === "--test" ? [args[index + 1]] : []);
  return targets.length === 0 || targets.includes(target);
}

function rustCommandExecutes(module, file) {
  return module.command.program === "cargo" && cargoTestExecutes(module.command.args, file);
}

function nodeCommandExecutesRust(module, file) {
  if (module.command.program !== "node" || !file.endsWith(".rs")) return false;
  if (module.command.args[0] === "tools/scripts/migration-crate-tests.mjs") {
    return cargoTestExecutes(migrationCrateTestArgs(module.command.args.slice(1)), file);
  }
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

test("owner schema and frozen fixture changes select the actual migration diagnostic exactly once", () => {
  const diagnostic = "tests/contract/client/client-state-migration-diagnostic.test.mjs";
  for (const changed of [
    "crates/licoup-conversation/src/store/schema.rs",
    "crates/licoup-conversation/src/store/native_sessions.rs",
    "crates/licoup-foundation/src/core/sqlite_contract.rs",
    "crates/licoup-native/src/domain/workflow_store/store.rs",
    "crates/licoup-native/src/domain/workflow_store/queue.rs",
    "crates/licoup-native/src/domain/workflow_store/subscriptions.rs",
    "crates/licoup-native/src/domain/workflow_store/commit.rs",
    "crates/licoup-native/src/domain/workflow_store/control.rs",
    "crates/licoup-native/src/domain/client_state_migration/stores.rs",
    "crates/licoup-native/src/domain/client_state_migration/tests/structural.rs",
    "tests/fixtures/client_state_migration/released_source.rs",
    "tests/fixtures/client_state_migration/owner_layouts.rs",
    "tests/fixtures/client_state_migration/continuity_layout.rs",
    "tests/fixtures/client_state_migration/structural_cases.json",
    "tools/scripts/client-state-migration/sqlite-contract.mjs",
    "tools/scripts/client-state-migration/probe.mjs",
    diagnostic,
  ]) {
    const selected = selectModulesForChangedPaths([changed]);
    const invocations = selected.filter((module) => module.command.program === "node" && module.command.args.includes(diagnostic));
    assert.equal(invocations.length, 1, changed);
    assert.deepEqual(invocations[0].command.args, ["--test", "tests/contract/client/privacy-test-fixtures.test.mjs", "tests/contract/client/client-state-migration.test.mjs", diagnostic]);
    if (changed.endsWith("/continuity_layout.rs")) {
      const owner = selected.find((module) => module.id === "rust.domain.client-conversations");
      assert.ok(owner?.command.args.includes("store::schema::tests::"), "the frozen producer fixture selects its actual Rust schema consumer");
    }
    assert.equal(invocations[0].command.cwd, ".");
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
      if (["regression.rust-format", "regression.rust-clippy"].includes(module.id)) {
        continue;
      }
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

test("startup and client-state checks select every production owner they execute", () => {
  const bootstrap = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "flutter.controller.scenario.bootstrap");
  const clientState = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "regression.client-state-contracts");
  for (const input of [
    "apps/desktop/lib/src/application/controller/client_lifecycle_coordinator.dart",
    "apps/desktop/lib/src/application/controller/client_lifecycle_facade.dart",
    "apps/desktop/lib/src/application/features/agents/conversation/conversation_session_state_controller.dart",
    "apps/desktop/lib/src/application/features/layout/layout_manager.dart",
    "crates/licoup-native/resources/client-state-migration-frontier.json",
    "crates/licoup-native/src/domain/client_state_migration.rs",
  ]) {
    assert.equal(bootstrap.inputs.includes(input), true, input);
    assert.equal(selectModulesForChangedPaths([input]).some((module) =>
      module.id === bootstrap.id), true, input);
  }
  for (const input of [
    "apps/desktop/lib/src/application/controller/client_lifecycle_facade.dart",
    "apps/desktop/lib/src/platform/storage/portable_data_root.dart",
    "crates/licoup-conversation/src/store/mod.rs",
    "crates/licoup-native/resources/client-state-migration-frontier.json",
    "crates/licoup-native/src/domain/client_state_migration.rs",
    "crates/licoup-native/src/domain/client_state_migration/stores.rs",
    "crates/licoup-native/src/domain/client_state_migration/strategy_store.rs",
    "crates/licoup-native/src/platform/client_state/migration.rs",
    "crates/licoup-native/src/platform/client_state/policy.rs",
    "schemas/client_bridge/state.json",
    "tools/scripts/client-state-migration/frontier.mjs",
    "tools/scripts/client-state-migration/probe.mjs",
    "tools/scripts/client-state-migration/report.mjs",
  ]) {
    assert.equal(selectModulesForChangedPaths([input]).some((module) =>
      module.id === clientState.id), true, input);
  }
  assert.equal(clientState.inputs.includes(
    "crates/licoup-native/src/domain/client_state_migration/**"), true);
  assert.equal(clientState.inputs.includes("tools/scripts/client-state-migration/**"), true);
  assert.deepEqual(clientState.command.args, [
    "--test",
    "tests/contract/client/privacy-test-fixtures.test.mjs",
    "tests/contract/client/client-state-migration.test.mjs",
    "tests/contract/client/client-state-migration-diagnostic.test.mjs",
  ]);
  assert.equal(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/client_state_migration/tests/structural.rs",
  ]).some((module) => module.id === "rust.domain.client-state-migration"), true);
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

test("complete catalog owns format lint analysis and dependency audit", () => {
  const commands = new Map(CLIENT_MODULE_CATALOG.map((module) => [
    module.id,
    [module.command.program, ...module.command.args].join(" "),
  ]));
  assert.match(commands.get("regression.flutter-format"), /dart format .*--set-exit-if-changed/u);
  assert.equal(commands.get("regression.rust-format"), "cargo fmt --all -- --check");
  assert.match(commands.get("regression.rust-clippy"), /^cargo clippy --workspace --all-targets/u);
  assert.equal(commands.get("regression.dependency-audit"),
    "node tools/scripts/client-deps-audit.mjs");
  assert.match(commands.get("flutter.composition.dependencies"), /flutter analyze --no-pub/u);
  assert.equal(CLIENT_MODULE_CATALOG[0].id, "regression.flutter-dependencies");
  assert.deepEqual(CLIENT_MODULE_CATALOG[0].regression.resources, ["flutter-cache"]);
  assert.deepEqual(
    CLIENT_MODULE_CATALOG.find((module) => module.id === "regression.native-client-smoke")
      .regression.resources,
    ["cargo-target"],
  );
});

const LEGACY_LANE_EQUIVALENT_MODULES = Object.freeze({
  "client:gate:topology": ["regression.release-workflow-contracts"],
  "client:gate:self-test": ["regression.release-workflow-contracts"],
  "client:verify:build-entry:self-test": ["regression.release-workflow-contracts"],
  "client:version:check": [
    "regression.release-workflow-contracts",
    "regression.client-version",
    "regression.client-support-matrix",
  ],
  "client:verify:agent-conversation-parity": [
    "regression.agent-conversation-parity-reducer",
    "regression.agent-conversation-parity-reducer-source-bundle",
    "regression.acp-conversation-parity-source-bundle",
  ],
  "client:format:check": ["regression.flutter-format"],
  "client:analyze": ["flutter.composition.dependencies"],
  "client:test": ["@tracked-flutter-test-partitions"],
  "client:native:clippy": ["regression.rust-clippy"],
  "client:native:test:helpers": ["rust.core.mcp-server"],
  "client:native:test": ["@catalog-rust-test-partitions"],
  "client:promotion:self-test": ["regression.release-workflow-contracts"],
  "client:pricing:check": ["release.model-pricing"],
  "client:release:packages:self-test": ["regression.release-workflow-contracts"],
  "client:verify:android-physical-install-launch:self-test": [
    "regression.android-physical-install-launch-source-bundle",
  ],
  "client:cli:vm:self-test": ["regression.cli-vm-source-bundle"],
  "client:state:migration:self-test": ["regression.client-state-contracts"],
  "client:verify:artifact-verification-receipts:self-test": [
    "regression.artifact-verification-receipts-source-bundle",
  ],
  "client:verify:secure-mesh-e2ee-evidence:leak-scan-self-test": [
    "regression.e2ee-evidence-bundle-source-bundle",
  ],
});

function catalogCommand(module) {
  return [module.command.program, ...module.command.args].join(" ");
}

test("every legacy lane command has one real catalog execution or declared partition equivalence", async () => {
  const packageJson = JSON.parse(await fs.readFile(path.join(repoRoot, "package.json"), "utf8"));
  const catalogCommands = new Set(CLIENT_MODULE_CATALOG.map(catalogCommand));
  const legacyScripts = Object.values(CLIENT_GATE_LANES).flat();
  const unmatched = [];
  for (const script of legacyScripts) {
    const packageCommand = packageJson.scripts[script];
    assert.equal(typeof packageCommand, "string", `legacy lane script is missing: ${script}`);
    if (catalogCommands.has(packageCommand)) continue;
    const equivalents = LEGACY_LANE_EQUIVALENT_MODULES[script];
    if (!equivalents) {
      unmatched.push(script);
      continue;
    }
    for (const moduleId of equivalents) {
      if (moduleId === "@tracked-flutter-test-partitions") {
        assert.equal(CLIENT_MODULE_CATALOG.some((module) =>
          module.command.args.includes("flutter") && module.command.args.includes("test")), true);
        continue;
      }
      if (moduleId === "@catalog-rust-test-partitions") {
        assert.equal(CLIENT_MODULE_CATALOG.some((module) =>
          module.command.program === "cargo" && module.command.args[0] === "test"), true);
        continue;
      }
      assert.ok(CLIENT_MODULE_CATALOG.find((module) => module.id === moduleId),
        `${script} references missing equivalent module ${moduleId}`);
    }
  }
  assert.deepEqual(unmatched, []);
  const legacyNames = new Set(legacyScripts);
  assert.deepEqual(
    Object.keys(LEGACY_LANE_EQUIVALENT_MODULES).filter((script) => !legacyNames.has(script)),
    [],
  );
});

test("tracked contribution guides require focused repair and one complete gate", async () => {
  const docs = await Promise.all([
    "CONTRIBUTING.md",
    "CONTRIBUTING.zh-CN.md",
  ].map((relativePath) => fs.readFile(path.join(repoRoot, relativePath), "utf8")));
  assert.match(docs[0], /run the smallest registered check/u);
  assert.match(docs[0], /client:gate:step -- <module-id>/u);
  assert.match(docs[0], /client:gate:verify -- --base origin\/nightly/u);
  assert.match(docs[0], /Neither command\s+builds, installs, launches, or publishes a client/iu);
  assert.match(docs[1], /开发过程中运行负责本次改动的最小已注册检查/u);
  assert.match(docs[1], /client:gate:step -- <module-id>/u);
  assert.match(docs[1], /client:gate:verify -- --base origin\/nightly/u);
  assert.match(docs[1], /这些命令都不会构建、安装、启动\s+或发布客户端/u);
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
  assert.deepEqual(ids(flutter), [
    "regression.flutter-dependencies",
    "regression.client-version",
    "regression.dependency-audit",
    "flutter.composition.dependencies",
  ]);

  const rust = selectModulesForChangedPaths(["Cargo.lock"]);
  assert.deepEqual(ids(rust), [
    "regression.client-version",
    "regression.dependency-audit",
    "rust.composition",
  ]);
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

test("development report sources select the existing report suite", () => {
  const module = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.development-reports");
  assert.ok(module, "the report suite has one maintained owner");
  assert.equal(module.kind, "regression-infrastructure");
  assert.deepEqual(module.command.args, [
    "--test",
    "tools/development/tests/reports.test.mjs",
  ]);
  for (const relativePath of [
    "tools/development/reports.mjs",
    "tools/development/reporting/adapters/better-plan.mjs",
    "tools/development/reporting/plan.mjs",
    "tools/development/state-machines.json",
    "tools/development/architecture-views.json",
    "tools/development/workflows/13-installed-milestone-candidate.json",
    "tools/development/tests/reports.test.mjs",
  ]) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "regression.development-reports",
    ], `${relativePath} must select the report suite`);
  }
  // Dependency inputs keep every existing owner and additionally select the
  // report suite, so a dependency change reruns the rendered-fixture contract.
  for (const relativePath of ["package.json", "package-lock.json"]) {
    const selected = ids(selectModulesForChangedPaths([relativePath]));
    assert.ok(selected.includes("regression.development-reports"), `${relativePath} must select the report suite`);
    assert.ok(selected.includes("regression.infrastructure"), `${relativePath} keeps its dependency owner`);
  }
  // The maintained policy is a report input too, and keeps any other owner.
  const policySelection = ids(selectModulesForChangedPaths([".lico-auditor/policy.json"]));
  assert.ok(policySelection.includes("regression.development-reports"), "the policy file must select the report suite");
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
  const ratchetSources = [
    "apps/desktop/scripts/client-architecture/checks/ratchet.mjs",
    "apps/desktop/scripts/client-architecture/ratchet/baseline.mjs",
    "apps/desktop/scripts/client-architecture/ratchet/cargo-manifest.mjs",
    "apps/desktop/scripts/client-architecture/ratchet/definitions.mjs",
    "apps/desktop/scripts/client-architecture/ratchet/developer-tools.mjs",
    "apps/desktop/scripts/client-architecture/ratchet/lexical.mjs",
    "apps/desktop/scripts/client-architecture/ratchet/measure.mjs",
    "apps/desktop/scripts/client-architecture/ratchet/ownership.mjs",
    "apps/desktop/scripts/client-architecture/ratchet/runtime-interfaces.mjs",
    "apps/desktop/scripts/client-architecture/ratchet/runtime-review.mjs",
    "apps/desktop/scripts/client-architecture/ratchet/target-attribution.mjs",
  ];
  const ratchetTest =
    "tests/contract/client/client-architecture-ratchet.test.mjs";
  const runtimeReviewTest = "tests/contract/client/client-architecture-runtime-review.test.mjs";
  const ratchetDependencySelections = new Map([
    ["package.json", [
      "regression.flutter-dependencies",
      "regression.repository-local-info-hygiene",
      "regression.client-version",
      "regression.flutter-format",
      "regression.rust-format",
      "regression.rust-clippy",
      "regression.dependency-audit",
      "regression.infrastructure",
      "regression.test-artifact-lifecycle",
      "regression.documentation-governance",
      "regression.development-reports",
      "regression.client-architecture-ratchet",
      "architecture.client-boundaries",
      "release.workflows",
    ]],
    ["package-lock.json", [
      "regression.repository-local-info-hygiene",
      "regression.client-version",
      "regression.dependency-audit",
      "regression.infrastructure",
      "regression.development-reports",
      "regression.client-architecture-ratchet",
      "architecture.client-boundaries",
    ]],
  ]);
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
    const expected = [
      "regression.client-architecture-modules",
      ...(["apps/desktop/scripts/verify-client-architecture.mjs", "apps/desktop/scripts/client-architecture/context.mjs"].includes(relativePath)
        ? ["regression.client-architecture-ratchet"] : []),
      "architecture.client-boundaries",
    ];
    if (relativePath === "tools/verify-client-boundary.mjs") {
      expected.unshift("regression.client-boundary");
    }
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), expected);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([architectureTest])), [
    "regression.client-architecture-modules",
  ]);
  for (const relativePath of ratchetSources) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "regression.client-architecture-ratchet",
      "architecture.client-boundaries",
    ]);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([ratchetTest])), [
    "regression.client-architecture-ratchet",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([runtimeReviewTest])), ["regression.client-architecture-ratchet"]);
  for (const [relativePath, expectedIds] of ratchetDependencySelections) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), expectedIds);
  }

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
    if ([
      "apps/desktop/scripts/package-client/build/release-tools.mjs",
      "apps/desktop/scripts/package-client/build/native.mjs",
      "apps/desktop/scripts/package-client/orchestrator.mjs",
    ].includes(relativePath)) {
      expected.push("release.migration-asset");
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
  const ratchetBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.client-architecture-ratchet");
  const packageBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.package-client-source-bundle");
  const planBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.verify-client-plan-source-bundle");
  assert.deepEqual(architectureBundle.inputs, [
    ...architectureSources,
    architectureTest,
  ]);
  assert.deepEqual(architectureBundle.command.args, ["--test", architectureTest]);
  assert.deepEqual(ratchetBundle.inputs, [
    ...ratchetSources,
    ...ratchetDependencySelections.keys(),
    "apps/desktop/scripts/verify-client-architecture.mjs",
    "apps/desktop/scripts/client-architecture/context.mjs",
    "crates/licoup-native/src/platform/strategy_runtime/mod.rs",
    "crates/licoup-extension-contracts/src/deployment.rs",
    ratchetTest,
    runtimeReviewTest,
  ]);
  assert.deepEqual(ratchetBundle.command.args, ["--test", ratchetTest, runtimeReviewTest]);
  for (const source of [
    "crates/licoup-native/src/platform/strategy_runtime/mod.rs",
    "crates/licoup-extension-contracts/src/deployment.rs",
  ]) {
    assert.ok(ids(selectModulesForChangedPaths([source])).includes(ratchetBundle.id), source);
  }
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
  assert.equal([...architectureBundle.inputs, ...ratchetBundle.inputs,
    ...packageBundle.inputs, ...planBundle.inputs]
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

test("architecture gate owns every measured manifest and runtime source root", async () => {
  const measuredPaths = [
    "Cargo.toml",
    "apps/desktop/packaging.modules.json",
    "crates/licoup-extension-contracts/src/deployment.rs",
    "package.json",
    "package-lock.json",
  ];
  for (const root of ["crates", "components", "sdk"]) {
    const entries = await fs.readdir(path.join(repoRoot, root), { withFileTypes: true });
    for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
      if (!entry.isDirectory()) {
        continue;
      }
      measuredPaths.push(`${root}/${entry.name}/Cargo.toml`);
      const sources = await sourceFiles(`${root}/${entry.name}/src`, ".rs");
      if (sources.length > 0) {
        measuredPaths.push(sources[0]);
      }
    }
  }
  const dartSources = await sourceFiles("apps/desktop/lib", ".dart");
  if (dartSources.length > 0) {
    measuredPaths.push(dartSources[0]);
  }
  for (const relativePath of measuredPaths) {
    assert.equal(
      ids(selectModulesForChangedPaths([relativePath])).includes("architecture.client-boundaries"),
      true,
      relativePath,
    );
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

test("migration runner inventory follows the actual crate and target selectors", () => {
  const migrate = CLIENT_MODULE_CATALOG.find((module) => module.id === "rust.crate.migrate");
  const recovery = CLIENT_MODULE_CATALOG.find((module) => module.id === "rust.platform.data-home-relocation");
  assert.equal(migrate.regression.toolchain, "rust");
  assert.ok(migrate.regression.resources.includes("cargo-target"));
  assert.equal(nodeCommandExecutesRust(migrate, "crates/licoup-migrate/tests/interoperability.rs"), true);
  assert.equal(nodeCommandExecutesRust(migrate, "crates/licoup-native/tests/data_home_process.rs"), false);
  assert.equal(nodeCommandExecutesRust(recovery, "crates/licoup-native/tests/data_home_process.rs"), true);
  assert.equal(nodeCommandExecutesRust(recovery, "crates/licoup-native/tests/cli_command_contract_cases.rs"), false);
});

test("retained schema fixtures select the validating and initializing owners", () => {
  const selected = ids(selectModulesForChangedPaths([
    "tests/fixtures/client_state_migration/retained_related_tables.sql",
  ]));
  assert.ok(selected.includes("rust.domain.client-conversations"));
  assert.ok(selected.includes("regression.client-state-contracts"));
  assert.ok(ids(selectModulesForChangedPaths([
    "crates/licoup-foundation/src/core/sqlite_contract.rs",
  ])).includes("rust.core.sqlite-contract"));
});
