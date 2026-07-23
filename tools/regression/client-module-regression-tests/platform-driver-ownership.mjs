import {
  assert,
  path,
  process,
  test,
  CLIENT_MODULE_CATALOG,
  selectModulesForChangedPaths,
  main,
  ids,
  sourceFiles,
} from "./support.mjs";

test("layer, FFI, bridge, packaging, and release paths select dedicated modules", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/platform/native_client/orchestrator_ipc/client.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.orchestrator-projection",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/domain/mobile_relay/config.rs",
  ])), ["architecture.client-boundaries", "rust.domain.mobile-relay.configuration"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/domain/targets/binaries.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.targets.binaries",
    "rust.domain.targets.platform-integration",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/ffi/android_ffi.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.ffi.android-secret-store-tristate",
    "bridge.android",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/ffi/commands/mcp.rs",
  ])), ["architecture.client-boundaries", "bridge.native-mcp-command"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/mcp_streamable_http.rs",
  ])), ["architecture.client-boundaries", "rust.platform.mcp-streamable-http"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/mcp_approval_plan_store.rs",
  ])), ["architecture.client-boundaries", "rust.platform.mcp-approval-plan-store"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/orchestrator_ipc/client.rs",
  ])), ["regression.orchestrator-ipc", "architecture.client-boundaries"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "packages/contracts/client/lico-arc-orchestrator-ipc.schema.json",
  ])), ["regression.orchestrator-ipc"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/bin/lico-client.rs",
  ])), ["architecture.client-boundaries", "rust.bin.lico-client"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/bin/lico-client/stdio_rpc.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.bin.lico-client.rpc",
    "bridge.native-mcp-rpc-guard",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/bin/lico-client/stdio_rpc/request.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.bin.lico-client.rpc",
    "bridge.native-mcp-rpc-guard",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/bin/lico-client/tests/rpc/request.rs",
  ])), ["architecture.client-boundaries", "rust.bin.lico-client.rpc"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/bin/lico-client/tests/skill_commands.rs",
  ])), ["architecture.client-boundaries", "rust.bin.lico-client.skill-commands"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/ios/Runner/SecureMeshIosBridge.swift",
  ])), ["architecture.client-boundaries", "bridge.ios"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/scripts/build-android-apk.mjs",
  ])), ["packaging.android"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    ".github/workflows/client-release.yml",
  ])), ["release.workflows"]);
});

