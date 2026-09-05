import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:licoup/src/composition/binding_shell_renderer.dart';
import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/composition/dispose_all.dart';
import 'package:licoup/src/composition/features/agent_hub/agent_hub_feature_composition.dart';
import 'package:licoup/src/composition/features/agents/agents_feature_composition.dart';
import 'package:licoup/src/composition/features/chrome/chrome_feature_composition.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_feature_composition.dart';
import 'package:licoup/src/composition/features/models/models_feature_composition.dart';
import 'package:licoup/src/composition/features/monitoring/monitoring_feature_composition.dart';
import 'package:licoup/src/composition/features/plugin_management/plugin_management_feature_composition.dart';
import 'package:licoup/src/composition/features/search/search_feature_composition.dart';
import 'package:licoup/src/composition/features/settings/settings_feature_composition.dart';
import 'package:licoup/src/composition/features/skill_hub/skill_hub_feature_composition.dart';
import 'package:licoup/src/composition/features/targets/targets_feature_composition.dart';
import 'package:licoup/src/composition/shell_intent_adapter.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/user_home_directory.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/binding/causal_frame_telemetry.dart';
import 'package:licoup/src/frontend/binding/causal_projection_source_registry.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/platform/agent_render_adapter/agent_render_adapter_service.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/search/search_binding.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/shell/shell_binding.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/platform/presentation/presentation_preferences_repository.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/projections/environment/environment_projection_source.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';
import 'package:licoup/src/projections/shell/shell_effect_producer.dart';
import 'package:licoup/src/projections/shell/shell_projection_producer.dart';

final class ClientAppComposition {
  factory ClientAppComposition({
    ClientController? controller,
    CausalFrameTelemetry? telemetry,
  }) {
    AgentRenderAdapterRegistry.instance = AgentRenderAdapterRegistry(
      loadJson: DefaultAgentRenderAdapterJsonSource().loadAdapterJson,
    );
    final resolvedTelemetry = telemetry ?? createOptInCausalFrameTelemetry();
    final layout = controller == null
        ? BuiltInLayoutComposition()
        : BuiltInLayoutComposition.attach(catalog: controller.layoutCatalog);
    final resolvedController =
        controller ?? _createProductionController(layout);
    return ClientAppComposition._(
      resolvedController,
      layout,
      resolvedTelemetry,
    );
  }

