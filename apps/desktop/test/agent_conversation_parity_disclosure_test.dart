import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/application/controller/future_client_controller.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({
  required FutureClientController controller,
}) {
  return MaterialApp(
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: LicoStrings.supportedLocales,
    theme: buildLicoTheme(
      platformBrightness: Brightness.dark,
    ).copyWith(platform: TargetPlatform.macOS),
    home: Scaffold(
      body: SizedBox(
        width: 1200,
        height: 800,
        child: AgentConversationWorkspace(
          controller: controller,
          targets: controller.scannedTargets,
          scanning: false,
          adding: false,
          onAddTarget: () async {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'workspace discloses readiness, capabilities, evidence age, and blocked cause',
    (tester) async {
      final controller = FutureClientController();
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'copilot',
          label: 'Copilot',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          adapterStatus: 'implemented',
          supportedActions: const ['runtime.message.send'],
          adapterCapabilities: {
            'conversationDriver': 'implemented',
            'conversationProtocol': 'copilot-acp-v1-stdio-ndjson',
            'conversationReadiness': 'blocked',
            'conversationBlocker': 'exact_session_resume_unavailable',
            'conversationSummaryCodes': const [
              'exact_session_resume_unavailable',
            ],
            'conversationEvidenceAge': 'missing',
            'conversationConsecutivePasses': 0,
            'conversationCapabilityMatrix': {
              'laneFamily': 'acp',
              'openNew': true,
              'exactResume': false,
              'streaming': true,
              'cancel': true,
              'officialLane': true,
            },
          },
        ),
      ];
      controller.selectedConversationAgentId = 'copilot';
      controller.selectedConversationSessionId = 'session-1';
      controller.conversationSessionsByAgent = {
        'copilot': const [
          AgentConversationSession(
            id: 'session-1',
            agentId: 'copilot',
            title: 'parity-disclosure',
            createdAt: '2026-07-11T00:00:00Z',
            updatedAt: '2026-07-11T00:00:00Z',
            adapterId: 'copilot-native-import',
            nativeSessionId: 'native-1',
            sourceKind: 'native-agent-history',
            sourcePath: 'redacted',
            messages: const [],
          ),
        ],
      };

      await tester.pumpWidget(_harness(controller: controller));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('conversation-parity-readiness')), findsOneWidget);
      expect(find.text('BLOCKED'), findsOneWidget);
      expect(find.byKey(const Key('conversation-parity-send-gate')), findsOneWidget);
      expect(
        find.byKey(const Key('conversation-parity-send-gate-reason')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Exact native session resume is unavailable'),
        findsWidgets,
      );
      expect(
        find.byKey(const Key('conversation-parity-send-gate-unblock')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('conversation-parity-readiness')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('conversation-parity-disclosure')), findsOneWidget);
      expect(
        find.byKey(const Key('conversation-parity-evidence-age')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('conversation-parity-blocked-cause')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('conversation-parity-capabilities')),
        findsOneWidget,
      );
      expect(find.textContaining('exactResume:no'), findsOneWidget);
      expect(find.textContaining('streaming:yes'), findsOneWidget);

      final disclosureText = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? '')
          .join('\n');
      expect(disclosureText.contains('/Users/'), isFalse);
      expect(disclosureText.contains('/home/'), isFalse);
    },
  );

  testWidgets(
    'send-gate shows evidence_missing reason with rescan unblock action',
    (tester) async {
      final controller = FutureClientController();
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'opencode',
          label: 'OpenCode',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          adapterStatus: 'implemented',
          supportedActions: const ['runtime.message.send'],
          adapterCapabilities: {
            'conversationReadiness': 'unverified',
            'conversationBlocker': 'evidence_missing',
            'conversationSummaryCodes': const ['evidence_missing'],
            'conversationEvidenceAge': 'missing',
            'conversationCapabilityMatrix': {
              'laneFamily': 'acp',
              'openNew': true,
              'exactResume': true,
              'streaming': true,
              'cancel': true,
              'officialLane': true,
            },
          },
        ),
      ];
      controller.selectedConversationAgentId = 'opencode';

      await tester.pumpWidget(_harness(controller: controller));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('conversation-parity-send-gate')), findsOneWidget);
      final reason = tester.widget<Text>(
        find.byKey(const Key('conversation-parity-send-gate-reason')),
      );
      expect(reason.data, contains('Current parity evidence is missing'));
      expect(
        find.byKey(const Key('conversation-parity-send-gate-unblock')),
        findsOneWidget,
      );
      expect(find.text('Scan agents'), findsOneWidget);
    },
  );
}
