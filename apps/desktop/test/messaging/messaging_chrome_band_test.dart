import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';

void main() {
  Future<ProductionClientShellFixture> pumpMessagingApp(
    WidgetTester tester, {
    ClientSection destination = ClientSection.agents,
  }) async {
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('messaging'),
      surface: LayoutRuntimeSurface.desktop,
      destination: destination,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
    );
    addTearDown(fixture.controller.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      fixture.buildApp(
        semanticsKey: const Key('messaging-chrome-band-semantics'),
        repaintBoundaryKey: const Key('messaging-chrome-band-repaint'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    return fixture;
  }

  testWidgets('opening a conversation previews a tab in the chrome band', (
    tester,
  ) async {
    final fixture = await pumpMessagingApp(tester);
    final controller = fixture.controller;
    final agentId = controller.selectedConversationAgentId;
    final session = controller.conversationSessionsByAgent[agentId]!.single;

    expect(find.byKey(const Key('messaging-chrome-tab-strip')), findsOneWidget);
    // The open conversation shows as the preview tab.
    expect(
      find.byKey(Key('messaging-chrome-tab-${session.id}')),
      findsOneWidget,
    );

    // The new-conversation home clears the preview tab.
    controller.startNewConversationSession();
    await tester.pump();
    expect(controller.selectedConversationSession, isNull);
    expect(find.byKey(Key('messaging-chrome-tab-${session.id}')), findsNothing);

    // Opening the conversation again (any selection path, here the switcher's
    // selection call) revives the preview tab; tapping it keeps the session
    // open through the tab's own selection handler.
    controller.selectConversationSession(session.id);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(controller.selectedConversationSession?.id, session.id);
    expect(
      find.byKey(Key('messaging-chrome-tab-${session.id}')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(Key('messaging-chrome-tab-${session.id}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(controller.selectedConversationAgentId, agentId);
    expect(controller.selectedConversationSession?.id, session.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned tab of a second agent navigates across agents', (
    tester,
  ) async {
    final fixture = await pumpMessagingApp(tester);
    final controller = fixture.controller;
    final agentA = controller.selectedConversationAgentId;

    // Add a second detected conversation agent with its own session.
    const agentBId = 'kimi-code';
    const agentBSession = AgentConversationSession(
      id: 'session-b',
      agentId: 'kimi-code',
      title: 'Bravo conversation',
      createdAt: '2020-01-02T03:04:00Z',
      updatedAt: '2020-01-03T03:04:00Z',
      messages: [
        AgentConversationMessage(
          id: 'm1',
          role: 'user',
          text: 'hello bravo',
          createdAt: '2020-01-03T03:04:00Z',
        ),
      ],
    );
    controller.scannedTargets = [
      ...controller.scannedTargets,
      TargetCandidate(
        id: agentBId,
        target: agentBId,
        label: 'Kimi Code',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 1,
        binaryPath: '/test-bin/kimi-code',
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationDriver': 'implemented',
          'conversationProtocol': 'deterministic-fixture',
          'conversationReadiness': 'ready',
        },
        supportedActions: const ['runtime.message.send'],
      ),
    ];
    controller.conversationSessionsByAgent = {
      ...controller.conversationSessionsByAgent,
      agentBId: const [agentBSession],
    };
    controller.agentWorkspaceNotifyConversationStructureChanged();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // Pin B's session via the send signal, then move selection back to A so
    // B shows as a pinned tab of a non-selected agent.
    await controller.selectConversationAgent(agentBId);
    controller.selectConversationSession(agentBSession.id);
    controller.isSendingConversationMessage = true;
    controller.sendingConversationSessionId = agentBSession.id;
    controller.agentWorkspaceNotifyStateChanged();
    await tester.pump();
    controller.isSendingConversationMessage = false;
    controller.sendingConversationSessionId = '';
    controller.selectedConversationAgentId = agentA;
    controller.selectedConversationSessionId = 'fixture-session';
    controller.agentWorkspaceNotifyStateChanged();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(const Key('messaging-chrome-tab-session-b')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(controller.selectedConversationAgentId, agentBId);
    expect(controller.selectedConversationSession?.id, agentBSession.id);
    expect(find.text('Bravo conversation'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plus pill starts a new conversation for the selected agent', (
    tester,
  ) async {
    final fixture = await pumpMessagingApp(tester);
    final controller = fixture.controller;

    expect(controller.selectedConversationSession, isNotNull);
    await tester.tap(find.byKey(const Key('messaging-chrome-new-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(controller.selectedConversationSession, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('notification bell empty state, badge, and agent jump', (
    tester,
  ) async {
    final fixture = await pumpMessagingApp(tester);
    final controller = fixture.controller;
    final agentId = controller.selectedConversationAgentId;

    // Empty state: no badge, dropdown shows the empty label.
    expect(
      find.byKey(const Key('messaging-notification-bell-badge')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('messaging-notification-bell')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('No notifications'), findsOneWidget);
    await tester.tap(find.byKey(const Key('messaging-notification-bell')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // With activity, the badge appears and the item jumps to the agent.
    controller.setConversationTabActivity(
      agentId,
      AgentConversationTabActivity.needsApproval,
    );
    controller.agentWorkspaceNotifyStateChanged();
    await tester.pump();
    expect(
      find.byKey(const Key('messaging-notification-bell-badge')),
      findsOneWidget,
    );

    controller.startNewConversationSession();
    await tester.pump();
    await tester.tap(find.byKey(const Key('messaging-notification-bell')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Needs approval'), findsOneWidget);

    await tester.tap(find.byKey(Key('messaging-notification-item-$agentId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    expect(controller.currentSection, ClientSection.agents);
    expect(controller.selectedConversationAgentId, agentId);
    expect(controller.selectedConversationSession, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cold-start gateway failure does not open the notification panel',
    (tester) async {
      final fixture = await pumpMessagingApp(tester);
      final controller = fixture.controller;

      await controller.llmGatewayLifecycleController.initialize();
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const Key('messaging-notification-bell-badge')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('messaging-notification-bell-panel')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('messaging-notification-bell')));
      await tester.pump();
      expect(
        find.byKey(const Key('llm-gateway-notification-item')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('llm-gateway-restart-action')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'operation feedback auto-opens the top-right notification panel',
    (tester) async {
      final fixture = await pumpMessagingApp(tester);
      final controller = fixture.controller;

      controller.agentWorkspacePublishNotification(
        id: 'subagent-mcp-cursor',
        messageChinese: '主智能体（cursor）不支持 Subagent MCP。',
        messageEnglish: 'Main agent (cursor) does not support Subagent MCP.',
        tone: MessagingNotificationTone.warning,
        code: 'subagent_mcp_unsupported',
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const Key('messaging-notification-bell-badge')),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(
        find.byKey(
          const Key(
            'messaging-operation-notification-item-subagent-mcp-cursor',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('does not support Subagent MCP'),
        findsOneWidget,
      );

      // Panel is window-anchored at the top-right, not mid-content.
      final panel = tester.getTopLeft(
        find.byKey(const Key('messaging-notification-bell-panel')),
      );
      final size = tester.getSize(find.byType(MaterialApp));
      expect(panel.dx + 300, greaterThan(size.width - 40));
      expect(panel.dy, lessThan(80));

      await tester.tapAt(const Offset(640, 400));
      await tester.pump();
      expect(
        find.byKey(const Key('messaging-notification-bell-panel')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tab tap from a non-agents section switches to the conversation',
    (tester) async {
      final fixture = await pumpMessagingApp(
        tester,
        destination: ClientSection.skillHub,
      );
      final controller = fixture.controller;

      // The fixture only seeds a conversation on the agents destination; seed
      // the same state manually so the band shows a tab to tap.
      const session = AgentConversationSession(
        id: 'fixture-session',
        agentId: '',
        title: 'Layout baseline conversation',
        createdAt: '2020-01-02T03:04:00Z',
        updatedAt: '2020-01-02T03:04:00Z',
        messages: [],
      );
      final agentId = controller.scannedTargets
          .firstWhere((target) => target.visibleInClient)
          .target;
      final seeded = AgentConversationSession(
        id: session.id,
        agentId: agentId,
        title: session.title,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        messages: session.messages,
      );
      controller.selectedConversationAgentId = agentId;
      controller.conversationSessionsByAgent = {
        ...controller.conversationSessionsByAgent,
        agentId: [seeded],
      };
      controller.selectedConversationSessionId = seeded.id;
      controller.agentWorkspaceNotifyStateChanged();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(controller.currentSection, ClientSection.skillHub);
      expect(
        find.byKey(Key('messaging-chrome-tab-${seeded.id}')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(Key('messaging-chrome-tab-${seeded.id}')));
      // Preview tabs arm the double-tap recognizer; onTap fires after its
      // timeout, so let it elapse before asserting.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(controller.currentSection, ClientSection.agents);
      expect(controller.selectedConversationAgentId, agentId);
      expect(controller.selectedConversationSession?.id, seeded.id);
      expect(find.text('Layout baseline conversation'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
