import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

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
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
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
    final controller = ClientController(agentService: FakeAgentService());
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
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      targetFixture('codex'),
      targetFixture('cursor'),
    ];
    controller.selectedConversationAgentId = 'codex';
    controller.conversationSessionsByAgent = {
      'codex': [_activitySession('session-approval', 'codex')],
      'cursor': [_activitySession('session-finished', 'cursor')],
    };
    controller.conversationTabActivityByAgent = const {
      'codex': AgentConversationTabActivity.needsApproval,
      'cursor': AgentConversationTabActivity.workFinished,
    };

    await pumpWorkspace(tester, controller);

    final colors = buildLicoTheme(
      platformBrightness: Brightness.dark,
    ).extension<LicoThemeColors>()!;

    final approvalDot = tester.widget<Container>(
      find.byKey(const Key('agents-sidebar-activity-session-approval')),
    );
    final finishedDot = tester.widget<Container>(
      find.byKey(const Key('agents-sidebar-activity-session-finished')),
    );
    expect((approvalDot.decoration as BoxDecoration).color, colors.warning);
    expect((finishedDot.decoration as BoxDecoration).color, colors.accent);
  });

  testWidgets('selecting a sidebar agent clears unfinished work light only', (
    tester,
  ) async {
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      targetFixture('codex'),
      targetFixture('cursor'),
    ];
    controller.selectedConversationAgentId = 'codex';
    controller.conversationSessionsByAgent = {
      'codex': [_activitySession('session-1', 'codex')],
      'cursor': [_activitySession('session-2', 'cursor')],
    };
    controller.conversationTabActivityByAgent = {
      'codex': AgentConversationTabActivity.workFinished,
      'cursor': AgentConversationTabActivity.needsApproval,
    };

    await pumpWorkspace(tester, controller);
    expect(
      find.byKey(const Key('agents-sidebar-activity-session-1')),
      findsOneWidget,
    );

    await controller.selectConversationAgent('codex');
    await tester.pump();

    expect(
      find.byKey(const Key('agents-sidebar-activity-session-1')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('agents-sidebar-activity-session-2')),
      findsOneWidget,
    );
    expect(
      controller.conversationTabActivityFor('cursor'),
      AgentConversationTabActivity.needsApproval,
    );
  });
}

AgentConversationSession _activitySession(String id, String agentId) {
  final now = DateTime.now().toUtc().toIso8601String();
  return AgentConversationSession(
    id: id,
    agentId: agentId,
    title: 'Session',
    createdAt: now,
    updatedAt: now,
    messages: const [],
  );
}