test("Android Secure Mesh leaves select boundary tests and Kotlin compile independently", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/android/app/src/main/kotlin/com/liko/arc/MainActivity.kt",
  ])), [
    "architecture.client-boundaries",
    "bridge.android.secure-mesh-boundaries",
    "bridge.android.kotlin-compile",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/android/app/src/test/kotlin/com/liko/arc/SecureMeshAndroidBridgeBoundaryTest.kt",
  ])), [
    "architecture.client-boundaries",
    "bridge.android.secure-mesh-boundaries",
  ]);
  for (const source of [
    "SecureMeshAndroidAtomicRecordWriter.kt",
    "SecureMeshAndroidNativeDispatchQueue.kt",
  ]) {
    assert.deepEqual(ids(selectModulesForChangedPaths([
      `apps/desktop/android/app/src/main/kotlin/com/liko/arc/${source}`,
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
    "com.liko.arc.SecureMeshAndroidBridgeBoundaryTest",
    "com.liko.arc.SecureMeshAndroidSecretStoreBoundaryTest",
    "com.liko.arc.SecureMeshAndroidSecretContractTest",
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
    "architecture.client-boundaries",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/acp.rs",
  ])), ["architecture.client-boundaries", "rust.core.acp.composition"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/acp/requests.rs",
  ])), ["architecture.client-boundaries", "rust.core.acp.requests"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/acp/responses.rs",
  ])), ["architecture.client-boundaries", "rust.core.acp.responses"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/acp/codec.rs",
  ])), ["architecture.client-boundaries", "rust.core.acp.codec"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/task_queue.rs",
  ])), ["architecture.client-boundaries", "rust.core.task-queue"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/authorized_secure_record.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.secret-custody-port",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/authorized_secure_record/ledger.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.secure-mesh-secret-store.authorization",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/user_presence.rs",
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
      `crates/lico-client-native/src/domain/collaboration_plugin/${source}`,
    ])), [
      "architecture.client-boundaries",
      "rust.domain.optional-collaboration",
    ]);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/domain/collaboration_plugin/workflow/mcp_transaction.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.optional-collaboration.workflow-operations.apply-mcp",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/mcp.rs",
  ])), ["architecture.client-boundaries", "rust.core.mcp.composition"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/mcp/wire.rs",
  ])), ["architecture.client-boundaries", "rust.core.mcp.wire"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/mcp/transfer.rs",
  ])), ["architecture.client-boundaries", "rust.core.mcp.transfer"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/safe_archive.rs",
  ])), ["architecture.client-boundaries", "rust.core.safe-archive"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/secure_mesh_pairwise.rs",
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
    "crates/lico-client-native/src/core/secure_mesh_pairwise/codec.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.pairwise-codec",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/secure_mesh_relay_envelope.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.relay-envelope.composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/secure_mesh_relay_envelope/mailbox/schedule.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.relay-envelope.schedule",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/secure_mesh_relay_envelope/private_header.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.relay-envelope.header",
    "rust.core.secure-mesh.relay-envelope.header-negatives",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/secure_mesh_command.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.command",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/secure_mesh_command/schema.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.command.schema",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/core/secure_mesh_directory/authority.rs",
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
  assert.deepEqual(stdioTransport.command.args.slice(-2), [
    "test/native_stdio_rpc_client_test.dart",
    "test/stdio_rpc_operation_queue_test.dart",
  ]);
  assert.deepEqual(stdioIntegration.command.args.slice(-2), ["--name", "RPC"]);
  assert.deepEqual(stdioSourceBundle.command.args, [
    "--test",
    "tests/contract/client/native-stdio-rpc-source-bundle.test.mjs",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.orchestrator-projection",
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
    "crates/lico-client-native/src/domain/conversation/history/cursor_openagent",
    ".rs",
  );
  for (const relativePath of [
    "crates/lico-client-native/src/domain/conversation/history/cursor_openagent.rs",
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
    "crates/lico-client-native/src/platform/acp_driver_runtime", ".rs");
  for (const relativePath of [
    "crates/lico-client-native/src/platform/acp_driver_runtime.rs",
    ...sources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `neutral ACP runtime source must have a precise regression owner: ${relativePath}`);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/acp_driver_runtime/session_plan.rs",
  ])), ["architecture.client-boundaries", "rust.platform.acp-runtime.continuity"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/acp_driver_runtime/params.rs",
  ])), ["architecture.client-boundaries", "rust.platform.acp-runtime.params"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/acp_driver_runtime/protocol.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.acp-runtime.interaction",
    "rust.platform.acp-runtime.protocol",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/acp_driver_runtime/stdio_transport.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.acp-runtime.stdio-transport",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/acp_session_transport/execution.rs",
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
    "crates/lico-client-native/src/platform/acp_session_transport.rs",
    ...await sourceFiles(
      "crates/lico-client-native/src/platform/acp_session_transport",
      ".rs",
    ),
  ]) {
    assert.equal(sessionInputs.has(relativePath), true,
      `neutral ACP session source must have a precise regression owner: ${relativePath}`);
  }
});

