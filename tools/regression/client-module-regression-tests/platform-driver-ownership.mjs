import {
  assert,
  fs,
  path,
  process,
  test,
  CLIENT_MODULE_CATALOG,
  repoRoot,
  selectModulesForChangedPaths,
  main,
  ids,
  sourceFiles,
} from "./support.mjs";

/// Whether one repository path exists, for the paths a move retired.
async function exists(relativePath) {
  try {
    await fs.access(path.join(repoRoot, relativePath));
    return true;
  } catch {
    return false;
  }
}

test("layer, FFI, bridge, packaging, and release paths select dedicated modules", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mobile_relay/config.rs",
  ])), ["architecture.client-boundaries", "rust.domain.mobile-relay.configuration"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-agent-targets/src/domain/targets/binaries.rs",
  ])), [
    "regression.agent-scan-paths",
    "architecture.client-boundaries",
    "rust.domain.targets.binaries",
    "rust.domain.targets.platform-integration",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/ffi/android_ffi.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.ffi.android-secret-store-tristate",
    "bridge.android",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/ffi/commands/mcp.rs",
  ])), [
    "regression.cli-command-admission-source-bundle",
    "architecture.client-boundaries",
    "rust.ffi.cli-command-admission",
    "bridge.native-mcp-command",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/platform/mcp_streamable_http.rs",
  ])), ["architecture.client-boundaries", "rust.platform.mcp-streamable-http"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/platform/mcp_approval_plan_store.rs",
  ])), ["architecture.client-boundaries", "rust.platform.mcp-approval-plan-store"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/bin/licoup.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.ffi.cli-command-admission",
    "rust.bin.licoup",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/bin/licoup/stdio_rpc.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.bin.licoup.rpc",
    "bridge.native-mcp-rpc-guard",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/bin/licoup/stdio_rpc/request.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.ffi.client-state-contract",
    "rust.ffi.cli-command-admission",
    "rust.bin.licoup.rpc",
    "bridge.native-mcp-rpc-guard",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/bin/licoup/tests/rpc/request.rs",
  ])), ["architecture.client-boundaries", "rust.bin.licoup.rpc"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/bin/licoup/tests/skill_commands.rs",
  ])), ["architecture.client-boundaries", "rust.bin.licoup.skill-commands"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/ios/Runner/SecureMeshIosBridge.swift",
  ])), ["architecture.client-boundaries", "bridge.ios"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/scripts/build-android-apk.mjs",
  ])), ["packaging.android"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "tools/apple-release/macos-direct-arm64.json",
  ])), ["release.contracts", "release.package-index", "release.workflows"]);
});

test("Android Secure Mesh leaves select boundary tests and Kotlin compile independently", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/MainActivity.kt",
  ])), [
    "architecture.client-boundaries",
    "bridge.android.secure-mesh-boundaries",
    "bridge.android.kotlin-compile",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/android/app/src/test/kotlin/land/lico/licoup/SecureMeshAndroidBridgeBoundaryTest.kt",
  ])), [
    "architecture.client-boundaries",
    "bridge.android.secure-mesh-boundaries",
  ]);
  for (const source of [
    "SecureMeshAndroidAtomicRecordWriter.kt",
    "SecureMeshAndroidNativeDispatchQueue.kt",
  ]) {
    assert.deepEqual(ids(selectModulesForChangedPaths([
      `apps/desktop/android/app/src/main/kotlin/land/lico/licoup/${source}`,
    ])), [
      "architecture.client-boundaries",
      "flutter.feature.mobile-relay.scenario.android-bridge",
    ]);
  }

  const boundaries = CLIENT_MODULE_CATALOG.find(
    (module) => module.id === "bridge.android.secure-mesh-boundaries",
  );
  const compile = CLIENT_MODULE_CATALOG.find(
    (module) => module.id === "bridge.android.kotlin-compile",
  );
  assert.equal(boundaries.command.args.includes(":app:testDebugUnitTest"), true);
  for (const className of [
    "land.lico.licoup.SecureMeshAndroidBridgeBoundaryTest",
    "land.lico.licoup.SecureMeshAndroidSecretStoreBoundaryTest",
    "land.lico.licoup.SecureMeshAndroidSecretContractTest",
  ]) {
    assert.equal(boundaries.command.args.includes(className), true);
  }
  assert.equal(compile.command.args.includes(":app:compileDebugKotlin"), true);
});

test("foundation adapters and architecture scripts have explicit changed-path owners", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/scripts/verify-client-architecture.mjs",
  ])), [
    "regression.client-architecture-modules",
    "regression.client-architecture-ratchet",
    "architecture.client-boundaries",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-foundation/src/core/acp.rs",
  ])), ["architecture.client-boundaries", "rust.core.acp.composition"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-foundation/src/core/acp/requests.rs",
  ])), ["architecture.client-boundaries", "rust.core.acp.requests"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-foundation/src/core/acp/responses.rs",
  ])), ["architecture.client-boundaries", "rust.core.acp.responses"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-foundation/src/core/acp/codec.rs",
  ])), ["architecture.client-boundaries", "rust.core.acp.codec"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-foundation/src/core/task_queue.rs",
  ])), ["architecture.client-boundaries", "rust.core.task-queue"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-foundation/src/platform/ansi_stripper.rs",
  ])), ["architecture.client-boundaries", "rust.platform.ansi-stripper"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-foundation/src/platform/url_security.rs",
  ])), ["architecture.client-boundaries", "rust.platform.url-security"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/authorized_secure_record.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.secret-custody-port",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/platform/authorized_secure_record/ledger.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.secure-mesh-secret-store.authorization",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/platform/user_presence.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.secure-mesh-secret-store.authorization",
  ]);
  for (const source of [
    "authority.rs",
    "runner_signature.rs",
    "test_support.rs",
    "transaction.rs",
  ]) {
    assert.deepEqual(ids(selectModulesForChangedPaths([
      `crates/licoup-native/src/domain/collaboration_plugin/${source}`,
    ])), [
      "architecture.client-boundaries",
      "rust.domain.optional-collaboration",
    ]);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/collaboration_plugin/workflow/mcp_transaction.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.optional-collaboration.workflow-operations.apply-mcp",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/mcp.rs",
  ])), ["architecture.client-boundaries", "rust.core.mcp.composition"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/mcp/wire.rs",
  ])), ["architecture.client-boundaries", "rust.core.mcp.wire"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/mcp/transfer.rs",
  ])), ["architecture.client-boundaries", "rust.core.mcp.transfer"]);
  for (const source of [
    "crates/licoup-foundation/src/core/safe_archive.rs",
    "crates/licoup-foundation/src/core/safe_archive/zip_structure.rs",
  ]) {
    assert.deepEqual(ids(selectModulesForChangedPaths([source])), [
      "architecture.client-boundaries",
      "rust.domain.adaptive-flywheel",
      "rust.domain.optional-collaboration",
      "rust.core.safe-archive",
      "rust.core.full-data-root-archive",
      "rust.platform.extension-packages.artifact",
    ]);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-foundation/src/platform/paths.rs",
  ])), [
    "regression.agent-scan-paths",
    "architecture.client-boundaries",
    "rust.domain.targets.scan-paths",
    "rust.domain.targets.platform-paths",
    "rust.platform.paths",
    "rust.platform",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/platform/extension_packages/artifact.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.extension-packages",
    "rust.platform.extension-packages.artifact",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/tests/package_lifecycle/main.rs",
  ])), ["rust.platform.extension-packages"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "tests/integration/package_lifecycle/verify_component_lifecycle.py",
  ])), ["rust.platform.extension-packages"]);
  assert.deepEqual(
    CLIENT_MODULE_CATALOG.find((candidate) =>
      candidate.id === "rust.platform.extension-packages").command.args,
    [
      "test",
      "--manifest-path",
      "crates/licoup-native/Cargo.toml",
      "--test",
      "package_lifecycle",
    ],
  );
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/secure_mesh_pairwise.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.pairwise-codec",
    "rust.core.secure-mesh.pairwise-key-ratchet.core",
    "rust.core.secure-mesh.pairwise-manager-fanout",
    "rust.core.secure-mesh.pairwise-persistence",
    "rust.core.secure-mesh.pairwise-runtime-self-test",
    "rust.core.secure-mesh.pairwise-session-negotiation.handshake-machine",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/secure_mesh_pairwise/codec.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.pairwise-codec",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-protocol-bindings/src/licoarc_relay.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.protocol-bindings",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-protocol-bindings/src/licoarc_relay/mailbox/schedule.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.protocol-bindings",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-protocol-bindings/src/licoarc_relay/private_header.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.protocol-bindings",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/secure_mesh_command.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.command",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/secure_mesh_command/schema.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.command.schema",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/secure_mesh_directory/authority.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.directory",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/test/skill_hub_controller_test.dart",
  ])), ["flutter.feature.skill-hub"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/test/target_controller_test.dart",
  ])), ["flutter.feature.targets"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/test/client_navigation_controller_test.dart",
  ])), ["flutter.layer.shell"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/test/native_cli_runtime_context_test.dart",
  ])), ["bridge.flutter-native-client"]);
  for (const source of [
    "native_conversation_command_policy.dart",
    "native_conversation_port.dart",
  ]) {
    assert.deepEqual(ids(selectModulesForChangedPaths([
      `apps/desktop/lib/src/platform/native_client/${source}`,
    ])), [
      "architecture.client-boundaries",
      "bridge.flutter-native-client.stdio-transport",
      "regression.native-stdio-rpc-source-bundle",
    ]);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/platform/native_client/agent_service_stdio_rpc/client.dart",
  ])), [
    "architecture.client-boundaries",
    "bridge.flutter-native-client.stdio-transport",
    "bridge.flutter-native-client.stdio-integration",
    "regression.native-stdio-rpc-source-bundle",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/platform/native_client/agent_service_stdio_rpc/protocol.dart",
  ])), [
    "architecture.client-boundaries",
    "bridge.flutter-native-client.stdio-codec",
    "bridge.flutter-native-client.stdio-integration",
    "regression.native-stdio-rpc-source-bundle",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/test/native_stdio_rpc_protocol_test.dart",
  ])), [
    "bridge.flutter-native-client.stdio-codec",
    "regression.native-stdio-rpc-source-bundle",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/test/native_stdio_rpc_client_test.dart",
  ])), [
    "bridge.flutter-native-client.stdio-transport",
    "bridge.flutter-native-client.stdio-integration",
    "regression.native-stdio-rpc-source-bundle",
  ]);
  const stdioCodec = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "bridge.flutter-native-client.stdio-codec");
  const stdioTransport = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "bridge.flutter-native-client.stdio-transport");
  const stdioIntegration = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "bridge.flutter-native-client.stdio-integration");
  const stdioSourceBundle = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "regression.native-stdio-rpc-source-bundle");
  assert.deepEqual(stdioCodec.command.args.slice(-2), [
    "test/native_stdio_rpc_line_framer_test.dart",
    "test/native_stdio_rpc_protocol_test.dart",
  ]);
  // The transport module gained the bounded flow-control suites and then the
  // production stream-observation suite, so the command executes thirteen
  // targets. The assertion covers all of them rather than the original eight: a
  // suite that is selected but no longer executed is exactly what this check
  // exists to catch.
  const stdioTransportTests = [
    "test/stdio_rpc_method_policy_test.dart",
    "test/native_stdio_rpc_client_test.dart",
    "test/native_stdio_rpc_read_pool_test.dart",
    "test/native_stdio_rpc_decoding_test.dart",
    "test/native_stdio_rpc_operation_pending_queue_test.dart",
    "test/stdio_transport_flow_control/bulk_decode_lane_test.dart",
    "test/stdio_transport_flow_control/control_lane_priority_test.dart",
    "test/stdio_transport_flow_control/native_child_backlog_test.dart",
    "test/stdio_transport_flow_control/stream_observation_test.dart",
    "test/stdio_transport_flow_control/stream_observation_production_test.dart",
    "test/conversation_execution_transport_test.dart",
    "test/native_conversation_port_test.dart",
    "test/stdio_rpc_operation_queue_test.dart",
  ];
  assert.deepEqual(stdioTransport.command.args.slice(-13), stdioTransportTests);
  // Every selected dart suite must also be executed, and the other way round.
  const selectedTransportTests = stdioTransport.inputs
    .filter((input) => /^apps\/desktop\/test\/.*_test\.dart$/u.test(input))
    .map((input) => input.replace(/^apps\/desktop\//u, ""))
    .sort();
  assert.deepEqual(
    selectedTransportTests,
    [...stdioTransportTests].sort(),
    "a selected stdio-transport suite must be executed by its own command",
  );
  assert.deepEqual(stdioIntegration.command.args.slice(-2), ["--name", "RPC"]);
  assert.deepEqual(stdioSourceBundle.command.args, [
    "--test",
    "tests/contract/client/native-stdio-rpc-source-bundle.test.mjs",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/test/directory_path_controller_test.dart",
  ])), ["flutter.feature.settings"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "tools/scripts/client-module-regression.mjs",
  ])), ["regression.infrastructure", "architecture.client-boundaries"]);
});

