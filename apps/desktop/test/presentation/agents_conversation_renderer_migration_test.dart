import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_search_palette.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_chrome_tabs.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_notification_bell.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/chrome/chrome_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_effect.dart';
import 'package:licoup/src/presentation/chrome/chrome_intent.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/search/search_binding.dart';
import 'package:licoup/src/presentation/search/search_effect.dart';
import 'package:licoup/src/presentation/search/search_intent.dart';
import 'package:licoup/src/presentation/search/search_projection.dart';

import '../layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets(
    'native workspace renders the shared persistent turn without truncation '
    'and sends a steer through the conversation binding',
    (tester) async {
      final messages = [
        for (var index = 0; index < 121; index += 1)
          AgentConversationMessage(
            id: 'message-$index',
            role: index.isEven ? 'user' : 'assistant',
            text: 'message $index',
            createdAt: '2026-01-01T00:00:00Z',
          ),
      ];
      final session = AgentConversationSession(
        id: 'session-1',
        agentId: 'codex',
        title: 'Persistent session',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        messages: const [],
      );
      final conversationIntents = _RecordingIntentSink<ConversationIntent>();
      final bindings = _RendererBindings(
        session: session,
        messages: messages,
        conversationIntents: conversationIntents,
      );

      await tester.pumpWidget(_host(bindings.workspace));
      await tester.pump();

      final pane = tester.widget<AgentConversationActivePane>(
        find.byType(AgentConversationActivePane),
      );
      expect(pane.state.liveMessages, hasLength(121));
      expect(pane.state.liveMessages.first.text, 'message 0');
      expect(pane.state.liveMessages.last.text, 'message 120');
      expect(pane.state.turnActive, isTrue);

      expect(await pane.actions.onSend('steer while waiting'), isTrue);
      final sent = conversationIntents.values
          .whereType<PostConversationMessage>();
      expect(sent, hasLength(1));
      expect(sent.single.conversationId, 'session-1');
      expect(sent.single.content, 'steer while waiting');
      expect(sent.single.dispatchCanonical, isFalse);
      expect(
        conversationIntents.values.whereType<InterruptConversationTurn>(),
        isEmpty,
      );
    },
  );

  testWidgets(
    'Chrome tabs render and select native catalog sessions by intent',
    (tester) async {
      final session = AgentConversationSession(
        id: 'session-1',
        agentId: 'codex',
        title: 'Persistent session',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        messages: const [],
      );
      final conversationIntents = _RecordingIntentSink<ConversationIntent>();
      final bindings = _RendererBindings(
        session: session,
        messages: const [],
        conversationIntents: conversationIntents,
      );

      await tester.pumpWidget(
        _host(
          SizedBox(
            height: 60,
            child: MessagingConversationTabStrip(
              agents: bindings.agents,
              conversation: bindings.conversation,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('messaging-chrome-tab-session-1')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('messaging-chrome-tab-session-1')));
      await tester.pump(const Duration(milliseconds: 400));
      final selection = bindings.agentsIntents.values
          .whereType<SelectAgentConversationSession>()
          .single;
      expect(selection.agentId, 'codex');
      expect(selection.sessionId, 'session-1');
      expect(selection.nativeSessionId, isEmpty);
      expect(
        conversationIntents.values.whereType<SelectConversationSession>(),
        isEmpty,
      );
    },
  );

  testWidgets('search palette consumes projection results and emits intents', (
    tester,
  ) async {
    final source = _MutableProjection(
      SearchProjection(
        query: '',
        results: const [],
        open: true,
        phase: PresentationPhase.ready,
      ),
    );
    addTearDown(source.close);
    final intents = _RecordingIntentSink<SearchIntent>();
    final binding = SearchBinding(
      projection: source,
      intents: intents,
      effects: const _EmptyEffects<SearchEffect>(),
    );

    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                unawaited(showAgentConversationSearchPalette(context, binding)),
            child: const Text('Search'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('agent-conversation-search-field')),
      'alpha',
    );
    expect(intents.values.whereType<UpdateSearchQuery>().last.query, 'alpha');

    source.publish(
      SearchProjection(
        query: 'alpha',
        results: const [
          SearchResultProjection(
            id: 'session-1',
            title: 'Alpha',
            subtitle: 'Codex',
            destination: ClientSection.agents,
            resultKind: 'conversation',
          ),
        ],
        open: true,
        phase: PresentationPhase.ready,
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('agent-conversation-search-session-1')),
    );
    await tester.pumpAndSettle();
    expect(
      intents.values.whereType<SelectSearchResult>().last.resultId,
      'session-1',
    );
    expect(intents.values.whereType<DismissSearch>(), isNotEmpty);
  });

  testWidgets(
    'Chrome notification bell renders and dismisses binding notices',
    (tester) async {
      final intents = _RecordingIntentSink<ChromeIntent>();
      final binding = ChromeBinding(
        projection: _FixedProjection(
          ChromeProjection(
            destinations: const [],
            notifications: const [
              PresentationNotice(
                id: 'notice-1',
                title: 'Runtime',
                message: 'Needs attention',
                severity: PresentationNoticeSeverity.warning,
              ),
            ],
            auxiliaryPanelOpen: false,
            searchAvailable: true,
          ),
        ),
        intents: intents,
        effects: const _EmptyEffects<ChromeEffect>(),
      );

      await tester.pumpWidget(
        _host(Center(child: MessagingNotificationBell(chrome: binding))),
      );
      expect(
        find.byKey(const Key('messaging-notification-bell-badge')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('messaging-notification-bell')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const Key('messaging-operation-notification-dismiss-notice-1'),
        ),
      );
      expect(
        intents.values
            .whereType<DismissChromeNotification>()
            .single
            .notificationId,
        'notice-1',
      );
    },
  );
}

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: LicoStrings.supportedLocales,
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  theme: buildLicoTheme(platformBrightness: Brightness.dark),
  home: Scaffold(
    body: FixtureLayoutPresentationScope(
      child: SizedBox(width: 1000, height: 700, child: child),
    ),
  ),
);