test("Kilo Code adapter leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.kilo-code-driver.composition",
      "platform::kilo_code_driver::tests::composition::"],
    ["rust.platform.kilo-code-driver.config",
      "platform::kilo_code_driver::tests::config::"],
    ["rust.platform.kilo-code-driver.execution",
      "platform::kilo_code_driver::tests::execution::"],
    ["rust.platform.kilo-code-driver.probe",
      "platform::kilo_code_driver::tests::probe::"],
    ["rust.platform.kilo-code-driver.projection",
      "platform::kilo_code_driver::tests::projection::"],
    ["rust.platform.kilo-code-driver.transport",
      "platform::kilo_code_driver::tests::transport::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.kilo-code-driver."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    assert.equal(CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id)
      .command.args.at(-1), filter);
  }
  const ownedInputs = new Set(modules.flatMap((module) => module.inputs));
  const sources = await sourceFiles(
    "crates/lico-client-native/src/platform/kilo_code_driver", ".rs");
  for (const relativePath of [
    "crates/lico-client-native/src/platform/kilo_code_driver.rs",
    ...sources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Kilo Code adapter source must have a precise regression owner: ${relativePath}`);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/kilo_code_driver/transport.rs",
  ])), ["architecture.client-boundaries", "rust.platform.kilo-code-driver.transport"]);
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
      "crates/lico-client-native/src/platform/runtime_adapters.rs"), false);
  }
});

test("Codex app-server leaves retain exact narrow regression ownership", async () => {
  const sourceBundleId = "regression.codex-app-server-source-bundle";
  const selections = new Map([
    ["config.rs", "rust.platform.codex-app-server.config"],
    ["protocol/session.rs", "rust.platform.codex-app-server.session"],
    ["protocol/events.rs", "rust.platform.codex-app-server.events"],
    ["protocol/control.rs", "rust.platform.codex-app-server.control"],
    ["io.rs", "rust.platform.codex-app-server.io"],
    ["launch.rs", "rust.platform.codex-app-server.launch"],
    ["supervision.rs", "rust.platform.codex-app-server.transport"],
    ["transport.rs", "rust.platform.codex-app-server.transport"],
  ]);
  for (const [leaf, moduleId] of selections) {
    assert.deepEqual(ids(selectModulesForChangedPaths([
      `crates/lico-client-native/src/platform/codex_app_server/${leaf}`,
    ])), [sourceBundleId, "architecture.client-boundaries", moduleId]);
  }

  const filters = new Map([
    ["rust.platform.codex-app-server", "platform::codex_app_server::tests::"],
    ["rust.platform.codex-app-server.config",
      "platform::codex_app_server::tests::config::"],
    ["rust.platform.codex-app-server.session",
      "platform::codex_app_server::tests::session::"],
    ["rust.platform.codex-app-server.events",
      "platform::codex_app_server::tests::events::"],
    ["rust.platform.codex-app-server.control",
      "platform::codex_app_server::tests::control::"],
    ["rust.platform.codex-app-server.io",
      "platform::codex_app_server::tests::io::"],
    ["rust.platform.codex-app-server.launch",
      "platform::codex_app_server::tests::launch::"],
    ["rust.platform.codex-app-server.transport",
      "platform::codex_app_server::tests::transport::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.codex-app-server"));
  assert.equal(modules.length, filters.size);
  for (const [moduleId, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === moduleId);
    assert.equal(module.command.args.at(-1), filter);
  }

  const ownedInputs = new Set(modules.flatMap((module) => module.inputs));
  const splitSources = await sourceFiles(
    "crates/lico-client-native/src/platform/codex_app_server",
    ".rs",
  );
  for (const relativePath of [
    "crates/lico-client-native/src/platform/codex_app_server.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Codex app-server source must have a precise regression owner: ${relativePath}`);
  }

  const sourceBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === sourceBundleId);
  assert.deepEqual(sourceBundle.command.args, [
    "--test",
    "tests/contract/client/codex-app-server-source-bundle.test.mjs",
  ]);
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
        "crates/lico-client-native/src/platform/local_service.rs"), false);
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
    "crates/lico-client-native/src/platform/local_service", ".rs");
  for (const relativePath of [
    "crates/lico-client-native/src/platform/local_service.rs",
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
    ["rust.platform.file-security.atomic-replace", "platform::file_security::tests::atomic_replace::"],
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
        "crates/lico-client-native/src/platform/file_security.rs"), false);
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
    "crates/lico-client-native/src/platform/file_security", ".rs");
  for (const relativePath of [
    "crates/lico-client-native/src/platform/file_security.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `file security source must have a precise regression owner: ${relativePath}`);
  }
});