test("Cursor and OpenAgent leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.domain.agent-conversations.parser-cursor-openagent.composition",
      "domain::conversation::history::cursor_openagent::tests::composition::"],
    ["rust.domain.agent-conversations.parser-cursor-openagent.codec",
      "domain::conversation::history::cursor_openagent::tests::codec::"],
    ["rust.domain.agent-conversations.parser-cursor-openagent.cursor",
      "domain::conversation::history::cursor_openagent::tests::cursor::"],
    ["rust.domain.agent-conversations.parser-cursor-openagent.cursor-projection",
      "domain::conversation::history::cursor_openagent::tests::cursor_projection::"],
    ["rust.domain.agent-conversations.parser-cursor-openagent.openagent",
      "domain::conversation::history::cursor_openagent::tests::openagent::"],
    ["rust.domain.agent-conversations.parser-cursor-openagent.fallback",
      "domain::conversation::history::cursor_openagent::tests::fallback::"],
    ["rust.domain.agent-conversations.parser-cursor-openagent.integration",
      "domain::conversation::history::tests::cursor_openagent"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.domain.agent-conversations.parser-cursor-openagent."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
  }
  assert.equal(CLIENT_MODULE_CATALOG.some((candidate) =>
    candidate.id === "rust.domain.agent-conversations.parser-cursor-openagent"), false);

  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.cursor-openagent-source-bundle");
  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = await sourceFiles(
    "crates/licoup-native/src/domain/conversation/history/cursor_openagent",
    ".rs",
  );
  for (const relativePath of [
    "crates/licoup-native/src/domain/conversation/history/cursor_openagent.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Cursor/OpenAgent source must have a focused regression owner: ${relativePath}`);
  }
});

