import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_process_operations.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_process_status_row.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('collapsed row summarizes duration and step count', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      events: [_event('e1', _at(10, 1, 0)), _event('e2', _at(10, 1, 12))],
    );

    expect(find.text('Tool activity'), findsOneWidget);
    expect(find.text('Worked for 12s · 2 steps'), findsOneWidget);
    expect(find.byType(ConversationProcessOperationList), findsNothing);
  });

  testWidgets('tap expands the shared operation list inline', (tester) async {
    await _pumpRow(
      tester,
      events: [_event('e1', _at(10, 1, 0)), _event('e2', _at(10, 1, 12))],
    );

    await tester.tap(find.byKey(const Key('messaging-process-status-toggle')));
    await tester.pump();

    expect(find.byType(ConversationProcessOperationList), findsOneWidget);

    await tester.tap(find.byKey(const Key('messaging-process-status-toggle')));
    await tester.pump();

    expect(find.byType(ConversationProcessOperationList), findsNothing);
  });

  testWidgets('expanded operations scroll below a fixed status header', (
    tester,
  ) async {
    final events = List<AgentConversationMessage>.generate(
      18,
      (index) => _toolEvent(
        'bounded-$index',
        _at(10, 1, index),
        title: 'Operation ${index + 1}',
        subtitle: 'Native agent activity',
      ),
    );
    await _pumpRow(tester, events: events, height: 700);

    const toggleKey = Key('messaging-process-status-toggle');
    const scrollKey = ValueKey(
      'conversation-process-operation-scroll-bounded-0',
    );
    await tester.tap(find.byKey(toggleKey));
    await tester.pumpAndSettle();

    final scroll = find.byKey(scrollKey);
    expect(scroll, findsOneWidget);
    expect(
      tester.getSize(scroll).height,
      lessThanOrEqualTo(conversationProcessExpandedBodyMaxHeight(700)),
    );
    final headerTop = tester.getTopLeft(find.byKey(toggleKey)).dy;
    const firstOperationKey = ValueKey(
      'conversation-process-operation-bounded-0',
    );
    expect(find.byKey(firstOperationKey), findsOneWidget);
    final operationScrollable = find.descendant(
      of: scroll,
      matching: find.byType(Scrollable),
    );
    final initialPixels = tester
        .state<ScrollableState>(operationScrollable)
        .position
        .pixels;

    await tester.drag(scroll, const Offset(0, -280));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.byKey(toggleKey)).dy, headerTop);
    expect(
      tester.state<ScrollableState>(operationScrollable).position.pixels,
      greaterThan(initialPixels),
    );
    expect(find.byKey(firstOperationKey), findsNothing);

    await tester.tap(find.byKey(toggleKey));
    await tester.pumpAndSettle();
    expect(find.byKey(scrollKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expansion pins the status header below the top overlay', (
    tester,
  ) async {
    const topOverlayInset = 72.0;
    final events = List<AgentConversationMessage>.generate(
      18,
      (index) => _toolEvent(
        'pinned-$index',
        _at(10, 1, index),
        title: 'Operation ${index + 1}',
        subtitle: 'Native agent activity',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 700,
            child: Stack(
              children: [
                ListView(
                  reverse: true,
                  padding: const EdgeInsets.only(top: topOverlayInset),
                  children: [
                    const SizedBox(height: 420),
                    MessagingProcessStatusRow(
                      events: events,
                      adapter: AgentRenderAdapter.fallback(),
                      detailsBuilder: buildAgentConversationEventDetails,
                      topOverlayInset: topOverlayInset,
                    ),
                    const SizedBox(height: 420),
                  ],
                ),
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: topOverlayInset,
                  child: ColoredBox(color: Colors.black),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    const toggleKey = Key('messaging-process-status-toggle');
    await tester.ensureVisible(find.byKey(toggleKey));
    await tester.tap(find.byKey(toggleKey));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(toggleKey)).dy,
      closeTo(topOverlayInset, 2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('active row presents the working label and top-edge pulse', (
    tester,
  ) async {
    await _pumpRow(tester, events: [_event('e1', _at(10, 1, 0))], active: true);

    expect(find.text('Tool activity'), findsOneWidget);
    expect(find.text('Working… · 1 step'), findsOneWidget);
    expect(
      find.byKey(const Key('messaging-process-status-active')),
      findsOneWidget,
    );
    final pulse = tester.widget<LicoTopEdgePulse>(
      find.byKey(const Key('messaging-process-status-active')),
    );
    expect(pulse.enabled, isTrue);
  });

  testWidgets('active row auto-expands the operation list', (tester) async {
    await _pumpRow(
      tester,
      events: [_event('e1', _at(10, 1, 0)), _event('e2', _at(10, 1, 4))],
      active: true,
    );

    expect(find.byType(ConversationProcessOperationList), findsOneWidget);
  });

  testWidgets('active row surfaces the latest redacted step headline', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      events: [
        _event('e1', _at(10, 1, 0)),
        _toolEvent(
          'e2',
          _at(10, 1, 4),
          title: 'Read file',
          subtitle: 'Native agent activity',
        ),
      ],
      active: true,
    );

    await tester.tap(find.byKey(const Key('messaging-process-status-toggle')));
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-process-latest-step')),
      findsOneWidget,
    );
    expect(find.text('Read file · Native agent activity'), findsOneWidget);
  });

  testWidgets('active lifecycle shows the five-stage progress rail', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      events: [
        _lifecycleEvent(
          'processing',
          observed: 'submitted,accepted,processing',
        ),
      ],
      active: true,
    );

    expect(find.text('Agent is working'), findsOneWidget);
    expect(find.text('3 of 5 stages observed'), findsOneWidget);
    expect(
      find.byKey(const Key('conversation-lifecycle-rail')),
      findsOneWidget,
    );
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Working'), findsOneWidget);
    expect(find.text('Replying'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('lifecycle rail hides once structured operations arrive', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      events: [
        _lifecycleEvent(
          'processing',
          observed: 'submitted,accepted,processing',
        ),
        _event('e1', _at(10, 1, 1)),
      ],
      active: true,
    );

    expect(find.byKey(const Key('conversation-lifecycle-rail')), findsNothing);
    expect(find.byType(ConversationProcessOperationList), findsOneWidget);
  });

  testWidgets('completed lifecycle collapses to one completion row', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      events: [
        _lifecycleEvent(
          'completed',
          observed: 'submitted,accepted,processing,responding,completed',
        ),
      ],
    );

    expect(find.textContaining('Response complete'), findsOneWidget);
    expect(find.byKey(const Key('conversation-lifecycle-rail')), findsNothing);
  });

  testWidgets('row stretches to the full detail column width', (tester) async {
    const detailWidth = 600.0;
    await _pumpRow(
      tester,
      events: [
        _lifecycleEvent(
          'completed',
          observed: 'submitted,accepted,processing,responding,completed',
        ),
      ],
      detailWidth: detailWidth,
    );

    final card = tester.renderObject<RenderBox>(
      find.byKey(const Key('messaging-process-status-idle')),
    );
    expect(card.size.width, closeTo(detailWidth, 1));
  });

  testWidgets('expand chevron sits at the card trailing edge', (tester) async {
    const detailWidth = 600.0;
    await _pumpRow(
      tester,
      events: [
        _lifecycleEvent(
          'completed',
          observed: 'submitted,accepted,processing,responding,completed',
        ),
      ],
      detailWidth: detailWidth,
    );

    final card = tester.renderObject<RenderBox>(
      find.byKey(const Key('messaging-process-status-idle')),
    );
    final chevron = tester.renderObject<RenderBox>(
      find.byIcon(Icons.chevron_right_rounded),
    );
    // Idle header uses 8px horizontal padding; chevron sits at content trailing edge.
    const horizontalPadding = 8.0;
    final cardTrailing = card.localToGlobal(Offset(card.size.width, 0)).dx;
    final chevronTrailing = chevron
        .localToGlobal(Offset(chevron.size.width, 0))
        .dx;
    expect(chevronTrailing, closeTo(cardTrailing - horizontalPadding, 1));
  });

  testWidgets('row centers horizontally in the detail column', (tester) async {
    const paneWidth = 800.0;
    const detailWidth = 600.0;
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
            width: paneWidth,
            height: 400,
            child: Center(
              child: SizedBox(
                width: detailWidth,
                child: MessagingProcessStatusRow(
                  events: [
                    _lifecycleEvent(
                      'completed',
                      observed:
                          'submitted,accepted,processing,responding,completed',
                    ),
                  ],
                  adapter: AgentRenderAdapter.fallback(),
                  detailsBuilder: buildAgentConversationEventDetails,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final card = tester.renderObject<RenderBox>(
      find.byKey(const Key('messaging-process-status-idle')),
    );
    final cardCenter = card.localToGlobal(Offset(card.size.width / 2, 0)).dx;
    expect(cardCenter, closeTo(paneWidth / 2, 1));
    expect(card.size.width, closeTo(detailWidth, 1));
  });
}

String _at(int hour, int minute, int second) =>
    DateTime(2026, 7, 20, hour, minute, second).toIso8601String();

AgentConversationMessage _event(String id, String createdAt) {
  return AgentConversationMessage(
    id: id,
    role: 'tool',
    text: 'ran tool',
    createdAt: createdAt,
  );
}

AgentConversationMessage _toolEvent(
  String id,
  String createdAt, {
  required String title,
  required String subtitle,
}) {
  return AgentConversationMessage(
    id: id,
    role: 'tool',
    text: '',
    createdAt: createdAt,
    cardTitle: title,
    cardSubtitle: subtitle,
  );
}

AgentConversationMessage _lifecycleEvent(
  String stage, {
  required String observed,
}) {
  return AgentConversationMessage(
    id: 'lifecycle',
    role: 'event',
    text: stage,
    createdAt: _at(10, 1, 0),
    cardType: 'lifecycle',
    cardTitle: 'lifecycle.$stage',
    cardSubtitle: observed,
  );
}

Future<void> _pumpRow(
  WidgetTester tester, {
  required List<AgentConversationMessage> events,
  bool active = false,
  double detailWidth = 600,
  double height = 400,
}) async {
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
          width: detailWidth,
          height: height,
          child: MessagingProcessStatusRow(
            events: events,
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
