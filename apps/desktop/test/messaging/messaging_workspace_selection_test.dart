import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';
import '../layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets(
    'tapping a messaging contact lands on its new-conversation home',
    (tester) async {
      final fixture = await ProductionClientShellFixture.create(
        profileId: LayoutProfileId.parse('messaging'),
        surface: LayoutRuntimeSurface.desktop,
        destination: ClientSection.agents,
        size: const Size(1180, 820),
        brightness: Brightness.dark,
      );
      addTearDown(fixture.controller.dispose);
      final controller = fixture.controller;
      final agentId = controller.selectedConversationAgentId;
      final session = controller.conversationSessionsByAgent[agentId]!.single;

      await tester.binding.setSurfaceSize(const Size(1180, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        fixture.buildApp(
          semanticsKey: const Key('messaging-selection-semantics'),
          repaintBoundaryKey: const Key('messaging-selection-repaint'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();

      // With a conversation open, tapping the active contact returns the
      // detail to its new-conversation home and drills the sidebar into that
      // target's conversation list.
      controller.selectConversationSession(session.id);
      await tester.pump();
      expect(controller.selectedConversationSession?.id, session.id);

      // A restored selection starts inside its target list. Return to the
      // aggregate targets before exercising the target-row drill-down.
      expect(
        find.byKey(const Key('messaging-conversation-list')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('messaging-conversation-list-back')),
      );
      await tester.pump();

      await tester.tap(find.byKey(Key('messaging-contact-$agentId')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();

      expect(controller.selectedConversationAgentId, agentId);
      expect(controller.selectedConversationSession, isNull);
      expect(
        find.byKey(const Key('messaging-conversation-list')),
        findsOneWidget,
      );
      final sessionRow = find.byKey(
        Key('agents-sidebar-conversation-${session.id}'),
      );
      if (sessionRow.evaluate().isEmpty) {
        await tester.tap(
          find.byKey(const Key('agents-sidebar-earlier-toggle')),
        );
        await tester.pump();
      }
      expect(sessionRow, findsOneWidget);
      expect(find.byKey(Key('messaging-contact-$agentId')), findsNothing);

      await tester.tap(
        find.byKey(const Key('messaging-conversation-list-back')),
      );
      await tester.pump();
      expect(find.byKey(Key('messaging-contact-$agentId')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Welcome header action clears the visible conversation', (
    tester,
  ) async {
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('messaging'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      size: const Size(1180, 820),
      brightness: Brightness.dark,
    );
    addTearDown(fixture.controller.dispose);
    final controller = fixture.controller;

    await tester.binding.setSurfaceSize(const Size(1180, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      fixture.buildApp(
        semanticsKey: const Key('messaging-welcome-action-semantics'),
        repaintBoundaryKey: const Key('messaging-welcome-action-repaint'),
      ),
    );
    await tester.pump();

    final welcomeAction = find.byKey(const Key('messaging-open-welcome'));
    expect(welcomeAction, findsOneWidget);
    expect(
      find.descendant(
        of: welcomeAction,
        matching: find.byIcon(Icons.home_outlined),
      ),
      findsOneWidget,
    );

    await tester.tap(welcomeAction);
    await tester.pump();

    expect(controller.selectedConversationAgentId, isEmpty);
    expect(
      find.byKey(const Key('agent-conversation-welcome-actions')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('back from an Agent opened in a group restores the group', (
    tester,
  ) async {
    final agentService = _GroupNavigationAgentService();
    final controller = ClientController(
      agentService: agentService,
      llmGatewayMonitorInterval: Duration.zero,
    );
    addTearDown(controller.dispose);
    controller.scannedTargets = [_groupTarget];
    await controller.clientConversationController.initialize();
    await controller.clientConversationController.selectConversation(
      'conversation:local',
    );

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1180, 820);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Builder(
          builder: (context) => FixtureLayoutPresentationScope(
            child: LayoutAgentsStrategyScope(
              strategy: const AgentsPresentationStrategy.messaging(),
              child: Scaffold(
                body: AgentConversationWorkspace(
                  controller: controller,
                  targets: controller.scannedTargets,
                  scanning: false,
                  adding: false,
                  onAddTarget: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final agentAvatar = find.byKey(
      const Key('canonical-group-roster-agent-codex'),
    );
    await tester.tap(agentAvatar);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(agentAvatar);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(controller.selectedConversationAgentId, 'codex');
    expect(
      controller.clientConversationController.selectedConversationId,
      isEmpty,
    );
    expect(
      find.byKey(const Key('messaging-conversation-list-heading')),
      findsOneWidget,
    );

    final backButton = find.byKey(
      const Key('messaging-conversation-list-back'),
    );
    final backTooltip = tester.widget<Tooltip>(
      find.ancestor(of: backButton, matching: find.byType(Tooltip)),
    );
    expect(backTooltip.message, '返回');

    await tester.tap(backButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      controller.clientConversationController.selectedConversationId,
      'conversation:local',
    );
    expect(
      find.byKey(const Key('canonical-group-conversation-pane')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('messaging-conversation-list-heading')),
          )
          .data,
      'Local',
    );
    expect(tester.takeException(), isNull);
  });
}

final _groupTarget = TargetCandidate(
  id: 'codex',
  target: 'codex',
  label: 'Codex',
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
  adapterCapabilities: {
    'conversationDriver': 'implemented',
    'conversationProtocol': 'fixture',
    'conversationReadiness': 'ready',
  },
  supportedActions: ['runtime.message.send'],
);

final class _GroupNavigationAgentService extends AgentService {
  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    return {
      'ok': true,
      'result': switch (request['action']) {
        'conversation.list' => [_groupSummary],
        'conversation.get' => _groupConversation,
        'conversation.events.page' => {
          'events': <Map<String, dynamic>>[],
          'nextCursor': null,
          'totalCount': 0,
        },
        _ => <String, dynamic>{},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async => {'ok': true};
}

const Map<String, dynamic> _groupSummary = {
  'id': 'conversation:local',
  'title': 'Local',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'revision': 1,
  'updatedAtUnixMs': 2,
  'membershipCount': 2,
  'eventCount': 0,
};

const Map<String, dynamic> _groupConversation = {
  ..._groupSummary,
  'createdAtUnixMs': 1,
  'memberships': [
    {
      'id': 'membership:owner',
      'conversationId': 'conversation:local',
      'principal': {
        'id': 'human:local',
        'kind': 'human',
        'displayName': 'Local User',
        'createdAtUnixMs': 1,
      },
      'access': 'owner',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
    {
      'id': 'membership:codex',
      'conversationId': 'conversation:local',
      'principal': {
        'id': 'agent:codex',
        'kind': 'agent',
        'displayName': 'Codex',
        'agentId': 'codex',
        'createdAtUnixMs': 1,
      },
      'access': 'member',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
  ],
};
