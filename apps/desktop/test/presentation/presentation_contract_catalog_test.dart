import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_effect.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_intent.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/chrome/chrome_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_effect.dart';
import 'package:licoup/src/presentation/chrome/chrome_intent.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/models/models_effect.dart';
import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_effect.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_intent.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_effect.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/search/search_binding.dart';
import 'package:licoup/src/presentation/search/search_effect.dart';
import 'package:licoup/src/presentation/search/search_intent.dart';
import 'package:licoup/src/presentation/search/search_projection.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_effect.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/presentation/shell/shell_binding.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/presentation/appearance/appearance_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/layout/layout_projection.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_effect.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';
import 'package:licoup/src/presentation/targets/targets_effect.dart';
import 'package:licoup/src/presentation/targets/targets_intent.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';

void main() {
  test('unordered semantic maps preserve the equality/hash contract', () {
    final first = SettingsResourceUsageProjection(
      supported: true,
      clientRssBytes: 1,
      totalMemoryBytes: 4,
      agentRssBytes: const {'alpha': 2, 'beta': 3},
    );
    final second = SettingsResourceUsageProjection(
      supported: true,
      clientRssBytes: 1,
      totalMemoryBytes: 4,
      agentRssBytes: const {'beta': 3, 'alpha': 2},
    );

    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });

  test('catalog exposes every destination and shared semantic binding', () {
    final bindings = <Object>[
      AgentsBinding(
        projection: _Projection(
          AgentsProjection(
            targets: const [],
            selectedAgentId: '',
            workingDirectoryLabel: '',
            phase: PresentationPhase.idle,
          ),
        ),
        intents: _Intents<AgentsIntent>(),
        effects: _Effects<AgentsEffect>(),
      ),
      MonitoringBinding(
        projection: _Projection(
          MonitoringProjection(
            usage: const [],
            quotas: const [],
            historyDays: 30,
            phase: PresentationPhase.idle,
          ),
        ),
        intents: _Intents<MonitoringIntent>(),
        effects: _Effects<MonitoringEffect>(),
      ),
      SkillHubBinding(
        projection: _Projection(
          SkillHubProjection(
            skills: const [],
            query: '',
            phase: PresentationPhase.idle,
          ),
        ),
        intents: _Intents<SkillHubIntent>(),
        effects: _Effects<SkillHubEffect>(),
      ),
      PluginManagementBinding(
        projection: _Projection(
          PluginManagementProjection(
            plugins: const [],
            workflows: const [],
            phase: PresentationPhase.idle,
          ),
        ),
        intents: _Intents<PluginManagementIntent>(),
        effects: _Effects<PluginManagementEffect>(),
      ),
      MobileRelayBinding(
        projection: _Projection(
          MobileRelayProjection(
            peers: const [],
            approvals: const [],
            transfers: const [],
            pairingCode: '',
            stationLabel: '',
            phase: PresentationPhase.idle,
          ),
        ),
        intents: _Intents<MobileRelayIntent>(),
        effects: _Effects<MobileRelayEffect>(),
      ),
      ModelsBinding(
        projection: _Projection(
          ModelsProjection(
            providers: const [],
            gatewayEnabled: false,
            gatewayStateLabel: '',
            phase: PresentationPhase.idle,
          ),
        ),
        intents: _Intents<ModelsIntent>(),
        effects: _Effects<ModelsEffect>(),
      ),
      SettingsBinding(
        projection: _Projection(
          SettingsProjection(
            appearancePresetId: '',
            appearancePresets: const [],
            localeChoices: const [],
            layoutChoices: const [],
            archivedConversations: const [],
            layoutPhase: PresentationPhase.ready,
            layoutFailureReasonCode: '',
            appearancePresetDirectoryPath: '',
            appearancePresetLoadErrorCount: 0,
            portableDataPath: '',
            snapshotRootPath: '',
            savingSnapshotRoot: false,
            clientLogExportPath: '',
            exportingClientLogs: false,
            clientUpdate: const SettingsClientUpdateProjection(
              phase: ClientUpdatePhase.idle,
              runningVersion: '',
              runningReleaseTrack: ReleaseTrack.nightly,
              targetReleaseTrack: ReleaseTrack.nightly,
              availableVersion: '',
              githubReleaseUrl: '',
              artifactSha256: '',
              updateAvailable: false,
            ),
            clientUpdateRepo: '',
            catalog: const SettingsCatalogProjection(
              phase: SettingsCatalogPhase.disabled,
              reasonCode: '',
              busy: false,
              partitionCount: 0,
              pendingInvalidationCount: 0,
              appliedCohortCount: 0,
              uiObservedRevision: -1,
            ),
            phase: PresentationPhase.idle,
          ),
        ),
        resourceUsage: _Projection(
          SettingsResourceUsageProjection.unsupported(),
        ),
        autostart: _Projection(const SettingsAutostartProjection.loading()),
        intents: _Intents<SettingsIntent>(),
        effects: _Effects<SettingsEffect>(),
      ),
      AgentHubBinding(
        projection: _Projection(
          AgentHubProjection(entries: const [], phase: PresentationPhase.idle),
        ),
        intents: _Intents<AgentHubIntent>(),
        effects: _Effects<AgentHubEffect>(),
      ),
      _conversationBinding(),
      TargetsBinding(
        projection: _Projection(
          TargetsProjection(targets: const [], phase: PresentationPhase.idle),
        ),
        intents: _Intents<TargetsIntent>(),
        effects: _Effects<TargetsEffect>(),
      ),
      SearchBinding(
        projection: _Projection(
          SearchProjection(
            query: '',
            results: const [],
            open: false,
            phase: PresentationPhase.idle,
          ),
        ),
        intents: _Intents<SearchIntent>(),
        effects: _Effects<SearchEffect>(),
      ),
      ChromeBinding(
        projection: _Projection(
          ChromeProjection(
            destinations: const [],
            notifications: const [],
            auxiliaryPanelOpen: false,
            searchAvailable: true,
          ),
        ),
        intents: _Intents<ChromeIntent>(),
        effects: _Effects<ChromeEffect>(),
      ),
      _shellBinding(),
    ];

    expect(bindings, hasLength(13));
    expect(ClientSection.values, hasLength(8));
  });

  test('projection collections are immutable snapshots', () {
    final mutable = <AgentTargetProjection>[
      const AgentTargetProjection(
        id: 'agent-a',
        displayName: 'Agent A',
        available: true,
        pinned: false,
        capabilityLabel: 'Structured stream',
      ),
    ];
    final projection = AgentsProjection(
      targets: mutable,
      selectedAgentId: 'agent-a',
      workingDirectoryLabel: 'Project',
      phase: PresentationPhase.ready,
    );

    mutable.clear();
    expect(projection.targets, hasLength(1));
    expect(
      () => projection.targets.add(projection.targets.first),
      throwsUnsupportedError,
    );
  });

  test(
    'stable presentation sources have no renderer or implementation leak',
    () {
      final files = Directory('lib/src/presentation')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      const forbidden = <String>[
        'package:flutter',
        '/application/',
        '/backend/',
        '/platform/',
        '/projections/',
        '/composition/',
        'ClientController',
        'ChangeNotifier',
        'ValueNotifier',
        'ValueListenable',
        'BuildContext',
        'Widget',
      ];

      for (final file in files) {
        final source = file.readAsStringSync();
        for (final token in forbidden) {
          expect(source, isNot(contains(token)), reason: token);
        }
      }
    },
  );
}

