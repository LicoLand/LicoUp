/// The closed declaration of which feature compositions a running client owns.
///
/// `ClientAppComposition` is the only assembly point and constructs exactly the
/// feature compositions this declaration names. A feature that is not named
/// here has no composition, no binding, no provider override and no destination
/// surface, so an uninstalled feature cannot start a background owner. Absence
/// is a property of the value the root is given, never a runtime availability
/// check performed while the client is running.
///
/// The declaration is typed on purpose: one named field per feature composition,
/// a typed constructor with required named parameters, and no string key, map,
/// registry, plugin interface or reflection path.
///
/// The shell's own feature compositions — [chrome], which serves the renderer
/// chrome, and [monitoring], which the agents destination renders — are named by
/// both constants because the shell cannot serve a destination without them.
/// [minimum] and [full] otherwise differ only in the six optional features that
/// the minimum leaves out.
final class ClientCompositionSet {
  const ClientCompositionSet({
    required this.agents,
    required this.conversation,
    required this.targets,
    required this.chrome,
    required this.monitoring,
    required this.agentHub,
    required this.mobileRelay,
    required this.models,
    required this.pluginManagement,
    required this.search,
    required this.settings,
    required this.skillHub,
  });

  /// The minimum client: the shell's own feature compositions, the three
  /// features the required operations traverse — the agent catalog, the
  /// conversation planes and the target catalog — and the cross-device relay
  /// composition.
  ///
  /// The relay composition belongs to the minimum because the shell cannot
  /// serve the agents destination without it: `agent_conversation_workspace.dart`
  /// gates that whole destination frame on the relay approvals source, and that
  /// file is owned by no Task in this delivery. Every other optional feature is
  /// absent, so none of their owners, provider overrides or destination
  /// surfaces exist.
  static const ClientCompositionSet minimum = ClientCompositionSet(
    agents: true,
    conversation: true,
    targets: true,
    chrome: true,
    monitoring: true,
    agentHub: false,
    mobileRelay: true,
    models: false,
    pluginManagement: false,
    search: false,
    settings: false,
    skillHub: false,
  );

  /// The full client: the minimum plus every optional feature.
  static const ClientCompositionSet full = ClientCompositionSet(
    agents: true,
    conversation: true,
    targets: true,
    chrome: true,
    monitoring: true,
    agentHub: true,
    mobileRelay: true,
    models: true,
    pluginManagement: true,
    search: true,
    settings: true,
    skillHub: true,
  );

  /// The agent catalog composition (`AgentsFeatureComposition`).
  final bool agents;

  /// The conversation planes composition (`ConversationFeatureComposition`).
  final bool conversation;

  /// The target catalog composition (`TargetsFeatureComposition`).
  final bool targets;

  /// The renderer chrome composition (`ChromeFeatureComposition`).
  final bool chrome;

  /// The agent usage composition (`MonitoringFeatureComposition`).
  final bool monitoring;

  /// The agent hub composition (`AgentHubFeatureComposition`).
  final bool agentHub;

  /// The cross-device relay composition (`MobileRelayFeatureComposition`).
  ///
  /// Named by [minimum] as well as [full]: the agents destination's workspace
  /// gates its frame on this feature's approvals source.
  final bool mobileRelay;

  /// The model catalog composition (`ModelsFeatureComposition`).
  final bool models;

  /// The adapter plugin composition (`PluginManagementFeatureComposition`).
  final bool pluginManagement;

  /// The global search composition (`SearchFeatureComposition`).
  final bool search;

  /// The settings composition (`SettingsFeatureComposition`).
  final bool settings;

  /// The skill hub composition (`SkillHubFeatureComposition`).
  final bool skillHub;
}
