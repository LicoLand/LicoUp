import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  emitArchitectureResult,
  formatArchitectureResult,
} from "../../../apps/desktop/scripts/client-architecture/context.mjs";
import {
  CLIENT_ARCHITECTURE_PHASE_IDS,
  runClientArchitecturePhases,
} from "../../../apps/desktop/scripts/verify-client-architecture.mjs";
import { REQUIRED_FLUTTER_TOP_LEVEL_DIRS } from "../../../apps/desktop/scripts/client-architecture/checks/flutter/physical-layers-and-libraries.mjs";
import {
  PRESENTATION_BINDING_NAMES,
  PRESENTATION_STATE_PLANES,
  RETIRED_PRESENTATION_PATHS,
  inspectPresentationBoundaryPolicySources,
  inspectPresentationBoundarySources,
  inspectPresentationContractPubspec,
  inspectPresentationContractSources,
} from "../../../apps/desktop/scripts/client-architecture/checks/flutter/presentation-boundary.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const entryPath = "apps/desktop/scripts/verify-client-architecture.mjs";
const moduleRoot = "apps/desktop/scripts/client-architecture";
const checkRoot = `${moduleRoot}/checks`;

const expectedImplFacades = Object.freeze({
  "composition.mjs": [
    "checkConversationBridges",
    "checkClientRootAndShell",
  ],
  "foundations.mjs": [
    "checkPackagingAndTargetProjection",
    "checkPackageDryRuns",
  ],
  "privacy.mjs": [
    "checkProductContractsAndPortableData",
    "checkFileSecurityAndClientState",
  ],
});

const expectedReexportFacades = Object.freeze({
  "flutter.mjs": Object.freeze([
    ["checkFlutterPhysicalLayersAndLibraries", "flutter/physical-layers-and-libraries.mjs"],
    ["checkShellIsolationAndNativeStdio", "flutter/shell-isolation-and-native-stdio.mjs"],
    ["checkMobileRelayBridges", "flutter/mobile-relay-bridges.mjs"],
    ["checkPresentationBoundary", "flutter/presentation-boundary.mjs"],
  ]),
  "native.mjs": Object.freeze([
    ["checkCrateCoreAndFacadeBounds", "native/crate-core-and-facade-bounds.mjs"],
    ["checkDomainAndCryptoBoundaries", "native/domain-and-crypto-boundaries.mjs"],
    ["checkSecureMeshFoundationsAndLocalArchive", "native/secure-mesh-foundations-and-local-archive.mjs"],
    ["checkConversationDomain", "native/conversation-domain.mjs"],
    ["checkSecureMeshAuthorityAndCustody", "native/secure-mesh-authority-and-custody.mjs"],
    ["checkCommandAndFileTransport", "native/command-and-file-transport.mjs"],
    ["checkTargetReadinessReducer", "native/target-readiness-reducer.mjs"],
  ]),
  "platform.mjs": Object.freeze([
    ["checkRuntimeDriversAndLocalService", "platform/runtime-drivers-and-local-service.mjs"],
    ["checkTargetServeAndGateway", "platform/target-serve-and-gateway.mjs"],
    ["checkIosSecureMesh", "platform/ios-secure-mesh.mjs"],
    ["checkAndroidSecureMesh", "platform/android-secure-mesh.mjs"],
  ]),
});

const expectedCheckRootEntries = Object.freeze([
  ...Object.keys(expectedImplFacades),
  ...Object.keys(expectedReexportFacades),
  "flutter",
  "native",
  "platform",
].sort());

const ownedCheckLeaves = Object.freeze(
  Object.values(expectedReexportFacades).flatMap((bindings) =>
    bindings.map(([, relativeLeaf]) => relativeLeaf)),
);
const supportCheckLeaves = Object.freeze([
  "native/licoarc-badtower-boundary.mjs",
]);

