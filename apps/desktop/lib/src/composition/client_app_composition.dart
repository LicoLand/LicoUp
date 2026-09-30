import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/misc.dart' show Override;

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:licoup/src/composition/binding_shell_renderer.dart';
import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
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
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/composition/client_platform_port_adapters.dart';
import 'package:licoup/src/platform/agent_render_adapter/agent_render_adapter_service.dart';
import 'package:licoup/src/platform/window_chrome/window_chrome_channel.dart';
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
import 'package:licoup/src/presentation/shell/shell_providers.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/platform/presentation/presentation_preferences_repository.dart';
import 'package:licoup/src/platform/presentation/macos_reduce_motion_channel.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/projections/environment/environment_projection_source.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';
import 'package:licoup/src/projections/chrome/chrome_presentation_source.dart';
import 'package:licoup/src/projections/shell/shell_effect_producer.dart';
import 'package:licoup/src/projections/shell/shell_projection_producer.dart';
import 'package:licoup/src/projections/shell/shell_presentation_sources.dart';

/// Assembles one client from the feature compositions its declaration names.
///
/// This is the only assembly point: a feature the injected
/// [ClientCompositionSet] does not name is never constructed, so it can neither
/// hold an owner nor install a provider override nor serve a destination. The
/// declaration defaults to the full set, so callers that omit it keep the
/// complete client.
final class ClientAppComposition {
  factory ClientAppComposition({
    ClientController? controller,
    CausalFrameTelemetry? telemetry,
    Stream<bool>? systemReduceMotionChanges,
    ClientCompositionSet compositionSet = ClientCompositionSet.full,
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
    // Frontend code never imports the platform layer; the composition root
    // hands the renderer its platform-backed services here instead.
    ClientPlatformPorts.install(
      portableData: resolvedController.portableData,
      featureOrderStore: PlatformDashboardFeatureOrderStoreAdapter.new,
      dockLayoutStore: PlatformDesktopDockLayoutStoreAdapter.new,
      reportTrafficLightAnchor:
          WindowChromeChannel.instance.setTrafficLightAnchor,
    );
    return ClientAppComposition._(
      resolvedController,
      layout,
      resolvedTelemetry,
      compositionSet,
      systemReduceMotionChanges ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
              ? const MacosReduceMotionChannel().changes
              : const Stream<bool>.empty()),
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
      TargetPlatform.android => LayoutProfileId.parse('dashboard'),
      _ => LayoutProfileId.parse('desktop'),
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

  ClientAppComposition._(
    this._controller,
    this._layout,
    this.telemetry,
    this._compositionSet,
    Stream<bool> systemReduceMotionChanges,
  ) : _projectionTracing = CausalProjectionSourceRegistry(telemetry) {
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
    _systemReduceMotionSubscription = systemReduceMotionChanges.listen(
      _environment.replaceSystemReduceMotion,
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
    _shellSources = ShellPresentationSources(
      appearance: binding.appearance,
      locale: binding.locale,
      layout: binding.layout,
      environment: binding.environment,
      navigation: binding.navigation,
      status: binding.status,
    );

    if (_compositionSet.agents) {
      _agents = AgentsFeatureComposition(
        _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.monitoring) {
      _monitoring = MonitoringFeatureComposition(
        _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.conversation) {
      _conversation = ConversationFeatureComposition(
        _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.mobileRelay) {
      _mobileRelay = MobileRelayFeatureComposition(
        relay: _controller.mobileRelayController,
        secureMesh: _controller.secureMeshController,
        homeLayout: _controller.mobileHomeLayoutController,
        readMobileRuntime: () => _controller.mobileClientRuntimePlatform,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.models) {
      _models = ModelsFeatureComposition(
        _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.skillHub) {
      _skillHub = SkillHubFeatureComposition(
        _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.pluginManagement) {
      _pluginManagement = PluginManagementFeatureComposition(
        _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.agentHub) {
      _agentHub = AgentHubFeatureComposition(
        _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.targets) {
      _targets = TargetsFeatureComposition(
        _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.search) {
      _search = SearchFeatureComposition(
        _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.chrome) {
      _chrome = ChromeFeatureComposition(
        _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }
    if (_compositionSet.settings) {
      _settings = SettingsFeatureComposition(
        controller: _controller,
        beginRendererIntent: beginRendererIntent,
      );
    }

    if (_compositionSet.agents) {
      final rawAgents = _agents.binding;
      agents = AgentsBinding(
        projection: _projectionTracing.wrap(rawAgents.projection),
        intents: rawAgents.intents,
        effects: rawAgents.effects,
      );
    }
    if (_compositionSet.monitoring) {
      final rawMonitoring = _monitoring.binding;
      monitoring = MonitoringBinding(
        projection: _projectionTracing.wrap(rawMonitoring.projection),
        intents: rawMonitoring.intents,
        effects: rawMonitoring.effects,
      );
    }
    if (_compositionSet.conversation) {
      final rawConversation = _conversation.binding;
      final rawConversationExecution = rawConversation.execution;
      conversation = ConversationBinding(
        projection: _projectionTracing.wrap(rawConversation.projection),
        execution: rawConversationExecution == null
            ? null
            : _projectionTracing.wrap(rawConversationExecution),
        nativeCatalog: _projectionTracing.wrap(rawConversation.nativeCatalog),
        canonicalEvents: _projectionTracing.wrap(
          rawConversation.canonicalEvents,
        ),
        persistentTurns: _projectionTracing.wrap(rawConversation.persistentTurns),
        composer: _projectionTracing.wrap(rawConversation.composer),
        attachments: _projectionTracing.wrap(rawConversation.attachments),
        tabActivity: _projectionTracing.wrap(rawConversation.tabActivity),
        notifications: _projectionTracing.wrap(rawConversation.notifications),
        archive: _projectionTracing.wrap(rawConversation.archive),
        intents: rawConversation.intents,
        effects: rawConversation.effects,
      );
    }
    if (_compositionSet.mobileRelay) {
      final rawMobileRelay = _mobileRelay.binding;
      mobileRelay = MobileRelayBinding(
        projection: _projectionTracing.wrap(rawMobileRelay.projection),
        intents: rawMobileRelay.intents,
        effects: rawMobileRelay.effects,
      );
    }
    if (_compositionSet.models) {
      final rawModels = _models.binding;
      models = ModelsBinding(
        projection: _projectionTracing.wrap(rawModels.projection),
        intents: rawModels.intents,
        effects: rawModels.effects,
      );
    }
    if (_compositionSet.skillHub) {
      final rawSkillHub = _skillHub.binding;
      skillHub = SkillHubBinding(
        projection: _projectionTracing.wrap(rawSkillHub.projection),
        intents: rawSkillHub.intents,
        effects: rawSkillHub.effects,
      );
    }
    if (_compositionSet.pluginManagement) {
      final rawPluginManagement = _pluginManagement.binding;
      pluginManagement = PluginManagementBinding(
        projection: _projectionTracing.wrap(rawPluginManagement.projection),
        intents: rawPluginManagement.intents,
        effects: rawPluginManagement.effects,
      );
    }
    if (_compositionSet.agentHub) {
      final rawAgentHub = _agentHub.binding;
      agentHub = AgentHubBinding(
        projection: _projectionTracing.wrap(rawAgentHub.projection),
        intents: rawAgentHub.intents,
        effects: rawAgentHub.effects,
      );
    }
    if (_compositionSet.targets) {
      final rawTargets = _targets.binding;
      targets = TargetsBinding(
        projection: _projectionTracing.wrap(rawTargets.projection),
        intents: rawTargets.intents,
        effects: rawTargets.effects,
      );
    }
    if (_compositionSet.search) {
      final rawSearch = _search.binding;
      search = SearchBinding(
        projection: _projectionTracing.wrap(rawSearch.projection),
        intents: rawSearch.intents,
        effects: rawSearch.effects,
      );
    }
    if (_compositionSet.chrome) {
      final rawChrome = _chrome.binding;
      chrome = ChromeBinding(
        projection: _projectionTracing.wrap(rawChrome.projection),
        intents: rawChrome.intents,
        effects: rawChrome.effects,
      );
    }
    if (_compositionSet.settings) {
      final rawSettings = _settings.binding;
      settings = SettingsBinding(
        projection: _projectionTracing.wrap(rawSettings.projection),
        resourceUsage: _projectionTracing.wrap(rawSettings.resourceUsage),
        autostart: _projectionTracing.wrap(rawSettings.autostart),
        intents: rawSettings.intents,
        effects: rawSettings.effects,
      );
    }

    _renderer = BindingShellRenderer(
      layout: _layout,
      shellIntents: _shellIntents,
      runtime: _runtime,
      chromeSource: _chrome.source,
      statusSource: _shellSources.status,
      localeSource: _shellSources.locale,
      agents: agents,
      conversation: conversation,
      monitoring: monitoring,
      skillHub: _compositionSet.skillHub ? skillHub : null,
      pluginManagement: _compositionSet.pluginManagement
          ? pluginManagement
          : null,
      mobileRelay: _compositionSet.mobileRelay ? mobileRelay : null,
      models: _compositionSet.models ? models : null,
      settings: _compositionSet.settings ? settings : null,
      agentHub: _compositionSet.agentHub ? agentHub : null,
      search: _compositionSet.search ? search : null,
      targets: targets,
      openExternalUri: _controller.runtimePlatformBridge.openHttps,
      workspaceHomeDirectory: userHomeDirectory(),
    );
    renderer = _renderer;
  }

  final ClientController _controller;
  final BuiltInLayoutComposition _layout;
  final CausalFrameTelemetry? telemetry;

  /// The closed declaration this client was assembled from. Every feature
  /// composition below is constructed only when this set names it.
  final ClientCompositionSet _compositionSet;
  final CausalProjectionSourceRegistry _projectionTracing;

  /// The app-scope presentation runtime.
  ///
  /// The composition root owns it so the renderer chrome and every feature
  /// provider observe the same sources through one lifetime; the root
  /// `ProviderScope` receives it through [presentationOverrides].
  final PresentationRuntime _runtime = PresentationRuntime();
  late final ShellProjectionProducer _shellProjection;
  late final ShellPresentationSources _shellSources;
  late final EnvironmentProjectionSource _environment;
  late final StreamSubscription<bool> _systemReduceMotionSubscription;
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

  /// One binding per feature the declaration names.
  ///
  /// A binding for a feature the injected [ClientCompositionSet] does not name
  /// is never assigned, so reading it fails: there is no owner behind it, no
  /// provider override for it and no destination surface for it.
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

  /// Aggregated Riverpod overrides that install every installed feature's live
  /// presentation sources and the app-scope runtime. The app root wraps its
  /// tree in a `ProviderScope` with these; feature tests install their own
  /// synthetic overrides instead. A feature the declaration does not name
  /// contributes no override, so its regions keep their documented disabled
  /// value and no consumer can observe an owner that was never constructed.
  List<Override> get presentationOverrides => <Override>[
    presentationRuntimeProvider.overrideWithValue(_runtime),
    shellAppearanceSourceProvider.overrideWithValue(_shellSources.appearance),
    shellLocaleSourceProvider.overrideWithValue(_shellSources.locale),
    shellLayoutSourceProvider.overrideWithValue(_shellSources.layout),
    shellEnvironmentSourceProvider.overrideWithValue(_shellSources.environment),
    shellNavigationSourceProvider.overrideWithValue(_shellSources.navigation),
    shellStatusSourceProvider.overrideWithValue(_shellSources.status),
    if (_compositionSet.agents) ..._agents.providerOverrides,
    if (_compositionSet.targets) ..._targets.providerOverrides,
    if (_compositionSet.monitoring) ..._monitoring.providerOverrides,
    if (_compositionSet.models) ..._models.providerOverrides,
    if (_compositionSet.agentHub) ..._agentHub.providerOverrides,
    if (_compositionSet.search) ..._search.providerOverrides,
    if (_compositionSet.conversation) ..._conversation.providerOverrides,
    if (_compositionSet.settings) ..._settings.providerOverrides,
    if (_compositionSet.pluginManagement) ..._pluginManagement.providerOverrides,
    if (_compositionSet.skillHub) ..._skillHub.providerOverrides,
    if (_compositionSet.mobileRelay) ..._mobileRelay.providerOverrides,
  ];

  Future<void> initialize() => _controller.initialize();

  Future<void> initializeLlmGateway() => _controller.initializeLlmGateway();

  /// The app-scope runtime the root scope and the renderer share.
  PresentationRuntime get presentationRuntime => _runtime;

  /// The runtime-backed chrome source observed by the renderer chrome.
  ChromePresentationSource get chromeSource => _chrome.source;

  /// The six runtime-backed shell region sources installed at the root.
  ShellPresentationSources get shellSources => _shellSources;

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
    _shellSources.dispose,
    _runtime.dispose,
    _projectionTracing.dispose,
    () => telemetry?.dispose(),
    if (_compositionSet.settings) _settings.dispose,
    if (_compositionSet.chrome) _chrome.close,
    if (_compositionSet.search) _search.close,
    if (_compositionSet.targets) _targets.dispose,
    if (_compositionSet.agentHub) _agentHub.dispose,
    if (_compositionSet.pluginManagement) _pluginManagement.dispose,
    if (_compositionSet.skillHub) _skillHub.dispose,
    if (_compositionSet.models) _models.dispose,
    if (_compositionSet.mobileRelay) _mobileRelay.dispose,
    if (_compositionSet.conversation) _conversation.close,
    if (_compositionSet.monitoring) _monitoring.close,
    if (_compositionSet.agents) _agents.close,
    _shellProjection.dispose,
    _systemReduceMotionSubscription.cancel,
    _environment.dispose,
    _shellEffects.dispose,
    _controller.close,
  ]);
}
