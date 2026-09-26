import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/misc.dart' show Override;

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/composition/features/agents/agents_feature_composition.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/mobile_widgets_page.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_pairing_channels.dart';
import 'package:licoup/src/frontend/features/targets/ui/targets_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/agents/agents_providers.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/models/models_effect.dart';
import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/models/models_providers.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_effect.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_intent.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_providers.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';
import 'package:licoup/src/presentation/targets/targets_effect.dart';
import 'package:licoup/src/presentation/targets/targets_intent.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';
import 'package:licoup/src/presentation/targets/targets_resources.dart';
import 'package:licoup/src/presentation/targets/targets_providers.dart';
import 'package:licoup/src/projections/agents/agents_presentation_source.dart';

import '../fixtures/client_controller/support/fake_agent_service.dart';
import '../layout/layout_host_test_fixtures.dart';
import 'package:licoup/src/projections/models/models_presentation_source.dart';
import 'package:licoup/src/projections/monitoring/monitoring_presentation_source.dart';
import 'package:licoup/src/projections/targets/targets_presentation_source.dart';

/// V7-F6A NODE-04: the migrated views driven by composition-injected runtime
/// sources. Every case uses a real user action or a real projection update and
/// asserts the visible outcome plus the exact number of dispatched commands.
/// The counter-examples prove that a failing or revoked source never falls
/// back to the legacy owner value that the binding still holds.
void main() {
  testWidgets('targets panel follows the projection and refreshes once', (
    tester,
  ) async {
    final producer = _FakeSource<TargetsProjection>(
      _targetsProjection(id: 'first', name: 'First target'),
    );
    final intents = _RecordingIntents<TargetsIntent>();
    final binding = TargetsBinding(
      projection: producer,
      intents: intents,
      effects: const _EmptyEffects<TargetsEffect>(),
    );

    await _pump(
      tester,
      TargetsPanel(binding: binding),
      overrides: <Override>[
        targetsCatalogSourceProvider.overrideWithValue(
          TargetsPresentationSource(projection: producer),
        ),
      ],
    );
    await _settleProjection(tester);
    expect(find.byKey(const Key('target-projection-first')), findsOne);

    producer.publish(_targetsProjection(id: 'second', name: 'Second target'));
    await _settleProjection(tester);
    expect(find.byKey(const Key('target-projection-second')), findsOne);
    expect(find.byKey(const Key('target-projection-first')), findsNothing);

    await tester.tap(find.byKey(const Key('targets-refresh')));
    await tester.pump();
    expect(intents.sent.whereType<ScanTargets>(), hasLength(1));

    // The manual target dialog reads its options from the same runtime value.
    await tester.tap(find.byKey(const Key('targets-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manual-target-dialog')), findsOne);
    expect(intents.sent, hasLength(1));
  });

  testWidgets('revoked targets region hides the value the owner still has', (
    tester,
  ) async {
    final producer = _FakeSource<TargetsProjection>(
      _targetsProjection(id: 'first', name: 'First target'),
    );
    final binding = TargetsBinding(
      projection: producer,
      intents: _RecordingIntents<TargetsIntent>(),
      effects: const _EmptyEffects<TargetsEffect>(),
    );

    await _pump(
      tester,
      TargetsPanel(binding: binding),
      overrides: <Override>[
        targetsCatalogSourceProvider.overrideWithValue(
          TargetsPresentationSource(projection: producer),
        ),
      ],
    );
    await _settleProjection(tester);
    expect(find.byKey(const Key('target-projection-first')), findsOne);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(TargetsPanel)),
      listen: false,
    );
    container
        .read(presentationRuntimeProvider)
        .revoke(targetsCatalogFields.resource);
    await _settleProjection(tester);

    // The legacy owner still returns the target; the view must not show it.
    expect(producer.current.targets.single.id, 'first');
    expect(find.byKey(const Key('target-projection-first')), findsNothing);
  });

  testWidgets('a failing source hides the owner value instead of reviving it', (
    tester,
  ) async {
    final producer = _FakeSource<ModelsProjection>(
      _modelsProjection(stateLabel: 'ready'),
    );
    final binding = ModelsBinding(
      projection: producer,
      intents: _RecordingIntents<ModelsIntent>(),
      effects: const _EmptyEffects<ModelsEffect>(),
    );

    await _pump(
      tester,
      MobilePairingChannels(binding: binding),
      overrides: <Override>[
        modelsCatalogSourceProvider.overrideWithValue(
          const _FailingSource<ModelsProjection>(),
        ),
      ],
    );
    await _settleProjection(tester);

    expect(producer.current.telegram.stateLabel, 'ready');
    expect(find.text('ready'), findsNothing);
  });

  testWidgets('mobile widgets page refreshes once per user action', (
    tester,
  ) async {
    final producer = _FakeSource<MonitoringProjection>(_monitoringProjection());
    final intents = _RecordingIntents<MonitoringIntent>();
    final binding = MonitoringBinding(
      projection: producer,
      intents: intents,
      effects: const _EmptyEffects<MonitoringEffect>(),
    );

    await _pump(
      tester,
      MobileWidgetsPage(binding: binding),
      overrides: <Override>[
        monitoringUsageSourceProvider.overrideWithValue(
          MonitoringPresentationSource(projection: producer),
        ),
      ],
    );
    await _settleProjection(tester);
    final automaticStarts = intents.sent
        .whereType<StartAutomaticMonitoring>()
        .length;
    final refreshesBefore = intents.sent.whereType<RefreshMonitoring>().length;

    await tester.tap(find.byKey(const Key('mobile-widgets-refresh-usage')));
    await tester.pump();
    expect(
      intents.sent.whereType<RefreshMonitoring>(),
      hasLength(refreshesBefore + 1),
    );
    expect(
      intents.sent.whereType<StartAutomaticMonitoring>(),
      hasLength(automaticStarts),
      reason: 'a manual refresh must not restart automatic monitoring',
    );

    producer.publish(_monitoringProjection(refreshing: true));
    await _settleProjection(tester);
    expect(find.byKey(const Key('mobile-widgets-refresh-usage')), findsOne);
  });

  testWidgets('usage panel refreshes through exactly one command', (
    tester,
  ) async {
    final producer = _FakeSource<MonitoringProjection>(_monitoringProjection());
    final intents = _RecordingIntents<MonitoringIntent>();
    final binding = MonitoringBinding(
      projection: producer,
      intents: intents,
      effects: const _EmptyEffects<MonitoringEffect>(),
    );

    await _pump(
      tester,
      AgentUsagePanel(binding: binding, autoLoad: false),
      overrides: <Override>[
        monitoringUsageSourceProvider.overrideWithValue(
          MonitoringPresentationSource(projection: producer),
        ),
      ],
    );
    await _settleProjection(tester);
    expect(intents.sent, isEmpty);

    producer.publish(_monitoringProjection(refreshing: true));
    await _settleProjection(tester);
    await tester.tap(find.byKey(const Key('agent-usage-refresh')));
    await tester.pump();
    expect(
      intents.sent.whereType<RefreshMonitoring>(),
      isEmpty,
      reason: 'the refresh control is disabled while the usage refreshes',
    );

    producer.publish(_monitoringProjection());
    await _settleProjection(tester);
    await tester.tap(find.byKey(const Key('agent-usage-refresh')));
    await tester.pump();
    expect(intents.sent.whereType<RefreshMonitoring>(), hasLength(1));
  });

  testWidgets('chat channels follow the model projection and refresh once', (
    tester,
  ) async {
    // The chat channels column is hosted inside a scrollable in production;
    // give the test surface enough height for its natural size.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final producer = _FakeSource<ModelsProjection>(
      _modelsProjection(stateLabel: 'ready'),
    );
    final intents = _RecordingIntents<ModelsIntent>();
    final binding = ModelsBinding(
      projection: producer,
      intents: intents,
      effects: const _EmptyEffects<ModelsEffect>(),
    );

    await _pump(
      tester,
      MobilePairingChannels(binding: binding),
      overrides: <Override>[
        modelsCatalogSourceProvider.overrideWithValue(
          ModelsPresentationSource(projection: producer),
        ),
      ],
    );
    await _settleProjection(tester);
    expect(find.byKey(const Key('telegram-channel-card')), findsOne);
    expect(find.text('ready'), findsOne);
    final refreshesBefore = intents.sent
        .whereType<RefreshTelegramChannel>()
        .length;

    producer.publish(_modelsProjection(stateLabel: 'needs token'));
    await _settleProjection(tester);
    expect(find.text('needs token'), findsOne);

    await tester.tap(find.byKey(const Key('models-chat-channels-refresh')));
    await tester.pump();
    expect(
      intents.sent.whereType<RefreshTelegramChannel>(),
      hasLength(refreshesBefore + 1),
    );
  });

  testWidgets('flywheel dialog follows the agents projection', (tester) async {
    final layoutRuntime = buildFixtureLayoutRuntime();
    final preferences = _MemoryPreferencesRepository();
    final controller = ClientController(
      agentService: FakeAgentService(),
      layoutCatalog: layoutRuntime.catalog,
      layoutManager: LayoutManager(
        catalog: layoutRuntime.catalog,
        preferencesRepository: preferences,
        canonicalFallback: preferences.value,
      ),
    );
    await controller.layoutManager.initialize();
    addTearDown(controller.dispose);
    final agents = AgentsFeatureComposition(controller);
    final conversation = ConversationFeatureComposition(controller);

    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          key: const Key('open-flywheel'),
          onPressed: () => showAdaptiveFlywheelDialog(
            context,
            conversation: conversation.binding,
            agents: agents.binding,
          ),
          child: const Text('open'),
        ),
      ),
      overrides: <Override>[
        agentsCatalogSourceProvider.overrideWithValue(
          AgentsPresentationSource(projection: agents.binding.projection),
        ),
      ],
    );
    await tester.tap(find.byKey(const Key('open-flywheel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('adaptive-flywheel-dialog')), findsOne);
    expect(find.byKey(const Key('main-agent-settings')), findsOne);

    // A real controller update flows through the projection provider into the
    // open dialog without rebuilding it into an error state.
    controller.scannedTargets = const <TargetCandidate>[];
    await _settleProjection(tester);
    expect(find.byKey(const Key('adaptive-flywheel-dialog')), findsOne);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required List<Override> overrides,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

/// Pumps until the injected source has installed its snapshot and the widget
/// rebuilt from it.
Future<void> _settleProjection(WidgetTester tester) async {
  for (var attempt = 0; attempt < 32; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

TargetsProjection _targetsProjection({
  required String id,
  required String name,
}) => TargetsProjection(
  targets: <TargetProjectionItem>[
    TargetProjectionItem(
      id: id,
      name: name,
      typeLabel: 'CLI',
      readinessLabel: 'ready',
      detail: 'synthetic',
      locationLabel: '/synthetic',
      configured: true,
      pinned: false,
      selected: false,
    ),
  ],
  manualTargetOptions: const <ManualTargetOptionProjection>[
    ManualTargetOptionProjection(id: 'codex', label: 'Codex'),
  ],
  phase: PresentationPhase.ready,
);

MonitoringProjection _monitoringProjection({
  PresentationPhase phase = PresentationPhase.ready,
  bool refreshing = false,
}) => MonitoringProjection(
  usage: const <PresentationMetric>[],
  quotas: const <PresentationMetric>[],
  historyDays: 7,
  phase: phase,
  refreshing: refreshing,
  report: AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: '2026-09-21T00:00:00Z',
    summary: const <String, dynamic>{'totalTokens': 1200},
    agents: const <AgentUsageAgentSummary>[],
    warnings: const <String>[],
  ),
);

ModelsProjection _modelsProjection({required String stateLabel}) =>
    ModelsProjection(
      providers: const <ModelProviderProjection>[],
      gatewayEnabled: false,
      gatewayStateLabel: '',
      telegram: TelegramProjection(
        stateLabel: stateLabel,
        configured: false,
        tokenSourceLabel: 'none',
        pairings: const <TelegramPairingProjection>[],
        chats: const <TelegramChatProjection>[],
      ),
      phase: PresentationPhase.ready,
    );

final class _FakeSource<T> implements ProjectionSource<T> {
  _FakeSource(this._current);

  T _current;
  final StreamController<ProjectionUpdate<T>> _changes =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _changes.stream;

  void publish(T value) {
    _current = value;
    _changes.add(ProjectionUpdate<T>(value));
  }
}

/// A source whose authority is gone: opening it fails, so the runtime can
/// never install a snapshot and the view must stay on the error state.
final class _FailingSource<T> implements PresentationSource<T> {
  const _FailingSource();

  @override
  ResourceFieldGroup<T> get fieldGroup =>
      throw UnsupportedError('field group is never read from a failing source');

  @override
  Future<SourceObservation<T>> open() =>
      Future<SourceObservation<T>>.error(StateError('source unavailable'));
}

final class _RecordingIntents<T> implements IntentSink<T> {
  final List<T> sent = <T>[];

  @override
  void send(T intent) => sent.add(intent);
}

final class _EmptyEffects<T> implements EffectSource<T> {
  const _EmptyEffects();

  @override
  Stream<T> get effects => const Stream<Never>.empty().cast<T>();
}

final class _MemoryPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences value = PresentationPreferences(
    layoutProfileId: LayoutProfileId.parse('dashboard'),
    appearancePresetId: 'default-system',
    localePreference: LocalePreference.system,
  );

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: value);

  @override
  Future<PresentationPreferences> setReduceMotion(bool enabled) async =>
      value = value.copyWith(reduceMotion: enabled);

  @override
  Future<PresentationPreferences> setLoadingEffect(String id) async =>
      value = value.copyWith(loadingEffectId: id);

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async =>
      value = value.copyWith(appearancePresetId: id);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async =>
      value = value.copyWith(layoutProfileId: id);

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => value = value.copyWith(localePreference: preference);
}
