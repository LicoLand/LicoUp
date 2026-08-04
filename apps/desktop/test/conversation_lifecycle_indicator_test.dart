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

  testWidgets('completed process card collapses the lifecycle rail', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      stage: 'completed',
      observed: 'submitted,accepted,processing,responding,completed',
    );

    expect(find.text('Response complete'), findsOneWidget);
    expect(find.byKey(const Key('conversation-lifecycle-rail')), findsNothing);
  });
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required String stage,
  required String observed,
  bool active = false,
}) async {
  final event = AgentConversationMessage(
    id: 'turn-lifecycle',
    role: 'event',
    text: stage,
    createdAt: '2026-08-03T00:00:00Z',
    cardType: 'lifecycle',
    cardTitle: 'lifecycle.$stage',
    cardSubtitle: observed,
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
            events: [event],
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