test("client state leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.client-state.composition", "platform::client_state::tests::composition::"],
    ["rust.platform.client-state.policy", "platform::client_state::tests::policy::"],
    ["rust.platform.client-state.collections", "platform::client_state::tests::collections::"],
    ["rust.platform.client-state.activity", "platform::client_state::tests::activity::"],
    ["rust.platform.client-state.snapshots", "platform::client_state::tests::snapshots::"],
    ["rust.platform.client-state.redaction", "platform::client_state::tests::redaction::"],
    ["rust.platform.client-state.serialization", "platform::client_state::tests::serialization::"],
    ["rust.platform.client-state.paths", "platform::client_state::tests::paths::"],
    ["rust.platform.client-state.accessors", "platform::client_state::tests::accessors::"],
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
        "crates/lico-client-native/src/platform/client_state.rs"), false);
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
  const splitSources = await sourceFiles(
    "crates/lico-client-native/src/platform/client_state", ".rs");
  for (const relativePath of [
    "crates/lico-client-native/src/platform/client_state.rs",
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
    "crates/lico-client-native/src/platform/opencode_serve", ".rs");
  for (const relativePath of [
    "crates/lico-client-native/src/platform/opencode_serve.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `OpenCode serve source must have a precise regression owner: ${relativePath}`);
  }
});

test("Kilo Code serve leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.kilo-code-serve.composition", "platform::kilo_code_serve::tests::composition::"],
    ["rust.platform.kilo-code-serve.policy", "platform::kilo_code_serve::tests::policy::"],
    ["rust.platform.kilo-code-serve.events", "platform::kilo_code_serve::tests::events::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.kilo-code-serve."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
  }
  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.kilo-code-serve-source-bundle");
  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = await sourceFiles(
    "crates/lico-client-native/src/platform/kilo_code_serve", ".rs");
  for (const relativePath of [
    "crates/lico-client-native/src/platform/kilo_code_serve.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Kilo Code serve source must have a precise regression owner: ${relativePath}`);
  }
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
    "crates/lico-client-native/src/platform/openclaw_gateway", ".rs");
  for (const relativePath of [
    "crates/lico-client-native/src/platform/openclaw_gateway.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `OpenClaw Gateway source must have a precise regression owner: ${relativePath}`);
  }
});

test("Claude Code driver leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.claude-code-driver.composition",
      "platform::claude_code_driver::tests::composition::"],
    ["rust.platform.claude-code-driver.test-support",
      "platform::claude_code_driver::tests::"],
    ["rust.platform.claude-code-driver.model",
      "platform::claude_code_driver::tests::model::"],
    ["rust.platform.claude-code-driver.errors",
      "platform::claude_code_driver::tests::errors::"],
    ["rust.platform.claude-code-driver.params",
      "platform::claude_code_driver::tests::params::"],
    ["rust.platform.claude-code-driver.command",
      "platform::claude_code_driver::tests::command::"],
    ["rust.platform.claude-code-driver.events",
      "platform::claude_code_driver::tests::events::"],
    ["rust.platform.claude-code-driver.protocol",
      "platform::claude_code_driver::tests::protocol::"],
    ["rust.platform.claude-code-driver.io",
      "platform::claude_code_driver::tests::io::"],
    ["rust.platform.claude-code-driver.control",
      "platform::claude_code_driver::tests::control::"],
    ["rust.platform.claude-code-driver.transport",
      "platform::claude_code_driver::tests::transport::"],
    ["rust.platform.claude-code-driver.supervision",
      "platform::claude_code_driver::tests::supervision::"],
    ["rust.platform.claude-code-driver.probe",
      "platform::claude_code_driver::tests::probe::"],
    ["rust.platform.claude-code-driver.execution",
      "platform::claude_code_driver::tests::execution::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.claude-code-driver."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    if (!id.endsWith(".composition")) {
      assert.equal(module.inputs.includes(
        "crates/lico-client-native/src/platform/claude_code_driver.rs"), false);
    }
  }

  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.claude-code-driver-source-bundle");
  assert.deepEqual(sourceCheck.command.args,
    ["--test", "tests/contract/client/claude-code-driver-source-bundle.test.mjs"]);

  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = await sourceFiles(
    "crates/lico-client-native/src/platform/claude_code_driver",
    ".rs",
  );
  for (const relativePath of [
    "crates/lico-client-native/src/platform/claude_code_driver.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Claude Code driver source must have a precise regression owner: ${relativePath}`);
  }
});

