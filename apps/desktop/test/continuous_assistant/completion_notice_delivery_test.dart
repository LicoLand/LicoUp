import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/chrome/chrome_projection_producer.dart';

import '../fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  for (final authorized in [true, false]) {
    testWidgets(
      authorized
          ? 'idle group receives completion toast and opens current admitted task child'
          : 'denied completion action preserves the displayed group and composer',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(900, 520);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final runner = _NoticeBridgeRunner()..failResolve = !authorized;
        final controller = ClientController(
          agentService: FakeAgentService(),
          conversationCommandRunner: runner,
          pendingNoticePollInterval: const Duration(hours: 1),
        );
        addTearDown(controller.close);
        final conversation = ConversationFeatureComposition(controller);
        addTearDown(conversation.close);
        final chrome = ChromeProjectionProducer(controller);
        addTearDown(chrome.close);
        final notices = ValueNotifier(_chromeNotices(chrome.current));
        addTearDown(notices.dispose);
        final chromeSub = chrome.changes.listen((update) {
          notices.value = _chromeNotices(update.value);
        });
        addTearDown(chromeSub.cancel);

        final owner = controller.clientConversationController;
        await owner.initialize();
        await owner.selectConversation('conversation:a');
        expect(
          owner.events
              .singleWhere((event) => event.id == 'event:card-3')
              .sequence,
          3,
        );
        await owner.selectConversation('conversation:b');
        owner.updateDraft('keep composing');
        runner.requests.clear();

        await tester.pumpWidget(
          _host(
            notices: notices,
            onActivate: (notice) {
              final id = notice.completionTarget?.notificationId ?? '';
              if (id.isNotEmpty) {
                conversation.binding.intents.send(
                  ActivateContinuityCompletionNotice(notificationId: id),
                );
              }
            },
            child: _LiveCanonicalPane(
              conversation: conversation.binding,
              agents: _agentsBinding(),
            ),
          ),
        );
        await tester.pump();
        CanonicalGroupConversationPane displayedPane() =>
            tester.widget<CanonicalGroupConversationPane>(
              find.byType(CanonicalGroupConversationPane),
            );
        expect(displayedPane().canonical.conversationId, 'conversation:b');
        expect(find.text('Task completed'), findsNothing);

        runner.requests.clear();
        runner.pendingNotices = [_noticeA()];
        unawaited(owner.pollPendingCompletionNotices());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('Task completed'), findsOneWidget);
        expect(find.text('Open original matter'), findsOneWidget);
        expect(displayedPane().canonical.conversationId, 'conversation:b');
        expect(owner.draft, 'keep composing');
        expect(
          runner.requests.where(
            (request) => request['action'] == 'conversation.get',
          ),
          isEmpty,
        );
        expect(
          runner.requests.where((request) => request['action'] == 'close-goal'),
          isEmpty,
        );
        expect(runner.acked, ['notice:a']);

        await tester.tap(find.text('Open original matter'));
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(
          displayedPane().canonical.conversationId,
          authorized ? 'conversation:child-a' : 'conversation:b',
        );
        expect(
          displayedPane().canonical.conversation?.id,
          authorized ? 'conversation:child-a' : 'conversation:b',
        );
        if (!authorized) expect(owner.draft, 'keep composing');
        await owner.selectConversation('conversation:a');
        await tester.pump();
        expect(
          owner.events
              .singleWhere((event) => event.id == 'event:card-3')
              .sequence,
          3,
        );
        expect(owner.events.last.sequence, 60);
        await owner.pollPendingCompletionNotices();
        await tester.pump();
        expect(runner.acked, ['notice:a']);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(controller.close);
      },
    );
  }
}

