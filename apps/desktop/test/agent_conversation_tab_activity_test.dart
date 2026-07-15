import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_conversation_tab_activity.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

void main() {
  TargetCandidate targetFixture(String id, {String status = 'detected'}) {
    return TargetCandidate(
      target: id,
      label: id,
      kind: 'native-history',
      status: status,
      configured: status == 'configured',
      confidence: 1,
      adapterStatus: 'implemented',
    );
  }

  Future<void> pumpWorkspace(
    WidgetTester tester,
    ClientController controller,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
  }

  test('approval detection uses userInteractionRequired and codes', () {
    expect(
      agentConversationResultNeedsApproval({
        'ok': false,
        'error': {'userInteractionRequired': true, 'code': 'other'},
      }),
      isTrue,
    );
    expect(
      agentConversationResultNeedsApproval({
        'ok': false,
        'error': {'code': 'codex_user_interaction_required'},
      }),
      isTrue,
    );
    expect(
      agentConversationResultNeedsApproval({
        'ok': false,
        'turnStatus': 'userInteractionRequired',
      }),
      isTrue,
    );
    expect(
      agentConversationResultNeedsApproval({
        'ok': false,
        'error': {'code': 'native_agent_timeout'},
      }),
      isFalse,
    );
  });

  testWidgets('agent sidebar hides status lights by default', (tester) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      targetFixture('codex'),
      targetFixture('cursor', status: 'configured'),
      targetFixture('claude-code', status: 'manual'),
    ];
    controller.selectedConversationAgentId = 'codex';

    await pumpWorkspace(tester, controller);

    expect(find.byKey(const Key('agent-sidebar-activity-codex')), findsNothing);
    expect(
      find.byKey(const Key('agent-sidebar-activity-cursor')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('agent-sidebar-activity-claude-code')),
      findsNothing,
    );
  });

  testWidgets('agent sidebar shows yellow for approval and blue for finished', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      targetFixture('codex'),
      targetFixture('cursor'),
    ];
    controller.selectedConversationAgentId = 'codex';
    controller.conversationTabActivityByAgent = const {
      'codex': AgentConversationTabActivity.needsApproval,
      'cursor': AgentConversationTabActivity.workFinished,
    };

    await pumpWorkspace(tester, controller);

    final colors = buildLicoTheme(
      platformBrightness: Brightness.dark,
    ).extension<LicoThemeColors>()!;

    final approvalDot = tester.widget<Container>(
      find.byKey(const Key('agent-sidebar-activity-codex')),
    );
    final finishedDot = tester.widget<Container>(
      find.byKey(const Key('agent-sidebar-activity-cursor')),
    );
    expect((approvalDot.decoration as BoxDecoration).color, colors.warning);
    expect((finishedDot.decoration as BoxDecoration).color, colors.info);
  });

  testWidgets('selecting a sidebar agent clears unfinished work light only', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      targetFixture('codex'),
      targetFixture('cursor'),
    ];
    controller.selectedConversationAgentId = 'codex';
    controller.conversationSessionsByAgent = {
      'codex': [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'codex',
          title: 'Session',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          messages: const [],
        ),
      ],
    };
    controller.conversationTabActivityByAgent = {
      'codex': AgentConversationTabActivity.workFinished,
      'cursor': AgentConversationTabActivity.needsApproval,
    };

    await pumpWorkspace(tester, controller);
    expect(
      find.byKey(const Key('agent-sidebar-activity-codex')),
      findsOneWidget,
    );

    await controller.selectConversationAgent('codex');
    await tester.pump();

    expect(find.byKey(const Key('agent-sidebar-activity-codex')), findsNothing);
    expect(
      find.byKey(const Key('agent-sidebar-activity-cursor')),
      findsOneWidget,
    );
    expect(
      controller.conversationTabActivityFor('cursor'),
      AgentConversationTabActivity.needsApproval,
    );
  });
}