test("OpenClaw driver leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.openclaw-driver.composition",
      "platform::openclaw_driver::tests::composition::"],
    ["rust.platform.openclaw-driver.test-support",
      "platform::openclaw_driver::tests::"],
    ["rust.platform.openclaw-driver.model",
      "platform::openclaw_driver::tests::model::"],
    ["rust.platform.openclaw-driver.errors",
      "platform::openclaw_driver::tests::errors::"],
    ["rust.platform.openclaw-driver.params",
      "platform::openclaw_driver::tests::params::"],
    ["rust.platform.openclaw-driver.codec",
      "platform::openclaw_driver::tests::codec::"],
    ["rust.platform.openclaw-driver.continuity",
      "platform::openclaw_driver::tests::continuity::"],
    ["rust.platform.openclaw-driver.events",
      "platform::openclaw_driver::tests::events::"],
    ["rust.platform.openclaw-driver.protocol",
      "platform::openclaw_driver::tests::protocol::"],
    ["rust.platform.openclaw-driver.interaction",
      "platform::openclaw_driver::tests::interaction::"],
    ["rust.platform.openclaw-driver.io",
      "platform::openclaw_driver::tests::io::"],
    ["rust.platform.openclaw-driver.supervision",
      "platform::openclaw_driver::tests::supervision::"],
    ["rust.platform.openclaw-driver.probe",
      "platform::openclaw_driver::tests::probe::"],
    ["rust.platform.openclaw-driver.execution",
      "platform::openclaw_driver::tests::execution::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.openclaw-driver."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    if (!id.endsWith(".composition")) {
      assert.equal(module.inputs.includes(
        "crates/lico-client-native/src/platform/openclaw_driver.rs"), false);
    }
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/openclaw_driver/params.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.openclaw-driver-source-bundle",
    "rust.platform.openclaw-driver.params",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/openclaw_driver/continuity.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.openclaw-driver-source-bundle",
    "rust.platform.openclaw-driver.continuity",
  ]);

  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.openclaw-driver-source-bundle");
  assert.deepEqual(sourceCheck.command.args,
    ["--test", "tests/contract/client/openclaw-driver-source-bundle.test.mjs"]);

  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = await sourceFiles(
    "crates/lico-client-native/src/platform/openclaw_driver",
    ".rs",
  );
  for (const relativePath of [
    "crates/lico-client-native/src/platform/openclaw_driver.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `OpenClaw driver source must have a precise regression owner: ${relativePath}`);
  }
});

test("Pi driver leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.pi-driver.composition",
      "platform::pi_driver::tests::composition::"],
    ["rust.platform.pi-driver.test-support",
      "platform::pi_driver::tests::"],
    ["rust.platform.pi-driver.model",
      "platform::pi_driver::tests::model::"],
    ["rust.platform.pi-driver.errors",
      "platform::pi_driver::tests::errors::"],
    ["rust.platform.pi-driver.params",
      "platform::pi_driver::tests::params::"],
    ["rust.platform.pi-driver.settings",
      "platform::pi_driver::tests::settings::"],
    ["rust.platform.pi-driver.protocol",
      "platform::pi_driver::tests::protocol::"],
    ["rust.platform.pi-driver.interaction",
      "platform::pi_driver::tests::interaction::"],
    ["rust.platform.pi-driver.events",
      "platform::pi_driver::tests::events::"],
    ["rust.platform.pi-driver.sessions",
      "platform::pi_driver::tests::sessions::"],
    ["rust.platform.pi-driver.io",
      "platform::pi_driver::tests::io::"],
    ["rust.platform.pi-driver.supervision",
      "platform::pi_driver::tests::supervision::"],
    ["rust.platform.pi-driver.probe",
      "platform::pi_driver::tests::probe::"],
    ["rust.platform.pi-driver.execution",
      "platform::pi_driver::tests::execution::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.pi-driver."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    if (!id.endsWith(".composition")) {
      assert.equal(module.inputs.includes(
        "crates/lico-client-native/src/platform/pi_driver.rs"), false);
    }
  }

  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.pi-driver-source-bundle");
  assert.deepEqual(sourceCheck.command.args,
    ["--test", "tests/contract/client/pi-driver-source-bundle.test.mjs"]);

  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = await sourceFiles(
    "crates/lico-client-native/src/platform/pi_driver",
    ".rs",
  );
  for (const relativePath of [
    "crates/lico-client-native/src/platform/pi_driver.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Pi driver source must have a precise regression owner: ${relativePath}`);
  }
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
        "crates/lico-client-native/src/platform/opencode_driver.rs"), false);
    }
  }

  const ownedInputs = new Set(modules.flatMap((module) => module.inputs));
  const splitSources = await sourceFiles(
    "crates/lico-client-native/src/platform/opencode_driver",
    ".rs",
  );
  for (const relativePath of [
    "crates/lico-client-native/src/platform/opencode_driver.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `OpenCode driver source must have a precise regression owner: ${relativePath}`);
  }
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/lico-client-native/src/platform/opencode_driver/continuity.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.opencode-driver.serve-transport",
  ]);
});