test("neutral ACP runtime and session transport retain bounded ownership", async () => {
  const filters = new Map([
    ["rust.platform.acp-runtime.composition",
      "platform::acp_driver_runtime::tests::composition::"],
    ["rust.platform.acp-runtime.test-support",
      "platform::acp_driver_runtime::tests::"],
    ["rust.platform.acp-runtime.continuity",
      "platform::acp_driver_runtime::tests::continuity::"],
    ["rust.platform.acp-runtime.errors",
      "platform::acp_driver_runtime::tests::errors::"],
    ["rust.platform.acp-runtime.events",
      "platform::acp_driver_runtime::tests::events::"],
    ["rust.platform.acp-runtime.interaction",
      "platform::acp_driver_runtime::tests::interaction::"],
    ["rust.platform.acp-runtime.io",
      "platform::acp_driver_runtime::tests::io::"],
    ["rust.platform.acp-runtime.model",
      "platform::acp_driver_runtime::tests::model::"],
    ["rust.platform.acp-runtime.params",
      "platform::acp_driver_runtime::tests::params::"],
    ["rust.platform.acp-runtime.probe",
      "platform::acp_driver_runtime::tests::probe::"],
    ["rust.platform.acp-runtime.protocol",
      "platform::acp_driver_runtime::tests::protocol::"],
    ["rust.platform.acp-runtime.settings",
      "platform::acp_driver_runtime::tests::settings::"],
    ["rust.platform.acp-runtime.stdio-transport",
      "platform::acp_driver_runtime::tests::stdio_transport::"],
    ["rust.platform.acp-runtime.supervision",
      "platform::acp_driver_runtime::tests::supervision::"],
    ["rust.platform.acp-runtime.replay",
      "platform::native_agent_parser::replay::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.acp-runtime."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    assert.equal(CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id)
      .command.args.at(-1), filter);
  }
  const ownedInputs = new Set(modules.flatMap((module) => module.inputs));
  const sources = await sourceFiles(
    "crates/licoup-agent-drivers/src/acp_driver_runtime", ".rs");
  for (const relativePath of [
    "crates/licoup-agent-drivers/src/acp_driver_runtime.rs",
    ...sources,
    // The moved Agent's dialect and parser are its package's, so the neutral ACP
    // runtime's precise owner for them is the package source it really reads.
    "crates/licoup-agent-kimi/src/parser.rs",
    "crates/licoup-agent-drivers/src/acp_driver_runtime/events.rs",
    "crates/licoup-agent-drivers/src/acp_driver_runtime/protocol.rs",
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `neutral ACP runtime source must have a precise regression owner: ${relativePath}`);
  }
  // The dialects this neutral runtime parses itself. A dialect the host holds is
  // a parser source here; a dialect whose Agent moved into its own package is
  // that package's source, because the composition names the package instead of
  // keeping a copy. The requirement follows the dialect rather than pinning the
  // path an extraction retires, so moving the next dialect changes one entry and
  // cannot leave a requirement behind on a file that no longer exists.
  const neutralDialects = [
    "crates/licoup-agent-copilot/src/dialect.rs",
    "crates/licoup-agent-copilot/src/parser.rs",
    "crates/licoup-agent-kimi/src/dialect.rs",
    "crates/licoup-agent-kimi/src/parser.rs",
  ];
  for (const relativePath of neutralDialects) {
    assert.equal(await exists(relativePath), true,
      `a composed dialect the neutral ACP runtime parses must ship: ${relativePath}`);
    assert.equal(ownedInputs.has(relativePath), true,
      `neutral ACP dialect must have a precise regression owner: ${relativePath}`);
  }
  // The host paths the Copilot and Kimi Code extractions retired must not come
  // back as a second owner of the dialect each package now owns.
  for (const retiredPath of [
    "crates/licoup-native/src/platform/native_agent_parser/adapters/copilot.rs",
    "crates/licoup-native/src/platform/native_agent_parser/adapters/kimi_code.rs",
  ]) {
    assert.equal(await exists(retiredPath), false,
      `${retiredPath} is retired: each moved dialect has one owner, its own package`);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-agent-drivers/src/acp_driver_runtime/session_plan.rs",
  ])), ["architecture.client-boundaries", "rust.platform.acp-runtime.continuity"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-agent-drivers/src/acp_driver_runtime/params.rs",
  ])), ["architecture.client-boundaries", "rust.platform.acp-runtime.params"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-agent-drivers/src/acp_driver_runtime/protocol.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.acp-runtime.interaction",
    "rust.platform.acp-runtime.protocol",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-agent-drivers/src/acp_driver_runtime/stdio_transport.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.acp-runtime.stdio-transport",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-agent-drivers/src/acp_session_transport/execution.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.acp-session-transport.collaboration-mcp",
  ]);
  assert.equal(CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.platform.acp-session-transport").command.args.at(-1),
  "platform::acp_session_transport::tests::");
  const sessionMcp = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.platform.acp-session-transport.collaboration-mcp");
  assert.equal(sessionMcp.command.args.at(-1),
    "platform::acp_session_transport::tests::");
  const sessionModules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id === "rust.platform.acp-session-transport"
      || candidate.id === "rust.platform.acp-session-transport.collaboration-mcp");
  const sessionInputs = new Set(sessionModules.flatMap((module) => module.inputs));
  for (const relativePath of [
    "crates/licoup-agent-drivers/src/acp_session_transport.rs",
    ...await sourceFiles(
      "crates/licoup-agent-drivers/src/acp_session_transport",
      ".rs",
    ),
    "crates/licoup-agent-hermes/src/dialect.rs",
    "crates/licoup-agent-hermes/src/parser.rs",
  ]) {
    assert.equal(sessionInputs.has(relativePath), true,
      `neutral ACP session source must have a precise regression owner: ${relativePath}`);
  }
});

