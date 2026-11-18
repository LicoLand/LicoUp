import {
  assert,
  fs,
  path,
  test,
  CLIENT_MODULE_CATALOG,
  selectModulesForChangedPaths,
  validateClientModuleCatalog,
  repoRoot,
  ids,
  sourceFiles,
} from "./support.mjs";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
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
import { partitionModulesByRunnableHost } from "../client-module-selection.mjs";

function trackedTestEntrypoints() {
  const result = spawnSync("git", ["ls-files", "-z"], {
    cwd: repoRoot,
    encoding: "buffer",
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
  });
  assert.equal(result.status, 0, "tracked test inventory requires git ls-files");
  return result.stdout.toString("utf8").split("\0").filter((file) =>
    (file.endsWith(".test.mjs") ||
    /(?:^|\/)test\/.*_test\.dart$/u.test(file) ||
    /(?:^|\/)integration_test\/.*_test\.dart$/u.test(file)) &&
    // A file deleted in the worktree but not yet removed from the index is
    // not a runnable entrypoint; classification applies to existing files.
    existsSync(path.join(repoRoot, file)));
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
      const source = readFileSync(absolutePath, "utf8");
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

function moduleExecutes(module, file) {
  if (module.command.program === "node" && nodeReachableFiles(module).has(file)) return true;
  if (flutterCommandExecutes(module, file)) return true;
  return module.id === "regression.continuous-assistant-ux" &&
    file.startsWith("apps/desktop/test/continuous_assistant_journeys/");
}

test("catalog declares every independently accepted client architecture family", () => {
  assert.equal(validateClientModuleCatalog(), true);
  const kinds = new Set(CLIENT_MODULE_CATALOG.map((module) => module.kind));
  for (const required of [
    "flutter-feature",
    "flutter-layer",
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
    assert.equal(module.command.program, "node");
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

// A repository path literal a source reads is a registration, and the reverse
// of "every real source file has an owner" is "every registered file exists".
// Only a path a read helper consumes is a registration: a path used as a
// fixture object key names a temporary directory entry, and a helper that
// catches a missing file probes existence instead of reading its owner.
const REPOSITORY_PATH_PATTERN =
  /(?<quote>["'`])(?<path>(?:apps|tests|tools|schemas|packages|docs|\.github)\/[A-Za-z0-9._@/-]*)\k<quote>/gu;

function readHelperNames(source) {
  const helpers = new Set();
  for (const match of source.matchAll(
    /const\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\([^)]*\)\s*=>\s*([^;]*);/gu)) {
    if (match[2].includes("readFile")) helpers.add(match[1]);
  }
  for (const match of source.matchAll(/function\s+([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{/gu)) {
    const body = source.slice(match.index, match.index + 600);
    const end = body.indexOf("\n}");
    if (body.includes("readFile") &&
        !(end < 0 ? body : body.slice(0, end)).includes("catch")) {
      helpers.add(match[1]);
    }
  }
  return helpers;
}

function registeredReadPaths(source) {
  const helpers = readHelperNames(source);
  if (helpers.size === 0) return new Set();
  const literals = () => new RegExp(REPOSITORY_PATH_PATTERN.source, "gu");
  const bindings = new Map();
  for (const match of source.matchAll(new RegExp(
    `(?:const|let|var)\\s+([A-Za-z_$][\\w$]*)\\s*=\\s*${REPOSITORY_PATH_PATTERN.source}`, "gu"))) {
    if (!bindings.has(match[1])) bindings.set(match[1], new Set());
    bindings.get(match[1]).add(match.groups.path);
  }
  const fixtureKeys = new Set();
  for (const match of source.matchAll(new RegExp(
    `(?:\\[\\s*([A-Za-z_$][\\w$]*)\\s*\\]|${REPOSITORY_PATH_PATTERN.source})\\s*:`, "gu"))) {
    if (match[1]) fixtureKeys.add(match[1]);
    if (match.groups?.path) fixtureKeys.add(match.groups.path);
  }
  const single = new Map();
  for (const [identifier, values] of bindings) {
    if (values.size === 1 && !fixtureKeys.has(identifier)) {
      single.set(identifier, [...values][0]);
    }
  }
  const named = [...helpers].join("|");
  const paths = new Set();
  for (const match of source.matchAll(new RegExp(
    `(?:${named})\\s*\\(\\s*${REPOSITORY_PATH_PATTERN.source}`, "gu"))) {
    paths.add(match.groups.path);
  }
  for (const match of source.matchAll(/\[([^\][]*)\]\s*\.map\(\s*([A-Za-z_$][\w$]*)\s*\)/gu)) {
    if (!helpers.has(match[2])) continue;
    for (const identifier of match[1].matchAll(/[A-Za-z_$][\w$]*/gu)) {
      if (single.has(identifier[0])) paths.add(single.get(identifier[0]));
    }
  }
  for (const match of source.matchAll(/readFile(?:Sync)?\s*\(([^;]*?)\)\s*[,;)]/gu)) {
    for (const identifier of match[1].matchAll(/[A-Za-z_$][\w$]*/gu)) {
      if (single.has(identifier[0])) paths.add(single.get(identifier[0]));
    }
    for (const literal of match[1].matchAll(literals())) paths.add(literal.groups.path);
  }
  return paths;
}

test("every repository file a registered contract source reads really exists", async () => {
  const registered = new Set();
  for (const module of CLIENT_MODULE_CATALOG) {
    for (const candidate of [...module.inputs, ...module.command.args]) {
      if (typeof candidate === "string" && candidate.endsWith(".test.mjs")) {
        registered.add(candidate);
      }
    }
  }
  const checked = new Set();
  const missing = [];
  for (const relativePath of [...registered].sort()) {
    const source = await fs.readFile(path.join(repoRoot, relativePath), "utf8");
    for (const declared of registeredReadPaths(source)) {
      // A `**` registration owns a directory prefix, so the prefix is what the
      // repository must carry; a concrete registration must name a real file.
      const target = declared.endsWith("/**") ? declared.slice(0, -3) : declared;
      checked.add(target);
      if (!await fs.stat(path.join(repoRoot, target)).then(() => true, () => false)) {
        missing.push(`${relativePath} registers ${declared}`);
      }
    }
  }
  assert.ok(checked.size > 0, "the reverse registration check found no declarations");
  assert.deepEqual(missing, []);
});

test("startup scenario checks select every production owner they execute", () => {
  const bootstrap = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "flutter.controller.scenario.bootstrap");
  for (const input of [
    "apps/desktop/lib/src/application/controller/client_lifecycle_coordinator.dart",
    "apps/desktop/lib/src/application/controller/client_lifecycle_facade.dart",
    "apps/desktop/lib/src/application/features/agents/conversation/conversation_session_state_controller.dart",
    "apps/desktop/lib/src/application/features/layout/layout_manager.dart",
  ]) {
    assert.equal(bootstrap.inputs.includes(input), true, input);
    assert.equal(selectModulesForChangedPaths([input]).some((module) =>
      module.id === bootstrap.id), true, input);
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

test("complete catalog owns format lint analysis", () => {
  const commands = new Map(CLIENT_MODULE_CATALOG.map((module) => [
    module.id,
    [module.command.program, ...module.command.args].join(" "),
  ]));
  assert.match(commands.get("regression.flutter-format"), /dart format .*--set-exit-if-changed/u);
  assert.match(commands.get("flutter.composition.dependencies"), /flutter analyze --no-pub/u);
  assert.equal(CLIENT_MODULE_CATALOG[0].id, "regression.flutter-dependencies");
  assert.deepEqual(CLIENT_MODULE_CATALOG[0].regression.resources, ["flutter-cache"]);
});

const LEGACY_LANE_EQUIVALENT_MODULES = Object.freeze({
  "repo:identity:self-test": ["regression.release-workflow-contracts"],
  "client:artifacts:self-test": ["regression.test-artifact-lifecycle"],
  "client:verify:package-index:self-test": ["regression.client-release-package-index"],
  "client:gate:topology": ["regression.release-workflow-contracts"],
  "client:gate:self-test": ["regression.release-workflow-contracts"],
  "client:verify:build-entry:self-test": ["regression.release-workflow-contracts"],
  "client:version:check": [
    "regression.release-workflow-contracts",
    "regression.client-version",
    "regression.client-support-matrix",
  ],
  "client:format:check": ["regression.flutter-format"],
  "client:analyze": ["flutter.composition.dependencies"],
  "client:test": ["@tracked-flutter-test-partitions"],
  "client:packages:verify": [
    "flutter.package.presentation-contract",
    "flutter.package.presentation-runtime",
    "flutter.package.presentation-flutter",
  ],
  "client:promotion:self-test": ["regression.release-workflow-contracts"],
  "client:release:packages:self-test": ["regression.release-workflow-contracts"],
  "client:cli:vm:self-test": ["regression.cli-vm-source-bundle"],
  "client:verify:artifact-verification-receipts:self-test": [
    "regression.artifact-verification-receipts-source-bundle",
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
  assert.match(docs[0], /After the host profile\s+passes, the delivery target uses the existing owners\s+to build, install, and open\s+the local client/iu);
  assert.match(docs[0], /It never publishes or activates real data/iu);
  assert.match(docs[1], /开发过程中运行负责本次改动的最小已注册检查/u);
  assert.match(docs[1], /client:gate:step -- <module-id>/u);
  assert.match(docs[1], /client:gate:verify -- --base origin\/nightly/u);
  assert.match(docs[1], /构建、安装并打开客户端/u);
  assert.match(docs[1], /它绝不发布或激活真实数据/u);
  assert.deepEqual(ids(selectModulesForChangedPaths(["CONTRIBUTING.md"])),
    [
      "regression.infrastructure",
      "regression.public-client-docs",
      "regression.documentation-governance",
      "architecture.client-boundaries",
    ]);
});

test("catalog maps every Flutter and platform-host source file", async () => {
  const candidates = [
    ...await sourceFiles("apps/desktop/lib", ".dart"),
    ...await sourceFiles("apps/desktop/test", ".dart"),
    ...await sourceFiles("apps/desktop/assets", ".json"),
    ...await sourceFiles("apps/desktop/assets", ".png"),
    ...await sourceFiles("apps/desktop/assets", ".svg"),
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

test("shared Flutter manifests select their own technology families", () => {
  const flutter = selectModulesForChangedPaths(["apps/desktop/pubspec.yaml"]);
  assert.deepEqual(ids(flutter), [
    "regression.flutter-dependencies",
    "regression.client-version",
    "flutter.composition.dependencies",
  ]);
});

test("host classification separates portable coverage from target adapters", () => {
  for (const module of CLIENT_MODULE_CATALOG) {
    for (const host of ["darwin", "linux", "win32"]) {
      const partition = partitionModulesByRunnableHost([module], host);
      assert.equal(partition.runnable.length + partition.unsupported.length, 1);
      assert.equal(partition.runnable.includes(module),
        module.regression.runnableHosts.includes(host));
    }
  }
});

test("shared module roots select composition without leaf-regression fanout", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/analysis_options.yaml",
  ])), ["flutter.composition.dependencies"]);
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
    "apps/desktop/scripts/client-architecture/checks/flutter/physical-layers-and-libraries.mjs",
    "apps/desktop/scripts/client-architecture/checks/flutter/presentation-boundary.mjs",
    "apps/desktop/scripts/client-architecture/checks/flutter/shell-isolation-and-native-stdio.mjs",
    "apps/desktop/scripts/client-architecture/checks/foundations.mjs",
    "apps/desktop/scripts/client-architecture/checks/privacy.mjs",
  ];
  const architectureTest =
    "tests/contract/client/client-architecture-modules.test.mjs";
  const packageDependencySelections = new Map([
    ["package.json", [
      "regression.flutter-dependencies",
      "regression.repository-local-info-hygiene",
      "regression.client-version",
      "regression.flutter-format",
      "regression.infrastructure",
      "regression.test-artifact-lifecycle",
      "regression.documentation-governance",
      "regression.development-reports",
      "architecture.client-boundaries",
      "release.workflows",
    ]],
    ["package-lock.json", [
      "regression.repository-local-info-hygiene",
      "regression.client-version",
      "regression.infrastructure",
      "regression.development-reports",
      "architecture.client-boundaries",
    ]],
  ]);
  const packageAssets = [
    "apps/desktop/macos/CustodyHelper/Info.plist",
    "apps/desktop/macos/CustodyHelper/ProductionRelease.entitlements",
    "tools/licoup-cli-release.json",
  ];
  const packageSources = [
    "apps/desktop/scripts/package-client.mjs",
    ...await sourceFiles("apps/desktop/scripts/package-client", ".mjs"),
  ];
  const packageTests = [
    "tests/contract/client/package-client/package-client-source-bundle.test.mjs",
    "tests/contract/client/package-client/macos-custody-helper.test.mjs",
    "tests/contract/client/package-client/cli-release.test.mjs",
  ];
  const planSources = [
    "apps/desktop/scripts/verify-client-plan.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/client-boundary.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/docs-readiness.mjs",
    "apps/desktop/scripts/verify-client-plan/checks/package-and-runner.mjs",
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
  for (const [relativePath, expectedIds] of packageDependencySelections) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), expectedIds);
  }

  for (const relativePath of [...packageAssets, ...packageSources]) {
    const expected = [
      "regression.package-client-source-bundle",
      "packaging.client-plan",
      ...(relativePath.startsWith("apps/desktop/macos/") ? ["packaging.macos"] : []),
    ];
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
  assert.equal([...architectureBundle.inputs,
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
    "apps/desktop/packaging.modules.json",
    "package.json",
    "package-lock.json",
  ];
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
    "tools/regression/client-module-catalog/groups/regression.mjs",
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
    kind: "regression-infrastructure",
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
