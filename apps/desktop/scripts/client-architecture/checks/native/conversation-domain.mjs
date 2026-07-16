export async function checkConversationDomain(context, { agentConversationServiceSource }) {
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
  const agentConversationCommandsRustSource = await readText(
    "crates/lico-client-native/src/ffi/commands/agent_conversation.rs"
  );
  assert(
    agentConversationCommandsRustSource.includes("dispatch_lane_operation(operation, &params)") &&
      !agentConversationCommandsRustSource.includes("handle_agent_message_send") &&
      !agentConversationCommandsRustSource.includes("runtime_adapters::send_message"),
    "native conversation CLI commands must enter the shared conversation lane without a legacy send bypass"
  );
  for (const token of ["appendLocalMessage", "deleteSession", "'append'", "'delete'"]) {
    assert(!agentConversationServiceSource.includes(token), `agent_conversation_service.dart must not expose LicoLite-local write path: ${token}`);
  }
  const conversationsRustSource = await readJoinedText([
    "crates/lico-client-native/src/domain/conversations.rs",
    ...await collectSourceFiles("crates/lico-client-native/src/domain/conversation/history", ".rs")
  ]);
  const conversationModuleRustSource = await readText(
    "crates/lico-client-native/src/domain/conversation/mod.rs"
  );
  const conversationSourceCatalogRustSource = await readText(
    "crates/lico-client-native/src/domain/conversation/source_catalog.rs"
  );
  assert(
    conversationModuleRustSource.includes("pub(crate) mod parameters;") &&
      conversationModuleRustSource.includes("pub(crate) mod paths;") &&
      conversationModuleRustSource.includes("pub(crate) mod source_catalog;") &&
      conversationsRustSource.includes("crate::domain::conversation::parameters") &&
      conversationsRustSource.includes("crate::domain::conversation::paths") &&
      conversationsRustSource.includes("crate::domain::conversation::source_catalog") &&
      conversationSourceCatalogRustSource.includes("enum HistoryAdapter") &&
      conversationSourceCatalogRustSource.includes("fn adapter_for_agent") &&
      conversationSourceCatalogRustSource.includes("fn history_roots"),
    "native conversation history must delegate parameters, paths, and adapter discovery to the conversation domain modules"
  );
  assert(
    conversationsRustSource.includes('"native-history"') &&
      conversationsRustSource.includes('"readOnly": true') &&
      conversationsRustSource.includes('"precise-adapter"') &&
      conversationsRustSource.includes("unsupported native history adapter") &&
      conversationsRustSource.includes("ValueRef::Blob") &&
      conversationsRustSource.includes("native agent history is read-only"),
    "native conversation history must remain a precise, read-only projection of native agent data"
  );
  const messageProjectionRoot =
    "crates/lico-client-native/src/domain/conversation/history/message_projection";
  const messageProjectionLeaves = [
    "antigravity.rs",
    "generated_context.rs",
    "json_extract.rs",
    "projection.rs",
    "semantic.rs",
    "structured_privacy.rs"
  ];
  const messageProjectionFacadeSource = await readText(`${messageProjectionRoot}.rs`);
  const messageProjectionSources = Object.fromEntries(await Promise.all(
    messageProjectionLeaves.map(async (leaf) => [
      leaf,
      await readText(`${messageProjectionRoot}/${leaf}`)
    ])
  ));
  assert(messageProjectionLeaves.every((leaf) =>
      messageProjectionFacadeSource.includes(`mod ${leaf.replace(".rs", "")};`)) &&
    messageProjectionFacadeSource.split(/\r?\n/u).length <= 40 &&
    messageProjectionLeaves.every((leaf) =>
      !messageProjectionSources[leaf].includes("use super::*")),
    "native message projection must use one thin root and six explicitly dependent leaves"
  );
  assert(messageProjectionSources["structured_privacy.rs"].includes("OnceLock<Regex>") &&
    messageProjectionSources["structured_privacy.rs"].includes("MAX_STRUCTURED_EVENT_TEXT_CHARS") &&
    messageProjectionSources["structured_privacy.rs"].includes("[local path hidden]") &&
    messageProjectionSources["generated_context.rs"].includes("generated_control_text") &&
    messageProjectionSources["antigravity.rs"].includes("extract_user_request") &&
    messageProjectionSources["json_extract.rs"].includes("MAX_TEXT_EXTRACTION_DEPTH") &&
    messageProjectionSources["semantic.rs"].includes("enum HistoryMessageKind") &&
    messageProjectionSources["projection.rs"].includes("SemanticLayer::Thread") &&
    messageProjectionSources["projection.rs"].includes("SemanticLayer::Execution"),
    "message projection leaves must retain bounded privacy, generated-context, Antigravity, JSON, semantic, and layer policies"
  );
  const cursorOpenAgentRoot =
    "crates/lico-client-native/src/domain/conversation/history/cursor_openagent";
  const cursorOpenAgentLeaves = [
    "codec.rs",
    "composition.rs",
    "cursor.rs",
    "cursor_projection.rs",
    "fallback.rs",
    "openagent.rs"
  ];
  const cursorOpenAgentFacadeSource = await readText(`${cursorOpenAgentRoot}.rs`);
  const cursorOpenAgentSources = Object.fromEntries(await Promise.all(
    cursorOpenAgentLeaves.map(async (leaf) => [
      leaf,
      await readText(`${cursorOpenAgentRoot}/${leaf}`)
    ])
  ));
  assert(cursorOpenAgentLeaves.every((leaf) =>
      cursorOpenAgentFacadeSource.includes(`mod ${leaf.replace(".rs", "")};`)) &&
    cursorOpenAgentFacadeSource.split(/\r?\n/u).length <= 25 &&
    !cursorOpenAgentFacadeSource.includes("use super::*") &&
    cursorOpenAgentLeaves.every((leaf) =>
      !cursorOpenAgentSources[leaf].includes("use super::*")),
    "native Cursor and OpenAgent SQLite parsing must use one thin root and six explicitly dependent leaves"
  );
  assert(
    cursorOpenAgentSources["codec.rs"].includes("SQLITE_OPEN_READ_ONLY") &&
      cursorOpenAgentSources["codec.rs"].includes("MAX_SQLITE_FIELDS_PER_ROW") &&
      cursorOpenAgentSources["codec.rs"].includes("MAX_SQLITE_VALUE_BYTES") &&
      cursorOpenAgentSources["codec.rs"].includes("MAX_SQLITE_ROW_BYTES") &&
      cursorOpenAgentSources["cursor.rs"].includes("parse_cursor_sqlite_sessions") &&
      cursorOpenAgentSources["cursor_projection.rs"].includes("selectedModels") &&
      cursorOpenAgentSources["openagent.rs"].includes("parse_openagent_sqlite_sessions") &&
      cursorOpenAgentSources["openagent.rs"].includes("openagent_usage_from_columns") &&
      cursorOpenAgentSources["fallback.rs"].includes("ARCHIVE_SQLITE_PAGE_ROWS") &&
      cursorOpenAgentSources["fallback.rs"].includes("MAX_SQLITE_ROWS_PER_TABLE"),
    "Cursor/OpenAgent leaves must retain read-only bounded codec, precise adapter parsing, usage projection, and paged generic fallback"
  );
  const sessionMergeRoot =
    "crates/lico-client-native/src/domain/conversation/history/session_merge";
  const sessionMergeLeaves = [
    "codex_lineage.rs",
    "composition.rs",
    "dedupe_paging.rs",
    "delegated_merge.rs",
    "model_names.rs",
    "session_index.rs",
    "stable_order.rs"
  ];
  const sessionMergeFacadeSource = await readText(`${sessionMergeRoot}.rs`);
  const sessionMergeSources = Object.fromEntries(await Promise.all(
    sessionMergeLeaves.map(async (leaf) => [
      leaf,
      await readText(`${sessionMergeRoot}/${leaf}`)
    ])
  ));
  assert(sessionMergeLeaves.every((leaf) =>
      sessionMergeFacadeSource.includes(`mod ${leaf.replace(".rs", "")};`)) &&
    sessionMergeFacadeSource.split(/\r?\n/u).length <= 30 &&
    !sessionMergeFacadeSource.includes("use super::*") &&
    sessionMergeLeaves.every((leaf) =>
      !sessionMergeSources[leaf].includes("use super::*")),
    "native session merge must use one thin root and seven explicitly dependent leaves"
  );
  assert(
    sessionMergeSources["codex_lineage.rs"].includes("codex_rollout_lineage_root") &&
      sessionMergeSources["codex_lineage.rs"].includes("codex_lineage_message_fingerprint") &&
      sessionMergeSources["delegated_merge.rs"].includes("remaining_children") &&
      sessionMergeSources["delegated_merge.rs"].includes("MAX_SUBAGENT_PREVIEW_CHARS") &&
      !sessionMergeSources["delegated_merge.rs"].includes("indexed_sessions.remove") &&
      sessionMergeSources["dedupe_paging.rs"].includes("paged_history_sessions") &&
      sessionMergeSources["model_names.rs"].includes("MAX_MODEL_DISCOVERY_DEPTH") &&
      sessionMergeSources["model_names.rs"].includes("MAX_MODEL_NAME_CHARS") &&
      sessionMergeSources["session_index.rs"].includes("parse_codex_session_index_titles") &&
      sessionMergeSources["stable_order.rs"].includes("sort_sessions_by_updated_at"),
    "session merge leaves must retain cycle-safe lineage, leaf-to-root delegation, bounded paging/model discovery, local index IO, and stable ordering"
  );
  const collaborationWorkflowOperationsRoot =
    "crates/lico-client-native/src/domain/collaboration_plugin/workflow/operations";
  const collaborationWorkflowOperationLeaves = [
    "apply_local.rs",
    "apply_mcp.rs",
    "cancel.rs",
    "destination_policy.rs",
    "package_revalidation.rs",
    "plan_local.rs",
    "plan_mcp.rs",
    "projection.rs",
    "staging.rs",
    "validation.rs"
  ];
  const collaborationWorkflowOperationsFacadeSource = await readText(
    `${collaborationWorkflowOperationsRoot}.rs`
  );
  const collaborationWorkflowOperationSources = Object.fromEntries(await Promise.all(
    collaborationWorkflowOperationLeaves.map(async (leaf) => [
      leaf,
      await readText(`${collaborationWorkflowOperationsRoot}/${leaf}`)
    ])
  ));
  assert(collaborationWorkflowOperationLeaves.every((leaf) =>
      collaborationWorkflowOperationsFacadeSource.includes(
        `mod ${leaf.replace(".rs", "")};`
      )) &&
    collaborationWorkflowOperationsFacadeSource.split(/\r?\n/u).length <= 25 &&
    !collaborationWorkflowOperationsFacadeSource.includes("use super::*") &&
    collaborationWorkflowOperationLeaves.every((leaf) =>
      !collaborationWorkflowOperationSources[leaf].includes("use super::*")),
    "optional collaboration workflow operations must use one thin root and ten explicitly dependent leaves"
  );
  assert(
    collaborationWorkflowOperationSources["validation.rs"].includes("requestOrigin") &&
      collaborationWorkflowOperationSources["validation.rs"].includes("validate_expected_digests") &&
      collaborationWorkflowOperationSources["destination_policy.rs"].includes("open_directory_path_no_follow") &&
      collaborationWorkflowOperationSources["destination_policy.rs"].includes("validate_export_destination") &&
      collaborationWorkflowOperationSources["package_revalidation.rs"].includes("planned_payload(&payload)? == record.payload_files") &&
      collaborationWorkflowOperationSources["staging.rs"].includes("stage_private_registration") &&
      collaborationWorkflowOperationSources["staging.rs"].includes("collaboration_mcp_registration_digest_mismatch") &&
      collaborationWorkflowOperationSources["staging.rs"].includes("cleanup_staged") &&
      collaborationWorkflowOperationSources["apply_local.rs"].includes("validate_apply_binding") &&
      collaborationWorkflowOperationSources["apply_mcp.rs"].includes("revalidate_payload") &&
      collaborationWorkflowOperationSources["cancel.rs"].includes("validate_expected_digests"),
    "collaboration workflow leaves must retain explicit approval, digest binding, no-follow destinations, package revalidation, and rollback cleanup"
  );
  const conversationSemanticRoot =
    "crates/lico-client-native/src/domain/conversation_semantic";
  const conversationSemanticLeaves = [
    "artifact_projection.rs",
    "builder.rs",
    "execution_projection.rs",
    "io.rs",
    "markdown.rs",
    "model.rs",
    "privacy.rs",
    "thread_projection.rs",
    "validation.rs"
  ];
  const conversationSemanticFacadeSource = await readText(
    `${conversationSemanticRoot}.rs`
  );
  const conversationSemanticSources = Object.fromEntries(await Promise.all(
    conversationSemanticLeaves.map(async (leaf) => [
      leaf,
      await readText(`${conversationSemanticRoot}/${leaf}`)
    ])
  ));
  assert(conversationSemanticLeaves.every((leaf) =>
      conversationSemanticFacadeSource.includes(`mod ${leaf.replace(".rs", "")};`)) &&
    conversationSemanticFacadeSource.split(/\r?\n/u).length <= 45 &&
    conversationSemanticLeaves.every((leaf) =>
      !conversationSemanticSources[leaf].includes("use super::*")),
    "native semantic conversation must use one thin root and nine explicitly dependent leaves"
  );
  assert(
    conversationSemanticSources["model.rs"].includes("semantic-conversation") &&
      conversationSemanticSources["builder.rs"].includes("privacy_defaults") &&
      conversationSemanticSources["builder.rs"].includes("build_semantic_conversation") &&
      conversationSemanticSources["builder.rs"].includes("timeline_messages_from_semantic") &&
      conversationSemanticSources["validation.rs"].includes("validate_semantic_conversation") &&
      conversationSemanticSources["privacy.rs"].includes("assert_no_default_view_leakage") &&
      conversationSemanticSources["thread_projection.rs"].includes("thread_wire_message_from_tagged") &&
      conversationSemanticSources["execution_projection.rs"].includes("execution_wire_message_from_tagged") &&
      conversationSemanticSources["artifact_projection.rs"].includes("artifact_from_message") &&
      conversationSemanticSources["markdown.rs"].includes("render_semantic_markdown") &&
      conversationSemanticSources["io.rs"].includes("materialize_semantic_documents") &&
      conversationSemanticSources["io.rs"].includes("load_and_validate_fixture"),
    "semantic conversation leaves must retain separate model, assembly, projection, privacy, validation, rendering, and IO authorities"
  );
  assert(
    conversationsRustSource.includes("conversation_semantic::build_semantic_conversation") &&
      conversationsRustSource.includes("\"semantic\": semantic"),
    "conversations.rs must emit semantic documents as the session authority"
  );
  await readText("packages/contracts/client/semantic-conversation.schema.json");
  const agentConversationModelsSource = await readJoinedText([
    "apps/desktop/lib/src/contracts/agent_conversation_models.dart",
    "apps/desktop/lib/src/contracts/agent_conversation_message.dart",
    "apps/desktop/lib/src/contracts/agent_conversation_message_parser.dart",
    "apps/desktop/lib/src/contracts/agent_conversation_semantic.dart",
    "apps/desktop/lib/src/contracts/agent_conversation_session.dart"
  ]);
  assert(
    agentConversationModelsSource.includes("AgentSemanticConversation") &&
      agentConversationModelsSource.includes("AgentConversationSemanticLayer") &&
      agentConversationModelsSource.includes("threadMessages") &&
      agentConversationModelsSource.includes("executionMessages") &&
      agentConversationModelsSource.includes("hasDiagnostics"),
    "Flutter conversation models must preserve semantic layers without flattening authority"
  );
  return { conversationSourceCatalogRustSource };
}