const phaseRunners = Object.freeze([
  ["foundations.packaging-and-target-projection", "checkPackagingAndTargetProjection"],
  ["privacy.product-contracts-and-portable-data", "checkProductContractsAndPortableData"],
  ["flutter.physical-layers-and-libraries", "checkFlutterPhysicalLayersAndLibraries"],
  ["foundations.package-dry-runs", "checkPackageDryRuns"],
  ["native.crate-core-and-facade-bounds", "checkCrateCoreAndFacadeBounds"],
  ["native.domain-and-crypto-boundaries", "checkDomainAndCryptoBoundaries"],
  ["platform.runtime-drivers-and-local-service", "checkRuntimeDriversAndLocalService"],
  ["privacy.file-security-and-client-state", "checkFileSecurityAndClientState"],
  ["platform.target-serve-and-gateway", "checkTargetServeAndGateway"],
  ["native.secure-mesh-foundations-and-local-archive", "checkSecureMeshFoundationsAndLocalArchive"],
  ["flutter.shell-isolation-and-native-stdio", "checkShellIsolationAndNativeStdio"],
  ["native.conversation-domain", "checkConversationDomain"],
  ["composition.conversation-bridges", "checkConversationBridges"],
  ["native.secure-mesh-authority-and-custody", "checkSecureMeshAuthorityAndCustody"],
  ["platform.ios-secure-mesh", "checkIosSecureMesh"],
  ["platform.android-secure-mesh", "checkAndroidSecureMesh"],
  ["native.command-and-file-transport", "checkCommandAndFileTransport"],
  ["flutter.mobile-relay-bridges", "checkMobileRelayBridges"],
  ["flutter.presentation-boundary", "checkPresentationBoundary"],
  ["composition.client-root-and-shell", "checkClientRootAndShell"],
  ["native.target-readiness-reducer", "checkTargetReadinessReducer"],
]);