test("Kilo Code adapter leaves retain exact tests and complete source ownership", async () => {
  // The Agent's driver moved into the package that owns it, so the client keeps
  // one Kilo Code source: the host answer for the package's ports, with its own
  // test tree. The module and tree the move retired must not come back as a
  // second owner, and no narrow driver module may outlive the code it named.
  assert.equal(
    await exists("crates/licoup-native/src/platform/kilo_code_driver.rs"),
    false,
    "the host still declares a Kilo Code driver module",
  );
  assert.equal(
    await exists("crates/licoup-native/src/platform/kilo_code_driver"),
    false,
    "the host still declares a Kilo Code driver tree",
  );
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id === "rust.platform.kilo-code-host" ||
    candidate.id.startsWith("rust.platform.kilo-code-driver."));
  assert.equal(modules.length, 1);
  const host = modules[0];
  // The host's own suite is what states what the host still owns: the engine
  // specification, the descriptor force stop reads and the readiness crossing.
  assert.equal(host.command.args.at(-1), "platform::kilo_code_host::tests::");
  const ownedInputs = new Set(host.inputs);
  for (const relativePath of [
    "crates/licoup-native/src/platform/kilo_code_host.rs",
    ...await sourceFiles("crates/licoup-native/src/platform/kilo_code_host", ".rs"),
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Kilo Code host source must have a precise regression owner: ${relativePath}`);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/platform/kilo_code_host.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.kilo-code-serve-source-bundle",
    "rust.platform.kilo-code-host",
  ]);
  // The Agent's own half carries its own narrow owners, and every source the
  // package ships is owned by the package's whole-tree module.
  const packageModuleId = "rust.core.agent-kilo-package";
  const packageSources = await sourceFiles("crates/licoup-agent-kilo/src", ".rs");
  assert.ok(packageSources.length > 0);
  const owns = (relativePath) => CLIENT_MODULE_CATALOG.some((module) =>
    module.inputs.some((input) => input.endsWith("/**")
      ? relativePath.startsWith(input.slice(0, -2))
      : input === relativePath));
  for (const relativePath of packageSources) {
    assert.equal(owns(relativePath), true,
      `Kilo Code package source must have a regression owner: ${relativePath}`);
  }
  const packageModule = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === packageModuleId);
  assert.deepEqual(packageModule.inputs, ["crates/licoup-agent-kilo/**"]);
});

test("runtime adapter modules retain leaf-owned inputs and exact command filters", () => {
  const filters = new Map([
    ["rust.platform.runtime-adapters.registry",
      "platform::runtime_adapters::tests::registry::"],
    ["rust.platform.runtime-adapters.dispatch",
      "platform::runtime_adapters::tests::adapter_dispatch::"],
    ["rust.platform.runtime-adapters.artifact",
      "platform::runtime_adapters::tests::artifact::"],
    ["rust.platform.runtime-adapters.normalization",
      "platform::runtime_adapters::tests::normalization::"],
    ["rust.platform.runtime-adapters.probe",
      "platform::runtime_adapters::tests::probe::"],
  ]);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    assert.equal(module.inputs.includes(
      "crates/licoup-native/src/platform/runtime_adapters.rs"), false);
  }
});

test("Codex app-server leaves retain exact narrow regression ownership", async () => {
  const sourceBundleId = "regression.codex-app-server-source-bundle";
  const packageModuleId = "rust.core.agent-codex-package";
  // The whole Codex driver — protocol, process and the program an extension
  // host starts — is the Codex adapter package's since CODEX-PACKAGE. Every
  // leaf keeps a precise narrow owner inside the package instead of the
  // package's whole-directory fallback.
  const selections = new Map([
    ["crates/licoup-agent-codex/src/app_server/driver/io.rs",
      [packageModuleId, "rust.platform.codex-app-server.io"]],
    ["crates/licoup-agent-codex/src/app_server/driver/launch.rs",
      [packageModuleId, "rust.platform.codex-app-server.launch"]],
    ["crates/licoup-agent-codex/src/app_server/driver/supervision.rs",
      [packageModuleId, "rust.platform.codex-app-server.transport"]],
    ["crates/licoup-agent-codex/src/app_server/driver/transport.rs",
      [packageModuleId, "rust.platform.codex-app-server.transport"]],
    ["crates/licoup-agent-codex/src/app_server/config.rs",
      [packageModuleId, "rust.platform.codex-app-server.config"]],
    ["crates/licoup-agent-codex/src/parser/session.rs",
      [packageModuleId, "rust.platform.codex-app-server.session"]],
    ["crates/licoup-agent-codex/src/parser/events.rs",
      [packageModuleId, "rust.platform.codex-app-server.events"]],
    ["crates/licoup-agent-codex/src/parser/control.rs",
      [packageModuleId, "rust.platform.codex-app-server.control"]],
  ]);
  for (const [source, moduleIds] of selections) {
    assert.deepEqual(ids(selectModulesForChangedPaths([
      source,
    ])), [sourceBundleId, "architecture.client-boundaries", ...moduleIds]);
  }

  const filters = new Map([
    ["rust.platform.codex-app-server", "app_server::driver::tests::"],
    ["rust.platform.codex-app-server.config",
      "app_server::driver::tests::config::"],
    ["rust.platform.codex-app-server.session",
      "app_server::driver::tests::session::"],
    ["rust.platform.codex-app-server.events",
      "app_server::driver::tests::events::"],
    ["rust.platform.codex-app-server.control",
      "app_server::driver::tests::control::"],
    ["rust.platform.codex-app-server.io",
      "app_server::driver::tests::io::"],
    ["rust.platform.codex-app-server.launch",
      "app_server::driver::tests::launch::"],
    ["rust.platform.codex-app-server.transport",
      "app_server::driver::tests::transport::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.codex-app-server"));
  assert.equal(modules.length, filters.size);
  for (const [moduleId, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === moduleId);
    assert.equal(module.command.args.at(-1), filter);
  }

  // Every source that carries the Codex protocol or its process has a precise
  // narrow owner rather than the package's whole-directory fallback.
  const narrowInputs = new Set(modules.flatMap((module) => module.inputs));
  for (const relativePath of [
    "crates/licoup-agent-codex/src/app_server.rs",
    ...await sourceFiles("crates/licoup-agent-codex/src/app_server", ".rs"),
    "crates/licoup-agent-codex/src/parser.rs",
    ...await sourceFiles("crates/licoup-agent-codex/src/parser", ".rs"),
  ]) {
    assert.equal(narrowInputs.has(relativePath), true,
      `Codex app-server source must have a precise regression owner: ${relativePath}`);
  }
  // The client keeps no Codex module: the path the move retired must not come
  // back as a second owner.
  assert.equal(await exists("crates/licoup-native/src/platform/codex_app_server.rs"), false);
  assert.equal(await exists("crates/licoup-native/src/platform/codex_app_server"), false);
  // Every other file the package ships is owned by the package's own module,
  // which owns the crate tree as a whole.
  const owns = (relativePath) => CLIENT_MODULE_CATALOG.some((module) =>
    module.inputs.some((input) => input.endsWith("/**")
      ? relativePath.startsWith(input.slice(0, -2))
      : input === relativePath));
  const packageSources = await sourceFiles("crates/licoup-agent-codex/src", ".rs");
  assert.ok(packageSources.length > 0);
  for (const relativePath of packageSources) {
    assert.equal(owns(relativePath), true,
      `Codex package source must have a regression owner: ${relativePath}`);
  }
  const packageModule = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === packageModuleId);
  assert.deepEqual(packageModule.inputs, ["crates/licoup-agent-codex/**"]);

  const sourceBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === sourceBundleId);
  assert.deepEqual(sourceBundle.command.args, [
    "--test",
    "tests/contract/client/codex-app-server-source-bundle.test.mjs",
  ]);
});

test("Cursor leaves and the Cursor adapter package retain exact regression ownership", async () => {
  const packageModuleId = "rust.core.agent-cursor-package";
  const subagentMcpId = "regression.subagent-mcp-common";
  const owns = (relativePath) => CLIENT_MODULE_CATALOG.some((module) =>
    module.inputs.some((input) => input.endsWith("/**")
      ? relativePath.startsWith(input.slice(0, -2))
      : input === relativePath));
  // The process half is still composed by the client, under the platform
  // fallback that owns the driver it launches; the wire half moved into the
  // Cursor adapter package, and the Subagent MCP caller contract reaches the
  // package's own parser and registration. A source that moved selects the
  // package's own module, and the contract that names it selects the verifier.
  // The kernel sources the process half still owns are measured roots, so they
  // select the client-boundary architecture module as well.
  const hostSelections = new Map([
    ["crates/licoup-native/src/platform/cursor_driver.rs",
      ["rust.platform"]],
    ["crates/licoup-native/src/platform/cursor_driver/model.rs",
      ["rust.platform"]],
    ["crates/licoup-native/src/platform/cursor_driver/errors.rs",
      ["rust.platform"]],
    ["crates/licoup-native/src/platform/cursor_driver/probe.rs",
      ["rust.platform"]],
    ["crates/licoup-native/src/platform/cursor_driver/update_watcher.rs",
      ["rust.platform"]],
  ]);
  for (const [source, moduleIds] of hostSelections) {
    assert.deepEqual(ids(selectModulesForChangedPaths([
      source,
    ])), ["architecture.client-boundaries", ...moduleIds]);
  }
  // The package's own sources select the package's module, and the two the
  // Subagent MCP caller contract reads select that contract's verifier too. The
  // manifest is also the client compatibility declaration the client version
  // check reads, so it selects that check as well.
  const packageSelections = new Map([
    ["crates/licoup-agent-cursor/package/manifest.json",
      ["regression.client-version", packageModuleId]],
    ["crates/licoup-agent-cursor/tests/package_artifact.rs", [packageModuleId]],
    ["crates/licoup-agent-cursor/src/replay.rs",
      ["architecture.client-boundaries", packageModuleId]],
    ["crates/licoup-agent-cursor/src/parser.rs",
      [subagentMcpId, "architecture.client-boundaries", packageModuleId]],
    ["crates/licoup-agent-cursor/src/registration.rs",
      [subagentMcpId, "architecture.client-boundaries", packageModuleId]],
  ]);
  for (const [source, moduleIds] of packageSelections) {
    assert.deepEqual(ids(selectModulesForChangedPaths([
      source,
    ])), moduleIds);
  }

  // The package runs its own tests against its own manifest, and the module
  // owns the crate tree as a whole rather than a list that can drift from it.
  const packageModule = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === packageModuleId);
  assert.deepEqual(packageModule.inputs, ["crates/licoup-agent-cursor/**"]);
  assert.deepEqual(packageModule.command.args, [
    "test",
    "--no-fail-fast",
    "--manifest-path",
    "crates/licoup-agent-cursor/Cargo.toml",
  ]);

  // Every source the package ships has a regression owner, and the kernel
  // sources it left behind keep one too.
  const packageSources2 = await sourceFiles("crates/licoup-agent-cursor", ".rs");
  assert.ok(packageSources2.length > 0);
  for (const relativePath of packageSources2) {
    assert.equal(owns(relativePath), true,
      `Cursor package source must have a regression owner: ${relativePath}`);
  }
  for (const relativePath of [
    "crates/licoup-native/src/platform/cursor_driver.rs",
    ...await sourceFiles("crates/licoup-native/src/platform/cursor_driver", ".rs"),
  ]) {
    assert.equal(owns(relativePath), true,
      `Cursor process-half source must keep a regression owner: ${relativePath}`);
  }
});

test("DeepSeek Harness leaves retain exact narrow regression ownership", async () => {
  const sourceBundleId = "regression.deepseek-harness-source-bundle";
  const packageModuleId = "rust.core.agent-deepseek-package";
  const protocolModuleId = "rust.platform.deepseek-harness-package-protocol";
  const driverModuleId = "rust.platform.deepseek-harness-driver";
  // The whole driver is the DeepSeek adapter package's: the wire half, the
  // session-log reader and the process half all moved out of the kernel. Each
  // keeps a precise owner, and a source that moved selects the package's own
  // module as well.
  const selections = new Map([
    ["crates/licoup-agent-deepseek/src/driver.rs",
      [sourceBundleId, packageModuleId, driverModuleId]],
    ["crates/licoup-agent-deepseek/src/port/launch_environment.rs",
      [sourceBundleId, packageModuleId, driverModuleId]],
    ["crates/licoup-native/src/platform/runtime_adapters/drivers.rs",
      [sourceBundleId, "rust.platform.runtime-adapters"]],
    ["crates/licoup-agent-deepseek/src/parser.rs",
      [packageModuleId, protocolModuleId]],
    ["crates/licoup-agent-deepseek/src/session_store.rs",
      [packageModuleId, "rust.domain.agent-usage.deepseek-reader"]],
    ["crates/licoup-agent-deepseek/package/manifest.json",
      ["regression.agent-deepseek-adapter-package", packageModuleId]],
    ["crates/licoup-agent-deepseek/src/bin/lico-agent-deepseek.rs",
      [packageModuleId, "rust.domain.agent-usage.deepseek-reader"]],
    ["crates/licoup-agent-deepseek/tests/package_artifact.rs",
      [packageModuleId, "rust.domain.agent-usage.deepseek-reader"]],
  ]);
  for (const [source, moduleIds] of selections) {
    const selected = ids(selectModulesForChangedPaths([source]));
    for (const moduleId of moduleIds) {
      assert.ok(selected.includes(moduleId),
        `${source} must select ${moduleId}: ${selected.join(", ")}`);
    }
  }

  // The host keeps no DeepSeek Harness driver source at all, so no retired path
  // can keep a regression owner.
  for (const retiredPath of [
    "crates/licoup-native/src/platform/deepseek_harness_driver.rs",
    "crates/licoup-native/src/platform/deepseek_harness_driver",
  ]) {
    assert.equal(await exists(retiredPath), false,
      `the host still carries the retired DeepSeek Harness driver: ${retiredPath}`);
  }

  // The package's own module runs its own crate tests, so a change anywhere in
  // the package is exercised by the package rather than by the kernel.
  const packageModule = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === packageModuleId);
  assert.deepEqual(packageModule.inputs, ["crates/licoup-agent-deepseek/**"]);
  assert.deepEqual(packageModule.command.args,
    ["test", "--no-fail-fast", "--manifest-path", "crates/licoup-agent-deepseek/Cargo.toml"]);

  // Every source the package ships has a regression owner, and the reader's own
  // module names the package's crate rather than the removed Node script.
  const owns = (relativePath) => CLIENT_MODULE_CATALOG.some((module) =>
    module.inputs.some((input) => input.endsWith("/**")
      ? relativePath.startsWith(input.slice(0, -2))
      : input === relativePath));
  const packageSources2 = await sourceFiles("crates/licoup-agent-deepseek/src", ".rs");
  assert.ok(packageSources2.length > 0);
  for (const relativePath of packageSources2) {
    assert.equal(owns(relativePath), true,
      `DeepSeek package source must have a regression owner: ${relativePath}`);
  }
  const readerModule = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.domain.agent-usage.deepseek-reader");
  assert.equal(
    readerModule.inputs.some((input) => input.includes("deepseek_reader.mjs")),
    false,
    "the removed Node reader must not keep a regression owner",
  );

  const sourceBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === sourceBundleId);
  assert.deepEqual(sourceBundle.command.args, [
    "--test",
    "tests/contract/client/deepseek-harness-source-bundle.test.mjs",
  ]);
});

test("Lico Agent leaves retain exact narrow regression ownership", async () => {
  const packageModuleId = "rust.core.agent-lico-agent-package";
  // The RPC wire, the request envelopes, the session layout and the plan layout
  // moved into the Lico Agent adapter package; the process half is still
  // composed by the client under `platform::lico_agent_driver`. Both keep a
  // precise owner, and a source that moved selects the package's own module.
  const selections = new Map([
    ["crates/licoup-native/src/platform/lico_agent_driver/execution.rs",
      ["rust.platform"]],
    ["crates/licoup-agent-lico-agent/src/parser.rs", [packageModuleId]],
    ["crates/licoup-agent-lico-agent/src/session.rs", [packageModuleId]],
    ["crates/licoup-agent-lico-agent/src/bin/lico-agent-lico-agent.rs", [packageModuleId]],
    ["crates/licoup-agent-lico-agent/tests/package_artifact.rs", [packageModuleId]],
    ["crates/licoup-agent-lico-agent/package/manifest.json", [packageModuleId]],
  ]);
  for (const [source, moduleIds] of selections) {
    const selected = ids(selectModulesForChangedPaths([source]));
    for (const moduleId of moduleIds) {
      assert.ok(selected.includes(moduleId),
        `${source} must select ${moduleId}: ${selected.join(", ")}`);
    }
  }

  // The package's own module runs its own crate tests, so a change anywhere in
  // the package is exercised by the package rather than by the kernel.
  const packageModule = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === packageModuleId);
  assert.deepEqual(packageModule.inputs, ["crates/licoup-agent-lico-agent/**"]);
  assert.deepEqual(packageModule.command.args,
    ["test", "--no-fail-fast", "--manifest-path", "crates/licoup-agent-lico-agent/Cargo.toml"]);

  // Every source the package ships has a regression owner.
  const owns = (relativePath) => CLIENT_MODULE_CATALOG.some((module) =>
    module.inputs.some((input) => input.endsWith("/**")
      ? relativePath.startsWith(input.slice(0, -2))
      : input === relativePath));
  const packageSources = await sourceFiles("crates/licoup-agent-lico-agent/src", ".rs");
  assert.ok(packageSources.length > 0);
  for (const relativePath of packageSources) {
    assert.equal(owns(relativePath), true,
      `Lico Agent package source must have a regression owner: ${relativePath}`);
  }

  // No module may still name a host copy the package took over as an exact
  // input: a deleted file kept as a measured input looks owned while nothing
  // runs it, and the package's own copy is what a change must select. A
  // directory glob over a tree that still exists is a live owner of that tree,
  // not a reference to the file that left it, so the check is exact.
  const exactInputs = new Set(CLIENT_MODULE_CATALOG.flatMap((module) => module.inputs));
  for (const relativePath of [
    "crates/licoup-native/src/platform/native_agent_parser/adapters/lico_agent.rs",
    "crates/licoup-native/src/platform/native_agent_parser/replay/adapters/lico_agent.rs",
  ]) {
    assert.equal(exactInputs.has(relativePath), false,
      `a moved host copy must not stay a measured catalog input: ${relativePath}`);
  }
});

test("local service leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.local-service.composition", "platform::local_service::tests::composition::"],
    ["rust.platform.local-service.bounds", "platform::local_service::tests::bounds::"],
    ["rust.platform.local-service.concurrency", "platform::local_service::tests::concurrency::"],
    ["rust.platform.local-service.endpoint", "platform::local_service::tests::endpoint::"],
    ["rust.platform.local-service.executable", "platform::local_service::tests::executable::"],
    ["rust.platform.local-service.http", "platform::local_service::tests::http::"],
    ["rust.platform.local-service.params", "platform::local_service::tests::params::"],
    ["rust.platform.local-service.port", "platform::local_service::tests::port::"],
    ["rust.platform.local-service.process", "platform::local_service::tests::process::"],
    ["rust.platform.local-service.serve", "platform::local_service::tests::serve::"],
    ["rust.platform.local-service.sse", "platform::local_service::tests::sse::"],
    ["rust.platform.local-service.state", "platform::local_service::tests::state::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.local-service."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    if (!id.endsWith(".composition")) {
      assert.equal(module.inputs.includes(
        "crates/licoup-agent-drivers/src/local_service.rs"), false);
    }
  }
  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.local-service-source-bundle");
  assert.deepEqual(sourceCheck.command.args,
    ["--test", "tests/contract/client/local-service-source-bundle.test.mjs"]);
  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = await sourceFiles(
    "crates/licoup-agent-drivers/src/local_service", ".rs");
  for (const relativePath of [
    "crates/licoup-agent-drivers/src/local_service.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `local service source must have a precise regression owner: ${relativePath}`);
  }
});

test("file security leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.file-security.composition", "platform::file_security::tests::composition::"],
    ["rust.platform.file-security.policy", "platform::file_security::tests::policy::"],
    ["rust.platform.file-security.append-lock", "platform::file_security::tests::append_lock::"],
    ["rust.platform.file-security.atomic-replace", "platform::file_security::tests::atomic_"],
    ["rust.platform.file-security.marker", "platform::file_security::tests::marker::"],
    ["rust.platform.file-security.validation", "platform::file_security::tests::validation::"],
    ["rust.platform.file-security.sync", "platform::file_security::tests::sync::"],
    ["rust.platform.file-security.hardening", "platform::file_security::tests::hardening::"],
    ["rust.platform.file-security.unix-hardening", "platform::file_security::tests::unix_hardening::"],
    ["rust.platform.file-security.windows-acl", "platform::file_security::tests::windows_acl::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.file-security."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    if (!id.endsWith(".composition")) {
      assert.equal(module.inputs.includes(
        "crates/licoup-foundation/src/platform/file_security.rs"), false);
    }
  }
  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.file-security-source-bundle");
  assert.deepEqual(sourceCheck.command.args,
    ["--test", "tests/contract/client/file-security-source-bundle.test.mjs"]);
  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = await sourceFiles(
    "crates/licoup-foundation/src/platform/file_security", ".rs");
  for (const relativePath of [
    "crates/licoup-foundation/src/platform/file_security.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `file security source must have a precise regression owner: ${relativePath}`);
  }
});

test("client state leaves retain exact tests and complete source ownership", async () => {
  // The store and its journal owners moved to `licoup-client-state`; only the
  // facade and the wire-contract command surface stay in the host.
  const filters = new Map([
    ["rust.platform.client-state.composition", "platform::client_state::tests::composition::"],
    ["rust.platform.client-state.policy", "tests::policy::"],
    ["rust.platform.client-state.collections", "tests::collections::"],
    ["rust.platform.client-state.activity", "tests::activity::"],
    ["rust.platform.client-state.snapshots", "tests::snapshots::"],
    ["rust.platform.client-state.redaction", "tests::redaction::"],
    ["rust.platform.client-state.serialization", "tests::serialization::"],
    ["rust.platform.client-state.paths", "tests::paths::"],
    ["rust.platform.client-state.accessors", "tests::accessors::"],
    ["rust.platform.client-state.operations", "platform::client_state::tests::operations::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.client-state."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    if (!id.endsWith(".composition")) {
      assert.equal(module.inputs.includes(
        "crates/licoup-native/src/platform/client_state.rs"), false);
    }
  }
  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.client-state-source-bundle");
  assert.deepEqual(sourceCheck.command.args,
    ["--test", "tests/contract/client/client-state-source-bundle.test.mjs"]);
  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = [
    ...await sourceFiles("crates/licoup-native/src/platform/client_state", ".rs"),
    ...await sourceFiles("crates/licoup-client-state/src", ".rs"),
  ];
  for (const relativePath of [
    "crates/licoup-native/src/platform/client_state.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `client state source must have a precise regression owner: ${relativePath}`);
  }
});

test("OpenCode serve leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.opencode-serve.composition", "platform::opencode_serve::tests::composition::"],
    ["rust.platform.opencode-serve.policy", "platform::opencode_serve::tests::policy::"],
    ["rust.platform.opencode-serve.events", "platform::opencode_serve::tests::events::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.opencode-serve."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
  }
  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.opencode-serve-source-bundle");
  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = await sourceFiles(
    "crates/licoup-native/src/platform/opencode_serve", ".rs");
  for (const relativePath of [
    "crates/licoup-native/src/platform/opencode_serve.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `OpenCode serve source must have a precise regression owner: ${relativePath}`);
  }
});

test("Kilo Code protocol leaves retain exact tests in the package that owns them", async () => {
  // The parser, the endpoint policy and the driver's own half moved into the
  // Agent's package, so their leaves run against the package's manifest rather
  // than against the host that composes it.
  const filters = new Map([
    ["rust.platform.kilo-code-package.parser",
      "parser::"],
    ["rust.platform.kilo-code-package.driver",
      "driver::"],
    ["rust.platform.kilo-code-package.registration",
      "registration::"],
    ["rust.platform.kilo-code-package.policy",
      "policy::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.kilo-code-package."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    assert.equal(module.command.args.includes("crates/licoup-agent-kilo/Cargo.toml"), true,
      `${id} must run against the package's own manifest`);
  }
  const ownedInputs = new Set(modules.flatMap((module) => module.inputs));
  // Every source one of the package's narrow owners covers is owned by one of
  // them rather than by another Agent's module or by nothing at all. The narrow
  // inputs are directory globs, so each real file is matched the way the catalog
  // matches it.
  const narrow = (relativePath) => modules.some((module) =>
    module.inputs.some((input) => input.endsWith("/**")
      ? relativePath.startsWith(input.slice(0, -2))
      : input === relativePath));
  for (const relativePath of [
    ...await sourceFiles("crates/licoup-agent-kilo/src/parser", ".rs"),
    "crates/licoup-agent-kilo/src/policy.rs",
    // The turn the host composes, the probe it offers and the claims that drive
    // them moved here with the driver module the host retired.
    ...await sourceFiles("crates/licoup-agent-kilo/src/driver", ".rs"),
    "crates/licoup-agent-kilo/src/registration.rs",
  ]) {
    assert.equal(narrow(relativePath), true,
      `Kilo Code package source must have a precise regression owner: ${relativePath}`);
  }
  assert.equal(ownedInputs.has("crates/licoup-agent-kilo/src/driver/**"), true,
    "the moved driver leaves must stay owned by the package's driver module");
});

