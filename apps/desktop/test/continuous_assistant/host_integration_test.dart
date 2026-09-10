import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/sidebar.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant.dart';

import 'support/continuous_assistant_test_harness.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    const noProxy = 'localhost,127.0.0.1,::1';
    final proxy =
        Platform.environment['HTTPS_PROXY'] ??
        Platform.environment['https_proxy'] ??
        Platform.environment['HTTP_PROXY'] ??
        Platform.environment['http_proxy'];
    if (proxy != null && proxy.isNotEmpty) {
      HttpOverrides.global = _KeepProxyLocalhostOverrides();
    }
    HttpClient.enableTimelineLogging = false;
    expect(
      (Platform.environment['NO_PROXY'] ?? '').contains('localhost') ||
          noProxy.contains('localhost'),
      isTrue,
    );
  });

  testWidgets('sidebar take(3) is roots only and nests typed children', (
    tester,
  ) async {
    final roots = <ClientConversationSummary>[
      for (var index = 0; index < 4; index += 1)
        ClientConversationSummary(
          id: 'conversation:root-$index',
          title: 'Root $index',
          archived: false,
          group: true,
          revision: 1,
          updatedAtUnixMs: 1,
          membershipCount: 2,
          eventCount: 1,
        ),
    ];
    final withChild = roots.first.withChildren([
      const ClientConversationSummary(
        id: 'conversation:child-a',
        title: 'Child A',
        archived: false,
        group: true,
        revision: 1,
        updatedAtUnixMs: 1,
        membershipCount: 2,
        eventCount: 3,
        parentConversationId: 'conversation:root-0',
        taskGoalId: 'goal:a',
        listingKind: 'child-task',
      ),
    ]);
    await tester.pumpWidget(
      wrapContinuousAssistant(
        CanonicalGroupConversationSidebar(
          conversations: [withChild, ...roots.skip(1)],
          selectedConversationId: 'conversation:root-0',
          onSelect: (_) {},
          onCreate: () {},
        ),
      ),
    );
    expect(find.text('Root 0'), findsOneWidget);
    expect(find.text('Root 1'), findsOneWidget);
    expect(find.text('Root 2'), findsOneWidget);
    expect(find.text('Root 3'), findsNothing);
    expect(
      find.byKey(ContinuousAssistantKeys.child('conversation:child-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('canonical-archived-continuity-toggle')),
      findsNothing,
    );
  });

  testWidgets(
    'archived continuity children stay collapsed at the list bottom',
    (tester) async {
      final root =
          ClientConversationSummary(
                id: 'conversation:root-0',
                title: 'Root 0',
                archived: false,
                group: true,
                revision: 1,
                updatedAtUnixMs: 1,
                membershipCount: 2,
                eventCount: 1,
              )
              .withChildren([
                const ClientConversationSummary(
                  id: 'conversation:child-active',
                  title: 'Active child',
                  archived: false,
                  group: true,
                  revision: 1,
                  updatedAtUnixMs: 1,
                  membershipCount: 2,
                  eventCount: 2,
                  parentConversationId: 'conversation:root-0',
                  taskGoalId: 'goal:active',
                  listingKind: 'child-task',
                ),
              ])
              .withArchivedChildren([
                const ClientConversationSummary(
                  id: 'conversation:child-archived',
                  title: 'Archived child',
                  archived: true,
                  group: true,
                  revision: 1,
                  updatedAtUnixMs: 1,
                  membershipCount: 2,
                  eventCount: 4,
                  parentConversationId: 'conversation:root-0',
                  taskGoalId: 'goal:archived',
                  listingKind: 'child-task',
                ),
              ]);
      await tester.pumpWidget(
        wrapContinuousAssistant(
          CanonicalGroupConversationSidebar(
            conversations: [root],
            selectedConversationId: 'conversation:root-0',
            onSelect: (_) {},
            onCreate: () {},
          ),
        ),
      );
      expect(
        find.byKey(ContinuousAssistantKeys.child('conversation:child-active')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          ContinuousAssistantKeys.child('conversation:child-archived'),
        ),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const Key('canonical-archived-continuity-toggle')),
      );
      await tester.pump();
      expect(
        find.byKey(
          ContinuousAssistantKeys.child('conversation:child-archived'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('parent card stays at supplied sequence and commands fire once', (
    tester,
  ) async {
    final commands = <ContinuousAssistantCommandIntent>[];
    final task = testTask(
      goalId: 'goal:host',
      childConversationId: 'conversation:child-host',
      sequence: 4,
      eventId: 'event:card-host',
      label: 'Host notes',
    );
    await tester.pumpWidget(
      wrapContinuousAssistant(
        ContinuousAssistantParentCard(
          task: task,
          initiallyExpanded: true,
          onCommand: commands.add,
        ),
      ),
    );
    expect(
      find.byKey(ContinuousAssistantKeys.sequence('goal:host')),
      findsOneWidget,
    );
    expect(find.text('4'), findsOneWidget);
    await tester.tap(find.byKey(ContinuousAssistantKeys.pause('goal:host')));
    await tester.pump();
    expect(commands, hasLength(1));
    expect(commands.single.command, ContinuityCommand.pauseGoal);
  });

  test(
    'notification center publish is suppressed by stable id at the owner',
    () {
      final center = MessagingNotificationCenter();
      center.publish(
        id: 'notice:once',
        messageChinese: '任务已完成',
        messageEnglish: 'Task completed',
        tone: MessagingNotificationTone.success,
      );
      final firstRevision = center.revision;
      // Application owner must not call publish again for the same consumed id.
      expect(firstRevision, 1);
      expect(center.items, hasLength(1));
    },
  );
}

final class _KeepProxyLocalhostOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      if (uri.host == 'localhost' ||
          uri.host == '127.0.0.1' ||
          uri.host == '::1') {
        return 'DIRECT';
      }
      return HttpClient.findProxyFromEnvironment(
        uri,
        environment: Platform.environment,
      );
    };
    return client;
  }
}
