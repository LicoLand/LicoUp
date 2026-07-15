import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets(
    'conversation process card uses glass chrome without gold focus border',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = ClientController();
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'native-history',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'implemented',
        ),
      ];
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'session-process';
      controller.conversationSessionsByAgent = {
        'codex': [
          AgentConversationSession.fromJson({
            'id': 'session-process',
            'agentId': 'codex',
            'title': 'Process card',
            'createdAt': '2026-07-12T00:00:00Z',
            'updatedAt': '2026-07-12T00:00:02Z',
            'messages': [
              {
                'id': 'message-tool',
                'role': 'function_call',
                'cardType': 'tool-call',
                'cardTitle': 'Read file',
                'cardSubtitle': 'running',
                'text': jsonEncode({'path': 'fixture.txt'}),
                'createdAt': '2026-07-12T00:00:01Z',
              },
              {
                'id': 'message-tool-result',
                'role': 'function_call_output',
                'cardType': 'tool-result',
                'cardTitle': 'Read file',
                'cardSubtitle': 'done',
                'text': 'ok',
                'createdAt': '2026-07-12T00:00:02Z',
              },
            ],
          }),
        ],
      };

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 900,
              child: AgentConversationWorkspace(
                controller: controller,
                targets: controller.scannedTargets,
                scanning: false,
                adding: false,
                onAddTarget: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final processCard = find.byKey(
        const ValueKey('conversation-process-message-tool'),
      );
      expect(processCard, findsOneWidget);

      final container = tester.widget<AnimatedContainer>(processCard);
      final decoration = container.decoration! as BoxDecoration;
      final colors = buildLicoTheme(
        platformBrightness: Brightness.dark,
      ).extension<LicoThemeColors>()!;
      expect(decoration.border?.top.color, isNot(colors.primary));
      expect(decoration.border?.top.width, lessThan(1.1));
      expect(decoration.borderRadius, isNotNull);
    },
  );
}