test("OpenClaw Gateway leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.openclaw-gateway.composition", "platform::openclaw_gateway::tests::composition::"],
    ["rust.platform.openclaw-gateway.command", "platform::openclaw_gateway::tests::command::"],
    ["rust.platform.openclaw-gateway.config", "platform::openclaw_gateway::tests::config::"],
    ["rust.platform.openclaw-gateway.health", "platform::openclaw_gateway::tests::health::"],
    ["rust.platform.openclaw-gateway.lifecycle", "platform::openclaw_gateway::tests::lifecycle::"],
    ["rust.platform.openclaw-gateway.model", "platform::openclaw_gateway::tests::model::"],
    ["rust.platform.openclaw-gateway.policy", "platform::openclaw_gateway::tests::policy::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.openclaw-gateway."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
  }
  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.openclaw-gateway-source-bundle");
  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = await sourceFiles(
    "crates/licoup-native/src/platform/openclaw_gateway", ".rs");
  for (const relativePath of [
    "crates/licoup-native/src/platform/openclaw_gateway.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `OpenClaw Gateway source must have a precise regression owner: ${relativePath}`);
  }
});

test("Claude Code driver leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.claude-code-driver.composition",
      "driver::tests::composition::"],
    ["rust.platform.claude-code-driver.test-support",
      "driver::tests::"],
    ["rust.platform.claude-code-driver.model",
      "driver::tests::model::"],
    ["rust.platform.claude-code-driver.failure",
      "driver::tests::failure::"],
    ["rust.platform.claude-code-driver.launch-params",
      "driver::tests::launch::"],
    ["rust.platform.claude-code-driver.launch-argv",
      "driver::tests::command::"],
    ["rust.platform.claude-code-driver.events",
      "driver::tests::events::"],
    ["rust.platform.claude-code-package.protocol",
      "driver::tests::protocol::"],
    ["rust.platform.claude-code-driver.io",
      "driver::tests::io::"],
    ["rust.platform.claude-code-driver.control",
      "driver::tests::control::"],
    ["rust.platform.claude-code-driver.transport",
      "driver::tests::transport::"],
    ["rust.platform.claude-code-driver.supervision",
      "driver::tests::supervision::"],
    ["rust.platform.claude-code-driver.probe",
      "driver::tests::probe::"],
    ["rust.platform.claude-code-driver.execution",
      "driver::tests::execution::"],
    ["rust.platform.claude-code-driver.host-integration",
      "platform::runtime_adapters::tests::claude_code_package::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.claude-code-driver.")
      || candidate.id === "rust.platform.claude-code-package.protocol");
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    // No module owns a retired kernel Claude Code driver path: the host keeps
    // no module and no tree of its own for this Agent.
    for (const input of module.inputs) {
      assert.equal(
        input.startsWith("crates/licoup-native/src/platform/claude_code_driver"),
        false,
        `${id} still owns a retired kernel Claude Code driver path: ${input}`,
      );
    }
  }

  // A source that moved into the package selects the package's own module as
  // well as the leaf that owns the concern, and the host's own fold keeps its
  // precise narrow owner.
  const ownership = new Map([
    ["crates/licoup-agent-claude-code/src/driver/launch.rs",
      ["rust.core.agent-claude-code-package",
        "rust.platform.claude-code-driver.launch-params"]],
    ["crates/licoup-agent-claude-code/src/driver/reset.rs",
      ["rust.core.agent-claude-code-package",
        "rust.platform.claude-code-driver.failure"]],
    ["crates/licoup-agent-claude-code/src/protocol/parser/state.rs",
      ["rust.core.agent-claude-code-package",
        "rust.platform.claude-code-package.protocol"]],
    ["crates/licoup-agent-claude-code/src/protocol/parser/events.rs",
      ["rust.core.agent-claude-code-package",
        "rust.platform.claude-code-driver.events"]],
    ["crates/licoup-native/src/platform/runtime_adapters/tests/claude_code_package.rs",
      ["rust.platform.claude-code-driver.host-integration"]],
  ]);
  for (const [source, expected] of ownership) {
    const selected = ids(selectModulesForChangedPaths([source]));
    for (const id of expected) {
      assert.equal(selected.includes(id), true,
        `${source} must select ${id}, selected ${selected.join(", ")}`);
    }
  }

  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.claude-code-driver-source-bundle");
  assert.deepEqual(sourceCheck.command.args,
    ["--test", "tests/contract/client/claude-code-driver-source-bundle.test.mjs"]);
  const packageCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.claude-code-package-source-bundle");
  assert.deepEqual(packageCheck.command.args,
    ["--test", "tests/contract/client/claude-code-package-source-bundle.test.mjs"]);

  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
    ...packageCheck.inputs,
  ]);
  // The host declares no Claude Code driver module or tree at all.
  assert.equal(
    await exists("crates/licoup-native/src/platform/claude_code_driver.rs"),
    false,
    "the host still declares a Claude Code driver module",
  );
  assert.equal(
    await exists("crates/licoup-native/src/platform/claude_code_driver"),
    false,
    "the host still declares a Claude Code driver tree",
  );
  // Every driver leaf is the package's, and every one of them keeps a precise
  // owner rather than the package's fallback.
  const splitSources = await sourceFiles(
    "crates/licoup-agent-claude-code/src/driver",
    ".rs",
  );
  assert.ok(splitSources.length > 0);
  for (const relativePath of [
    "crates/licoup-agent-claude-code/src/driver.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Claude Code driver source must have a precise regression owner: ${relativePath}`);
  }
  // The package's own crate keeps one fallback owner for every source it ships,
  // and its protocol and document leaves are named precisely.
  const owns = (relativePath) => CLIENT_MODULE_CATALOG.some((module) =>
    module.inputs.some((input) => input.endsWith("/**")
      ? relativePath.startsWith(input.slice(0, -2))
      : input === relativePath));
  const packageSources = await sourceFiles("crates/licoup-agent-claude-code/src", ".rs");
  assert.ok(packageSources.length > 0);
  for (const relativePath of packageSources) {
    assert.equal(owns(relativePath), true,
      `Claude Code package source must have a regression owner: ${relativePath}`);
  }
  const packageModule = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.core.agent-claude-code-package");
  assert.deepEqual(packageModule.inputs, ["crates/licoup-agent-claude-code/**"]);
});