ConversationBinding _conversationBinding() => ConversationBinding(
  projection: _Projection(
    const ConversationProjection(
      authority: ConversationAuthority.nativeCatalog,
      conversationId: '',
      membershipId: '',
    ),
  ),
  nativeCatalog: _Projection(
    NativeConversationCatalogProjection(
      sessions: const [],
      hasMore: false,
      phase: PresentationPhase.idle,
    ),
  ),
  canonicalEvents: _Projection(
    CanonicalConversationProjection(
      conversationId: '',
      events: const [],
      hasEarlier: false,
      phase: PresentationPhase.idle,
    ),
  ),
  persistentTurns: _Projection(
    PersistentTurnProjection(conversationId: '', memberships: const []),
  ),
  composer: _Projection(
    ComposerProjection(
      conversationId: '',
      draft: '',
      inputEnabled: true,
      sendLabel: 'Send',
    ),
  ),
  attachments: _Projection(
    ConversationAttachmentsProjection(
      conversationId: '',
      attachments: const [],
      acceptsImages: false,
    ),
  ),
  tabActivity: _Projection(
    ConversationTabActivityProjection(
      conversationId: '',
      active: true,
      unreadCount: 0,
      requiresAttention: false,
    ),
  ),
  notifications: _Projection(
    ConversationNotificationsProjection(notices: const []),
  ),
  archive: _Projection(
    ConversationArchiveProjection(
      conversations: const [],
      phase: PresentationPhase.idle,
    ),
  ),
  intents: _Intents<ConversationIntent>(),
  effects: _Effects<ConversationEffect>(),
);

ShellBinding _shellBinding() {
  final environment = LayoutEnvironment.fromConstraints(
    surface: LayoutRuntimeSurface.desktop,
    width: 900,
    height: 700,
    textScale: 1,
  );
  return ShellBinding(
    appearance: _Projection(
      AppearanceProjection(presetId: 'default', presets: const []),
    ),
    locale: _Projection(const LocaleProjection('system')),
    layout: _Projection(
      LayoutProjection(
        LayoutSelectionState(
          committedId: LayoutProfileId.parse('messaging'),
          effectiveId: LayoutProfileId.parse('messaging'),
          status: LayoutSelectionStatus.stable,
          surface: LayoutRuntimeSurface.desktop,
          viewport: LayoutViewportClass.medium,
          operationEpoch: 0,
        ),
      ),
    ),
    environment: _Projection(
      EnvironmentProjection(
        environment: environment,
        runtimeSurface: LayoutRuntimeSurface.desktop,
      ),
    ),
    navigation: _Projection(
      NavigationProjection(
        destination: ClientSection.agents,
        destinations: ClientSection.values,
      ),
    ),
    status: _Projection(
      const StatusProjection(
        messageChinese: '',
        messageEnglish: '',
        caption: '',
        errorCode: '',
      ),
    ),
    intents: _Intents<ShellIntent>(),
    effects: _Effects<ShellEffect>(),
  );
}

final class _Projection<T> implements ProjectionSource<T> {
  const _Projection(this.current);

  @override
  final T current;

  @override
  Stream<ProjectionUpdate<T>> get changes =>
      Stream<ProjectionUpdate<T>>.empty();
}

final class _Intents<I> implements IntentSink<I> {
  @override
  void send(I intent) {}
}

final class _Effects<E> implements EffectSource<E> {
  @override
  Stream<E> get effects => Stream<E>.empty();
}
