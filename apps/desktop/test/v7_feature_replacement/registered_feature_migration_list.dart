/// Registered feature bindings and their production wiring.
///
/// Each row identifies the producer, runtime-backed port, concrete adapter,
/// state owner and behavior tests. The owning source and tests define the
/// current contract; a retired execution plan is not an implementation authority.
///
/// `registered_feature_migration_test.dart` verifies every claim against the
/// repository, so the list cannot silently omit a binding or a path.
library;

/// How the composition root supplies this feature's live presentation source.
enum FeatureSourceWiring {
  /// The feature exposes `providerOverrides` and the root `ProviderScope`
  /// installs them through `ClientAppComposition.presentationOverrides`.
  providerOverrides,

  /// The feature exposes a `PresentationProviderEntry`; no root override yet.
  providerEntry,

  /// No runtime-backed entry: the binding is fed by the legacy projection
  /// producer directly.
  none,
}

/// Which surface consumes the feature's values in the desktop shell.
enum FeatureUiConsumption {
  /// Views watch the runtime-backed provider inputs / projection providers.
  narrowInputs,

  /// Views still read the legacy `ProjectionSource` directly.
  legacyProjection,

  /// Both paths are live in the feature.
  mixed,

  /// Views consume the feature through the shell renderer port.
  rendererPort,

  /// The conversation view migration is in flight under V7-F5.
  inFlight,

  /// No desktop view consumes the feature's values yet.
  none,
}

/// One exact piece of remaining work for a registered feature.
final class MigrationRemainder {
  const MigrationRemainder({
    required this.owner,
    required this.reason,
    this.files = const <String>[],
    this.filesToCreate = const <String>[],
  });

  /// Declared v7 task that owns the change, or `unassigned` when no frozen
  /// write scope contains the file.
  final String owner;

  final String reason;

  /// Existing files that must change (app-relative paths).
  final List<String> files;

  /// Files that must be created (app-relative paths); must not exist yet.
  final List<String> filesToCreate;
}

/// One registered feature and its narrow-input migration state.
final class RegisteredFeatureMigration {
  const RegisteredFeatureMigration({
    required this.feature,
    required this.binding,
    required this.projectionProducers,
    required this.presentationSources,
    required this.composition,
    required this.wiring,
    required this.storeOwner,
    required this.legacyEntry,
    required this.legacyCallee,
    required this.newPort,
    required this.behaviorTests,
    required this.uiDirectories,
    required this.uiConsumption,
    required this.legacyRetired,
    this.remainders = const <MigrationRemainder>[],
  });

  final String feature;

  /// The `presentation/<feature>/<feature>_binding.dart` contract file.
  final String binding;

  final List<String> projectionProducers;

  /// Runtime-backed adapters in `projections/<feature>/`; empty when the
  /// feature has no adapter yet.
  final List<String> presentationSources;

  final String composition;

  final FeatureSourceWiring wiring;

  /// Which application object owns the feature state.
  final String storeOwner;

  final String legacyEntry;

  final String legacyCallee;

  final String newPort;

  final List<String> behaviorTests;

  final List<String> uiDirectories;

  final FeatureUiConsumption uiConsumption;

  /// True when no desktop view still reads the legacy projection path.
  final bool legacyRetired;

  final List<MigrationRemainder> remainders;
}

