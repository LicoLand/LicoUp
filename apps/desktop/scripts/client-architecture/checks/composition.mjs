export async function checkConversationBridges(context) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
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
  const agentConversationGatewaySource = await readDartSourceByBasename(
    "agent_conversation_gateway.dart"
  );
  const agentWorkspaceCoordinatorSource = await readDartSourceByBasename(
    "agent_workspace_coordinator.dart"
  );
  const agentConversationControllerSource = await readJoinedText([
    "apps/desktop/lib/src/application/features/agents/conversation/agent_conversation_controller.dart",
    ...await collectSourceFiles(
      "apps/desktop/lib/src/application/features/agents/conversation",
      ".dart"
    )
  ]);
  const conversationContractSource = await readText(
    "apps/desktop/lib/src/contracts/generated/conversation.g.dart"
  );
  const agentConversationGatewayAdapterSource = await readDartSourceByBasename(
    "agent_conversation_gateway_adapter.dart"
  );
  assert(
    agentConversationGatewaySource.includes("abstract interface class AgentConversationGateway") &&
      agentConversationGatewaySource.includes("Stream<AgentDispatchEvent> sendStreaming") &&
      agentWorkspaceCoordinatorSource.includes("AgentConversationGateway get conversationGateway") &&
      agentConversationControllerSource.includes("abstract class AgentConversationController extends AgentWorkspaceCoordinator") &&
      agentConversationControllerSource.includes("conversationGateway.streamSessions(") &&
      agentConversationControllerSource.includes("conversationGateway.loadSessions(") &&
      agentConversationControllerSource.includes("conversationGateway.sendStreaming(") &&
      /implements\s+AgentConversationGateway\b/u.test(agentConversationGatewayAdapterSource) &&
      agentConversationGatewayAdapterSource.includes("service.sendStreaming("),
    "direct agent conversation state must depend on the gateway port through its composition adapter"
  );
  assert(
    conversationContractSource.includes("enum ConversationPrincipalKind") &&
      conversationContractSource.includes("enum ConversationMembershipAccess") &&
      conversationContractSource.includes("enum ConversationMembershipStatus") &&
      conversationContractSource.includes("enum ConversationTurnState") &&
      conversationContractSource.includes("conversation.message.post"),
    "direct and group collaboration must share the generated canonical Conversation contract"
  );
  assert(
    !await exists(
      "apps/desktop/lib/src/application/features/agents/orchestration"
    ) &&
      !await exists("apps/desktop/lib/src/contracts/agent_orchestration_target.dart"),
    "retired Flutter orchestration owners must stay removed"
  );
  for (const [relativePath, source] of [
    ["agent_conversation_gateway.dart", agentConversationGatewaySource],
    ["agent_workspace_coordinator.dart", agentWorkspaceCoordinatorSource],
    ["agent_conversation_controller.dart", agentConversationControllerSource],
    ["conversation.g.dart", conversationContractSource]
  ]) {
    assert(
      !source.includes("package:licoup/src/backend/") &&
        !source.includes("package:licoup/src/platform/"),
      `${relativePath} must not depend on backend implementations or unrelated platform services`
    );
  }
  assert(
    !agentConversationControllerSource.includes("appendLocalMessage") &&
      !agentConversationControllerSource.includes("sendRuntimeMessage"),
    "agent conversation controller must not bypass the native read-only history and unified dispatch boundaries"
  );
  const agentUsageGatewaySource = await readDartSourceByBasename(
    "agent_usage_gateway.dart"
  );
  const agentUsageControllerSource = await readDartSourceByBasename(
    "agent_usage_controller.dart"
  );
  const agentUsageGatewayAdapterSource = await readDartSourceByBasename(
    "agent_usage_gateway_adapter.dart"
  );
  assert(
    agentUsageGatewaySource.includes("abstract interface class AgentUsageGateway") &&
      agentUsageControllerSource.includes("final AgentUsageGateway gateway") &&
      agentUsageControllerSource.includes("final Set<Object> _pollingOwners") &&
      agentUsageControllerSource.includes("Future<void>? _scanFuture") &&
      agentUsageControllerSource.includes("].take(20)") &&
      agentUsageGatewayAdapterSource.includes("implements AgentUsageGateway") &&
      agentUsageGatewayAdapterSource.includes("service.scan(") &&
      agentUsageGatewayAdapterSource.includes("service.reports("),
    "agent usage must own bounded, lease-based single-flight state behind an application gateway port"
  );
  assert(
    !agentUsageControllerSource.includes("package:licoup/src/backend/") &&
      !agentUsageControllerSource.includes("package:licoup/src/platform/"),
    "agent usage controller must not depend on backend or platform implementations"
  );
  const agentConversationWorkspaceSource = await readJoinedText([
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_workspace.dart",
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_pane.dart",
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_pane/composition.dart",
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_message_view.dart"
  ]);
  const agentConversationComposerSource = await readDartSourceByBasename(
    "agent_conversation_composer.dart"
  );
  const agentConversationTimelineSource = await readJoinedText([
    "apps/desktop/lib/src/frontend/features/agents/ui/conversation_execution_entry.dart",
    "apps/desktop/lib/src/frontend/features/agents/ui/conversation_execution_binding_viewer.dart",
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_timeline.dart"
  ]);
  assert(
    agentConversationWorkspaceSource.includes("agent_conversation_pane/composition.dart") &&
      agentConversationWorkspaceSource.includes("ConversationExecutionScope(") &&
      agentConversationWorkspaceSource.includes("showBoundConversationExecution(") &&
      agentConversationWorkspaceSource.includes("RuntimeMessageComposer(") &&
      agentConversationWorkspaceSource.includes("buildConversationTimelineItems(") &&
      agentConversationWorkspaceSource.includes("PostConversationMessage(") &&
      agentConversationComposerSource.includes("class RuntimeMessageComposer") &&
      agentConversationComposerSource.includes("InputField(") &&
      agentConversationComposerSource.includes("widget.onSend(text)") &&
      agentConversationTimelineSource.includes("class ConversationExecutionMenu") &&
      agentConversationTimelineSource.includes("ProjectionSource<ConversationExecutionProjection>") &&
      agentConversationTimelineSource.includes("OpenConversationExecutionView(") &&
      agentConversationTimelineSource.includes("CloseConversationExecutionView(") &&
      agentConversationTimelineSource.includes("showConversationExecutionViewer(") &&
      agentConversationTimelineSource.includes("List<ConversationTimelineItem> buildConversationTimelineItems"),
    "agent conversation workspace must compose independently testable composer, timeline, and execution-projection UI components"
  );
  assert(
    agentConversationWorkspaceSource.includes("_ConversationDiagnosticsPanel") &&
      agentConversationWorkspaceSource.includes("_ConversationArtifactsPanel") &&
      !agentConversationWorkspaceSource.includes("CodexMessageBlock") &&
      !agentConversationWorkspaceSource.includes("ClaudeCodeMessageBlock"),
    "workspace must render shared semantic layers without per-provider UI forks"
  );
}

