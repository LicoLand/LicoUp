import path from "node:path";

const rustCliRoot = "crates/licoup-native/src";
const rustNativePublicModules = ["core", "domain", "ffi", "platform"];
const rustNativePhysicalModuleDirs = [
  "crates/licoup-native/src/core",
  "crates/licoup-native/src/domain",
  "crates/licoup-native/src/ffi",
  "crates/licoup-native/src/platform"
];

export async function checkCrateCoreAndFacadeBounds(context) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
  } = context;
  const libRs = await readText("crates/licoup-native/src/lib.rs");
  const publicRustModules = collectRustPubMods(libRs);
  assert(
    sameSet(publicRustModules, rustNativePublicModules),
    `client native crate must publicly expose only ${rustNativePublicModules.join(", ")}`
  );
  assert(!libRs.includes("#[path ="), "client native lib.rs must use physical module directories, not #[path] remounts");
  for (const relativePath of rustNativePhysicalModuleDirs) {
    assert(await exists(relativePath), `${relativePath} must exist as a physical native module directory`);
    const modSource = await readText(`${relativePath}/mod.rs`);
    assert(!modSource.includes("#[path ="), `${relativePath}/mod.rs must not remount flat native files with #[path]`);
  }
  const coreModuleSource = await readText("crates/licoup-native/src/core/mod.rs");
  const taskQueueSource = await readText("crates/licoup-native/src/core/task_queue.rs");
  const mcpAdapterSource = await readJoinedText([
    "crates/licoup-native/src/core/mcp.rs",
    ...await collectSourceFiles("crates/licoup-native/src/core/mcp", ".rs")
  ]);
  const mcpProductionSource = await readJoinedText([
    "crates/licoup-native/src/domain/mcp_adapter.rs",
    ...await collectSourceFiles("crates/licoup-native/src/domain/mcp_adapter", ".rs"),
    "crates/licoup-native/src/platform/mcp_approval_plan_store.rs",
    "crates/licoup-native/src/platform/mcp_streamable_http.rs",
    "crates/licoup-native/src/ffi/commands/mcp.rs",
    "apps/desktop/lib/src/contracts/mcp_adapter.dart",
    "apps/desktop/lib/src/platform/native_client/native_mcp_actions.dart",
    "apps/desktop/lib/src/application/features/mcp/controller/mcp_transfer_controller.dart"
  ]);
  const acpAdapterSource = await readText("crates/licoup-native/src/core/acp.rs");
  const secureMeshCoreFiles = (await collectSourceFiles(
    "crates/licoup-native/src/core",
    ".rs"
  )).filter((relativePath) =>
    relativePath.includes("secure_mesh") &&
    !relativePath.includes("/tests/")
  );
  for (const relativePath of secureMeshCoreFiles) {
    const source = await readText(relativePath);
    assert(
      !source.includes("crate::platform::") && !source.includes("crate::domain::"),
      `${relativePath} must depend on core ports instead of domain or platform implementations`
    );
  }
  const secureMeshCustodyPortSource = await readJoinedText([
    "crates/licoup-native/src/core/secure_mesh_secret_store.rs",
    ...await collectSourceFiles(
      "crates/licoup-native/src/core/secure_mesh_secret_store",
      ".rs"
    )
  ]);
  const secureMeshRuntimeCompositionSource = await readJoinedText([
    "crates/licoup-native/src/core/secure_mesh_command/runtime.rs",
    "crates/licoup-native/src/domain/secure_mesh_command_runtime.rs",
    "crates/licoup-native/src/platform/secure_mesh_mls_store.rs"
  ]);
  assert(
    secureMeshCustodyPortSource.includes("trait SecureMeshSecretStore") &&
      secureMeshCustodyPortSource.includes("begin_authorized_session") &&
      secureMeshCustodyPortSource.includes("shared_system_context_required") &&
      secureMeshRuntimeCompositionSource.includes("SecureCommandRuntimeExecutor") &&
      secureMeshRuntimeCompositionSource.includes("open_with_path_hardener"),
    "Secure Mesh core ports and outer runtime/path-hardening composition must remain explicit"
  );
  const transparencySchemaSource = await readText(
    "crates/licoup-native/src/core/secure_mesh_transparency/persistence/schema.rs"
  );
  const secureMeshStatusSource = await readText(
    "crates/licoup-native/src/core/secure_mesh.rs"
  );
  assert(
    !transparencySchemaSource.includes("migrate_gossip_observation_binding") &&
      !secureMeshStatusSource.includes("mlsLegacySessionMigration"),
    "Secure Mesh must initialize current state or require reset without retaining runtime migrations"
  );
  assert(
    coreModuleSource.includes("pub mod task_queue;") &&
      taskQueueSource.includes("sync_channel") &&
      taskQueueSource.includes("try_submit") &&
      taskQueueSource.includes("bounded_queue_preserves_fifo_and_reports_depth"),
    "Rust core must expose a bounded, backpressured, independently tested local task queue"
  );
  assert(
    coreModuleSource.includes("pub mod mcp;") &&
      mcpAdapterSource.includes('PROTOCOL_REVISION: &str = "2025-11-25"') &&
      mcpAdapterSource.includes("mcp_batch_unsupported") &&
      mcpAdapterSource.includes("record_direct_user_approval") &&
      mcpAdapterSource.includes("send_request_once") &&
      mcpAdapterSource.includes("forward_response_once"),
    "Rust core must expose a service-neutral MCP adapter with digest-bound one-shot request/response transfer approval"
  );
  for (const token of [
    "McpApprovalPlanStore",
    "execute_http_transfer",
    "PrivateMcpApprovalPlanStore",
    "mcp-protocol-version",
    "application/json, text/event-stream",
    "preview_http_transfer",
    "handle_execute",
    "runCliWithStdin",
    "requiresDirectUserConfirmation",
    "McpTransferController"
  ]) {
    assert(
      mcpProductionSource.includes(token),
      `MCP production transfer closure must preserve token ${token}`
    );
  }
  assert(
    coreModuleSource.includes("pub mod acp;") &&
      acpAdapterSource.includes("PROTOCOL_VERSION") &&
      acpAdapterSource.includes("initialize_request") &&
      acpAdapterSource.includes("session_request") &&
      acpAdapterSource.includes("text_prompt_request") &&
      acpAdapterSource.includes("validate_initialize_response") &&
      acpAdapterSource.includes("validate_session_response") &&
      acpAdapterSource.includes("validate_prompt_response"),
    "Rust core must expose a bounded service-neutral ACP handshake, session, prompt, and response-validation adapter"
  );
  for (const platformRoot of ["macos", "windows", "linux", "android", "ios"]) {
    assert(
      await exists(`apps/desktop/${platformRoot}`),
      `Flutter client must keep an explicit ${platformRoot} platform adapter root`
    );
  }
  const cliSource = await readJoinedText([
    "crates/licoup-native/src/bin/licoup.rs",
    "crates/licoup-native/src/bin/licoup/presentation.rs"
  ]);
  for (const token of [
    "targets scan",
    "agents pair",
    "conversations list|append|delete",
    "agent conversation open|send|steer|cancel|cleanup|capabilities|stream",
    "mcp http preview|execute",
    "mobile relay",
    "skill list",
    "skill delete",
    "skill usage"
  ]) {
    assert(cliSource.includes(token), `licoup usage must expose command: ${token}`);
  }
  assert(!cliSource.includes("agent message send"),
    "licoup usage must not expose the retired agent message send entry point");
  assert(!cliSource.includes("skill update"),
    "licoup usage must not expose the retired skill update entry point");

  const reviewedRustUnsafeResponsibilities = new Map([
    ["crates/licoup-native/src/core/safe_archive.rs", "bounded archive FFI"],
    ["crates/licoup-native/src/ffi/android_ffi.rs", "Android ABI boundary"],
    ["crates/licoup-native/src/ffi/ios_ffi.rs", "iOS ABI boundary"],
    ["crates/licoup-native/src/domain/collaboration_plugin/package/writer.rs", "atomic package filesystem ownership"],
    ["crates/licoup-native/src/domain/collaboration_plugin/workflow/commit.rs", "atomic workflow filesystem ownership"],
    ["crates/licoup-native/src/domain/collaboration_plugin/assembly/runtime/immutable_file.rs", "immutable runtime file flags"],
    ["crates/licoup-native/src/domain/collaboration_plugin/assembly/runtime/process/unix.rs", "Unix child process identity"],
    ["crates/licoup-native/src/domain/collaboration_plugin/assembly/runtime/process/windows.rs", "Windows child process identity"],
    ["crates/licoup-native/src/domain/agent_resource_usage/process_snapshot.rs", "platform process metrics"],
    ["crates/licoup-native/src/domain/client_update/native_runner/plan.rs", "parent process identity and Windows process enumeration"],
    ["crates/licoup-native/src/domain/targets/model_catalog/tests.rs", "isolated process environment fixtures"],
    ["crates/licoup-native/src/bin/lico-gateway.rs", "inherited readiness file descriptor"],
    ["crates/licoup-native/src/bin/lico-llm-gateway.rs", "inherited readiness file descriptor"],
    ["crates/licoup-native/src/platform/authorized_secure_record/macos_keychain.rs", "macOS Keychain FFI"],
    ["crates/licoup-native/src/platform/user_presence.rs", "platform presence authorization"],
    ["crates/licoup-native/src/platform/secure_mesh_secret_store/macos_user_presence.rs", "macOS presence authorization"],
    ["crates/licoup-native/src/platform/antigravity_driver/tests.rs", "isolated process environment fixture"],
    ["crates/licoup-native/src/platform/client_autostart.rs", "launchd user identity"],
    ["crates/licoup-native/src/platform/cursor_driver/tests.rs", "isolated process environment fixtures"],
    ["crates/licoup-native/src/platform/gateway_runtime/channels/telegram/credentials.rs", "isolated credential environment fixture"],
    ["crates/licoup-native/src/platform/lico_agent_driver/tests.rs", "isolated process environment fixtures"],
    ["crates/licoup-native/src/platform/llm_gateway_autostart.rs", "launchd user identity"],
    ["crates/licoup-native/src/platform/llm_gateway_credentials_control.rs", "Unix peer credential verification"],
    ["crates/licoup-native/src/platform/llm_gateway_inventory_control.rs", "Unix peer credential verification"],
    ["crates/licoup-native/src/platform/llm_gateway_service.rs", "bounded sidecar pipe and process lifecycle"],
    ["crates/licoup-native/src/platform/pty_transport.rs", "PTY descriptor and ioctl ownership"],
  ]);
  const reviewedRustUnsafeFiles = new Set(reviewedRustUnsafeResponsibilities.keys());
  assert([...reviewedRustUnsafeResponsibilities.values()].every((value) => value.length > 0),
    "every reviewed unsafe owner must retain one explicit responsibility");
  const rustCliUnsafeFiles = (await collectRustUnsafeFiles(rustCliRoot))
    .filter((relativePath) => !reviewedRustUnsafeFiles.has(relativePath));
  assert(
    rustCliUnsafeFiles.length === 0,
    `Rust CLI source path must not contain unreviewed unsafe: ${rustCliUnsafeFiles.join(", ")}`
  );


  const stdioRpcFacade = await readText(
    "crates/licoup-native/src/bin/licoup/stdio_rpc.rs"
  );
  const stdioRpcLeaves = [
    "context.rs",
    "error.rs",
    "line.rs",
    "model.rs",
    "request.rs",
    "response.rs",
    "server.rs",
  ];
  for (const leaf of stdioRpcLeaves) {
    const relativePath = `crates/licoup-native/src/bin/licoup/stdio_rpc/${leaf}`;
    await readText(relativePath);
    assert(
      stdioRpcFacade.includes(`stdio_rpc/${leaf}`),
      `stdio RPC facade must mount ${leaf}`
    );
  }
  assert(
    !stdioRpcFacade.includes("fn "),
    "stdio RPC facade must remain composition-only"
  );
  const stdioRpcRequest = await readText(
    "crates/licoup-native/src/bin/licoup/stdio_rpc/request.rs"
  );
  assert(
    stdioRpcRequest.includes("parse_stdio_rpc_request") &&
      !stdioRpcRequest.includes("write_all") &&
      !stdioRpcRequest.includes("dispatch_lane_operation"),
    "stdio RPC request leaf must own decoding without response IO or command dispatch"
  );
  const stdioRpcResponse = await readText(
    "crates/licoup-native/src/bin/licoup/stdio_rpc/response.rs"
  );
  assert(
    stdioRpcResponse.includes("try_write_stdio_rpc_response") &&
      !stdioRpcResponse.includes("serde_json::from_slice") &&
      !stdioRpcResponse.includes("execute_cli"),
    "stdio RPC response leaf must own bounded encoding without request decoding or CLI execution"
  );
  const stdioRpcServer = await readText(
    "crates/licoup-native/src/bin/licoup/stdio_rpc/server.rs"
  );
  assert(
    stdioRpcServer.includes("serve_stdio_rpc") &&
      !stdioRpcServer.includes("serde_json::from_slice"),
    "stdio RPC server leaf must coordinate parsed requests without owning wire decoding"
  );

  const stdioRpcTestFacade = await readText(
    "crates/licoup-native/src/bin/licoup/tests/rpc.rs"
  );
  const stdioRpcTestLeaves = [
    "error.rs",
    "line.rs",
    "request.rs",
    "response.rs",
    "server.rs",
  ];
  for (const leaf of stdioRpcTestLeaves) {
    const relativePath = `crates/licoup-native/src/bin/licoup/tests/rpc/${leaf}`;
    await readText(relativePath);
    assert(
      stdioRpcTestFacade.includes(`rpc/${leaf}`),
      `stdio RPC test facade must mount ${leaf}`
    );
  }
  assert(
    !stdioRpcTestFacade.includes("#[test]"),
    "stdio RPC test facade must remain composition-only"
  );

  return { reviewedRustUnsafeFiles };
}