Widget _host({
  required ValueNotifier<LicoToastNoticesSnapshot> notices,
  required ValueChanged<ChromeOperationNotificationProjection> onActivate,
  required Widget child,
}) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(900, 520)),
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(
        platformBrightness: Brightness.dark,
      ).copyWith(platform: TargetPlatform.macOS),
      home: Builder(
        builder: (context) => LayoutPaletteScope(
          palette: layoutPaletteFromColors(context.licoColors),
          child: LayoutAgentsStrategyScope(
            strategy: const AgentsPresentationStrategy.messaging(),
            child: LicoToastHost(
              child: LicoToastNoticesListener(
                notices: notices,
                onActivate: onActivate,
                child: Scaffold(body: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

LicoToastNoticesSnapshot _chromeNotices(ChromeProjection projection) {
  return LicoToastNoticesSnapshot(
    operationNotices: projection.operationNotifications,
    operationRevision: projection.operationAutoRevealRevision,
  );
}

AgentsBinding _agentsBinding() {
  final target = TargetCandidate(
    id: 'codex',
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'implemented',
  );
  return AgentsBinding(
    projection: _StaticProjection(
      AgentsProjection(
        targets: const [
          AgentTargetProjection(
            id: 'codex',
            displayName: 'Codex',
            available: true,
            pinned: false,
            capabilityLabel: 'detected',
          ),
        ],
        targetDetails: [target],
        selectedAgentId: 'codex',
        workingDirectoryLabel: '',
        phase: PresentationPhase.ready,
      ),
    ),
    intents: _IntentSink<AgentsIntent>((_) {}),
    effects: const _EmptyEffects<AgentsEffect>(),
  );
}

final class _LiveCanonicalPane extends StatelessWidget {
  const _LiveCanonicalPane({required this.conversation, required this.agents});

  final ConversationBinding conversation;
  final AgentsBinding agents;

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<
      CanonicalConversationProjection,
      CanonicalConversationProjection
    >(
      source: conversation.canonicalEvents,
      select: (projection) => projection,
      builder: (context, canonical) {
        return CanonicalGroupConversationPane(
          conversation: conversation,
          agents: agents,
          canonical: canonical,
          turns: conversation.persistentTurns.current,
          composer: conversation.composer.current,
          attachments: conversation.attachments.current,
          framed: false,
        );
      },
    );
  }
}

final class _StaticProjection<T> implements ProjectionSource<T> {
  const _StaticProjection(this.current);

  @override
  final T current;

  @override
  Stream<ProjectionUpdate<T>> get changes => const Stream.empty();
}

final class _IntentSink<T> implements IntentSink<T> {
  const _IntentSink(this._send);

  final void Function(T intent) _send;

  @override
  void send(T intent) => _send(intent);
}

final class _EmptyEffects<T> implements EffectSource<T> {
  const _EmptyEffects();

  @override
  Stream<T> get effects => const Stream.empty();
}

Map<String, dynamic> _noticeA() => <String, dynamic>{
  'notificationId': 'notice:a',
  'goalId': 'goal:a',
  'parentConversationId': 'conversation:a',
  'childConversationId': 'conversation:child-a',
  'cardEventId': 'event:card-3',
  'cardSequence': 3,
};

final class _NoticeBridgeRunner implements AgentCommandRunner {
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> pendingNotices = <Map<String, dynamic>>[];
  final List<String> acked = <String>[];
  bool failResolve = false;

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    requests.add(request);
    final action = request['action'];
    final conversationId = (request['conversationId'] ?? '').toString();
    if (action == 'resolve-completion-notice' && failResolve) {
      return {
        'ok': false,
        'error': {'code': 'ScopeDenied'},
      };
    }
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => [
          _summary('conversation:a', eventCount: 60),
          _summary('conversation:b'),
        ],
        'conversation.get' => _conversation(conversationId),
        'conversation.events.page' => _eventsPage(
          conversationId,
          (request['afterSequence'] as num?)?.toInt() ?? 0,
        ),
        'list-pending-completion-notices' => {
          'pendingCompletionNotices': pendingNotices,
        },
        'ack-completion-notices' => {
          'acknowledgedNotificationIds': _ack(request),
        },
        'resolve-completion-notice' => {
          'ok': true,
          'notificationId': request['notificationId'],
          'goalId': 'goal:a',
          'parentConversationId': 'conversation:a',
          'childConversationId': 'conversation:child-a',
          'cardEventId': 'event:card-3',
          'cardSequence': 3,
        },
        _ => <String, dynamic>{},
      },
    };
  }

  List<String> _ack(Map<String, dynamic> request) {
    final ids = ((request['notificationIds'] as List?) ?? const <dynamic>[])
        .map((id) => id.toString())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    acked.addAll(ids);
    pendingNotices = pendingNotices
        .where(
          (notice) =>
              !ids.contains((notice['notificationId'] ?? '').toString()),
        )
        .toList();
    return ids;
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      throw UnimplementedError();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}

Map<String, dynamic> _summary(String id, {int eventCount = 1}) => {
  'id': id,
  'title': id,
  'archived': false,
  'pinned': false,
  'isGroup': true,
  'revision': 1,
  'updatedAtUnixMs': 10,
  'membershipCount': 2,
  'eventCount': eventCount,
};

Map<String, dynamic> _conversation(String id) {
  final wide = id == 'conversation:a';
  return {
    'id': id,
    'title': id,
    'archived': false,
    'pinned': false,
    'isGroup': true,
    'revision': 1,
    'createdAtUnixMs': 1,
    'updatedAtUnixMs': 10,
    'eventCount': wide ? 60 : 1,
    'memberships': [
      {
        'id': 'membership:owner',
        'conversationId': id,
        'principal': {
          'id': 'human:local',
          'kind': 'human',
          'displayName': 'You',
          'createdAtUnixMs': 1,
        },
        'access': 'owner',
        'status': 'active',
        'joinedAtUnixMs': 1,
      },
      {
        'id': 'membership:agent',
        'conversationId': id,
        'principal': {
          'id': 'agent:codex',
          'kind': 'agent',
          'displayName': 'Codex',
          'agentId': 'codex',
          'createdAtUnixMs': 1,
        },
        'access': 'member',
        'status': 'active',
        'joinedAtUnixMs': 1,
      },
    ],
    'taskViews': [
      if (wide)
        {
          'id': 'goal:a',
          'relation': {
            'goalId': 'goal:a',
            'cardAnchor': {
              'parentConversationId': 'conversation:a',
              'eventId': 'event:card-3',
              'sequence': 3,
            },
          },
        }
      else
        {'id': 'task-b', 'conversationId': id},
    ],
  };
}

Map<String, dynamic> _eventsPage(String conversationId, int afterSequence) {
  if (conversationId != 'conversation:a') {
    return {
      'events': [_textEvent(conversationId, 1)],
      'nextCursor': null,
      'totalCount': 1,
    };
  }
  if (afterSequence == 2) {
    return {
      'events': [_cardEvent()],
      'nextCursor': null,
      'totalCount': 60,
    };
  }
  final start = afterSequence < 50 ? 51 : afterSequence + 1;
  return {
    'events': [
      for (var sequence = start; sequence <= 60; sequence += 1)
        _textEvent('conversation:a', sequence),
    ],
    'nextCursor': null,
    'totalCount': 60,
  };
}

Map<String, dynamic> _cardEvent() => {
  'id': 'event:card-3',
  'conversationId': 'conversation:a',
  'sequence': 3,
  'authorMembershipId': 'membership:owner',
  'kind': 'message',
  'createdAtUnixMs': 13,
  'finalized': true,
  'parts': [
    {
      'id': 'part:card-3',
      'eventId': 'event:card-3',
      'ordinal': 0,
      'kind': 'metadata',
      'content': jsonEncode({
        'goalId': 'goal:a',
        'childConversationId': 'conversation:child-a',
        'toLifecycle': 'achieved',
        'sequence': 3,
      }),
      'createdAtUnixMs': 13,
    },
  ],
};

Map<String, dynamic> _textEvent(String conversationId, int sequence) => {
  'id': 'event:$conversationId:$sequence',
  'conversationId': conversationId,
  'sequence': sequence,
  'authorMembershipId': 'membership:owner',
  'kind': 'message',
  'createdAtUnixMs': 10 + sequence,
  'finalized': true,
  'parts': [
    {
      'id': 'part:$sequence',
      'eventId': 'event:$conversationId:$sequence',
      'ordinal': 0,
      'kind': 'text',
      'content': 'hello $sequence',
      'createdAtUnixMs': 10 + sequence,
    },
  ],
};
