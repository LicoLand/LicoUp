import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout/fixtures/layout_destination_presentation_fixture.dart';
import 'support/agent_conversation_workspace_fixture.dart';

Widget _harness({required ClientController controller}) {
  return MaterialApp(
    builder: (context, child) => FixtureLayoutPresentationScope(child: child!),
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
        child: AgentConversationWorkspaceFixture(
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
      final controller = ClientController();
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
          // Blocked drivers never advertise the relay action.
          supportedActions: const [],
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
            messages: [],
          ),
        ],
      };

      await tester.pumpWidget(_harness(controller: controller));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('conversation-parity-readiness')),
        findsOneWidget,
      );
      expect(find.text('Blocked'), findsOneWidget);
      expect(
        find.byKey(const Key('conversation-send-unavailable')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('conversation-send-unavailable-reason')),
        findsOneWidget,
      );
      expect(
        find.textContaining('local CLI executable was not detected'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('conversation-send-unavailable-action')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('conversation-parity-readiness')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('conversation-parity-disclosure')),
        findsOneWidget,
      );
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
      expect(disclosureText.contains(['', 'Users', ''].join('/')), isFalse);
      expect(disclosureText.contains(['', 'home', ''].join('/')), isFalse);
    },
  );

  testWidgets('unverified local agent with a relay action is not send-gated', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'opencode',
        label: 'OpenCode',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 0.9,
        binaryPath: 'test-binary-opencode',
        adapterStatus: 'implemented',
        // Local agents are client-accessible by default: parity evidence
        // stays informational and never gates local runtime use.
        supportedActions: const ['runtime.message.send'],
        adapterCapabilities: {
          'conversationDriver': 'implemented',
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

    expect(
      find.byKey(const Key('conversation-send-unavailable')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('conversation-send-unavailable-reason')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('conversation-send-unavailable-action')),
      findsNothing,
    );
  });
}
