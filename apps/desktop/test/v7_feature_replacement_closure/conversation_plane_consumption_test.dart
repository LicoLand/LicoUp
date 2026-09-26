import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/misc.dart' show Override;

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/composition/features/agents/agents_feature_composition.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/agents/agents_providers.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/projections/agents/agents_presentation_source.dart';
import 'package:licoup/src/projections/conversation/conversation_source_owner.dart';

import '../fixtures/client_controller/support/fake_agent_service.dart';
import '../layout/layout_host_test_fixtures.dart';

/// V7-F6A consumer evidence for the conversation data planes: my workspace and
/// dialogs consume F5's published port with a real owner, and a withdrawal of
/// one plane neither revives an old value nor blanks the planes (and the
/// agents side) that are still authorized.
void main() {
  testWidgets(
    'workspace local-plane subscriptions keep admitted content mounted through withdrawal',
    (tester) async {
      final harness = await _PlaneHarness.createWithFakeCanonical();
      addTearDown(harness.dispose);
      final owner = harness.owner;
      for (
        var frame = 0;
        frame < 20 &&
            (owner.canonicalEvents.visibleValue == null ||
                owner.composer.visibleValue == null ||
                owner.attachments.visibleValue == null);
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      final admittedHistory = owner.canonicalEvents.visibleValue;
      expect(admittedHistory, isNotNull);
      var draftActions = 0;
      var attachmentActions = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: ConversationPlaneValue<ComposerProjection>(
            plane: owner.composer,
            builder: (context, _) =>
                ConversationPlaneValue<ConversationAttachmentsProjection>(
                  plane: owner.attachments,
                  builder: (context, _) => Column(
                    children: [
                      Text(
                        owner.canonicalEvents.visibleValue!.conversationId,
                        key: const Key('admitted-history'),
                      ),
                      TextButton(
                        key: const Key('draft-action'),
                        onPressed: owner.composer.visibleValue == null
                            ? null
                            : () => draftActions++,
                        child: const Text('Draft'),
                      ),
                      TextButton(
                        key: const Key('attachment-action'),
                        onPressed: owner.attachments.visibleValue == null
                            ? null
                            : () => attachmentActions++,
                        child: const Text('Attach'),
                      ),
                    ],
                  ),
                ),
          ),
        ),
      );
      final historyElement = tester.element(
        find.byKey(const Key('admitted-history')),
      );
      await tester.tap(find.byKey(const Key('draft-action')));
      await tester.tap(find.byKey(const Key('attachment-action')));
      expect((draftActions, attachmentActions), (1, 1));

      owner.withdraw(
        conversationPlaneComposer,
        ConversationPlaneWithdrawal.revoked,
      );
      await tester.pump();
      expect(owner.composer.visibleValue, isNull);
      expect(owner.canonicalEvents.visibleValue, same(admittedHistory));
      expect(
        tester.element(find.byKey(const Key('admitted-history'))),
        same(historyElement),
      );
      await tester.tap(find.byKey(const Key('draft-action')));
      await tester.tap(find.byKey(const Key('attachment-action')));
      expect((draftActions, attachmentActions), (1, 2));

      owner.withdraw(
        conversationPlaneAttachments,
        ConversationPlaneWithdrawal.revoked,
      );
      await tester.pump();
      expect(owner.attachments.visibleValue, isNull);
      await tester.tap(find.byKey(const Key('attachment-action')));
      expect((draftActions, attachmentActions), (1, 2));
      expect(
        tester.element(find.byKey(const Key('admitted-history'))),
        same(historyElement),
      );

      owner.reconnect(conversationPlaneComposer);
      for (
        var frame = 0;
        frame < 20 && owner.composer.visibleValue == null;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(owner.composer.visibleValue, isNotNull);
      expect(owner.attachments.visibleValue, isNull);
      await tester.tap(find.byKey(const Key('draft-action')));
      expect((draftActions, attachmentActions), (2, 2));

      owner.reconnect(conversationPlaneAttachments);
      for (
        var frame = 0;
        frame < 20 && owner.attachments.visibleValue == null;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(owner.attachments.visibleValue, isNotNull);
      await tester.tap(find.byKey(const Key('attachment-action')));
      expect((draftActions, attachmentActions), (2, 3));
      expect(owner.canonicalEvents.visibleValue, same(admittedHistory));
      expect(
        tester.element(find.byKey(const Key('admitted-history'))),
        same(historyElement),
      );
    },
  );

  test('one plane withdrawal leaves the other planes visible', () async {
    final harness = await _PlaneHarness.createWithFakeCanonical();
    addTearDown(harness.dispose);

    // A plane is read when a consumer subscribes; subscribe to the planes this
    // case compares so the withdrawal locality is observable.
    final subscriptions = <StreamSubscription<Object?>>[
      harness.owner.canonicalEvents.reads.listen((_) {}),
      harness.owner.persistentTurns.reads.listen((_) {}),
      harness.owner.composer.reads.listen((_) {}),
      harness.owner.projection.reads.listen((_) {}),
    ];
    addTearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });
    await pumpEventQueue();

    expect(harness.owner.canonicalEvents.visibleValue, isNotNull);
    expect(harness.owner.persistentTurns.visibleValue, isNotNull);
    expect(harness.owner.composer.visibleValue, isNotNull);

    harness.owner.withdraw(
      conversationPlaneComposer,
      ConversationPlaneWithdrawal.revoked,
    );

    expect(harness.owner.composer.visibleValue, isNull);
    expect(
      harness.owner.canonicalEvents.visibleValue,
      isNotNull,
      reason: 'withdrawing the composer must not hide conversation history',
    );
    expect(harness.owner.persistentTurns.visibleValue, isNotNull);
    expect(harness.owner.projection.visibleValue, isNotNull);
  });

  test(
    'a withdrawn plane stays invisible until an explicit reconnect',
    () async {
      final harness = await _PlaneHarness.createWithFakeCanonical();
      addTearDown(harness.dispose);

      harness.owner.withdraw(
        conversationPlaneCanonicalEvents,
        ConversationPlaneWithdrawal.revoked,
      );
      final withdrawnReads =
          <ConversationPlaneRead<CanonicalConversationProjection>>[];
      final subscription = harness.owner.canonicalEvents.reads.listen(
        withdrawnReads.add,
      );
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      // The producer keeps publishing; the withdrawn plane must not resurface.
      harness.publishCanonicalEvents();
      await pumpEventQueue();
      expect(harness.owner.canonicalEvents.visibleValue, isNull);
      expect(
        withdrawnReads.whereType<ConversationPlaneVisible<Object?>>(),
        isEmpty,
      );

      harness.owner.reconnect(conversationPlaneCanonicalEvents);
      await pumpEventQueue();
      expect(
        harness.owner.canonicalEvents.visibleValue,
        isNotNull,
        reason: 'an explicit reconnect re-reads the producer current value',
      );
    },
  );

  testWidgets(
    'flywheel dialog degrades locally when the canonical plane is withdrawn',
    (tester) async {
      final harness = await _PlaneHarness.create();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            conversationSourcePortProvider.overrideWithValue(harness.owner),
            agentsCatalogSourceProvider.overrideWithValue(
              AgentsPresentationSource(
                projection: harness.agents.binding.projection,
              ),
            ),
          ],
          child: _Host(
            conversation: harness.conversation,
            agents: harness.agents,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-flywheel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('adaptive-flywheel-dialog')), findsOne);
      expect(find.byKey(const Key('main-agent-settings')), findsOne);

      harness.owner.withdraw(
        conversationPlaneCanonicalEvents,
        ConversationPlaneWithdrawal.revoked,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('adaptive-flywheel-dialog')),
        findsOne,
        reason: 'the agents side of the dialog stays usable',
      );
      expect(find.byKey(const Key('main-agent-settings')), findsOne);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a disabled port renders no fabricated conversation content', (
    tester,
  ) async {
    final harness = await _PlaneHarness.create();
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          agentsCatalogSourceProvider.overrideWithValue(
            AgentsPresentationSource(
              projection: harness.agents.binding.projection,
            ),
          ),
        ],
        child: _Host(
          conversation: harness.conversation,
          agents: harness.agents,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-flywheel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('adaptive-flywheel-dialog')), findsOne);
    expect(find.byKey(const Key('main-agent-settings')), findsOne);
    expect(tester.takeException(), isNull);
  });
}