export async function checkClientRootAndShell(context, {
    agentConversationServiceSource,
  }) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
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
  const applicationSources = await readJoinedText(
    await collectSourceFiles("apps/desktop/lib/src/application", ".dart")
  );
    assert(applicationSources.includes("devicesController.loadNoticeAcknowledgement"),
      "core hydration must load the Devices legacy-pairing notice acknowledgement without authorizing secret access"
    );
  const devicesServiceSource = await readDartSourceByBasename("devices_service.dart");
  const clientLogExportServiceSource = await readDartSourceByBasename("client_log_export_service.dart");
  const clientShellSource = await readDartSourceByBasename("client_shell.dart");
  const semanticDestinationsSource = await readDartSourceByBasename("semantic_destination.dart");
  assert(clientLogExportServiceSource.includes("activityLogFile") &&
    clientLogExportServiceSource.includes("open(mode: FileMode.read)") &&
    clientLogExportServiceSource.includes("temporary.create(exclusive: true)") &&
    clientLogExportServiceSource.includes("temporary.rename(destination.path)"),
    "client_log_export_service.dart must export the portable activity log without rendering it as a standalone page"
  );
  assert(semanticDestinationsSource.includes("enum ClientSection") && [
    "agents",
    "monitoring",
    "skillHub",
    "pluginManagement",
    "devices",
    "models",
    "settings",
    "agentHub"
  ].every((destination) => semanticDestinationsSource.includes(destination)),
    "LicoUp client shell must expose only the current top-level section bodies"
  );
  for (const [relativePath, source] of [
    ["agent_conversation_service.dart", agentConversationServiceSource],
    ["devices_service.dart", devicesServiceSource]
  ]) {
    for (const token of ["HttpClient", "readAsString", "writeAsString", "Directory(", "File("]) {
      assert(!source.includes(token), `${relativePath} must not perform runtime IO/network directly; use licoup CLI`);
    }
  }

  const licoStringsBaseSource = await readDartSourceByBasename(
    "lico_strings_base.dart"
  );
  const licoStringsDevicesSource = await readDartSourceByBasename(
    "lico_strings_devices.dart"
  );
  for (const [getter, label, labelSource] of [
    ["agents", "Agents", licoStringsBaseSource],
    ["tokenUsage", "Token Usage", licoStringsBaseSource],
    ["skillHub", "Skill Hub", licoStringsBaseSource],
    ["agentHub", "Agent Hub", licoStringsBaseSource],
    ["devices", "Devices", licoStringsDevicesSource],
    ["settings", "Settings", licoStringsBaseSource]
  ]) {
    assert(
      labelSource.includes(`String get ${getter}`) &&
        labelSource.includes(`'${label}'`),
      `LicoStrings must expose the current module label through ${getter}`
    );
  }
  for (const getter of ["agents", "tokenUsage", "skillHub", "agentHub", "devices", "settings"]) {
    assert(
      clientShellSource.includes(`strings.${getter}`),
      `client shell must resolve destination labels through LicoStrings.${getter}`
    );
  }

}