test("OpenClaw package leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.openclaw-driver.composition",
      "driver::tests::composition::"],
    ["rust.platform.openclaw-driver.test-support",
      "driver::tests::"],
    ["rust.platform.openclaw-driver.model",
      "driver::tests::model::"],
    ["rust.platform.openclaw-driver.errors",
      "driver::tests::errors::"],
    ["rust.platform.openclaw-driver.params",
      "driver::tests::params::"],
    ["rust.platform.openclaw-driver.codec",
      "driver::tests::codec::"],
    ["rust.platform.openclaw-driver.continuity",
      "driver::tests::continuity::"],
    ["rust.platform.openclaw-driver.events",
      "driver::tests::events::"],
    ["rust.platform.openclaw-driver.protocol",
      "driver::tests::protocol::"],
    ["rust.platform.openclaw-driver.interaction",
      "driver::tests::interaction::"],
    ["rust.platform.openclaw-driver.io",
      "driver::tests::io::"],
    ["rust.platform.openclaw-driver.supervision",
      "driver::tests::supervision::"],
    ["rust.platform.openclaw-driver.probe",
      "driver::tests::probe::"],
    ["rust.platform.openclaw-driver.execution",
      "driver::tests::execution::"],
    ["rust.platform.openclaw-driver.replay",
      "replay::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.openclaw-driver."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    if (!id.endsWith(".composition")) {
      assert.equal(module.inputs.includes(
        "crates/licoup-native/src/platform/openclaw_driver.rs"), false);
    }
  }

  // Both halves of the driver are the package's: no kernel path may come back as
  // a second owner of the protocol, the reviewed process sites or their tests.
  for (const retiredPath of [
    "crates/licoup-native/src/platform/openclaw_driver.rs",
    "crates/licoup-native/src/platform/openclaw_driver",
  ]) {
    assert.equal(await exists(retiredPath), false,
      `${retiredPath} is retired: the OpenClaw package owns its driver`);
  }
  const platform = await fs.readFile(
    path.join(repoRoot, "crates/licoup-native/src/platform/mod.rs"), "utf8");
  assert.doesNotMatch(platform, /mod openclaw_driver;/u,
    "the host module tree still declares an OpenClaw driver module");
  // The composition names the package, exactly as the Codex arm names its own.
  const composition = await fs.readFile(
    path.join(repoRoot,
      "crates/licoup-native/src/platform/runtime_adapters/drivers.rs"), "utf8");
  assert.ok(
    composition.includes("use licoup_agent_openclaw::driver as openclaw_driver;"),
    "the composition must read the package's driver",
  );

  // A source the package owns selects the package's own module as well as the
  // leaf that owns the concern.
  const ownership = new Map([
    ["crates/licoup-agent-openclaw/src/driver/execution.rs",
      ["rust.core.agent-openclaw-package",
        "rust.platform.openclaw-driver.execution"]],
    ["crates/licoup-agent-openclaw/src/gateway_acp/params.rs",
      ["rust.core.agent-openclaw-package",
        "rust.platform.openclaw-driver.params"]],
    ["crates/licoup-native/src/platform/openclaw_host.rs",
      ["rust.platform.openclaw-host-ports"]],
    ["crates/licoup-native/tests/fixtures/fake_openclaw_acp.rs",
      ["rust.platform.openclaw-host-ports"]],
  ]);
  for (const [source, expected] of ownership) {
    const selected = ids(selectModulesForChangedPaths([source]));
    for (const id of expected) {
      assert.equal(selected.includes(id), true,
        `${source} must select ${id}, selected ${selected.join(", ")}`);
    }
  }

  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.openclaw-driver-source-bundle");
  assert.deepEqual(sourceCheck.command.args,
    ["--test", "tests/contract/client/openclaw-driver-source-bundle.test.mjs"]);
  const hostPorts = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.platform.openclaw-host-ports");
  assert.deepEqual(hostPorts.command.args.at(-1), "platform::openclaw_host::tests::");

  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
    ...hostPorts.inputs,
  ]);
  for (const relativePath of [
    "crates/licoup-agent-openclaw/src/driver.rs",
    "crates/licoup-agent-openclaw/src/policy.rs",
    "crates/licoup-agent-openclaw/src/port/gateway.rs",
    ...await sourceFiles("crates/licoup-agent-openclaw/src/driver", ".rs"),
    "crates/licoup-agent-openclaw/src/parser.rs",
    ...await sourceFiles("crates/licoup-agent-openclaw/src/parser", ".rs"),
    ...await sourceFiles("crates/licoup-agent-openclaw/src/gateway_acp", ".rs"),
    "crates/licoup-agent-openclaw/src/gateway.rs",
    "crates/licoup-agent-openclaw/src/replay.rs",
    // The host answers this package's ports from its own modules, and those
    // answers keep their own precise owner.
    "crates/licoup-native/src/platform/openclaw_host.rs",
    "crates/licoup-native/src/platform/openclaw_host/tests.rs",
    "crates/licoup-native/tests/fixtures/fake_openclaw_acp.rs",
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `OpenClaw source must have a precise regression owner: ${relativePath}`);
  }

  // The package's own crate keeps one fallback owner for every source it ships.
  const owns = (relativePath) => CLIENT_MODULE_CATALOG.some((module) =>
    module.inputs.some((input) => input.endsWith("/**")
      ? relativePath.startsWith(input.slice(0, -2))
      : input === relativePath));
  const packageSources = await sourceFiles("crates/licoup-agent-openclaw/src", ".rs");
  assert.ok(packageSources.length > 0);
  for (const relativePath of packageSources) {
    assert.equal(owns(relativePath), true,
      `OpenClaw package source must have a regression owner: ${relativePath}`);
  }
  const packageModule = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.core.agent-openclaw-package");
  assert.deepEqual(packageModule.inputs, ["crates/licoup-agent-openclaw/**"]);
});

