import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_lifecycle_indicator.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_process_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  test(
    'lifecycle projection unions every observed stage, not only the last',
    () {
      final projection = projectConversationTurnLifecycle([
        const AgentConversationMessage(
          id: 'submitted',
          role: 'event',
          text: 'submitted',
          createdAt: '2026-08-19T00:00:00Z',
          cardType: 'lifecycle',
          cardTitle: 'lifecycle.submitted',
        ),
        const AgentConversationMessage(
          id: 'accepted',
          role: 'event',
          text: 'accepted',
          createdAt: '2026-08-19T00:00:00Z',
          cardType: 'lifecycle',
          cardTitle: 'lifecycle.accepted',
        ),
        const AgentConversationMessage(
          id: 'failed',
          role: 'error',
          text: 'failed',
          createdAt: '2026-08-19T00:00:11Z',
          cardType: 'lifecycle',
          cardTitle: 'lifecycle.failed',
        ),
      ]);
      expect(projection, isNotNull);
      expect(projection!.stage, ConversationTurnLifecycleStage.failed);
      expect(
        projection.observedStages,
        containsAll([
          ConversationTurnLifecycleStage.submitted,
          ConversationTurnLifecycleStage.accepted,
        ]),
      );
      expect(projection.observedStages.length, 2);
      expect(projection.activeStep, 1);
    },
  );

  test(
    'Flutter does not invent a prefix from a coalesced processing event',
    () {
      final projection = projectConversationTurnLifecycle([
        const AgentConversationMessage(
          id: 'processing',
          role: 'event',
          text: 'processing',
          createdAt: '2026-08-19T00:00:00Z',
          cardType: 'lifecycle',
          cardTitle: 'lifecycle.processing',
        ),
      ]);

      expect(projection, isNotNull);
      expect(projection!.activeStep, 2);
      expect(projection.observedStages, {
        ConversationTurnLifecycleStage.processing,
      });
    },
  );

  test('lifecycle text and retired aliases are not stage authority', () {
    final projection = projectConversationTurnLifecycle([
      const AgentConversationMessage(
        id: 'text-only',
        role: 'event',
        text: 'completed',
        createdAt: '2026-08-19T00:00:00Z',
        cardType: 'lifecycle',
      ),
      const AgentConversationMessage(
        id: 'running-alias',
        role: 'event',
        text: 'running',
        createdAt: '2026-08-19T00:00:01Z',
        cardType: 'lifecycle',
        cardTitle: 'lifecycle.running',
      ),
      const AgentConversationMessage(
        id: 'cancelled-alias',
        role: 'event',
        text: 'cancelled',
        createdAt: '2026-08-19T00:00:02Z',
        cardType: 'lifecycle',
        cardTitle: 'lifecycle.cancelled',
      ),
    ]);
    expect(projection, isNull);
  });

  test('lifecycle projection ignores regressions and stops at failure', () {
    const eventTime = '2026-08-19T00:00:00Z';
    final projection = projectConversationTurnLifecycle([
      const AgentConversationMessage(
        id: 'processing',
        role: 'event',
        text: 'processing',
        createdAt: eventTime,
        cardType: 'lifecycle',
        cardTitle: 'lifecycle.processing',
      ),
      const AgentConversationMessage(
        id: 'accepted-late',
        role: 'event',
        text: 'accepted',
        createdAt: eventTime,
        cardType: 'lifecycle',
        cardTitle: 'lifecycle.accepted',
      ),
      const AgentConversationMessage(
        id: 'failed',
        role: 'error',
        text: 'failed',
        createdAt: eventTime,
        cardType: 'lifecycle',
        cardTitle: 'lifecycle.failed',
      ),
      const AgentConversationMessage(
        id: 'completed-after-failure',
        role: 'event',
        text: 'completed',
        createdAt: eventTime,
        cardType: 'lifecycle',
        cardTitle: 'lifecycle.completed',
      ),
    ]);

    expect(projection, isNotNull);
    expect(projection!.stage, ConversationTurnLifecycleStage.failed);
    expect(projection.activeStep, 2);
    expect(
      projection.observedStages,
      isNot(contains(ConversationTurnLifecycleStage.completed)),
    );
  });

  testWidgets('active process card exposes one five-stage lifecycle rail', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      stage: 'processing',
      observed: 'submitted,accepted,processing',
      active: true,
    );

    expect(find.text('Agent is working'), findsOneWidget);
    expect(find.text('3 of 5 stages observed'), findsOneWidget);
    expect(
      find.byKey(const Key('conversation-lifecycle-rail')),
      findsOneWidget,
    );
  });

  testWidgets('lifecycle rail paints only Rust-reported prefix stages', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      stage: 'processing',
      observed: 'processing',
      active: true,
    );

    final colors = tester
        .element(find.byType(ConversationLifecycleSteps))
        .licoColors;
    expect(_stepColor(tester, 'Sent'), colors.line);
    expect(_stepColor(tester, 'Received'), colors.line);
    expect(_stepColor(tester, 'Working'), colors.text);
    expect(find.text('1 of 5 stages observed'), findsOneWidget);
  });

  testWidgets('completed process card collapses the lifecycle rail', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      stage: 'completed',
      observed: 'submitted,accepted,processing,responding,completed',
      participantRole: 'subagent',
    );

    expect(find.text('Response complete'), findsOneWidget);
    expect(find.byKey(const Key('conversation-lifecycle-rail')), findsNothing);
    expect(find.text('0 of 5 stages observed'), findsNothing);
    expect(find.text('1 of 5 stages observed'), findsNothing);
  });

  testWidgets(
    'failed rail marks the last reached stage and completes its prefix',
    (tester) async {
      await _pumpCard(
        tester,
        stage: 'failed',
        observed: 'submitted,accepted,processing',
      );

      final colors = tester
          .element(find.byType(ConversationLifecycleSteps))
          .licoColors;
      expect(_stepColor(tester, 'Sent'), colors.text);
      expect(_stepColor(tester, 'Received'), colors.text);
      expect(_stepColor(tester, 'Working'), colors.error);
      expect(_stepColor(tester, 'Replying'), colors.line);
    },
  );

  testWidgets(
    'an early failure stays on sent instead of inventing processing',
    (tester) async {
      await _pumpCard(tester, stage: 'failed', observed: 'submitted');

      final colors = tester
          .element(find.byType(ConversationLifecycleSteps))
          .licoColors;
      expect(_stepColor(tester, 'Sent'), colors.error);
      expect(_stepColor(tester, 'Received'), colors.line);
      expect(_stepColor(tester, 'Working'), colors.line);
    },
  );

  testWidgets(
    'Assistant responding prefix and Subagent failure keep the rendered Rust prefix',
    (tester) async {
      await _pumpCard(
        tester,
        stage: 'responding',
        observed: 'submitted,accepted,processing,responding',
        active: true,
        participantRole: 'assistant',
      );

      expect(find.textContaining('4 of 5 stages observed'), findsOneWidget);
      expect(find.text('0 of 5 stages observed'), findsNothing);
      expect(find.text('1 of 5 stages observed'), findsNothing);
      final colors = tester
          .element(find.byType(ConversationLifecycleSteps))
          .licoColors;
      expect(_stepColor(tester, 'Sent'), colors.text);
      expect(_stepColor(tester, 'Replying'), colors.text);

      await _pumpCard(
        tester,
        stage: 'failed',
        observed: 'submitted,accepted,processing,responding',
        participantRole: 'subagent',
        extraEvents: const [
          AgentConversationMessage(
            id: 'observer-disconnected',
            role: 'error',
            text: 'Synthetic observer disconnected.',
            createdAt: '2026-08-03T00:00:01Z',
            cardType: 'diagnostic',
            cardTitle: 'observer_disconnected',
          ),
        ],
      );

      expect(find.textContaining('4 of 5 stages observed'), findsOneWidget);
      expect(_stepColor(tester, 'Replying'), colors.error);
      expect(_stepColor(tester, 'Done'), colors.line);
    },
  );
}

Color? _stepColor(WidgetTester tester, String label) {
  final step = tester.widget<AnimatedContainer>(
    find.byKey(Key('conversation-lifecycle-step-$label')),
  );
  return (step.decoration as BoxDecoration?)?.color;
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required String stage,
  required String observed,
  bool active = false,
  String participantRole = '',
  List<AgentConversationMessage> extraEvents = const [],
}) async {
  final event = AgentConversationMessage(
    id: 'turn-lifecycle',
    role: 'event',
    text: stage,
    createdAt: '2026-08-03T00:00:00Z',
    cardType: 'lifecycle',
    cardTitle: 'lifecycle.$stage',
    cardSubtitle: observed,
    participantRole: participantRole,
  );
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Scaffold(
        body: SizedBox(
          width: 720,
          child: ConversationProcessCard(
            events: [event, ...extraEvents],
            adapter: AgentRenderAdapter.fallback(),
            detailsBuilder: buildAgentConversationEventDetails,
            active: active,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