test("client architecture verifier has one thin entry and the complete source bundle", async () => {
  const rootLeaves = (await fs.readdir(path.join(repoRoot, moduleRoot)))
    .filter((name) => name.endsWith(".mjs"))
    .sort();
  assert.deepEqual(rootLeaves, ["assertions.mjs", "context.mjs", "filesystem.mjs"]);
  assert.deepEqual(
    (await fs.readdir(path.join(repoRoot, checkRoot))).sort(),
    expectedCheckRootEntries,
  );

  const entrySource = await fs.readFile(path.join(repoRoot, entryPath), "utf8");
  assert.equal(entrySource.includes("packaging.modules.json"), false);
  assert.equal(entrySource.includes("secure_mesh_file.rs"), false);
  assert.equal(entrySource.includes("agent_conversation_service.dart"), false);

  const sideEffectFreeSources = [
    "assertions.mjs",
    "context.mjs",
    "filesystem.mjs",
    ...Object.keys(expectedImplFacades).map((leaf) => `checks/${leaf}`),
    ...Object.keys(expectedReexportFacades).map((leaf) => `checks/${leaf}`),
    ...ownedCheckLeaves.map((leaf) => `checks/${leaf}`),
    ...supportCheckLeaves.map((leaf) => `checks/${leaf}`),
  ];
  for (const relativePath of sideEffectFreeSources) {
    const source = await fs.readFile(path.join(repoRoot, moduleRoot, relativePath), "utf8");
    assert.equal(/^await\s/mu.test(source), false, `${relativePath} performs top-level IO`);
    assert.equal(/^assert\s*\(/mu.test(source), false, `${relativePath} performs a top-level assertion`);
  }

  for (const [leaf, expectedExports] of Object.entries(expectedImplFacades)) {
    const source = await fs.readFile(path.join(repoRoot, checkRoot, leaf), "utf8");
    const actualExports = [...source.matchAll(
      /^export async function ([A-Za-z0-9_]+)\(/gmu,
    )].map((match) => match[1]);
    assert.deepEqual(actualExports, expectedExports, `${leaf} check exports changed`);
  }

  for (const [leaf, bindings] of Object.entries(expectedReexportFacades)) {
    const source = await fs.readFile(path.join(repoRoot, checkRoot, leaf), "utf8");
    assert.equal(source.includes("export async function"), false, `${leaf} must stay a thin re-export`);
    assert.equal(source.split(/\r?\n/u).filter(Boolean).length, bindings.length);
    for (const [exportName, relativeLeaf] of bindings) {
      assert.match(
        source,
        new RegExp(
          `^export \\{ ${exportName} \\} from "\\./${relativeLeaf.replaceAll(".", "\\.")}";$`,
          "mu",
        ),
        `${leaf} must re-export ${exportName} from ${relativeLeaf}`,
      );
      const leafSource = await fs.readFile(path.join(repoRoot, checkRoot, relativeLeaf), "utf8");
      assert.match(
        leafSource,
        new RegExp(`^export async function ${exportName}\\(`, "mu"),
        `${relativeLeaf} must own ${exportName}`,
      );
    }
  }

  for (const directoryName of ["flutter", "native", "platform"]) {
    const expectedLeaves = ownedCheckLeaves
      .filter((relativeLeaf) => relativeLeaf.startsWith(`${directoryName}/`))
      .map((relativeLeaf) => relativeLeaf.slice(directoryName.length + 1))
      .concat(
        supportCheckLeaves
          .filter((relativeLeaf) => relativeLeaf.startsWith(`${directoryName}/`))
          .map((relativeLeaf) => relativeLeaf.slice(directoryName.length + 1)),
      )
      .sort();
    const actualLeaves = (await fs.readdir(path.join(repoRoot, checkRoot, directoryName)))
      .filter((name) => name.endsWith(".mjs"))
      .sort();
    assert.deepEqual(actualLeaves, expectedLeaves, `${directoryName}/ leaf set changed`);
  }
});

test("source and architecture gates share one required Flutter layer catalog", async () => {
  assert.deepEqual(REQUIRED_FLUTTER_TOP_LEVEL_DIRS, [
    "events",
    "projections",
    "display",
    "protocol",
    "shared",
    "presentation",
    "composition",
    "application",
    "frontend",
    "backend",
    "platform",
    "contracts",
  ]);
  assert.equal(Object.isFrozen(REQUIRED_FLUTTER_TOP_LEVEL_DIRS), true);

  const sourceGate = await fs.readFile(
    path.join(repoRoot, "tools/verify-client-boundary.mjs"),
    "utf8",
  );
  assert.match(
    sourceGate,
    /import \{ REQUIRED_FLUTTER_TOP_LEVEL_DIRS \} from "\.\.\/apps\/desktop\/scripts\/client-architecture\/checks\/flutter\/physical-layers-and-libraries\.mjs";/u,
  );
  assert.equal(sourceGate.includes("const requiredFlutterPhysicalDirs"), false);
});

test("importing the architecture entry and leaves has no verification side effects", async () => {
  const entryUrl = pathToFileURL(path.join(repoRoot, entryPath)).href;
  const result = spawnSync(process.execPath, [
    "--input-type=module",
    "--eval",
    `await import(${JSON.stringify(entryUrl)})`,
  ], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr, "");

  await Promise.all([
    "assertions.mjs",
    "context.mjs",
    "filesystem.mjs",
    ...Object.keys(expectedImplFacades).map((leaf) => `checks/${leaf}`),
    ...Object.keys(expectedReexportFacades).map((leaf) => `checks/${leaf}`),
    ...ownedCheckLeaves.map((leaf) => `checks/${leaf}`),
  ].map((relativePath) => import(pathToFileURL(
    path.join(repoRoot, moduleRoot, relativePath),
  ).href)));
});

test("client architecture phases run strictly and sequentially in the frozen order", async () => {
  assert.equal(Object.isFrozen(CLIENT_ARCHITECTURE_PHASE_IDS), true);
  assert.deepEqual(
    CLIENT_ARCHITECTURE_PHASE_IDS,
    phaseRunners.map(([id]) => id),
  );
  assert.equal(CLIENT_ARCHITECTURE_PHASE_IDS.length, 21);

  const context = Object.freeze({ marker: "context" });
  const events = [];
  const modules = Object.freeze({ "portable-data": Object.freeze({}) });
  const outputs = {
    "foundations.packaging-and-target-projection": {
      futureModules: ["desktop-app"],
      modules,
      packagedTargets: ["codex"],
    },
    "flutter.physical-layers-and-libraries": {
      mobileRelayPanelFacadeSource: "panel-facade",
      mobileRelayPanelSources: Object.freeze({ "composition.dart": "panel-leaf" }),
    },
    "foundations.package-dry-runs": {
      packagePlanCheckedPlatforms: ["macos"],
    },
    "native.crate-core-and-facade-bounds": {
      reviewedRustUnsafeFiles: new Set(["reviewed-unsafe.rs"]),
    },
    "native.domain-and-crypto-boundaries": {
      secureMeshMobileFfiRoot: "mobile-ffi-root",
    },
    "platform.runtime-drivers-and-local-service": {
      localServiceSource: "local-service",
    },
    "flutter.shell-isolation-and-native-stdio": {
      agentConversationServiceSource: "conversation-service",
    },
    "native.conversation-domain": {
      conversationSourceCatalogRustSource: "source-catalog",
    },
    "native.command-and-file-transport": {
      secureMeshMobileFfiSource: "mobile-ffi",
    },
    "flutter.mobile-relay-bridges": {
      mobileRelayClientAdapterSource: "relay-adapter",
      mobileRelayServiceSource: "relay-service",
      secureMeshControllerSource: "mesh-controller",
    },
  };
  const expectedInputs = {
    "privacy.product-contracts-and-portable-data": { modules },
    "foundations.package-dry-runs": {
      futureModules: ["desktop-app"],
      modules,
    },
    "platform.runtime-drivers-and-local-service": {
      reviewedRustUnsafeFiles: new Set(["reviewed-unsafe.rs"]),
    },
    "platform.target-serve-and-gateway": {
      localServiceSource: "local-service",
    },
    "native.conversation-domain": {
      agentConversationServiceSource: "conversation-service",
    },
    "composition.conversation-bridges": {
      conversationSourceCatalogRustSource: "source-catalog",
      packagedTargets: ["codex"],
    },
    "native.command-and-file-transport": {
      secureMeshMobileFfiRoot: "mobile-ffi-root",
    },
    "flutter.mobile-relay-bridges": {
      secureMeshMobileFfiSource: "mobile-ffi",
    },
    "composition.client-root-and-shell": {
      agentConversationServiceSource: "conversation-service",
      mobileRelayClientAdapterSource: "relay-adapter",
      mobileRelayPanelFacadeSource: "panel-facade",
      mobileRelayPanelSources: { "composition.dart": "panel-leaf" },
      mobileRelayServiceSource: "relay-service",
      secureMeshControllerSource: "mesh-controller",
    },
  };
  const checks = Object.fromEntries(phaseRunners.map(([id, runner]) => [
    runner,
    async (receivedContext, input) => {
      assert.equal(receivedContext, context);
      assert.deepEqual(input, expectedInputs[id]);
      events.push(`start:${id}`);
      await Promise.resolve();
      events.push(`end:${id}`);
      return outputs[id];
    },
  ]));

  const state = await runClientArchitecturePhases(context, checks);
  assert.deepEqual(events, phaseRunners.flatMap(([id]) => [
    `start:${id}`,
    `end:${id}`,
  ]));
  assert.deepEqual(state.packagePlanCheckedPlatforms, ["macos"]);
  assert.equal(state.secureMeshControllerSource, "mesh-controller");
});

test("architecture finalization preserves JSON shape, stream, and exit semantics", () => {
  const failure = formatArchitectureResult({
    failures: ["first failure", "second failure"],
  });
  assert.deepEqual(failure, {
    ok: false,
    text: `{
  "ok": false,
  "failures": [
    "first failure",
    "second failure"
  ]
}`,
  });
  const failureStdout = [];
  const failureStderr = [];
  const exits = [];
  emitArchitectureResult(failure, {
    stdout: (value) => failureStdout.push(value),
    stderr: (value) => failureStderr.push(value),
    exit: (code) => exits.push(code),
  });
  assert.deepEqual(failureStdout, []);
  assert.deepEqual(failureStderr, [failure.text]);
  assert.deepEqual(exits, [1]);

  const success = formatArchitectureResult({
    failures: [],
    futureModules: ["desktop-app"],
    packagedTargets: ["codex"],
    packagePlanCheckedPlatforms: ["macos", "linux", "windows"],
  });
  assert.deepEqual(success, {
    ok: true,
    text: `{
  "ok": true,
  "futureModules": [
    "desktop-app"
  ],
  "packagedTargets": [
    "codex"
  ],
  "packagePlanCheckedPlatforms": [
    "macos",
    "linux",
    "windows"
  ]
}`,
  });
  const successStdout = [];
  emitArchitectureResult(success, {
    stdout: (value) => successStdout.push(value),
    stderr: () => assert.fail("success must not write stderr"),
    exit: () => assert.fail("success must not exit"),
  });
  assert.deepEqual(successStdout, [success.text]);
});

function terminalPresentationTree() {
  const tree = new Map();
  tree.set(
    "apps/desktop/lib/src/application/state/application_signal.dart",
    "import 'dart:async';\nfinal class ApplicationSignal<T> { Stream<T> get changes => const Stream.empty(); }\n",
  );
  tree.set(
    "apps/desktop/lib/src/presentation/shell/shell_binding.dart",
    `final class AppearanceProjection {}
final class LocaleProjection {}
final class LayoutProjection {}
final class EnvironmentProjection {}
final class NavigationProjection {}
final class StatusProjection {}
final class ShellBinding {
  const ShellBinding();
  final ProjectionSource<AppearanceProjection> appearance;
  final ProjectionSource<LocaleProjection> locale;
  final ProjectionSource<LayoutProjection> layout;
  final ProjectionSource<EnvironmentProjection> environment;
  final ProjectionSource<NavigationProjection> navigation;
  final ProjectionSource<StatusProjection> status;
}
`,
  );
  for (const bindingName of PRESENTATION_BINDING_NAMES.slice(1)) {
    const prefix = bindingName.slice(0, -"Binding".length);
    tree.set(
      `apps/desktop/lib/src/presentation/features/${prefix.toLowerCase()}_binding.dart`,
      `final class ${prefix}Projection {}
sealed class ${prefix}Intent {}
sealed class ${prefix}Effect {}
final class ${bindingName} {
  const ${bindingName}();
  final ProjectionSource<${prefix}Projection> projection;
  final IntentSink<${prefix}Intent> intents;
  final EffectSource<${prefix}Effect> effects;
}
`,
    );
  }
  tree.set(
    "apps/desktop/lib/src/frontend/shell/client_shell.dart",
    "import 'package:flutter/widgets.dart';\nimport 'package:licoup/src/presentation/shell/shell_binding.dart';\nfinal class ClientShell extends Widget {}\n",
  );
  tree.set(
    "apps/desktop/lib/src/composition/client_app_composition.dart",
    `import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';
import 'package:licoup/src/presentation/shell/shell_binding.dart';
final bindings = [
  ${PRESENTATION_BINDING_NAMES.map((name) => `${name}()`).join(",\n  ")}
];
`,
  );
  return tree;
}

function rulesFor(tree) {
  return inspectPresentationBoundarySources(tree).map(([rule]) => rule);
}

function withSource(tree, relativePath, source) {
  const changed = new Map(tree);
  changed.set(relativePath, source);
  return changed;
}

test("terminal presentation boundary accepts the complete target architecture", () => {
  assert.deepEqual(PRESENTATION_STATE_PLANES, [
    "appearance",
    "locale",
    "layout",
    "environment",
    "navigation",
    "status",
  ]);
  assert.equal(Object.isFrozen(PRESENTATION_STATE_PLANES), true);
  assert.deepEqual(PRESENTATION_BINDING_NAMES, [
    "ShellBinding",
    "AgentsBinding",
    "MonitoringBinding",
    "SkillHubBinding",
    "PluginManagementBinding",
    "MobileRelayBinding",
    "ModelsBinding",
    "SettingsBinding",
    "AgentHubBinding",
    "ConversationBinding",
    "TargetsBinding",
    "SearchBinding",
    "ChromeBinding",
  ]);
  assert.equal(Object.isFrozen(PRESENTATION_BINDING_NAMES), true);
  assert.deepEqual(inspectPresentationBoundarySources(terminalPresentationTree()), []);
});

test("Application gate rejects Flutter, notifier, lifecycle, and listener forwarding", () => {
  const tree = terminalPresentationTree();
  const sourcePath = "apps/desktop/lib/src/application/state/application_signal.dart";
  assert.ok(rulesFor(withSource(tree, sourcePath,
    "import 'package:flutter/foundation.dart';\nfinal class Signal {}\n",
  )).includes("presentation_boundary_application_flutter"));
  for (const token of [
    "ChangeNotifier",
    "ValueNotifier<int>",
    "ValueListenable<int>",
    "Widget",
    "BuildContext",
    "AppLifecycleState",
    "WidgetsBindingObserver",
    "debugPrint",
  ]) {
    assert.ok(
      rulesFor(withSource(tree, sourcePath, `final ${token} value;\n`))
        .includes("presentation_boundary_application_framework_type"),
      token,
    );
  }
  assert.ok(rulesFor(withSource(tree, sourcePath,
    "void forward() { addListener(forward); notifyListeners(); }\n",
  )).includes("presentation_boundary_application_listener"));
  assert.ok(rulesFor(withSource(tree, sourcePath,
    "import 'package:licoup/src/frontend/shell/client_shell.dart';\nfinal class Signal {}\n",
  )).includes("presentation_boundary_application_direction"));
  assert.equal(
    rulesFor(withSource(tree, sourcePath,
      "// ValueNotifier and notifyListeners are documentation only.\nfinal note = '''ClientController\nWidget\nValueNotifier''';\n",
    )).some((rule) => rule.startsWith("presentation_boundary_application_")),
    false,
  );
});

test("stable Presentation and frontend reject every implementation direction", () => {
  const tree = terminalPresentationTree();
  const stablePath = "apps/desktop/lib/src/presentation/features/example.dart";
  assert.ok(rulesFor(withSource(tree, stablePath,
    "import 'package:flutter/widgets.dart';\nfinal class Example {}\n",
  )).includes("presentation_boundary_stable_flutter"));
  for (const layer of ["application", "backend", "platform", "projections", "composition", "frontend"]) {
    assert.ok(
      rulesFor(withSource(tree, stablePath,
        `import 'package:licoup/src/${layer}/example.dart';\nfinal class Example {}\n`,
      )).includes("presentation_boundary_stable_direction"),
      layer,
    );
  }

  const frontendPath = "apps/desktop/lib/src/frontend/features/example_panel.dart";
  for (const layer of ["application", "backend", "platform", "projections", "composition"]) {
    assert.ok(
      rulesFor(withSource(tree, frontendPath,
        `import 'package:licoup/src/${layer}/example.dart' as hidden;\nfinal value = hidden.value;\n`,
      )).includes("presentation_boundary_frontend_direction"),
      layer,
    );
  }
  assert.ok(rulesFor(withSource(tree, frontendPath,
    "final Object? value = ClientController;\n",
  )).includes("presentation_boundary_frontend_controller"));
});

test("shell state planes are separate and reject a recombined root projection", () => {
  const tree = terminalPresentationTree();
  const shellPath = "apps/desktop/lib/src/presentation/shell/shell_binding.dart";
  const shellSource = tree.get(shellPath);
  assert.ok(rulesFor(withSource(
    tree,
    shellPath,
    shellSource.replace("  final ProjectionSource<LocaleProjection> locale;\n", ""),
  )).includes("presentation_boundary_state_plane_coverage"));
  assert.ok(rulesFor(withSource(
    tree,
    shellPath,
    shellSource.replace(
      "  final ProjectionSource<StatusProjection> status;",
      "  final ProjectionSource<ShellProjection> status;\n  final int appRevision;",
    ),
  )).includes("presentation_boundary_state_planes_combined"));
});

test("Binding catalog requires exact semantic, immutable, lifecycle-free surfaces", () => {
  const tree = terminalPresentationTree();
  const agentsPath = "apps/desktop/lib/src/presentation/features/agents_binding.dart";
  const agentsSource = tree.get(agentsPath);

  const missing = new Map(tree);
  missing.delete(agentsPath);
  assert.ok(rulesFor(missing).includes("presentation_boundary_binding_coverage"));

  assert.ok(rulesFor(withSource(
    tree,
    agentsPath,
    agentsSource.replace("final class AgentsProjection {}\n", ""),
  )).includes("presentation_boundary_binding_semantics"));
  assert.ok(rulesFor(withSource(
    tree,
    agentsPath,
    agentsSource.replace("  final EffectSource<AgentsEffect> effects;", "  void dispose() {}"),
  )).includes("presentation_boundary_binding_lifecycle"));
  assert.ok(rulesFor(withSource(
    tree,
    agentsPath,
    agentsSource.replace("  final EffectSource<AgentsEffect> effects;", "  final List<Object> mutableValues;"),
  )).includes("presentation_boundary_binding_mutable_collection"));
  assert.ok(rulesFor(withSource(
    tree,
    "apps/desktop/lib/src/presentation/features/root_binding.dart",
    "final class RootBinding {}\n",
  )).includes("presentation_boundary_binding_unexpected"));
});

test("only composition may wire concrete owners, renderers, and all Bindings", () => {
  const tree = terminalPresentationTree();
  const frontendPath = "apps/desktop/lib/src/frontend/features/example_panel.dart";
  assert.ok(rulesFor(withSource(
    tree,
    frontendPath,
    "final value = AgentsBinding();\n",
  )).includes("presentation_boundary_wiring_outside_composition"));

  const compositionPath = "apps/desktop/lib/src/composition/client_app_composition.dart";
  const compositionSource = tree.get(compositionPath);
  assert.ok(rulesFor(withSource(
    tree,
    compositionPath,
    compositionSource.replace("  ChromeBinding()", "  Object()"),
  )).includes("presentation_boundary_composition_binding_coverage"));
  assert.ok(rulesFor(withSource(
    tree,
    compositionPath,
    compositionSource.replace(
      "import 'package:licoup/src/frontend/shell/client_shell.dart';\n",
      "",
    ),
  )).includes("presentation_boundary_composition_concrete_edges"));
});

test("retired paths, symbols, annotations, and path-count substitution stay absent", async () => {
  const tree = terminalPresentationTree();
  assert.deepEqual(RETIRED_PRESENTATION_PATHS, [
    "apps/desktop/lib/src/composition/m2_legacy_shell_renderer_transition_adapter.dart",
    "apps/desktop/lib/src/projections/listenable_projection_consumer.dart",
    "apps/desktop/lib/src/projections/adapters/legacy_projection_consumer_source_adapter.dart",
  ]);
  assert.equal(Object.isFrozen(RETIRED_PRESENTATION_PATHS), true);
  assert.ok(rulesFor(withSource(tree, RETIRED_PRESENTATION_PATHS[0], ""))
    .includes("presentation_boundary_retired_path"));
  assert.ok(rulesFor(withSource(
    tree,
    "apps/desktop/lib/src/composition/replacement.dart",
    "final value = M2LegacyShellRendererTransitionAdapter();\n",
  )).includes("presentation_boundary_retired_symbol"));
  assert.ok(rulesFor(withSource(
    tree,
    "apps/desktop/lib/src/application/controller/client_controller.dart",
    "@Deprecated('migration')\nfinal class ClientController {}\n",
  )).includes("presentation_boundary_deprecated_controller_annotation"));

  for (const debtPath of [
    "apps/desktop/lib/src/frontend/features/agents/old_debt.dart",
    "apps/desktop/lib/src/frontend/features/new/replacement_debt.dart",
  ]) {
    assert.ok(rulesFor(withSource(
      tree,
      debtPath,
      "import 'package:licoup/src/application/controller/client_controller.dart';\n",
    )).includes("presentation_boundary_frontend_direction"));
  }

  const policyPath =
    "apps/desktop/scripts/client-architecture/checks/flutter/presentation-boundary.mjs";
  assert.deepEqual(inspectPresentationBoundaryPolicySources(new Map([
    [policyPath, "const terminalRules = Object.freeze([]);"],
  ])), []);
  assert.deepEqual(inspectPresentationBoundaryPolicySources(new Map([
    [policyPath, "const replacementDebtAllowlist = new Set(['one.dart']);"],
  ])), [["presentation_boundary_stale_allowlist", policyPath]]);

  for (const catalogPath of [
    "tools/regression/client-module-catalog/groups/flutter.mjs",
    "tools/regression/client-module-catalog/groups/regression.mjs",
  ]) {
    const source = await fs.readFile(path.join(repoRoot, catalogPath), "utf8");
    assert.equal(source.includes(RETIRED_PRESENTATION_PATHS[0]), false, catalogPath);
  }
});

test("SDK-only presentation contract source and pubspec have positive and negative fixtures", () => {
  const contractPath = "packages/presentation_contract/lib/projection_source.dart";
  assert.deepEqual(inspectPresentationContractSources(new Map([
    [contractPath, "import 'dart:async';\nabstract interface class ProjectionSource<T> {}\n"],
  ])), []);
  assert.deepEqual(inspectPresentationContractSources(new Map([
    [contractPath, "import 'package:flutter/widgets.dart';\nfinal class Port {}\n"],
  ])), [["presentation_boundary_package_purity", contractPath]]);
  assert.deepEqual(inspectPresentationContractSources(new Map([
    [contractPath, "final class Port { void close() {} }\n"],
  ])), [["presentation_boundary_package_surface", contractPath]]);
  assert.deepEqual(inspectPresentationContractPubspec("name: contract\n"), []);
  assert.deepEqual(inspectPresentationContractPubspec("name: contract\ndependencies:\n"), [
    "presentation_boundary_package_dependency_surface",
  ]);
});

test("terminal Presentation Boundary owns one focused Flutter module registration", async () => {
  const [flutterCatalog, order] = await Promise.all([
    fs.readFile(
      path.join(repoRoot, "tools/regression/client-module-catalog/groups/flutter.mjs"),
      "utf8",
    ),
    fs.readFile(
      path.join(repoRoot, "tools/regression/client-module-catalog/order.mjs"),
      "utf8",
    ),
  ]);
  assert.equal(
    [...flutterCatalog.matchAll(/id:\s*"flutter\.presentation\.boundary-closure"/gu)].length,
    1,
  );
  assert.equal(
    [...order.matchAll(/"flutter\.presentation\.boundary-closure"/gu)].length,
    1,
  );
  assert.equal(flutterCatalog.includes("flutter.presentation.shell-boundary"), false);
  assert.equal(order.includes("flutter.presentation.shell-boundary"), false);
});