test("Pi driver leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.pi-driver.composition",
      "driver::tests::composition::"],
    ["rust.platform.pi-driver.test-support",
      "driver::tests::"],
    ["rust.platform.pi-driver.model",
      "driver::tests::model::"],
    ["rust.platform.pi-driver.errors",
      "driver::tests::errors::"],
    ["rust.platform.pi-driver.params",
      "driver::tests::params::"],
    ["rust.platform.pi-driver.settings",
      "driver::tests::settings::"],
    ["rust.platform.pi-driver.protocol",
      "driver::tests::parser_protocol::"],
    ["rust.platform.pi-driver.interaction",
      "driver::tests::interaction::"],
    ["rust.platform.pi-driver.events",
      "driver::tests::parser_events::"],
    ["rust.platform.pi-driver.sessions",
      "driver::tests::sessions::"],
    ["rust.platform.pi-driver.io",
      "driver::tests::io::"],
    ["rust.platform.pi-driver.supervision",
      "driver::tests::supervision::"],
    ["rust.platform.pi-driver.probe",
      "driver::tests::probe::"],
    ["rust.platform.pi-driver.execution",
      "driver::tests::execution::"],
    ["rust.platform.pi-driver.native-events",
      "platform::runtime_adapters::tests::pi_turn_events::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.pi-driver."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    assert.equal(module.inputs.includes(
      "crates/licoup-native/src/platform/pi_driver.rs"), false,
      "a retired Pi driver path is still owned");
  }
  // The driver half is the package's, so every leaf runs against the package's
  // own manifest. The one host-side leaf runs against the host that owns the
  // turn-event consumer, because no package process can observe it.
  for (const module of modules) {
    const manifestIndex = module.command.args.indexOf("--manifest-path") + 1;
    assert.equal(module.command.args[manifestIndex],
      module.id.endsWith(".native-events")
        ? "crates/licoup-native/Cargo.toml"
        : "crates/licoup-agent-pi/Cargo.toml",
      module.id);
  }

  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.pi-driver-source-bundle");
  assert.deepEqual(sourceCheck.command.args,
    ["--test", "tests/contract/client/pi-driver-source-bundle.test.mjs"]);

  // The kernel keeps no Pi driver source at all: the module and its tree are
  // retired, and no regression group may own a path that no longer exists.
  for (const retired of [
    "crates/licoup-native/src/platform/pi_driver.rs",
    "crates/licoup-native/src/platform/pi_driver",
  ]) {
    assert.equal(await exists(retired), false,
      `the host still declares a retired Pi driver path: ${retired}`);
  }

  // The whole driver — the facade, the process half and the claims that drive
  // it — is owned by the package's own narrow groups.
  const packageModuleId = "rust.core.agent-pi-package";
  const narrowInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  for (const relativePath of [
    "crates/licoup-agent-pi/src/parser.rs",
    ...await sourceFiles("crates/licoup-agent-pi/src/parser", ".rs"),
    "crates/licoup-agent-pi/src/driver.rs",
    ...await sourceFiles("crates/licoup-agent-pi/src/driver", ".rs"),
  ]) {
    assert.equal(narrowInputs.has(relativePath), true,
      `Pi driver source must have a precise regression owner: ${relativePath}`);
  }
  const owns = (relativePath) => CLIENT_MODULE_CATALOG.some((module) =>
    module.inputs.some((input) => input.endsWith("/**")
      ? relativePath.startsWith(input.slice(0, -2))
      : input === relativePath));
  const packageSources = await sourceFiles("crates/licoup-agent-pi/src", ".rs");
  assert.ok(packageSources.length > 0);
  for (const relativePath of packageSources) {
    assert.equal(owns(relativePath), true,
      `Pi package source must have a regression owner: ${relativePath}`);
  }
  const packageModule = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === packageModuleId);
  assert.deepEqual(packageModule.inputs, ["crates/licoup-agent-pi/**"]);
});

