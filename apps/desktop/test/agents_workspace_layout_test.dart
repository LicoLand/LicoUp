import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/controllers/future_client_controller.dart';
import 'package:flutter_client/src/l10n/lico_strings.dart';
import 'package:flutter_client/src/services/agent_conversation_service.dart';
import 'package:flutter_client/src/services/agent_service.dart';
import 'package:flutter_client/src/ui/agent_conversation_workspace.dart';
import 'package:flutter_client/src/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('agent workspace does not overflow in a narrow app window', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'copilot',
        label: 'Copilot',
        kind: 'native-history-with-long-kind-label',
        status: 'detected',
        configured: false,
        confidence: 0.84,
        adapterStatus: 'implemented',
      ),
      TargetCandidate(
        target: 'kilo-code',
        label: 'Kilo Code',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
      TargetCandidate(
        target: 'openclaw',
        label: 'OpenClaw',
        kind: 'cli',
        status: 'not-detected',
        configured: false,
        confidence: 0.15,
        adapterStatus: 'unsupported',
      ),
    ];
    controller.selectedConversationAgentId = 'copilot';
    controller.selectedConversationSessionId = 'session-1';
    controller.conversationSessionsByAgent = {
      'copilot': const [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'copilot',
          title: 'key: workspace-history-with-a-long-title',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'copilot-native-import',
          nativeSessionId: 'native-session-with-long-identifier',
          sourceKind: 'native-agent-history',
          sourcePath: '<user-home>/.config/copilot/history/session.jsonl',
          messages: [
            AgentConversationMessage(
              id: 'message-1',
              role: 'assistant',
              text:
                  'A long native agent history preview should wrap inside the available message column instead of pushing adjacent controls outside the window.',
              createdAt: '2026-06-15T00:00:00Z',
            ),
          ],
        ),
        AgentConversationSession(
          id: 'session-2',
          agentId: 'copilot',
          title: 'second runtime conversation',
          createdAt: '2026-06-16T00:00:00Z',
          updatedAt: '2026-06-16T00:00:00Z',
          adapterId: 'copilot-native-import',
          nativeSessionId: 'native-session-2',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-2',
              role: 'user',
              text: 'Follow up from another imported native history.',
              createdAt: '2026-06-16T00:00:00Z',
            ),
          ],
        ),
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 540,
            height: 560,
            child: AgentConversationWorkspace(
              controller: controller,
              targets: controller.scannedTargets,
              scanning: false,
              adding: false,
              onRescan: () {},
              onAddTarget: () {},
              onInspect: (_) {},
              onPlan: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Copilot'), findsWidgets);
    expect(find.text('Kilo Code'), findsOneWidget);
    expect(find.text('OpenClaw'), findsNothing);
    expect(find.text('Not detected'), findsNothing);
    expect(find.text('Conversation history'), findsOneWidget);
    expect(find.text('second runtime conversation'), findsOneWidget);
    expect(find.text('Local agents'), findsNothing);
    expect(find.text('Inspect'), findsOneWidget);
    expect(find.text('Plan'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  test('agent tab wheel direction maps up to forward and down to back', () {
    expect(
      agentTabWheelTargetOffset(
        currentOffset: 100,
        minScrollExtent: 0,
        maxScrollExtent: 600,
        scrollDeltaY: -120,
        step: 184,
      ),
      284,
    );
    expect(
      agentTabWheelTargetOffset(
        currentOffset: 284,
        minScrollExtent: 0,
        maxScrollExtent: 600,
        scrollDeltaY: 120,
        step: 184,
      ),
      100,
    );
    expect(
      agentTabWheelTargetOffset(
        currentOffset: 560,
        minScrollExtent: 0,
        maxScrollExtent: 600,
        scrollDeltaY: -120,
        step: 184,
      ),
      600,
    );
  });

  testWidgets('agent workspace uses Chinese labels for Chinese locale', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'codex';

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
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
            height: 520,
            child: AgentConversationWorkspace(
              controller: controller,
              targets: controller.scannedTargets,
              scanning: false,
              adding: false,
              onRescan: () {},
              onAddTarget: () {},
              onInspect: (_) {},
              onPlan: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('历史对话'), findsOneWidget);
    expect(find.text('0 条对话'), findsOneWidget);
    expect(find.text('查看'), findsOneWidget);
    expect(find.text('计划'), findsOneWidget);
    expect(find.text('Conversation history'), findsNothing);
  });
}