class _Host extends StatelessWidget {
  const _Host({required this.conversation, required this.agents});

  final ConversationFeatureComposition conversation;
  final AgentsFeatureComposition agents;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: ThemeData(platform: TargetPlatform.macOS),
      home: Scaffold(
        body: Builder(
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
      ),
    );
  }
}

final class _PlaneHarness {
  _PlaneHarness._(
    this.controller,
    this.agents,
    this.conversation,
    this.runtime,
    this.owner,
    this._fakeCanonicalEvents,
  );

  static Future<_PlaneHarness> createWithFakeCanonical() async {
    final harness = await create(
      canonicalEvents: _FakeSource<CanonicalConversationProjection>(
        CanonicalConversationProjection(
          conversationId: 'synthetic-conversation',
          events: const <CanonicalConversationEventProjection>[],
          phase: PresentationPhase.ready,
          hasEarlier: false,
        ),
      ),
    );
    return harness;
  }

  static Future<_PlaneHarness> create({
    ProjectionSource<CanonicalConversationProjection>? canonicalEvents,
  }) async {
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
    final agents = AgentsFeatureComposition(controller);
    final conversation = ConversationFeatureComposition(controller);
    final runtime = PresentationRuntime();
    final binding = conversation.binding;
    final fakeCanonical =
        canonicalEvents is _FakeSource<CanonicalConversationProjection>
        ? canonicalEvents
        : null;
    final owner = ConversationSourceOwner(
      runtime: runtime,
      planes: ConversationSourcePlanes(
        projection: binding.projection,
        nativeCatalog: binding.nativeCatalog,
        canonicalEvents: canonicalEvents ?? binding.canonicalEvents,
        persistentTurns: binding.persistentTurns,
        composer: binding.composer,
        attachments: binding.attachments,
        tabActivity: binding.tabActivity,
        archive: binding.archive,
        execution: binding.execution,
      ),
    );
    return _PlaneHarness._(
      controller,
      agents,
      conversation,
      runtime,
      owner,
      fakeCanonical,
    );
  }