  static ClientController _createProductionController(
    BuiltInLayoutComposition layout,
  ) {
    final portableData = PortableDataRoot();
    final preferredLayout = switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.iOS ||
      TargetPlatform.android => LayoutProfileId.parse('messaging'),
      _ => LayoutProfileId.parse('dashboard'),
    };
    final fallback = PresentationPreferences(
      layoutProfileId: preferredLayout,
      appearancePresetId: AppearancePresetIds.defaultSystem,
      localePreference: LocalePreference.system,
    );
    final preferences = FilePresentationPreferencesRepository(
      portableData: portableData,
      fallback: fallback,
    );
    final manager = LayoutManager(
      catalog: layout.catalog,
      preferencesRepository: preferences,
      canonicalFallback: fallback,
      preferredDefaultId: preferredLayout,
    );
    return ClientController(
      portableData: portableData,
      layoutCatalog: layout.catalog,
      layoutManager: manager,
    );
  }

  ClientAppComposition._(this._controller, this._layout, this.telemetry)
    : _projectionTracing = CausalProjectionSourceRegistry(telemetry) {
    final beginRendererIntent = telemetry?.beginRendererIntent;
    final runtimeSurface = _controller.mobileClientRuntimePlatform
        ? LayoutRuntimeSurface.mobile
        : LayoutRuntimeSurface.desktop;
    _environment = EnvironmentProjectionSource(
      EnvironmentState(
        environment: LayoutEnvironment.fromConstraints(
          surface: runtimeSurface,
          width: runtimeSurface == LayoutRuntimeSurface.mobile ? 390 : 1280,
          height: runtimeSurface == LayoutRuntimeSurface.mobile ? 844 : 800,
          textScale: 1,
          hasPointer: runtimeSurface == LayoutRuntimeSurface.desktop,
          hasKeyboard: runtimeSurface == LayoutRuntimeSurface.desktop,
          hasTouch: runtimeSurface == LayoutRuntimeSurface.mobile,
        ),
        runtimeSurface: runtimeSurface,
      ),
    );
    _shellProjection = ShellProjectionProducer(
      appearance: _controller.appearancePreferenceOwner,
      locale: _controller.localePreferenceOwner,
      status: _controller.functionalStatusRuntime,
      navigation: _controller.navigationController,
      layoutManager: _controller.layoutManager,
      environment: _environment,
    );
    _shellEffects = ShellEffectProducer();
    _shellIntents = ShellIntentAdapter(
      _controller,
      _shellEffects,
      environment: _environment,
      beginRendererIntent: beginRendererIntent,
    );
    binding = ShellBinding(
      appearance: _projectionTracing.wrap(_shellProjection.appearance),
      locale: _projectionTracing.wrap(_shellProjection.locale),
      layout: _projectionTracing.wrap(_shellProjection.layout),
      environment: _projectionTracing.wrap(_shellProjection.environment),
      navigation: _projectionTracing.wrap(_shellProjection.navigation),
      status: _projectionTracing.wrap(_shellProjection.status),
      intents: _shellIntents,
      effects: _shellEffects,
    );

    _agents = AgentsFeatureComposition(
      _controller,
      beginRendererIntent: beginRendererIntent,
    );
    _monitoring = MonitoringFeatureComposition(
      _controller,
      beginRendererIntent: beginRendererIntent,
    );
    _conversation = ConversationFeatureComposition(
      _controller,
      beginRendererIntent: beginRendererIntent,
    );
    _mobileRelay = MobileRelayFeatureComposition(
      relay: _controller.mobileRelayController,
      secureMesh: _controller.secureMeshController,
      homeLayout: _controller.mobileHomeLayoutController,
      readMobileRuntime: () => _controller.mobileClientRuntimePlatform,
      beginRendererIntent: beginRendererIntent,
    );
    _models = ModelsFeatureComposition(
      _controller,
      beginRendererIntent: beginRendererIntent,
    );
    _skillHub = SkillHubFeatureComposition(
      _controller,
      beginRendererIntent: beginRendererIntent,
    );
    _pluginManagement = PluginManagementFeatureComposition(
      _controller,
      beginRendererIntent: beginRendererIntent,
    );
    _agentHub = AgentHubFeatureComposition(
      _controller,
      beginRendererIntent: beginRendererIntent,
    );
    _targets = TargetsFeatureComposition(
      _controller,
      beginRendererIntent: beginRendererIntent,
    );
    _search = SearchFeatureComposition(
      _controller,
      beginRendererIntent: beginRendererIntent,
    );
    _chrome = ChromeFeatureComposition(
      _controller,
      beginRendererIntent: beginRendererIntent,
    );
    _settings = SettingsFeatureComposition(
      controller: _controller,
      beginRendererIntent: beginRendererIntent,
    );

    final rawAgents = _agents.binding;
    agents = AgentsBinding(
      projection: _projectionTracing.wrap(rawAgents.projection),
      intents: rawAgents.intents,
      effects: rawAgents.effects,
    );
    final rawMonitoring = _monitoring.binding;
    monitoring = MonitoringBinding(
      projection: _projectionTracing.wrap(rawMonitoring.projection),
      intents: rawMonitoring.intents,
      effects: rawMonitoring.effects,
    );
    final rawConversation = _conversation.binding;
    conversation = ConversationBinding(
      projection: _projectionTracing.wrap(rawConversation.projection),
      nativeCatalog: _projectionTracing.wrap(rawConversation.nativeCatalog),
      canonicalEvents: _projectionTracing.wrap(rawConversation.canonicalEvents),
      persistentTurns: _projectionTracing.wrap(rawConversation.persistentTurns),
      composer: _projectionTracing.wrap(rawConversation.composer),
      attachments: _projectionTracing.wrap(rawConversation.attachments),
      tabActivity: _projectionTracing.wrap(rawConversation.tabActivity),
      notifications: _projectionTracing.wrap(rawConversation.notifications),
      archive: _projectionTracing.wrap(rawConversation.archive),
      intents: rawConversation.intents,
      effects: rawConversation.effects,
    );
    final rawMobileRelay = _mobileRelay.binding;
    mobileRelay = MobileRelayBinding(
      projection: _projectionTracing.wrap(rawMobileRelay.projection),
      intents: rawMobileRelay.intents,
      effects: rawMobileRelay.effects,
    );
    final rawModels = _models.binding;
    models = ModelsBinding(
      projection: _projectionTracing.wrap(rawModels.projection),
      intents: rawModels.intents,
      effects: rawModels.effects,
    );
    final rawSkillHub = _skillHub.binding;
    skillHub = SkillHubBinding(
      projection: _projectionTracing.wrap(rawSkillHub.projection),
      intents: rawSkillHub.intents,
      effects: rawSkillHub.effects,
    );
    final rawPluginManagement = _pluginManagement.binding;
    pluginManagement = PluginManagementBinding(
      projection: _projectionTracing.wrap(rawPluginManagement.projection),
      intents: rawPluginManagement.intents,
      effects: rawPluginManagement.effects,
    );
    final rawAgentHub = _agentHub.binding;
    agentHub = AgentHubBinding(
      projection: _projectionTracing.wrap(rawAgentHub.projection),
      intents: rawAgentHub.intents,
      effects: rawAgentHub.effects,
    );
    final rawTargets = _targets.binding;
    targets = TargetsBinding(
      projection: _projectionTracing.wrap(rawTargets.projection),
      intents: rawTargets.intents,
      effects: rawTargets.effects,
    );
    final rawSearch = _search.binding;
    search = SearchBinding(
      projection: _projectionTracing.wrap(rawSearch.projection),
      intents: rawSearch.intents,
      effects: rawSearch.effects,
    );
    final rawChrome = _chrome.binding;
    chrome = ChromeBinding(
      projection: _projectionTracing.wrap(rawChrome.projection),
      intents: rawChrome.intents,
      effects: rawChrome.effects,
    );
    final rawSettings = _settings.binding;
    settings = SettingsBinding(
      projection: _projectionTracing.wrap(rawSettings.projection),
      resourceUsage: _projectionTracing.wrap(rawSettings.resourceUsage),
      autostart: _projectionTracing.wrap(rawSettings.autostart),
      intents: rawSettings.intents,
      effects: rawSettings.effects,
    );

    _renderer = BindingShellRenderer(
      layout: _layout,
      shellIntents: _shellIntents,
      status: binding.status,
      locale: binding.locale,
      agents: agents,
      chrome: chrome,
      conversation: conversation,
      monitoring: monitoring,
      skillHub: skillHub,
      pluginManagement: pluginManagement,
      mobileRelay: mobileRelay,
      models: models,
      settings: settings,
      agentHub: agentHub,
      search: search,
      targets: targets,
      openExternalUri: _controller.runtimePlatformBridge.openHttps,
      workspaceHomeDirectory: userHomeDirectory(),
    );
    renderer = _renderer;
  }

  final ClientController _controller;
  final BuiltInLayoutComposition _layout;
  final CausalFrameTelemetry? telemetry;
  final CausalProjectionSourceRegistry _projectionTracing;
  late final ShellProjectionProducer _shellProjection;
  late final EnvironmentProjectionSource _environment;
  late final ShellEffectProducer _shellEffects;
  late final ShellIntentAdapter _shellIntents;
  late final AgentsFeatureComposition _agents;
  late final MonitoringFeatureComposition _monitoring;
  late final ConversationFeatureComposition _conversation;
  late final MobileRelayFeatureComposition _mobileRelay;
  late final ModelsFeatureComposition _models;
  late final SkillHubFeatureComposition _skillHub;
  late final PluginManagementFeatureComposition _pluginManagement;
  late final AgentHubFeatureComposition _agentHub;
  late final TargetsFeatureComposition _targets;
  late final SearchFeatureComposition _search;
  late final ChromeFeatureComposition _chrome;
  late final SettingsFeatureComposition _settings;
  late final BindingShellRenderer _renderer;

  late final ShellBinding binding;
  late final AgentsBinding agents;
  late final MonitoringBinding monitoring;
  late final ConversationBinding conversation;
  late final MobileRelayBinding mobileRelay;
  late final ModelsBinding models;
  late final SkillHubBinding skillHub;
  late final PluginManagementBinding pluginManagement;
  late final AgentHubBinding agentHub;
  late final TargetsBinding targets;
  late final SearchBinding search;
  late final ChromeBinding chrome;
  late final SettingsBinding settings;
  late final ShellRendererPort renderer;
  Future<void>? _disposal;

  Future<void> initialize() => _controller.initialize();

  Future<void> initializeLlmGateway() => _controller.initializeLlmGateway();

  void attachFlutterObservation(WidgetsBinding binding) =>
      telemetry?.attachFrameObservation(binding);

  void updateConversationAttention({
    AppLifecycleState? lifecycleState,
    bool? viewFocused,
  }) => _controller.updateConversationAttention(
    lifecycleState: lifecycleState == null
        ? null
        : switch (lifecycleState) {
            AppLifecycleState.resumed => ConversationLifecyclePhase.resumed,
            AppLifecycleState.inactive => ConversationLifecyclePhase.inactive,
            AppLifecycleState.hidden => ConversationLifecyclePhase.hidden,
            AppLifecycleState.paused => ConversationLifecyclePhase.paused,
            AppLifecycleState.detached => ConversationLifecyclePhase.detached,
          },
    viewFocused: viewFocused,
  );

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() => disposeAll([
    _renderer.dispose,
    _layout.dispose,
    _projectionTracing.dispose,
    () => telemetry?.dispose(),
    _settings.dispose,
    _chrome.close,
    _search.close,
    _targets.dispose,
    _agentHub.dispose,
    _pluginManagement.dispose,
    _skillHub.dispose,
    _models.dispose,
    _mobileRelay.dispose,
    _conversation.close,
    _monitoring.close,
    _agents.close,
    _shellProjection.dispose,
    _environment.dispose,
    _shellEffects.dispose,
    _controller.close,
  ]);
}
