import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

/// The closed declaration of which feature compositions a running client owns.
///
/// `ClientAppComposition` is the only assembly point and constructs exactly the
/// feature compositions this declaration names. A feature that is not named
/// here has no composition, no binding, no provider override, no destination
/// mount and no surface, so an absent feature cannot start a background owner
/// and cannot be reached from the shell. Absence is a property of the value the
/// root is given, never a runtime availability check performed while the client
/// is running, and it is never a state the renderer has to discover.
///
/// The declaration is typed on purpose: one named field per feature
/// composition, a typed constructor with required named parameters, and no
/// string key, map, registry, plugin interface or reflection path. Adding or
/// removing a capability is therefore a change to this declaration and to the
/// feature's own module, which is what keeps an installed capability and an
/// absent one different in exactly one place.
///
/// The shell's own feature compositions — [chrome], which serves the renderer
/// chrome, and [monitoring], which the agents destination renders — are named by
/// both constants because the shell cannot serve a destination without them.
/// [minimum] and [full] otherwise differ only in the five optional features that
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
  /// serve the agents destination without it:
  /// `agent_conversation_workspace.dart` renders its remote-approval region
  /// from a `MobileRelayBinding`, so the agents destination needs the feature's
  /// absent value when the composition does not install the feature itself.
  /// Every other optional feature is absent, so none of their owners, provider
  /// overrides, destinations or surfaces exist.
  static const ClientCompositionSet minimum = ClientCompositionSet(
    agents: true,
    conversation: true,
    targets: true,
    chrome: true,
    monitoring: true,
    agentHub: false,
    mobileRelay: false,
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
  /// Optional, but the agents destination still renders its remote-approval
  /// region: an absent relay feature contributes its absent value rather than a
  /// surface of its own.
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

  /// Whether the feature composition that serves [destination] is named by
  /// this declaration.
  ///
  /// This is the single destination-to-feature decision in the client: the
  /// capability catalogue, the shell renderer and the shell navigation
  /// projection all ask this method instead of repeating the mapping. Every
  /// destination belongs to exactly one feature composition, so the answer is
  /// total and no runtime availability probe can disagree with it.
  bool isInstalled(ClientSection destination) => switch (destination) {
    ClientSection.agents => agents,
    ClientSection.monitoring => monitoring,
    ClientSection.skillHub => skillHub,
    ClientSection.pluginManagement => pluginManagement,
    ClientSection.mobileRelay => mobileRelay,
    ClientSection.models => models,
    ClientSection.settings => settings,
    ClientSection.agentHub => agentHub,
  };
}