final class _RendererBindings {
  _RendererBindings({
    required AgentConversationSession session,
    required List<AgentConversationMessage> messages,
    required _RecordingIntentSink<ConversationIntent> conversationIntents,
  }) {
    final target = TargetCandidate(
      target: 'codex',
      label: 'Codex',
      kind: 'cli',
      status: TargetCandidateStatus.detected,
      configured: true,
      confidence: 1,
      adapterStatus: 'implemented',
    );
    agents = AgentsBinding(
      projection: _FixedProjection(
        AgentsProjection(
          targets: const [
            AgentTargetProjection(
              id: 'codex',
              displayName: 'Codex',
              available: true,
              pinned: false,
              capabilityLabel: 'ready',
            ),
          ],
          targetDetails: [target],
          selectedAgentId: 'codex',
          workingDirectoryLabel: '',
          phase: PresentationPhase.ready,
        ),
      ),
      intents: agentsIntents,
      effects: const _EmptyEffects<AgentsEffect>(),
    );
    conversation = ConversationBinding(
      projection: const _FixedProjection(
        ConversationProjection(
          authority: ConversationAuthority.nativeCatalog,
          conversationId: 'session-1',
          membershipId: 'membership-1',
        ),
      ),
      nativeCatalog: _FixedProjection(
        NativeConversationCatalogProjection(
          sessions: const [
            NativeConversationSessionProjection(
              id: 'session-1',
              title: 'Persistent session',
              updatedLabel: 'now',
              selected: true,
            ),
          ],
          nativeSessions: [session],
          hasMore: false,
          phase: PresentationPhase.ready,
        ),
      ),
      canonicalEvents: _FixedProjection(
        CanonicalConversationProjection(
          conversationId: '',
          events: const [],
          hasEarlier: false,
          phase: PresentationPhase.ready,
        ),
      ),
      persistentTurns: _FixedProjection(
        PersistentTurnProjection(
          conversationId: 'session-1',
          memberships: [
            MembershipTurnProjection(
              membershipId: 'membership-1',
              agentLabel: 'Codex',
              phase: PersistentTurnPhase.waiting,
              inputEnabled: true,
              liveParts: const [],
              messages: messages,
              participantAgentId: 'codex',
              participantRole: 'assistant',
            ),
          ],
        ),
      ),
      composer: _FixedProjection(
        ComposerProjection(
          conversationId: 'session-1',
          draft: '',
          inputEnabled: true,
          sendLabel: 'Send',
        ),
      ),
      attachments: _FixedProjection(
        ConversationAttachmentsProjection(
          conversationId: 'session-1',
          attachments: const [],
          acceptsImages: false,
        ),
      ),
      tabActivity: _FixedProjection(
        ConversationTabActivityProjection(
          conversationId: 'session-1',
          active: true,
          unreadCount: 0,
          requiresAttention: false,
        ),
      ),
      notifications: _FixedProjection(
        ConversationNotificationsProjection(notices: const []),
      ),
      archive: _FixedProjection(
        ConversationArchiveProjection(
          conversations: const [],
          phase: PresentationPhase.ready,
        ),
      ),
      intents: conversationIntents,
      effects: const _EmptyEffects<ConversationEffect>(),
    );
    relay = MobileRelayBinding(
      projection: _FixedProjection(
        MobileRelayProjection(
          peers: const [],
          approvals: const [],
          transfers: const [],
          pairingCode: '',
          stationLabel: '',
          phase: PresentationPhase.ready,
        ),
      ),
      intents: _RecordingIntentSink<MobileRelayIntent>(),
      effects: const _EmptyEffects<MobileRelayEffect>(),
    );
  }

  late final AgentsBinding agents;
  final agentsIntents = _RecordingIntentSink<AgentsIntent>();
  late final ConversationBinding conversation;
  late final MobileRelayBinding relay;

  Widget get workspace => AgentConversationWorkspace(
    agents: agents,
    conversation: conversation,
    relay: relay,
    onAddTarget: () {},
  );
}

final class _FixedProjection<T> implements ProjectionSource<T> {
  const _FixedProjection(this.current);

  @override
  final T current;

  @override
  Stream<ProjectionUpdate<T>> get changes => const Stream.empty();
}

final class _MutableProjection<T> implements ProjectionSource<T> {
  _MutableProjection(this.current);

  @override
  T current;
  final StreamController<ProjectionUpdate<T>> _changes =
      StreamController.broadcast(sync: true);

  @override
  Stream<ProjectionUpdate<T>> get changes => _changes.stream;

  void publish(T value) {
    current = value;
    _changes.add(ProjectionUpdate(value));
  }

  Future<void> close() => _changes.close();
}

final class _RecordingIntentSink<T> implements IntentSink<T> {
  final List<T> values = [];

  @override
  void send(T intent) => values.add(intent);
}

final class _EmptyEffects<T> implements EffectSource<T> {
  const _EmptyEffects();

  @override
  Stream<T> get effects => const Stream.empty();
}
