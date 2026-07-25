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
    sourceLineCount,
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
    "skill update",
    "skill delete",
    "skill usage"
  ]) {
    assert(cliSource.includes(token), `licoup usage must expose command: ${token}`);
  }
  assert(!cliSource.includes("agent message send"),
    "licoup usage must not expose the retired agent message send entry point");

  const reviewedRustUnsafeFiles = new Set([
    "crates/licoup-native/src/core/safe_archive.rs",
    "crates/licoup-native/src/ffi/android_ffi.rs",
    "crates/licoup-native/src/ffi/ios_ffi.rs",
    "crates/licoup-native/src/domain/collaboration_plugin/package/writer.rs",
    "crates/licoup-native/src/domain/collaboration_plugin/workflow/commit.rs",
    "crates/licoup-native/src/domain/collaboration_plugin/assembly/runtime/immutable_file.rs",
    "crates/licoup-native/src/domain/collaboration_plugin/assembly/runtime/process/unix.rs",
    "crates/licoup-native/src/domain/collaboration_plugin/assembly/runtime/process/windows.rs",
    "crates/licoup-native/src/platform/authorized_secure_record/macos_keychain.rs",
    "crates/licoup-native/src/platform/user_presence.rs",
    "crates/licoup-native/src/platform/secure_mesh_secret_store/macos_user_presence.rs",
    "crates/licoup-native/src/platform/antigravity_driver/tests.rs"
  ]);
  const rustCliUnsafeFiles = (await collectRustUnsafeFiles(rustCliRoot))
    .filter((relativePath) => !reviewedRustUnsafeFiles.has(relativePath));
  assert(
    rustCliUnsafeFiles.length === 0,
    `Rust CLI source path must not contain unreviewed unsafe: ${rustCliUnsafeFiles.join(", ")}`
  );

  for (const [relativePath, maxLines] of [
    ["crates/licoup-native/src/core/acp.rs", 60],
    ["crates/licoup-native/src/core/mcp.rs", 40],
    ["crates/licoup-native/src/core/secure_mesh_command.rs", 130],
    ["crates/licoup-native/src/core/secure_mesh_crypto.rs", 45],
    ["crates/licoup-native/src/core/secure_mesh_directory.rs", 75],
    ["crates/licoup-native/src/core/secure_mesh_file.rs", 70],
    ["crates/licoup-native/src/core/secure_mesh_mlkem_braid.rs", 50],
    ["crates/licoup-native/src/core/secure_mesh_mls.rs", 60],
    ["crates/licoup-native/src/core/secure_mesh_mls_product.rs", 80],
    ["crates/licoup-native/src/core/secure_mesh_pairwise.rs", 55],
    ["crates/licoup-native/src/core/secure_mesh_pairwise/persistence.rs", 45],
    ["crates/licoup-native/src/core/secure_mesh_approval.rs", 45],
    ["crates/licoup-native/src/core/secure_mesh_relay_envelope.rs", 45],
    ["crates/licoup-native/src/core/secure_mesh_trust.rs", 60],
    ["crates/licoup-native/src/platform/runtime_adapters.rs", 65],
    ["crates/licoup-native/src/platform/claude_code_driver.rs", 30],
    ["crates/licoup-native/src/platform/hermes_driver.rs", 30],
    ["crates/licoup-native/src/platform/openclaw_driver.rs", 30],
    ["crates/licoup-native/src/platform/opencode_driver.rs", 30],
    ["crates/licoup-native/src/platform/pi_driver.rs", 30],
    ["crates/licoup-native/src/domain/agent_usage.rs", 30],
    ["crates/licoup-native/src/domain/agent_usage/agent_usage_codex.rs", 35],
    ["crates/licoup-native/src/domain/conversations.rs", 50],
    ["crates/licoup-native/src/domain/conversation_archive_jobs.rs", 35],
    ["crates/licoup-native/src/domain/conversation_snapshots.rs", 70],
    ["crates/licoup-native/src/domain/client_update.rs", 45],
    ["crates/licoup-native/src/domain/client_update/macos_runner.rs", 45],
    ["crates/licoup-native/src/domain/mobile_relay.rs", 60],
    ["crates/licoup-native/src/domain/secure_mesh_mls.rs", 40],
    ["crates/licoup-native/src/domain/skill_hub.rs", 175],
    ["crates/licoup-native/src/domain/targets.rs", 70],
    ["crates/licoup-native/src/ffi/secure_mesh_mobile_ffi.rs", 45],
    ["crates/licoup-native/src/platform/secure_mesh_secret_store.rs", 50],
    ["crates/licoup-native/src/bin/licoup.rs", 80],
    ["crates/licoup-native/src/bin/licoup/stdio_rpc.rs", 40]
  ]) {
    const source = await readText(relativePath);
    assert(
      sourceLineCount(source) <= maxLines,
      `${relativePath} must remain a thin facade (${maxLines} lines maximum)`
    );
  }

  const stdioRpcFacade = await readText(
    "crates/licoup-native/src/bin/licoup/stdio_rpc.rs"
  );
  const stdioRpcLeaves = new Map([
    ["context.rs", 40],
    ["error.rs", 60],
    ["line.rs", 60],
    ["model.rs", 60],
    ["request.rs", 180],
    ["response.rs", 260],
    ["server.rs", 300]
  ]);
  for (const [leaf, maxLines] of stdioRpcLeaves) {
    const relativePath = `crates/licoup-native/src/bin/licoup/stdio_rpc/${leaf}`;
    const source = await readText(relativePath);
    assert(
      stdioRpcFacade.includes(`stdio_rpc/${leaf}`),
      `stdio RPC facade must mount ${leaf}`
    );
    assert(
      sourceLineCount(source) <= maxLines,
      `${relativePath} exceeds its stdio RPC responsibility limit (${maxLines} lines maximum)`
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
  const stdioRpcTestLeaves = new Map([
    ["error.rs", 40],
    ["line.rs", 40],
    ["request.rs", 100],
    ["response.rs", 100],
    ["server.rs", 150]
  ]);
  for (const [leaf, maxLines] of stdioRpcTestLeaves) {
    const relativePath = `crates/licoup-native/src/bin/licoup/tests/rpc/${leaf}`;
    const source = await readText(relativePath);
    assert(
      stdioRpcTestFacade.includes(`rpc/${leaf}`),
      `stdio RPC test facade must mount ${leaf}`
    );
    assert(
      sourceLineCount(source) <= maxLines,
      `${relativePath} exceeds its stdio RPC test responsibility limit (${maxLines} lines maximum)`
    );
  }
  assert(
    !stdioRpcTestFacade.includes("#[test]"),
    "stdio RPC test facade must remain composition-only"
  );

  return { reviewedRustUnsafeFiles };
}