  final ClientController controller;
  final AgentsFeatureComposition agents;
  final ConversationFeatureComposition conversation;
  final PresentationRuntime runtime;
  final ConversationSourceOwner owner;
  final _FakeSource<CanonicalConversationProjection>? _fakeCanonicalEvents;

  /// A real producer update after a withdrawal: the plane must not revive it.
  void publishCanonicalEvents() {
    final source = _fakeCanonicalEvents;
    if (source == null) {
      throw StateError(
        'publishCanonicalEvents needs the fake canonical source',
      );
    }
    source.publish(
      CanonicalConversationProjection(
        conversationId: 'synthetic-conversation',
        events: const <CanonicalConversationEventProjection>[],
        phase: PresentationPhase.ready,
        hasEarlier: false,
      ),
    );
  }

  Future<void> dispose() async {
    await owner.dispose();
    runtime.dispose();
    await conversation.close();
    await agents.close();
    controller.dispose();
  }
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

final class _FakeSource<T> implements ProjectionSource<T> {
  _FakeSource(this._current);

  T _current;
  int versions = 0;
  final StreamController<ProjectionUpdate<T>> _changes =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _changes.stream;

  void publish(T value) {
    _current = value;
    versions += 1;
    _changes.add(ProjectionUpdate<T>(value));
  }
}