test("Hermes driver leaves retain exact tests and complete source ownership", async () => {
  const filters = new Map([
    ["rust.platform.hermes-driver.composition",
      "platform::hermes_driver::tests::composition::"],
    ["rust.platform.hermes-driver.test-support",
      "platform::hermes_driver::tests::"],
    ["rust.platform.hermes-driver.capabilities",
      "platform::hermes_driver::tests::capabilities::"],
    ["rust.platform.hermes-driver.command",
      "platform::hermes_driver::tests::command::"],
    ["rust.platform.hermes-driver.protocol",
      "platform::hermes_driver::tests::protocol::"],
    ["rust.platform.hermes-driver.events",
      "platform::hermes_driver::tests::events::"],
    ["rust.platform.hermes-driver.approval",
      "platform::hermes_driver::tests::approval::"],
    ["rust.platform.hermes-driver.process-io",
      "platform::hermes_driver::tests::process_io::"],
    ["rust.platform.hermes-driver.execution",
      "platform::hermes_driver::tests::execution::"],
    ["rust.platform.hermes-driver.continuity",
      "platform::hermes_driver::tests::continuity::"],
    ["rust.platform.hermes-driver.probe",
      "platform::hermes_driver::tests::probe::"],
    ["rust.platform.hermes-driver.error-normalization",
      "platform::hermes_driver::tests::errors::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.platform.hermes-driver."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    if (!id.endsWith(".composition")) {
      assert.equal(module.inputs.includes(
        "crates/lico-client-native/src/platform/hermes_driver.rs"), false);
    }
  }

  const ownedInputs = new Set(modules.flatMap((module) => module.inputs));
  const splitSources = await sourceFiles(
    "crates/lico-client-native/src/platform/hermes_driver",
    ".rs",
  );
  for (const relativePath of [
    "crates/lico-client-native/src/platform/hermes_driver.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Hermes driver source must have a precise regression owner: ${relativePath}`);
  }
});

test("native CLI modules retain exact binary-scoped command filters", () => {
  const filters = new Map([
    ["rust.bin.lico-client", "tests::"],
    ["rust.bin.lico-client.rpc", "tests::rpc::"],
    ["rust.bin.lico-client.core-commands", "tests::core_commands::"],
    ["rust.bin.lico-client.skill-commands", "tests::skill_commands::"],
    ["rust.bin.lico-client.conversation-commands", "tests::conversation_commands::"],
    ["rust.bin.lico-client.parsing", "tests::parsing::"],
  ]);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.deepEqual(module.command.args, [
      "test",
      "-p",
      "lico-client-native",
      "--bin",
      "lico-client",
      filter,
    ]);
    if (id !== "rust.bin.lico-client") {
      assert.equal(module.inputs.includes(
        "crates/lico-client-native/src/bin/lico-client.rs"), false);
    }
  }
});