/// The 13 registered bindings in B0 order.
const registeredFeatureMigrations = <RegisteredFeatureMigration>[
  RegisteredFeatureMigration(
    feature: 'agents',
    binding: 'lib/src/presentation/agents/agents_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/agents/agents_projection_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/agents/agents_presentation_source.dart',
    ],
    composition:
        'lib/src/composition/features/agents/agents_feature_composition.dart',
    wiring: FeatureSourceWiring.providerEntry,
    storeOwner: 'ClientController + AdaptiveFlywheelController',
    legacyEntry:
        'lib/src/frontend/features/agents/ui/* binding.projection reads (retired by V7-F6A)',
    legacyCallee: 'AgentsProjectionProducer over ClientController',
    newPort:
        'agentsCatalogProjectionProvider over AgentsPresentationSource (runtime)',
    behaviorTests: <String>[
      'test/presentation/agents_presentation_source_test.dart',
      'test/presentation/agents_conversation_renderer_migration_test.dart',
      'test/v7_feature_replacement_closure/source_lifecycle_and_providers_test.dart',
      'test/v7_feature_replacement_closure/feature_view_behavior_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/features/agents/ui'],
    uiConsumption: FeatureUiConsumption.narrowInputs,
    legacyRetired: false,
    remainders: <MigrationRemainder>[
      MigrationRemainder(
        owner: 'V7-FI',
        reason:
            'root ProviderScope does not install the agents presentation entry/override; the agent views resolve their runtime source from the binding until it does',
        files: <String>['lib/src/composition/client_app_composition.dart'],
      ),
      MigrationRemainder(
        owner: 'V7-F5',
        reason:
            'the conversation projection chain inside the workspace and the two dialogs is the parallel conversation surface',
        files: <String>[
          'lib/src/frontend/features/agents/ui/agent_conversation_workspace.dart',
          'lib/src/frontend/features/agents/ui/adaptive_flywheel_dialog.dart',
          'lib/src/frontend/features/agents/ui/assistant_configuration_dialog.dart',
        ],
      ),
    ],
  ),
  RegisteredFeatureMigration(
    feature: 'conversation',
    binding: 'lib/src/presentation/conversation/conversation_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/conversation/conversation_projection_producer.dart',
      'lib/src/projections/conversation/conversation_execution_projection_producer.dart',
    ],
    presentationSources: <String>[],
    composition:
        'lib/src/composition/features/conversation/conversation_feature_composition.dart',
    wiring: FeatureSourceWiring.providerOverrides,
    storeOwner: 'ClientController conversation owners',
    legacyEntry:
        'lib/src/frontend/features/agents/ui/conversation/ composition root',
    legacyCallee:
        'ConversationProjectionProducer / ConversationExecutionProjectionProducer',
    newPort: 'prepared conversation view under V7-F5',
    behaviorTests: <String>[
      'test/conversation_presentation_signals_test.dart',
      'test/canonical_group_conversation_projection_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/features/agents/ui/conversation'],
    uiConsumption: FeatureUiConsumption.inFlight,
    legacyRetired: false,
    remainders: <MigrationRemainder>[
      MigrationRemainder(
        owner: 'V7-F5',
        reason:
            'conversation sources, prepared view and search wiring are owned by the parallel conversation task',
        files: <String>[
          'lib/src/projections/conversation/conversation_projection_producer.dart',
          'lib/src/presentation/conversation/conversation_binding.dart',
          'lib/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/pane.dart',
          'lib/src/composition/features/conversation/conversation_feature_composition.dart',
        ],
      ),
    ],
  ),
  RegisteredFeatureMigration(
    feature: 'settings',
    binding: 'lib/src/presentation/settings/settings_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/settings/settings_projection_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/settings/settings_presentation_sources.dart',
      'lib/src/projections/settings/settings_autostart_projection_source.dart',
      'lib/src/projections/settings/settings_resource_usage_projection_source.dart',
    ],
    composition:
        'lib/src/composition/features/settings/settings_feature_composition.dart',
    wiring: FeatureSourceWiring.providerOverrides,
    storeOwner: 'ClientController',
    legacyEntry:
        'lib/src/presentation/settings/settings_binding.dart projection field',
    legacyCallee: 'SettingsProjectionProducer over ClientController',
    newPort:
        'nine region sources through settings*SourceProvider overrides (presentation runtime)',
    behaviorTests: <String>[
      'test/settings_presentation_hub_test.dart',
      'test/settings_lazy_regions_test.dart',
      'test/settings_feature_composition_test.dart',
      'test/v7_feature_replacement/settings_replacement_component_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/features/settings/ui'],
    uiConsumption: FeatureUiConsumption.narrowInputs,
    legacyRetired: true,
  ),
  RegisteredFeatureMigration(
    feature: 'mobile_relay',
    binding: 'lib/src/presentation/mobile_relay/mobile_relay_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/mobile_relay/mobile_relay_projection_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/mobile_relay/mobile_relay_presentation_sources.dart',
    ],
    composition:
        'lib/src/composition/features/mobile_relay/mobile_relay_feature_composition.dart',
    wiring: FeatureSourceWiring.providerOverrides,
    storeOwner: 'MobileRelayController + SecureMeshController',
    legacyEntry:
        'lib/src/frontend/features/mobile_relay/ui/* (binding.projection reads retired by V7-F6A in the migrated views)',
    legacyCallee: 'MobileRelayProjectionProducer',
    newPort: 'six region sources through mobile relay provider overrides',
    behaviorTests: <String>[
      'test/mobile_relay_presentation_sources_test.dart',
      'test/mobile_relay_models_boundary_test.dart',
      'test/mobile_agents_home_regions_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/features/mobile_relay/ui'],
    uiConsumption: FeatureUiConsumption.narrowInputs,
    legacyRetired: false,
    remainders: <MigrationRemainder>[
      MigrationRemainder(
        owner: 'unassigned',
        reason:
            'the relay panel composition still reads binding.projection for its station label outside this task scope',
        files: <String>[
          'lib/src/frontend/features/mobile_relay/ui/mobile_relay_panel/composition.dart',
        ],
      ),
    ],
  ),
  RegisteredFeatureMigration(
    feature: 'plugin_management',
    binding:
        'lib/src/presentation/plugin_management/plugin_management_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/plugin_management/plugin_management_projection_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/plugin_management/plugin_management_presentation_sources.dart',
    ],
    composition:
        'lib/src/composition/features/plugin_management/plugin_management_feature_composition.dart',
    wiring: FeatureSourceWiring.providerOverrides,
    storeOwner: 'AdapterPluginController',
    legacyEntry: 'lib/src/frontend/features/plugin_management/ui/*',
    legacyCallee: 'PluginManagementProjectionProducer',
    newPort: 'catalog and collaboration region sources',
    behaviorTests: <String>[
      'test/plugin_management_presentation_sources_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/features/plugin_management/ui'],
    uiConsumption: FeatureUiConsumption.narrowInputs,
    legacyRetired: true,
  ),
  RegisteredFeatureMigration(
    feature: 'models',
    binding: 'lib/src/presentation/models/models_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/models/models_projection_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/models/models_presentation_source.dart',
    ],
    composition:
        'lib/src/composition/features/models/models_feature_composition.dart',
    wiring: FeatureSourceWiring.providerEntry,
    storeOwner: 'ModelsSemanticController',
    legacyEntry:
        'lib/src/frontend/features/models/ui/models_panel.dart (binding.projection read retired by V7-F6A)',
    legacyCallee: 'ModelsProjectionProducer over ModelsSemanticController',
    newPort:
        'modelsCatalogProjectionProvider over ModelsPresentationSource (runtime)',
    behaviorTests: <String>[
      'test/presentation/models_presentation_source_test.dart',
      'test/llm_gateway_models_panel_test.dart',
      'test/v7_feature_replacement_closure/source_lifecycle_and_providers_test.dart',
      'test/v7_feature_replacement_closure/feature_view_behavior_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/features/models/ui'],
    uiConsumption: FeatureUiConsumption.narrowInputs,
    legacyRetired: true,
    remainders: <MigrationRemainder>[
      MigrationRemainder(
        owner: 'V7-FI',
        reason:
            'root ProviderScope does not install the models presentation entry/override; the panel resolves its runtime source from the binding until it does',
        files: <String>['lib/src/composition/client_app_composition.dart'],
      ),
    ],
  ),
  RegisteredFeatureMigration(
    feature: 'agent_hub',
    binding: 'lib/src/presentation/agent_hub/agent_hub_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/agent_hub/agent_hub_projection_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/agent_hub/agent_hub_presentation_source.dart',
    ],
    composition:
        'lib/src/composition/features/agent_hub/agent_hub_feature_composition.dart',
    wiring: FeatureSourceWiring.providerEntry,
    storeOwner: 'ClientController agent hub owner',
    legacyEntry:
        'lib/src/frontend/features/agent_hub/ui/agent_hub_panel.dart (binding.projection read retired by V7-F6A)',
    legacyCallee: 'AgentHubProjectionProducer',
    newPort:
        'agentHubCatalogProjectionProvider over AgentHubPresentationSource (runtime)',
    behaviorTests: <String>[
      'test/presentation/agent_hub_presentation_source_test.dart',
      'test/agent_hub_binding_projection_test.dart',
      'test/agent_hub_panel_test.dart',
      'test/v7_feature_replacement_closure/feature_view_behavior_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/features/agent_hub/ui'],
    uiConsumption: FeatureUiConsumption.narrowInputs,
    legacyRetired: true,
    remainders: <MigrationRemainder>[
      MigrationRemainder(
        owner: 'V7-FI',
        reason:
            'root ProviderScope does not install the agent hub presentation entry/override; the panel resolves its runtime source from the binding until it does',
        files: <String>['lib/src/composition/client_app_composition.dart'],
      ),
    ],
  ),
  RegisteredFeatureMigration(
    feature: 'targets',
    binding: 'lib/src/presentation/targets/targets_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/targets/targets_projection_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/targets/targets_presentation_source.dart',
    ],
    composition:
        'lib/src/composition/features/targets/targets_feature_composition.dart',
    wiring: FeatureSourceWiring.providerEntry,
    storeOwner: 'ClientController scan/agent target owners',
    legacyEntry:
        'lib/src/frontend/features/targets/ui/targets_panel.dart (binding.projection read retired by V7-F6A)',
    legacyCallee: 'TargetsProjectionProducer',
    newPort:
        'targetsCatalogProjectionProvider over TargetsPresentationSource (runtime)',
    behaviorTests: <String>[
      'test/presentation/targets_presentation_source_test.dart',
      'test/v7_feature_replacement_closure/feature_view_behavior_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/features/targets/ui'],
    uiConsumption: FeatureUiConsumption.narrowInputs,
    legacyRetired: true,
    remainders: <MigrationRemainder>[
      MigrationRemainder(
        owner: 'V7-FI',
        reason:
            'root ProviderScope does not install the targets presentation entry/override; the panel resolves its runtime source from the binding until it does',
        files: <String>['lib/src/composition/client_app_composition.dart'],
      ),
    ],
  ),
  RegisteredFeatureMigration(
    feature: 'skill_hub',
    binding: 'lib/src/presentation/skill_hub/skill_hub_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/skill_hub/skill_hub_projection_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/skill_hub/skill_hub_presentation_sources.dart',
    ],
    composition:
        'lib/src/composition/features/skill_hub/skill_hub_feature_composition.dart',
    wiring: FeatureSourceWiring.providerOverrides,
    storeOwner: 'SkillHubController',
    legacyEntry: 'lib/src/frontend/features/skill_hub/ui/*',
    legacyCallee: 'SkillHubProjectionProducer',
    newPort: 'skill hub catalog source through provider overrides',
    behaviorTests: <String>['test/skill_hub_presentation_sources_test.dart'],
    uiDirectories: <String>['lib/src/frontend/features/skill_hub/ui'],
    uiConsumption: FeatureUiConsumption.narrowInputs,
    legacyRetired: true,
  ),
  RegisteredFeatureMigration(
    feature: 'chrome',
    binding: 'lib/src/presentation/chrome/chrome_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/chrome/chrome_projection_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/chrome/chrome_presentation_source.dart',
    ],
    composition:
        'lib/src/composition/features/chrome/chrome_feature_composition.dart',
    wiring: FeatureSourceWiring.none,
    storeOwner: 'ClientController navigation/notification owners',
    legacyEntry:
        'lib/src/composition/binding_shell_renderer.dart chrome port (renderer still reads chrome.projection)',
    legacyCallee: 'ChromeProjectionProducer',
    newPort: 'ChromePresentationSource (runtime); renderer wiring by V7-FI',
    behaviorTests: <String>[
      'test/presentation/shell_binding_test.dart',
      'test/v7_feature_replacement_closure/source_lifecycle_and_providers_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/shell'],
    uiConsumption: FeatureUiConsumption.rendererPort,
    legacyRetired: false,
    remainders: <MigrationRemainder>[
      MigrationRemainder(
        owner: 'V7-FI',
        reason:
            'chrome runtime source is not installed; the renderer port still reads the legacy chrome projection',
        files: <String>[
          'lib/src/composition/features/chrome/chrome_feature_composition.dart',
          'lib/src/composition/binding_shell_renderer.dart',
        ],
      ),
    ],
  ),
  RegisteredFeatureMigration(
    feature: 'monitoring',
    binding: 'lib/src/presentation/monitoring/monitoring_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/monitoring/monitoring_projection_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/monitoring/monitoring_presentation_source.dart',
    ],
    composition:
        'lib/src/composition/features/monitoring/monitoring_feature_composition.dart',
    wiring: FeatureSourceWiring.providerEntry,
    storeOwner: 'ClientController usage owners',
    legacyEntry:
        'lib/src/frontend/features/agents/ui/agent_usage_panel.dart (binding.projection read retired by V7-F6A)',
    legacyCallee: 'MonitoringProjectionProducer',
    newPort:
        'monitoringUsageProjectionProvider over MonitoringPresentationSource (runtime)',
    behaviorTests: <String>[
      'test/presentation/monitoring_presentation_source_test.dart',
      'test/agent_usage_native_projection_test.dart',
      'test/v7_feature_replacement_closure/feature_view_behavior_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/features/agents/ui'],
    uiConsumption: FeatureUiConsumption.narrowInputs,
    legacyRetired: false,
    remainders: <MigrationRemainder>[
      MigrationRemainder(
        owner: 'V7-FI',
        reason:
            'root ProviderScope does not install the monitoring usage entry/override; the usage panel resolves its runtime source from the binding until it does',
        files: <String>['lib/src/composition/client_app_composition.dart'],
      ),
    ],
  ),
  RegisteredFeatureMigration(
    feature: 'search',
    binding: 'lib/src/presentation/search/search_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/search/search_projection_producer.dart',
      'lib/src/projections/search/search_ranking.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/search/search_presentation_source.dart',
    ],
    composition:
        'lib/src/composition/features/search/search_feature_composition.dart',
    wiring: FeatureSourceWiring.providerOverrides,
    storeOwner: 'ClientController + SearchProjectionProducer',
    legacyEntry:
        'lib/src/frontend/features/agents/ui/agent_conversation_search_palette.dart (binding.projection read retired by V7-F6A)',
    legacyCallee: 'SearchProjectionProducer',
    newPort: 'searchProjectionProvider over SearchPresentationSource (runtime)',
    behaviorTests: <String>[
      'test/conversation_presentation_signals_test.dart',
      'test/agent_conversation_search_palette_test.dart',
      'test/v7_feature_replacement_closure/source_lifecycle_and_providers_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/features/agents/ui'],
    uiConsumption: FeatureUiConsumption.narrowInputs,
    legacyRetired: false,
    remainders: <MigrationRemainder>[
      MigrationRemainder(
        owner: 'V7-FI',
        reason:
            'runtime source override is installed; the remaining shell renderer mapping is retired by FI',
        files: <String>['lib/src/composition/binding_shell_renderer.dart'],
      ),
    ],
  ),
  RegisteredFeatureMigration(
    feature: 'shell',
    binding: 'lib/src/presentation/shell/shell_binding.dart',
    projectionProducers: <String>[
      'lib/src/projections/shell/shell_projection_producer.dart',
      'lib/src/projections/shell/shell_effect_producer.dart',
    ],
    presentationSources: <String>[
      'lib/src/projections/shell/shell_presentation_sources.dart',
    ],
    composition: 'lib/src/composition/client_app_composition.dart',
    wiring: FeatureSourceWiring.none,
    storeOwner:
        'AppearancePreferenceOwner + LocalePreferenceOwner + FunctionalStatusRuntime + ClientNavigationController + LayoutManager + EnvironmentProjectionSource',
    legacyEntry:
        'lib/src/frontend/shell/client_shell.dart (four shell projection builders retired by V7-F6A; the chrome port still reads status/locale)',
    legacyCallee: 'ShellProjectionProducer raw ProjectionSources',
    newPort:
        'shell<Region>ProjectionProvider over ShellPresentationSources (runtime)',
    behaviorTests: <String>[
      'test/presentation/shell_binding_test.dart',
      'test/presentation/shell_projection_producer_test.dart',
      'test/presentation/presentation_replacement_proof_test.dart',
      'test/client_shell_mobile_layout_test.dart',
      'test/client_shell_user_journey_test.dart',
    ],
    uiDirectories: <String>['lib/src/frontend/shell'],
    uiConsumption: FeatureUiConsumption.rendererPort,
    legacyRetired: false,
    remainders: <MigrationRemainder>[
      MigrationRemainder(
        owner: 'V7-FI',
        reason:
            'shell runtime sources are not installed at the root; the shell resolves them from its binding and the chrome port still reads status/locale projections',
        files: <String>[
          'lib/src/composition/client_app_composition.dart',
          'lib/src/composition/binding_shell_renderer.dart',
        ],
      ),
    ],
  ),
];
