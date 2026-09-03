export async function checkConversationBridges(context, { packagedTargets, conversationSourceCatalogRustSource }) {
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
  const driverInventory = await readJson(
    "crates/licoup-native/resources/agent-conversation-drivers.json"
  );
  const driverProfiles = new Map(
    (driverInventory.drivers || []).map((driver) => [driver.agentId, driver])
  );
  for (const target of packagedTargets) {
    const driver = driverProfiles.get(target);
    assert(driver, `packaged target must have a conversation driver profile: ${target}`);
    assert(typeof driver?.historyReadable === "boolean",
      `conversation driver must declare history readability: ${target}`);
    assert(
      conversationSourceCatalogRustSource.includes(`"${target}"`) === driver?.historyReadable,
      `native history adapter availability must match the conversation driver profile: ${target}`
    );
  }
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
      agentConversationGatewayAdapterSource.includes("implements AgentConversationGateway") &&
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
  const agentConversationEventCardSource = await readJoinedText([
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_process_card.dart",
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_process_operations.dart",
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_process_projection.dart",
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_timeline.dart",
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_truncation_notice.dart"
  ]);
  assert(
    agentConversationWorkspaceSource.includes("agent_conversation_composer.dart") &&
      agentConversationWorkspaceSource.includes("agent_conversation_event_card.dart") &&
      agentConversationWorkspaceSource.includes("RuntimeMessageComposer(") &&
      agentConversationWorkspaceSource.includes("buildConversationTimelineItems(") &&
      agentConversationWorkspaceSource.includes("sendConversationMessage") &&
      agentConversationComposerSource.includes("class RuntimeMessageComposer") &&
      agentConversationComposerSource.includes("TextField(") &&
      agentConversationComposerSource.includes("widget.onSend(text)") &&
      agentConversationEventCardSource.includes("class ConversationProcessCard") &&
      agentConversationEventCardSource.includes("List<ConversationTimelineItem> buildConversationTimelineItems"),
    "agent conversation workspace must compose independently testable composer and timeline-event UI components"
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
    mobileRelayClientAdapterSource,
    mobileRelayPanelFacadeSource,
    mobileRelayPanelSources,
    mobileRelayServiceSource,
    secureMeshControllerSource,
  }) {
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
  const clientControllerFacadeSource = await readText(
    "apps/desktop/lib/src/application/controller/client_controller.dart"
  );
  const clientComponentAssemblySource = await readText(
    "apps/desktop/lib/src/application/controller/client_component_assembly.dart"
  );
  const clientComponentAssemblyLeafSources = await Promise.all([
    "client_presentation_component_assembly.dart",
    "client_lifecycle_component_assembly.dart",
    "client_conversation_component_assembly.dart",
    "client_target_component_assembly.dart",
    "client_skill_component_assembly.dart",
    "client_settings_component_assembly.dart",
    "client_mobile_component_assembly.dart",
    "client_usage_component_assembly.dart",
    "client_navigation_component_assembly.dart",
  ].map((name) => readText(
    `apps/desktop/lib/src/application/controller/assembly/${name}`
  )));
  const clientControllerRuntimeFacadeSources = await Promise.all([
    "client_conversation_facade.dart",
    "client_presentation_facade.dart",
    "client_routing_facade.dart",
    "client_navigation_facade.dart",
    "client_lifecycle_facade.dart",
  ].map((name) => readText(
    `apps/desktop/lib/src/application/controller/${name}`
  )));
  const clientControllerSource = [
    clientControllerFacadeSource,
    clientComponentAssemblySource,
    ...clientComponentAssemblyLeafSources,
    ...clientControllerRuntimeFacadeSources,
    await readText(
      "apps/desktop/lib/src/application/controller/client_mobile_relay_facade.dart"
    )
  ].join("\n");
  const clientLifecycleControllerSource = await readDartSourceByBasename(
    "client_lifecycle_coordinator.dart"
  );
  const clientShellControllerSource = await readDartSourceByBasename(
    "client_shell_controller.dart"
  );
  const clientNavigationControllerSource = await readDartSourceByBasename(
    "client_navigation_controller.dart"
  );
  const clientRoutingFacadeSource = await readText(
    "apps/desktop/lib/src/application/controller/client_routing_facade.dart"
  );
  const conversationPresentationSignalsSource = await readDartSourceByBasename(
    "conversation_presentation_signals.dart"
  );
  assert(
    clientLifecycleControllerSource.includes("final class ClientLifecycleCoordinator") &&
      clientLifecycleControllerSource.includes("Future<void>? _initializeFuture") &&
      clientLifecycleControllerSource.includes("await Future.wait<void>") &&
      clientShellControllerSource.includes("final class ClientShellController") &&
      clientShellControllerSource.includes("ValueNotifier<int> _presentationRevision") &&
      clientNavigationControllerSource.includes("final class ClientNavigationController") &&
      clientNavigationControllerSource.includes("final Map<ClientSection, ClientSectionHooks> _hooks") &&
      conversationPresentationSignalsSource.includes("ValueNotifier<int> _structureRevision") &&
      conversationPresentationSignalsSource.includes("ValueNotifier<int> _activeRevision"),
    "root presentation, lifecycle, navigation, and conversation signals must have independent state owners"
  );
  assert(
    clientControllerSource.includes("shellController = ClientShellController()") &&
      clientControllerSource.includes("controller = ClientLifecycleCoordinator(") &&
      clientControllerSource.includes("controller = ClientNavigationController(") &&
      clientControllerSource.includes("Future<void> initialize() => initializeWithOptions()") &&
      clientControllerSource.includes("initializeWithOptions({bool runBackgroundSteps = true})") &&
      clientControllerSource.includes("lifecycleController.initialize(") &&
      clientControllerSource.includes("navigationController.select(section)") &&
      clientControllerSource.includes("shellController.presentationListenable") &&
      clientRoutingFacadeSource.includes("AgentService get agentService;") &&
      !clientRoutingFacadeSource.includes("orchestrator"),
    "ClientController must remain a composition facade that delegates root state to focused controllers"
  );
  assert(
  clientControllerFacadeSource.includes("ClientComponentAssembly(") &&
        !clientControllerFacadeSource.includes("TargetController(") &&
        !clientControllerFacadeSource.includes("SecureMeshController(") &&
        !clientControllerFacadeSource.includes("ClientNavigationController(") &&
        !clientComponentAssemblySource.includes("client_controller.dart") &&
        clientComponentAssemblySource.includes("ClientMobileComponentAssembly(") &&
        clientComponentAssemblySource.includes("ClientSettingsComponentAssembly(") &&
        clientComponentAssemblyLeafSources.every((source) =>
          !source.includes("client_controller.dart") &&
          !/^part(?: of)? /m.test(source)
        ) &&
        !/^part(?: of)? /m.test(clientComponentAssemblySource),
      "ClientController construction must remain delegated to the bounded, ordinary-import ClientComponentAssembly"
    );
    for (const [relativePath, source] of [
      ["client_lifecycle_coordinator.dart", clientLifecycleControllerSource],
      ["client_shell_controller.dart", clientShellControllerSource],
      ["client_navigation_controller.dart", clientNavigationControllerSource],
      ["conversation_presentation_signals.dart", conversationPresentationSignalsSource]
    ]) {
      assert(
        !source.includes("package:licoup/src/backend/") &&
          !source.includes("package:licoup/src/platform/") &&
          !source.includes("package:licoup/src/frontend/"),
        `${relativePath} must stay independent of backend, platform, and frontend implementations`
      );
    }
    const initializeCoreStart = clientControllerSource.indexOf(
      "Future<void> _initializeClientCore() async {"
    );
    const initializeCoreEnd = clientControllerSource.indexOf(
      "Future<void> _finalizeClientInitialization()",
      initializeCoreStart
    );
    const initializeCoreSource = initializeCoreStart >= 0 && initializeCoreEnd > initializeCoreStart
      ? clientControllerSource.slice(initializeCoreStart, initializeCoreEnd)
      : "";
    assert(initializeCoreSource.includes("mobileRelayController.loadConfig(authorizeSecrets: false)"),
      "core hydration must load public Mobile Relay configuration without authorizing secret access"
    );
    assert(clientControllerSource.includes("secureMeshFileReceiveDestination") &&
      secureMeshControllerSource.includes("evaluateFileReceiveDestination") &&
      mobileRelayClientAdapterSource.includes("evaluateSecureMeshFileReceiveDestination"),
      "LicoUp client controller must retain Secure Mesh file receive-destination policy state"
    );
    const mobileRelayPanelSource = [
      mobileRelayPanelFacadeSource,
      ...Object.values(mobileRelayPanelSources)
    ].join("\n");
  assert(!mobileRelayPanelSource.includes("mobileRelayE2eeStatus") &&
    !mobileRelayPanelSource.includes("mobileRelayE2eeSecretStore") &&
    !mobileRelayPanelSource.includes("_e2eeReadinessText") &&
    !mobileRelayPanelSource.includes("_secretStoreText") &&
    !mobileRelayPanelSource.includes("pairwiseCryptoStatus"),
    "mobile relay panel must not expose Secure Mesh diagnostic state"
  );
  const clientLogExportServiceSource = await readDartSourceByBasename("client_log_export_service.dart");
  const clientShellSource = await readDartSourceByBasename("client_shell.dart");
  const shellTransitionSource = await readText(
    "apps/desktop/lib/src/composition/m2_legacy_shell_renderer_transition_adapter.dart"
  );
  const semanticDestinationsSource = await readDartSourceByBasename("semantic_destination.dart");
  assert(clientLogExportServiceSource.includes("activityLogFile") &&
    clientLogExportServiceSource.includes("open(mode: FileMode.read)") &&
    clientLogExportServiceSource.includes("temporary.create(exclusive: true)") &&
    clientLogExportServiceSource.includes("temporary.rename(destination.path)"),
    "client_log_export_service.dart must export the portable activity log without rendering it as a standalone page"
  );
  assert(semanticDestinationsSource.includes("enum ClientSection") &&
    clientShellSource.includes("widget.renderer.buildDestination") &&
    shellTransitionSource.includes("ClientSection.agents => AgentsCanvas") &&
    shellTransitionSource.includes("ClientSection.monitoring => AgentUsagePanel") &&
    shellTransitionSource.includes("ClientSection.skillHub => SkillHubPanel") &&
    shellTransitionSource.includes("ClientSection.pluginManagement => AdapterPluginPanel") &&
    shellTransitionSource.includes("ClientSection.mobileRelay => MobileRelayPanel") &&
    shellTransitionSource.includes("ClientSection.models => ModelsPanel") &&
    shellTransitionSource.includes("ClientSection.settings => SettingsPanel") &&
    shellTransitionSource.includes("ClientSection.agentHub => AgentHubPanel"),
    "LicoUp client shell must expose only the current top-level section bodies"
  );
  for (const [relativePath, source] of [
    ["agent_conversation_service.dart", agentConversationServiceSource],
    ["mobile_relay_service.dart", mobileRelayServiceSource]
  ]) {
    for (const token of ["HttpClient", "/api/mobile-relay", "readAsString", "writeAsString", "Directory(", "File("]) {
      assert(!source.includes(token), `${relativePath} must not perform runtime IO/network directly; use licoup CLI`);
    }
  }

  const licoStringsBaseSource = await readDartSourceByBasename(
    "lico_strings_base.dart"
  );
  for (const [getter, label] of [
    ["agents", "Agents"],
    ["tokenUsage", "Token Usage"],
    ["skillHub", "Skill Hub"],
    ["agentHub", "Agent Hub"],
    ["mobileRelay", "Mobile Relay"],
    ["settings", "Settings"]
  ]) {
    assert(
      licoStringsBaseSource.includes(`String get ${getter}`) &&
        licoStringsBaseSource.includes(`: '${label}'`),
      `LicoStrings must expose the current module label through ${getter}`
    );
  }
  for (const getter of ["agents", "tokenUsage", "skillHub", "agentHub", "mobileRelay", "settings"]) {
    assert(
      clientShellSource.includes(`strings.${getter}`),
      `client shell must resolve destination labels through LicoStrings.${getter}`
    );
  }

}
