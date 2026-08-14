import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_chrome_tabs.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('opening a conversation previews an italic temporary tab', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpStrip(tester, controller);

    expect(find.text('Alpha session'), findsNothing);

    _select(controller, 's1');
    await tester.pump();

    expect(_titleStyle(tester, 'Alpha session').fontStyle, FontStyle.italic);
    expect(find.byKey(const Key('messaging-chrome-tab-s1')), findsOneWidget);
  });

  testWidgets('another open replaces the temporary tab', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpStrip(tester, controller);

    _select(controller, 's1');
    await tester.pump();
    _select(controller, 's2');
    await tester.pump();

    expect(find.text('Alpha session'), findsNothing);
    expect(_titleStyle(tester, 'Beta session').fontStyle, FontStyle.italic);
    expect(find.byKey(const Key('messaging-chrome-tab-s1')), findsNothing);
  });

  testWidgets('double-tap pins the temporary tab non-italic', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpStrip(tester, controller);

    _select(controller, 's1');
    await tester.pump();
    final tabCenter = tester.getCenter(
      find.byKey(const Key('messaging-chrome-tab-s1')),
    );
    await tester.tapAt(tabCenter);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(tabCenter);
    await tester.pump(const Duration(milliseconds: 300));

    expect(_titleStyle(tester, 'Alpha session').fontStyle, FontStyle.normal);

    // A later open previews a different session next to the pinned tab.
    _select(controller, 's2');
    await tester.pump();
    expect(_titleStyle(tester, 'Alpha session').fontStyle, FontStyle.normal);
    expect(_titleStyle(tester, 'Beta session').fontStyle, FontStyle.italic);
  });

  testWidgets('an active send pins the sending session', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpStrip(tester, controller);

    _select(controller, 's1');
    await tester.pump();
    expect(_titleStyle(tester, 'Alpha session').fontStyle, FontStyle.italic);

    controller.isSendingConversationMessage = true;
    controller.sendingConversationSessionId = 's1';
    controller.agentWorkspaceNotifyStateChanged();
    await tester.pump();

    expect(_titleStyle(tester, 'Alpha session').fontStyle, FontStyle.normal);
  });

  testWidgets('tab highlight follows the selected session, not the agent', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpStrip(tester, controller);

    _select(controller, 's1');
    await tester.pump();
    // Pin s1 so both sessions of the same agent render side by side.
    final tabCenter = tester.getCenter(
      find.byKey(const Key('messaging-chrome-tab-s1')),
    );
    await tester.tapAt(tabCenter);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(tabCenter);
    await tester.pump(const Duration(milliseconds: 300));

    expect(_titleStyle(tester, 'Alpha session').fontWeight, FontWeight.w600);

    _select(controller, 's2');
    await tester.pump();

    // Only the tab of the selected session highlights; the other tab of the
    // same agent stays quiet.
    expect(_titleStyle(tester, 'Beta session').fontWeight, FontWeight.w600);
    expect(_titleStyle(tester, 'Alpha session').fontWeight, FontWeight.w500);

    // Selecting the pinned session highlights its tab again.
    _select(controller, 's1');
    await tester.pump();
    expect(_titleStyle(tester, 'Alpha session').fontWeight, FontWeight.w600);
  });

  testWidgets('closing the sending tab does not re-pin it', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpStrip(tester, controller);

    _select(controller, 's1');
    await tester.pump();
    controller.isSendingConversationMessage = true;
    controller.sendingConversationSessionId = 's1';
    controller.agentWorkspaceNotifyStateChanged();
    await tester.pump();
    expect(find.byKey(const Key('messaging-chrome-tab-s1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('messaging-chrome-tab-close')));
    await tester.pump();
    expect(find.byKey(const Key('messaging-chrome-tab-s1')), findsNothing);

    // Another controller notification while the send is still in flight must
    // not re-add the user-closed tab.
    controller.agentWorkspaceNotifyStateChanged();
    await tester.pump();
    expect(find.byKey(const Key('messaging-chrome-tab-s1')), findsNothing);

    // The tab stays closed after the send completes.
    controller.isSendingConversationMessage = false;
    controller.sendingConversationSessionId = '';
    controller.agentWorkspaceNotifyStateChanged();
    await tester.pump();
    expect(find.byKey(const Key('messaging-chrome-tab-s1')), findsNothing);

    // Reopening the conversation restores preview rights.
    _select(controller, 's2');
    await tester.pump();
    expect(find.byKey(const Key('messaging-chrome-tab-s2')), findsOneWidget);
  });
  testWidgets('close removes the pinned tab without reviving the preview', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpStrip(tester, controller);

    _select(controller, 's1');
    await tester.pump();
    controller.isSendingConversationMessage = true;
    controller.sendingConversationSessionId = 's1';
    controller.agentWorkspaceNotifyStateChanged();
    await tester.pump();
    controller.isSendingConversationMessage = false;
    controller.sendingConversationSessionId = '';
    controller.agentWorkspaceNotifyStateChanged();
    await tester.pump();

    await tester.tap(find.byKey(const Key('messaging-chrome-tab-close')));
    await tester.pump();

    expect(find.byKey(const Key('messaging-chrome-tab-s1')), findsNothing);
    // The conversation stays open; the tab does not come back as a preview.
    expect(controller.selectedConversationSession?.id, 's1');
    expect(find.text('Alpha session'), findsNothing);

    // Opening another conversation previews again.
    _select(controller, 's2');
    await tester.pump();
    expect(_titleStyle(tester, 'Beta session').fontStyle, FontStyle.italic);
  });
  testWidgets('tap resolves a session re-emitted under a fresh id', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pumpStrip(tester, controller);

    _select(controller, 's2');
    await tester.pump();
    expect(find.byKey(const Key('messaging-chrome-tab-s2')), findsOneWidget);

    // A silent background commit re-emits the same native session under a
    // fresh id WITHOUT notifying listeners (non-selected-agent lane), so the
    // rendered tab still carries the stale entry at tap time.
    controller.conversationSessionsByAgent = {
      'codex': [
        _session('s1', 'codex', 'Alpha session', nativeId: 'native-1'),
        _session('s2-v2', 'codex', 'Beta session', nativeId: 'native-2'),
      ],
    };

    await tester.tap(find.byKey(const Key('messaging-chrome-tab-s2')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The native-id fallback navigates to the re-emitted session instead of
    // landing on an empty "no messages" state.
    expect(controller.selectedConversationSession?.id, 's2-v2');
  });
}

void _select(ClientController controller, String sessionId) {
  controller.selectedConversationAgentId = 'codex';
  controller.selectedConversationSessionId = sessionId;
  controller.agentWorkspaceNotifyStateChanged();
}

TextStyle _titleStyle(WidgetTester tester, String title) {
  final widget = tester.widget<Text>(find.text(title));
  return widget.style!;
}

ClientController _controller() {
  return ClientController()
    ..scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 1,
        adapterStatus: 'implemented',
      ),
    ]
    ..conversationSessionsByAgent = {
      'codex': [
        _session('s1', 'codex', 'Alpha session', nativeId: 'native-1'),
        _session('s2', 'codex', 'Beta session', nativeId: 'native-2'),
      ],
    };
}

AgentConversationSession _session(
  String id,
  String agentId,
  String title, {
  String nativeId = '',
}) => AgentConversationSession(
  id: id,
  agentId: agentId,
  title: title,
  createdAt: id == 's2' ? '2026-07-30T10:00:00' : '2026-07-29T10:00:00',
  updatedAt: id == 's2' ? '2026-07-30T10:00:00' : '2026-07-29T10:00:00',
  nativeSessionId: nativeId,
  messages: const [],
);

Future<void> _pumpStrip(WidgetTester tester, ClientController controller) {
  return tester.pumpWidget(
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
          width: 900,
          height: 80,
          child: MessagingConversationTabStrip(controller: controller),
        ),
      ),
    ),
  );
}
