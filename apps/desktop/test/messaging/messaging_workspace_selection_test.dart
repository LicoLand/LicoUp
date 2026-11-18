import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/agent_conversation_message.dart';
import 'package:licoup/src/contracts/agent_conversation_session.dart';
import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/contracts/target_management.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';
import '../layout/fixtures/layout_destination_presentation_fixture.dart';
import '../support/agent_conversation_workspace_fixture.dart';
import '../support/fake_conversation_transport.dart';

void main() {
  testWidgets(
    'tapping a messaging contact opens its conversation list and new-conversation home',
    (tester) async {
      final fixture = await ProductionClientShellFixture.create(
        profileId: LayoutProfileId.parse('dashboard'),
        surface: LayoutRuntimeSurface.desktop,
        destination: ClientSection.agents,
        size: const Size(1180, 820),
        brightness: Brightness.dark,
        // These assertions cover the classic card card chrome; pin the
        // preserved style rather than the new plain default.
        layoutStyleId: BuiltInLayoutSpec.dashboardCardStyleId,
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

      expect(find.byKey(const Key('messaging-sidebar-search')), findsOneWidget);
      expect(find.byKey(const Key('messaging-topstrip-search')), findsNothing);

      expect(
        find.byKey(const Key('agents-workspace-split-divider')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('messaging-sidebar-resize-handle')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('messaging-sidebar-foundation')),
          matching: find.byKey(const Key('messaging-sidebar-resize-handle')),
        ),
        findsNothing,
      );
      final sidebarCard = tester.widget<LicoPaneCard>(
        find.byKey(const Key('messaging-sidebar-column-card')),
      );
      expect(sidebarCard.borderRadius, BorderRadius.circular(14));

      // The contact list is the only sidebar level: a selected session
      // keeps the contact rows and there is no list-level back affordance.
      controller.selectConversationSession(session.id);
      await tester.pump();
      expect(controller.selectedConversationSession?.id, session.id);
      expect(find.byKey(Key('messaging-contact-$agentId')), findsOneWidget);
      expect(
        find.byKey(const Key('messaging-conversation-list')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('messaging-conversation-list-back')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('messaging-create-conversation')),
        findsOneWidget,
      );

      // A new conversation clears the session; tapping the contact row
      // then re-opens the Agent's most recent conversation directly.
      controller.startNewConversationSession();
      await tester.pump();
      expect(controller.selectedConversationSession, isNull);

      await tester.tap(find.byKey(Key('messaging-contact-$agentId')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      for (var attempt = 0; attempt < 20; attempt += 1) {
        if (!controller.isLoadingConversations) break;
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(controller.selectedConversationAgentId, agentId);
      expect(controller.selectedConversationSession?.id, session.id);
      expect(find.byKey(Key('messaging-contact-$agentId')), findsOneWidget);
      expect(
        find.byKey(const Key('messaging-conversation-list')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('member session inside a group offers Back to group', (
    tester,
  ) async {
    final agentService = _GroupNavigationAgentService();
    addTearDown(agentService.dispose);
    final controller = _GroupNavigationController(
      agentService: agentService,
      conversationNativePort: agentService,
      llmGatewayMonitorInterval: Duration.zero,
    );
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      _groupTarget,
      _historicalGroupTarget,
      _unrelatedGroupTarget,
    ];
    controller.conversationSessionsByAgent = {
      'codex': [_groupAgentSession(DateTime.now().toUtc().toIso8601String())],
    };
    await controller.clientConversationController.initialize();
    await controller.clientConversationController.selectConversation(
      'conversation:local',
    );
    await controller.hydrateGroupConversationSessions(
      controller.clientConversationController.selectedConversation!,
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
                body: AgentConversationWorkspaceFixture(
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

    expect(find.byKey(const Key('canonical-group-roster')), findsNothing);
    await tester.tap(find.byKey(const Key('canonical-group-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('canonical-group-roster-toggle')));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.groupNativeSessions.sessionsByAgent['codex'], isNotEmpty);

    // A single tap on the member opens its in-group conversation history;
    // selecting a session opens it as the member-session view inside the
    // group.
    await tester.tap(
      find.byKey(const Key('canonical-group-roster-agent-codex')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('messaging-conversation-history-menu')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('messaging-history-session-session:codex')),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(controller.selectedConversationAgentId, 'codex');
    expect(controller.selectedConversationSession?.id, 'session:codex');
    expect(
      find.byKey(const Key('canonical-group-conversation-pane')),
      findsNothing,
    );

    final backToGroup = find.byKey(
      const Key('messaging-conversation-back-to-group'),
    );
    expect(backToGroup, findsOneWidget);
    final backTooltip = tester.widget<Tooltip>(
      find.descendant(of: backToGroup, matching: find.byType(Tooltip)),
    );
    expect(backTooltip.message, '返回群组');

    await tester.tap(backToGroup);
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
      find.byKey(const Key('canonical-group-header-avatar')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.close);
  });

  testWidgets('group conversation row opens the group chat directly', (
    tester,
  ) async {
    final agentService = _GroupNavigationAgentService();
    addTearDown(agentService.dispose);
    final controller = _GroupNavigationController(
      agentService: agentService,
      conversationNativePort: agentService,
      llmGatewayMonitorInterval: Duration.zero,
    );
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      _groupTarget,
      _historicalGroupTarget,
      _unrelatedGroupTarget,
    ];
    final now = DateTime.now().toUtc().toIso8601String();
    controller.conversationSessionsByAgent = {
      'codex': [_groupAgentSession(now)],
      'claude-code': [
        _navigationSession(
          id: 'session:claude',
          agentId: 'claude-code',
          title: 'Historical group Agent detail',
          at: now,
        ),
      ],
      'kimi-code': [
        _navigationSession(
          id: 'session:kimi',
          agentId: 'kimi-code',
          title: 'Unrelated Agent detail',
          at: now,
        ),
      ],
    };
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
                body: AgentConversationWorkspaceFixture(
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

    // The sidebar holds one row per contact only — group and Agent rows,
    // never a drilled-in session list.
    final groupRow = find.byKey(
      const Key('messaging-group-conversation-conversation:local'),
    );
    expect(groupRow, findsOneWidget);
    expect(find.byKey(const Key('messaging-contact-codex')), findsOneWidget);
    expect(
      find.byKey(const Key('agents-sidebar-conversation-session:codex')),
      findsNothing,
    );
    expect(find.text('Agent detail'), findsNothing);
    expect(find.byKey(const Key('messaging-conversation-list')), findsNothing);

    // Open a member session through the roster history; only the detail
    // pane changes while the contact rows stay.
    await tester.tap(find.byKey(const Key('canonical-group-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('canonical-group-roster-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('canonical-group-roster-agent-codex')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('messaging-history-session-session:codex')),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(controller.selectedConversationAgentId, 'codex');
    expect(controller.selectedConversationSession?.id, 'session:codex');
    expect(
      find.byKey(const Key('canonical-group-conversation-pane')),
      findsNothing,
    );
    expect(groupRow, findsOneWidget);
    expect(find.byKey(const Key('messaging-contact-codex')), findsOneWidget);

    // The group row opens the group chat directly from the member view.
    await tester.tap(groupRow);
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
      find.byKey(const Key('canonical-group-header-avatar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-conversation-back-to-group')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.close);
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

final _historicalGroupTarget = _navigationTarget('claude-code', 'Claude Code');
final _unrelatedGroupTarget = _navigationTarget('kimi-code', 'Kimi Code');

TargetCandidate _navigationTarget(String id, String label) => TargetCandidate(
  id: id,
  target: id,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
  adapterCapabilities: const {
    'conversationDriver': 'implemented',
    'conversationProtocol': 'fixture',
    'conversationReadiness': 'ready',
  },
  supportedActions: const ['runtime.message.send'],
);

AgentConversationSession _groupAgentSession(String at) {
  return _navigationSession(
    id: 'session:codex',
    agentId: 'codex',
    title: 'Agent detail',
    at: at,
  );
}

AgentConversationSession _navigationSession({
  required String id,
  required String agentId,
  required String title,
  required String at,
}) {
  return AgentConversationSession(
    id: id,
    agentId: agentId,
    title: title,
    nativeSessionId: 'native:$id',
    createdAt: at,
    updatedAt: at,
    messages: [
      AgentConversationMessage(
        id: 'message:$id',
        role: 'assistant',
        text: title == 'Agent detail' ? 'Opened Agent detail' : title,
        createdAt: at,
      ),
    ],
  );
}

final class _GroupNavigationController extends ClientController {
  _GroupNavigationController({
    required super.agentService,
    required super.conversationNativePort,
    super.llmGatewayMonitorInterval,
  }) : super(memoryDiagnosticSink: const NoopClientMemoryDiagnosticSink());

  @override
  Future<ConversationSessionPage> readConversationSessionPage(
    String agentId, {
    String sessionId = '',
    required int offset,
    required int pageSize,
    String messageBefore = '',
    int? messageLimit,
    ConversationSessionProgressCallback? onProgress,
  }) async {
    if (sessionId.isEmpty) {
      return ConversationSessionPage(
        sessions: conversationSessionsByAgent[agentId] ?? const [],
        hasMore: false,
      );
    }
    expect(
      sessionId,
      isNotEmpty,
      reason: 'Group navigation must request an exact bound session.',
    );
    expect([
      'native:session:codex',
      'native:session:claude',
    ], contains(sessionId));
    return ConversationSessionPage(
      sessions: [
        _navigationSession(
          id: sessionId.substring('native:'.length),
          agentId: agentId,
          title: agentId == 'codex'
              ? 'Agent detail'
              : 'Historical group Agent detail',
          at: DateTime.now().toUtc().toIso8601String(),
        ),
      ],
      hasMore: false,
    );
  }
}

final class _GroupNavigationAgentService extends AgentService
    implements ClientConversationNativePort {
  _GroupNavigationAgentService()
    : super(conversationNativePort: FakeConversationTransport().native);

  @override
  Future<TargetScanBatch> scanTargetsBatch(
    List<String> targetIds, {
    bool enableAgentCliModelLookup = false,
  }) async => TargetScanBatch([
    for (final targetId in targetIds)
      TargetScanSlot(targetId: targetId, failed: true),
  ]);

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    final request = command.payload;
    return {
      'ok': true,
      'result': switch (request['action']) {
        'conversation.list' => [_groupSummary],
        'conversation.get' => {
          ..._groupConversation,
          if (request['includeNativeSessionReferences'] == true)
            'nativeSessionReferences': [
              {
                'membershipId': 'membership:codex',
                'agentId': 'codex',
                'nativeSessionId': 'native:session:codex',
              },
              {
                'membershipId': 'membership:claude',
                'agentId': 'claude-code',
                'nativeSessionId': 'native:session:claude',
              },
            ],
        },
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
  'membershipCount': 3,
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
    {
      'id': 'membership:claude',
      'conversationId': 'conversation:local',
      'principal': {
        'id': 'agent:claude-code',
        'kind': 'agent',
        'displayName': 'Claude Code',
        'agentId': 'claude-code',
        'createdAtUnixMs': 1,
      },
      'access': 'member',
      'status': 'left',
      'joinedAtUnixMs': 1,
      'leftAtUnixMs': 2,
    },
  ],
};
