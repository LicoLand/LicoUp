import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

import 'layout/fixtures/layout_destination_presentation_fixture.dart';
import 'support/agent_conversation_workspace_fixture.dart';

void main() {
  testWidgets(
    'group sidebar renders only explicitly associated native sessions',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final native = _Native();
      final service = _Service();
      addTearDown(service.dispose);
      final controller = _SidebarController(
        agentService: service,
        conversationNativePort: native,
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: false,
          confidence: 1,
          adapterStatus: 'implemented',
        ),
      ];
      controller.conversationSessionsByAgent = {
        'codex': [
          for (final id in [
            'old',
            'new',
            'unrelated',
            for (var i = 0; i < 500; i++) 'unrelated-$i',
          ])
            AgentConversationSession(
              id: 'catalog:$id',
              agentId: 'codex',
              title: 'Synthetic $id',
              nativeSessionId: id,
              createdAt: DateTime.now().toUtc().toIso8601String(),
              updatedAt: DateTime.now().toUtc().toIso8601String(),
              messages: const [],
            ),
        ],
      };
      await controller.clientConversationController.initialize();
      await controller.clientConversationController.selectConversation('group');
      expect(
        controller
            .clientConversationController
            .selectedConversation
            ?.nativeSessionReferences,
        hasLength(2),
      );
      await controller.hydrateGroupConversationSessions(
        controller.clientConversationController.selectedConversation!,
      );
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex'],
        hasLength(2),
      );
      expect(controller.readIds, unorderedEquals(['old', 'new']));
      expect(controller.conversationSessionsByAgent['codex'], hasLength(503));
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          builder: (context, child) =>
              FixtureLayoutPresentationScope(child: child!),
          home: Scaffold(
            body: LayoutAgentsStrategyScope(
              strategy: const AgentsPresentationStrategy.messaging(),
              child: AgentConversationWorkspaceFixture(
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
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.takeException(), isNull);
      final contacts = tester.widget<MessagingContactList>(
        find.byType(MessagingContactList),
      );
      expect(contacts.sessionsByAgent['codex'], hasLength(2));
      expect(contacts.showConversationList, isTrue);
      expect(contacts.conversationListTargets, hasLength(1));
      expect(find.text('Synthetic old'), findsOneWidget);
      expect(find.text('Synthetic new'), findsOneWidget);
      expect(find.text('Synthetic unrelated'), findsNothing);
      expect(
        tester
            .widget<MessagingContactList>(find.byType(MessagingContactList))
            .onPrefetchSessions,
        isNull,
      );
      native.associated = false;
      await controller.clientConversationController.reloadSelected();
      await tester.pump();
      expect(find.text('Synthetic old'), findsNothing);
      expect(find.text('Synthetic new'), findsNothing);
      expect(find.text('Synthetic unrelated'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      controller.clientConversationController.dispose();
    },
  );
}

class _Service extends AgentService {
  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async => {
    'ok': true,
    'sessions': <Object>[],
    'turns': <Object>[],
  };
  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => runCli(args);
}

class _SidebarController extends ClientController {
  _SidebarController({
    required super.agentService,
    required super.conversationNativePort,
  });
  final readIds = <String>[];
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
    expect(
      sessionId,
      isNotEmpty,
      reason: 'Group sidebar cannot browse all Agent history.',
    );
    readIds.add(sessionId);
    return ConversationSessionPage(
      sessions: [
        AgentConversationSession(
          id: 'catalog:$sessionId',
          agentId: agentId,
          title: 'Synthetic $sessionId',
          nativeSessionId: sessionId,
          createdAt: '2026-09-13T00:00:00Z',
          updatedAt: '2026-09-13T00:00:00Z',
          messages: const [],
        ),
      ],
      hasMore: false,
    );
  }

  @override
  AgentConversationGateway get conversationGateway => _Gateway();
}

class _Gateway implements AgentConversationGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected synthetic history read');
}

class _Native implements ClientConversationNativePort {
  bool associated = true;
  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    final request = command.payload;
    final conversation = {
      'id': 'group',
      'title': 'Synthetic group',
      'isGroup': true,
      'archived': false,
      'revision': associated ? 1 : 2,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 1,
      'eventCount': 0,
      'memberships': [
        {
          'id': 'member',
          'conversationId': 'group',
          'access': 'member',
          'status': 'active',
          'principal': {
            'id': 'agent:codex',
            'kind': 'agent',
            'agentId': 'codex',
            'displayName': 'Codex',
          },
        },
      ],
      if (request['includeNativeSessionReferences'] == true)
        'nativeSessionReferences': [
          if (associated)
            for (final id in ['old', 'new'])
              {
                'membershipId': 'member',
                'agentId': 'codex',
                'nativeSessionId': id,
              },
        ],
    };
    return {
      'ok': true,
      'result': switch (request['action']) {
        'conversation.list' => [conversation],
        'conversation.get' => conversation,
        'conversation.events.page' => {
          'events': <Object>[],
          'totalCount': 0,
          'hasEarlier': false,
        },
        _ => <String, dynamic>{},
      },
    };
  }
}