test("OpenCode driver leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.opencode-driver.composition",
      "platform::opencode_driver::tests::composition::"],
    ["rust.platform.opencode-driver.test-support",
      "platform::opencode_driver::tests::"],
    ["rust.platform.opencode-driver.probe",
      "platform::opencode_driver::tests::probe::"],
    ["rust.platform.opencode-driver.serve-transport",
      "platform::opencode_driver::tests::serve_transport::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.opencode-driver."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    if (!id.endsWith(".composition")) {
      assert.equal(module.inputs.includes(
        "crates/licoup-native/src/platform/opencode_driver.rs"), false);
    }
  }

  const ownedInputs = new Set(modules.flatMap((module) => module.inputs));
  const splitSources = await sourceFiles(
    "crates/licoup-native/src/platform/opencode_driver",
    ".rs",
  );
  for (const relativePath of [
    "crates/licoup-native/src/platform/opencode_driver.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `OpenCode driver source must have a precise regression owner: ${relativePath}`);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/platform/opencode_driver/continuity.rs",
  ])), [
    // The OpenCode adapter package's own ownership contract reads this file: the
    // package owns the serve protocol, and the driver that supervises the
    // endpoint is where the host reads it, so a change here is a change to the
    // claim that the host keeps no copy.
    "regression.opencode-adapter-package-source-bundle",
    "architecture.client-boundaries",
    "rust.platform.opencode-driver.serve-transport",
  ]);
});

test("Hermes package driver leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.hermes-driver.composition",
      "driver::tests::composition::"],
    ["rust.platform.hermes-driver.test-support",
      "driver::tests::"],
    ["rust.platform.hermes-driver.capabilities",
      "driver::tests::capabilities::"],
    ["rust.platform.hermes-driver.command",
      "driver::tests::command::"],
    ["rust.platform.hermes-driver.protocol",
      "driver::tests::protocol::"],
    ["rust.platform.hermes-driver.events",
      "driver::tests::events::"],
    ["rust.platform.hermes-driver.approval",
      "driver::tests::approval::"],
    ["rust.platform.hermes-driver.process-io",
      "driver::tests::process_io::"],
    ["rust.platform.hermes-driver.execution",
      "driver::tests::execution::"],
    ["rust.platform.hermes-driver.continuity",
      "driver::tests::continuity::"],
    ["rust.platform.hermes-driver.probe",
      "driver::tests::probe::"],
    ["rust.platform.hermes-driver.error-normalization",
      "driver::tests::errors::"],
    // The one Hermes lane the host keeps is its own TUI gateway transport, so it
    // is the only leaf here that still runs against the host's manifest.
    ["rust.platform.hermes-driver.tui-gateway",
      "platform::hermes_tui_gateway"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.hermes-driver."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    if (id.endsWith(".tui-gateway")) {
      assert.equal(module.command.args.includes("crates/licoup-native/Cargo.toml"), true,
        `${id} must run against the host's own manifest`);
    } else {
      assert.equal(module.command.args.includes("crates/licoup-agent-hermes/Cargo.toml"), true,
        `${id} must run against the package's own manifest`);
    }
    if (!id.endsWith(".composition")) {
      assert.equal(module.inputs.includes(
        "crates/licoup-agent-hermes/src/driver.rs"), false);
    }
  }

  // The host carries no Hermes driver source at all, so no retired path keeps a
  // regression owner.
  for (const retiredPath of [
    "crates/licoup-native/src/platform/hermes_driver.rs",
    "crates/licoup-native/src/platform/hermes_driver",
  ]) {
    assert.equal(await exists(retiredPath), false,
      `the host still carries the retired Hermes driver: ${retiredPath}`);
  }

  const ownedInputs = new Set(modules.flatMap((module) => module.inputs));
  const splitSources = await sourceFiles(
    "crates/licoup-agent-hermes/src/driver",
    ".rs",
  );
  for (const relativePath of [
    "crates/licoup-agent-hermes/src/driver.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Hermes package driver source must have a precise regression owner: ${relativePath}`);
  }
});

test("native CLI modules retain exact binary-scoped command filters", () => {
  const filters = new Map([
    ["rust.bin.licoup", ["tests::"]],
    ["rust.bin.licoup.rpc", ["--", "tests::rpc::", "stdio_rpc::server::conversation::",
      "stdio_rpc::server::work_control_routing_tests::",
      "stdio_rpc::request::work_control_routing_tests::"]],
    ["rust.bin.licoup.core-commands", ["tests::core_commands::"]],
    ["rust.bin.licoup.skill-commands", ["tests::skill_commands::"]],
    ["rust.bin.licoup.parsing", ["tests::parsing::"]],
  ]);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.deepEqual(module.command.args, [
      "test",
      "-p",
      "licoup-native",
      "--bin",
      "licoup-cli",
      ...filter,
    ]);
    if (id !== "rust.bin.licoup") {
      assert.equal(module.inputs.includes(
        "crates/licoup-native/src/bin/licoup.rs"), false);
    }
  }
});

test("extension host and isolation leaves retain exact tests and complete source ownership", async () => {
  const expectedCommands = new Map([
    ["rust.platform.extension-host", "extension_contract"],
    ["rust.platform.extension-isolation", "extension_isolation"],
  ]);
  for (const [id, target] of expectedCommands) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.deepEqual(module.command.args, [
      "test",
      "--manifest-path",
      "crates/licoup-native/Cargo.toml",
      "--test",
      target,
    ]);
  }
  const host = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.platform.extension-host");
  const isolation = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.platform.extension-isolation");
  assert.equal(host.inputs.some((input) => input.endsWith("/**")), true);
  assert.equal(isolation.inputs.some((input) => input.endsWith("/**")), true);

  // The declarative machines the host and the package store read are part of
  // what the host serves, so a change to one of them selects the host leaf.
  for (const relativePath of [
    "crates/licoup-native/resources/state-machines/extension-package.json",
    "crates/licoup-native/resources/state-machines/extension-instance.json",
    "crates/licoup-native/resources/state-machines/extension-invocation.json",
  ]) {
    assert.equal(host.inputs.includes(relativePath), true,
      `extension state machine must have a precise regression owner: ${relativePath}`);
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "rust.platform.extension-host",
    ]);
  }

  // Every source the host and the isolation carrier own resolves to exactly
  // one of the two leaves: the host's own suite for the host half, and the real
  // subprocess suite for the isolation half.
  const hostSources = [
    "crates/licoup-native/src/platform/extension_host/mod.rs",
    ...await sourceFiles("crates/licoup-native/src/platform/extension_host", ".rs"),
  ].filter((relativePath) =>
    !relativePath.startsWith("crates/licoup-native/src/platform/extension_host/isolation/"));
  for (const relativePath of hostSources) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "architecture.client-boundaries",
      "rust.platform.extension-host",
    ], `extension host source must have one regression owner: ${relativePath}`);
  }
  const isolationSources = [
    ...await sourceFiles("crates/licoup-native/src/platform/extension_host/isolation", ".rs"),
  ];
  for (const relativePath of isolationSources) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "architecture.client-boundaries",
      "rust.platform.extension-host",
      "rust.platform.extension-isolation",
    ], `extension isolation source must have one regression owner: ${relativePath}`);
  }
  for (const relativePath of [
    "tests/integration/extension_isolation/main.rs",
    ...await sourceFiles("tests/integration/extension_isolation", ".rs"),
    "sdk/agent-adapter/python/licoup_agent_sdk.py",
    "sdk/agent-adapter/samples/minimal-specialist/agent.py",
  ]) {
    assert.deepEqual(ids(selectModulesForChangedPaths([relativePath])), [
      "rust.platform.extension-isolation",
    ], `extension isolation fixture must have one regression owner: ${relativePath}`);
  }

  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/tests/extension_contract/main.rs",
  ])), ["rust.platform.extension-host"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "tests/integration/extension_isolation/main.rs",
  ])), ["rust.platform.extension-isolation"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "sdk/agent-adapter/python/licoup_agent_sdk.py",
  ])), ["rust.platform.extension-isolation"]);
});
