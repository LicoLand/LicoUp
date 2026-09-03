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
  inspectPresentationBoundarySources,
  inspectPresentationContractPubspec,
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

test("presentation boundary fixtures reject direction, lifecycle, transition, and new debt", () => {
  const stablePath = "apps/desktop/lib/src/presentation/shell/example.dart";
  const clean = new Map([[stablePath, "final class Example {}"]]);
  assert.deepEqual(inspectPresentationBoundarySources(clean), []);

  const direction = new Map([[stablePath,
    "import 'package:licoup/src/application/controller/client_controller.dart';\nfinal class Example { ClientController? controller; }",
  ]]);
  assert.deepEqual(
    inspectPresentationBoundarySources(direction).map(([rule]) => rule).sort(),
    [
      "presentation_boundary_complete_controller_forbidden",
      "presentation_boundary_stable_direction",
    ],
  );

  const lifecycle = new Map([[stablePath,
    "final StreamController<int> values = StreamController<int>();\nvoid dispose() {}",
  ]]);
  assert.deepEqual(inspectPresentationBoundarySources(lifecycle), [[
    "presentation_boundary_producer_lifecycle_forbidden",
    stablePath,
  ]]);

  const transition = new Map([[stablePath,
    "import 'package:licoup/src/composition/m2_legacy_shell_renderer_transition_adapter.dart';",
  ]]);
  assert.deepEqual(
    inspectPresentationBoundarySources(transition).map(([rule]) => rule).sort(),
    [
      "presentation_boundary_stable_direction",
      "presentation_boundary_transition_import_forbidden",
    ],
  );

  const newDebtPath = "apps/desktop/lib/src/frontend/features/new_panel.dart";
  assert.deepEqual(inspectPresentationBoundarySources(new Map([[newDebtPath,
    "import 'package:licoup/src/application/controller/client_controller.dart';",
  ]])), [["presentation_boundary_new_controller_debt", newDebtPath]]);

  const projectionPath =
    "apps/desktop/lib/src/projections/shell/example_producer.dart";
  assert.deepEqual(inspectPresentationBoundarySources(new Map([[projectionPath,
    "final ClientController? controller = null;",
  ]])), [["presentation_boundary_complete_controller_forbidden", projectionPath]]);

  const upwardDirection = new Map([[stablePath,
    "import 'package:licoup/src/projections/shell/example_producer.dart';",
  ]]);
  assert.deepEqual(inspectPresentationBoundarySources(upwardDirection), [[
    "presentation_boundary_stable_direction",
    stablePath,
  ]]);

  assert.deepEqual(inspectPresentationContractPubspec(`name: contract\n`), []);
  assert.deepEqual(inspectPresentationContractPubspec(`name: contract\ndependencies:\n`), [
    "presentation_boundary_package_dependency_surface",
  ]);
});
