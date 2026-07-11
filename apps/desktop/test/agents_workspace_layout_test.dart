import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/application/controller/future_client_controller.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/history_session_panel.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('agent workspace does not overflow in a narrow app window', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'copilot',
        label: 'Copilot',
        kind: 'native-history-with-long-kind-label',
        status: 'detected',
        configured: false,
        confidence: 0.84,
        adapterStatus: 'implemented',
      ),
      TargetCandidate(
        target: 'code',
        label: 'VS Code',
        kind: 'desktop-agent',
        status: 'detected',
        configured: false,
        confidence: 0.88,
        adapterStatus: 'unsupported',
      ),
      TargetCandidate(
        target: 'kilo-code',
        label: 'Kilo Code',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
      TargetCandidate(
        target: 'openclaw',
        label: 'OpenClaw',
        kind: 'cli',
        status: 'not-detected',
        configured: false,
        confidence: 0.15,
        adapterStatus: 'unsupported',
      ),
    ];
    controller.selectedConversationAgentId = 'copilot';
    controller.selectedConversationSessionId = 'session-1';
    controller.conversationSessionsByAgent = {
      'copilot': const [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'copilot',
          title: 'key: workspace-history-with-a-long-title',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'copilot-native-import',
          nativeSessionId: 'native-session-with-long-identifier',
          sourceKind: 'native-agent-history',
          sourcePath: '<user-home>/.config/copilot/history/session.jsonl',
          messages: [
            AgentConversationMessage(
              id: 'message-1',
              role: 'assistant',
              text:
                  'A long native agent history preview should wrap inside the available message column instead of pushing adjacent controls outside the window.',
              createdAt: '2026-06-15T00:00:00Z',
            ),
          ],
        ),
        AgentConversationSession(
          id: 'session-2',
          agentId: 'copilot',
          title: 'second runtime conversation',
          createdAt: '2026-06-16T00:00:00Z',
          updatedAt: '2026-06-16T00:00:00Z',
          adapterId: 'copilot-native-import',
          nativeSessionId: 'native-session-2',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-2',
              role: 'user',
              text: 'Follow up from another imported native history.',
              createdAt: '2026-06-16T00:00:00Z',
            ),
          ],
        ),
      ],
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 540,
            height: 560,
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

    expect(tester.takeException(), isNull);
    expect(find.text('Copilot'), findsWidgets);
    expect(
      find.byKey(const Key('conversation-parity-readiness')),
      findsOneWidget,
    );
    expect(find.text('UNVERIFIED'), findsOneWidget);
    expect(find.text('VS Code'), findsNothing);
    expect(find.text('Kilo Code'), findsOneWidget);
    expect(find.text('OpenClaw'), findsNothing);
    expect(find.text('Not detected'), findsNothing);
    expect(find.text('Conversation history'), findsNothing);
    expect(find.text('Search conversations'), findsNothing);
    expect(find.byTooltip('Archive agent conversations'), findsOneWidget);
    expect(find.byTooltip('New Conversation'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byTooltip('Archive agent conversations')).dx,
      lessThan(tester.getTopLeft(find.byTooltip('New Conversation')).dx),
    );
    expect(find.byTooltip('Collapse conversation history'), findsOneWidget);
    expect(
      find.text('key: workspace-history-with-a-long-title'),
      findsNWidgets(2),
    );
    expect(find.text('second runtime conversation'), findsOneWidget);
    expect(find.textContaining('Updated'), findsNothing);
    expect(find.textContaining('2026-06-15'), findsOneWidget);
    expect(find.textContaining('2026-06-16'), findsOneWidget);
    expect(
      find.textContaining(
        'A long native agent history preview should wrap inside the available message column',
      ),
      findsWidgets,
    );
    expect(find.textContaining('2 messages'), findsNothing);
    expect(find.textContaining('native-agent-history'), findsNothing);
    expect(
      find.textContaining('native-session-with-long-identifier'),
      findsNothing,
    );
    expect(find.text('Local agents'), findsNothing);
    expect(find.text('Inspect'), findsNothing);
    expect(find.text('Plan'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);

    await tester.tap(find.byTooltip('New Conversation'));
    await tester.pump();

    expect(controller.selectedConversationSessionId, isEmpty);
    expect(controller.selectedConversationSession, isNull);

    await tester.tap(find.byTooltip('Collapse conversation history'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Archive agent conversations'), findsNothing);
    expect(find.byTooltip('New Conversation'), findsNothing);
    expect(find.byTooltip('Expand conversation history'), findsOneWidget);
  });

  testWidgets('structured events converge into one accessible process card', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final controller = FutureClientController();
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
    controller.selectedConversationSessionId = 'session-events';
    controller.conversationSessionsByAgent = {
      'codex': [
        AgentConversationSession.fromJson({
          'id': 'session-events',
          'agentId': 'codex',
          'title': 'Structured events',
          'createdAt': '2026-06-15T00:00:00Z',
          'updatedAt': '2026-06-15T00:00:06Z',
          'messages': [
            {
              'id': 'message-user',
              'role': 'user',
              'text': 'Inspect and validate the workspace.',
              'createdAt': '2026-06-15T00:00:01Z',
            },
            {
              'id': 'message-tool',
              'role': 'function_call',
              'cardTitle': 'exec_command',
              'text':
                  '{"cmd":"read /workspace/private/source.rs","access_token":"secret-value"}',
              'createdAt': '2026-06-15T00:00:02Z',
            },
            {
              'id': 'message-reasoning',
              'role': 'reasoning',
              'providerSummary': true,
              'text':
                  'Inspected the adapter under /workspace/private/project and verified cleanup; api_key=secret-value.',
              'createdAt': '2026-06-15T00:00:03Z',
            },
            {
              'id': 'message-metadata',
              'role': 'metadata',
              'text':
                  '{"cwd":"/workspace/private/project","api_key":"secret-value"}',
              'createdAt': '2026-06-15T00:00:04Z',
            },
            {
              'id': 'message-error',
              'role': 'error',
              'text':
                  'Operation failed under /workspace/private/project with api_key=secret-value',
              'createdAt': '2026-06-15T00:00:05Z',
            },
            {
              'id': 'message-event',
              'role': 'lifecycle_notice',
              'text': 'Cleanup started.',
              'createdAt': '2026-06-15T00:00:06Z',
              'messages': [
                {
                  'id': 'message-container',
                  'role': 'assistant',
                  'text': 'Nested event container',
                  'createdAt': '2026-06-15T00:00:06Z',
                  'messages': [
                    {
                      'id': 'message-nested-error',
                      'role': 'system',
                      'cardType': 'runtime.error',
                      'text':
                          'thread_id=private-thread Nested operation failed.',
                      'createdAt': '2026-06-15T00:00:06.500Z',
                    },
                  ],
                },
              ],
            },
            {
              'id': 'message-assistant',
              'role': 'assistant',
              'text': 'Validation completed.',
              'createdAt': '2026-06-15T00:00:07Z',
            },
          ],
        }),
      ],
    };
    expect(controller.selectedConversationSession?.messages, hasLength(7));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 820,
            height: 800,
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
    await tester.pump(const Duration(milliseconds: 50));

    const processKey = Key('conversation-process-message-tool');
    const processToggleKey = Key('conversation-process-toggle-message-tool');
    const processSemanticsKey = Key(
      'conversation-process-semantics-message-tool',
    );

    expect(find.byKey(processKey), findsOneWidget);
    expect(find.text('Worked for 5s'), findsOneWidget);
    expect(find.text('6 steps · 2 issues'), findsOneWidget);
    expect(find.text('Inspect and validate the workspace.'), findsOneWidget);
    expect(find.text('Validation completed.'), findsWidgets);
    expect(
      tester.getSize(find.byKey(processToggleKey)).height,
      greaterThanOrEqualTo(44),
    );
    expect(
      tester.getSemantics(find.byKey(processSemanticsKey)),
      isSemantics(
        label: 'Agent process. Worked for 5s. 6 steps · 2 issues.',
        hint: 'Expand process details',
        isButton: true,
        isFocusable: true,
        hasExpandedState: true,
        isExpanded: false,
        hasTapAction: true,
      ),
    );
    expect(
      find.byKey(const Key('conversation-event-message-tool')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('conversation-event-message-error')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('conversation-process-operation-message-tool')),
      findsNothing,
    );
    expect(
      find.text('Invocation details are hidden.', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('Operation failed', findRichText: true),
      findsNothing,
    );
    expect(find.textContaining('secret-value'), findsNothing);
    expect(find.textContaining('/workspace/private'), findsNothing);
    expect(find.textContaining('{"'), findsNothing);

    await tester.tap(find.byKey(processToggleKey));
    await tester.pump(const Duration(milliseconds: 220));

    expect(
      find.byKey(const Key('conversation-process-operation-message-tool')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-process-operation-message-reasoning')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-process-operation-message-metadata')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-process-operation-message-error')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-process-operation-message-event')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('conversation-process-operation-message-nested-error'),
      ),
      findsOneWidget,
    );
    expect(find.text('exec_command'), findsOneWidget);
    expect(find.text('Reasoning summary'), findsOneWidget);
    expect(find.text('Metadata'), findsOneWidget);
    expect(find.text('Error'), findsNWidgets(2));
    expect(find.text('Native event'), findsOneWidget);
    expect(
      find.text('Invocation details are hidden.', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Inspected the adapter under', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Operation failed', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('secret-value'), findsNothing);
    expect(find.textContaining('/workspace/private'), findsNothing);
    expect(find.textContaining('private-thread'), findsNothing);
    expect(find.textContaining('{"'), findsNothing);
    expect(
      tester.getSemantics(find.byKey(processSemanticsKey)),
      isSemantics(hasExpandedState: true, isExpanded: true, hasTapAction: true),
    );

    await tester.tap(find.byKey(processToggleKey));
    await tester.pump(const Duration(milliseconds: 220));

    expect(
      find.byKey(const Key('conversation-process-operation-message-tool')),
      findsNothing,
    );

    final processToggle = tester.widget<InkWell>(find.byKey(processToggleKey));
    processToggle.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 220));

    expect(
      find.byKey(const Key('conversation-process-operation-message-tool')),
      findsOneWidget,
    );

    final currentSession = controller.selectedConversationSession!;
    controller.conversationSessionsByAgent = {
      'codex': [
        AgentConversationSession(
          id: currentSession.id,
          agentId: currentSession.agentId,
          title: currentSession.title,
          createdAt: currentSession.createdAt,
          updatedAt: '2026-06-15T00:00:08Z',
          messages: [
            ...currentSession.messages,
            const AgentConversationMessage(
              id: 'message-assistant-appended',
              role: 'assistant',
              text: 'A later final answer.',
              createdAt: '2026-06-15T00:00:08Z',
            ),
          ],
        ),
      ],
    };
    controller.selectConversationSession('session-events');
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-process-operation-message-tool')),
      findsOneWidget,
    );

    controller.conversationSessionsByAgent = {
      'codex': [
        ...controller.conversationSessionsByAgent['codex']!,
        const AgentConversationSession(
          id: 'session-events-2',
          agentId: 'codex',
          title: 'Second structured session',
          createdAt: '2026-06-15T01:00:00Z',
          updatedAt: '2026-06-15T01:00:01Z',
          messages: [
            AgentConversationMessage(
              id: 'message-tool',
              role: 'tool_call',
              cardType: 'tool-call',
              cardTitle: 'exec_command',
              text: 'Invocation details are hidden.',
              createdAt: '2026-06-15T01:00:01Z',
            ),
          ],
        ),
      ],
    };
    controller.selectConversationSession('session-events-2');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('conversation-process-operation-message-tool')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'long process stays operable, bounded, and localized after expansion',
    (tester) async {
      final controller = FutureClientController();
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
      controller.selectedConversationSessionId = 'long-process';
      controller.conversationSessionsByAgent = {
        'codex': [
          AgentConversationSession(
            id: 'long-process',
            agentId: 'codex',
            title: 'Long process',
            createdAt: '2026-06-15T00:00:00Z',
            updatedAt: '2026-06-15T00:02:09Z',
            messages: [
              for (var index = 0; index < 130; index++)
                AgentConversationMessage(
                  id: 'long-event-$index',
                  role: 'event',
                  cardType: 'event',
                  text: 'Safe operation ${index + 1}',
                  createdAt: DateTime.utc(
                    2026,
                    6,
                    15,
                  ).add(Duration(seconds: index)).toIso8601String(),
                ),
            ],
          ),
        ],
      };

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
          home: Scaffold(
            body: SizedBox(
              width: 720,
              height: 360,
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
      await tester.pumpAndSettle();

      const toggleKey = Key('conversation-process-toggle-long-event-0');
      expect(find.text('处理了 2分钟 9秒'), findsOneWidget);
      expect(find.text('130 个步骤'), findsOneWidget);
      expect(find.text('Safe operation 1', findRichText: true), findsNothing);

      await tester.ensureVisible(find.byKey(toggleKey));
      await tester.pump();
      await tester.tap(find.byKey(toggleKey));
      await tester.pump(const Duration(milliseconds: 240));

      expect(find.text('为保持对话流畅，其余操作已隐藏。'), findsOneWidget);
      expect(find.text('Safe operation 1', findRichText: true), findsOneWidget);
      expect(find.text('Safe operation 129', findRichText: true), findsNothing);
      final listFinder = find
          .ancestor(
            of: find.byKey(toggleKey),
            matching: find.byType(Scrollable),
          )
          .first;
      final toggleRect = tester.getRect(find.byKey(toggleKey));
      final listRect = tester.getRect(listFinder);
      expect(toggleRect.top, greaterThanOrEqualTo(listRect.top));
      expect(toggleRect.bottom, lessThanOrEqualTo(listRect.bottom));

      await tester.tap(find.byKey(toggleKey));
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text('Safe operation 1', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'truncation and hidden operation details stay explicit and localized',
    (tester) async {
      final controller = FutureClientController();
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
      controller.selectedConversationSessionId = 'truncated-process';
      controller.conversationSessionsByAgent = {
        'codex': [
          const AgentConversationSession(
            id: 'truncated-process',
            agentId: 'codex',
            title: 'Truncated process',
            createdAt: '2026-06-15T00:00:00Z',
            updatedAt: '2026-06-15T00:00:02Z',
            historyTruncated: true,
            messageTreeTruncated: true,
            messages: [
              AgentConversationMessage(
                id: 'user-before-process',
                role: 'user',
                text: '检查过程',
                createdAt: '2026-06-15T00:00:00Z',
              ),
              AgentConversationMessage(
                id: 'tool-hidden',
                role: 'tool_call',
                cardType: 'tool-call',
                cardTitle: 'exec',
                text: '',
                createdAt: '2026-06-15T00:00:01Z',
                childMessagesTruncated: true,
              ),
              AgentConversationMessage(
                id: 'final-after-process',
                role: 'assistant',
                text: '最终消息仍保留。',
                createdAt: '2026-06-15T00:00:02Z',
              ),
            ],
          ),
        ],
      };

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
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: SizedBox(
                width: 720,
                height: 520,
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
        ),
      );
      await tester.pumpAndSettle();

      const toggleKey = Key('conversation-process-toggle-tool-hidden');
      final truncationNotice = find.text('较早消息和部分嵌套过程详情未载入；当前显示最近的完整对话骨架。');
      await tester.scrollUntilVisible(
        truncationNotice,
        120,
        scrollable: find
            .ancestor(
              of: find.byKey(toggleKey),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(truncationNotice, findsOneWidget);
      expect(find.text('最终消息仍保留。'), findsWidgets);
      expect(find.text('调用详情已隐藏。', findRichText: true), findsNothing);

      await tester.tap(find.byKey(toggleKey));
      await tester.pump();

      expect(find.text('调用详情已隐藏。', findRichText: true), findsOneWidget);
      expect(find.text('Invocation details are hidden.'), findsNothing);
      expect(find.text('为保持对话流畅，其余操作已隐藏。'), findsOneWidget);
      expect(
        find.byKey(const Key('conversation-process-tool-hidden')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('runtime composer selects discovered model settings', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 0.9,
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationDriver': 'implemented',
          'conversationProtocol': 'codex-app-server-stdio-jsonrpc',
          'conversationReadiness': 'ready',
        },
        supportedActions: const ['runtime.message.send'],
        modelCatalog: const {
          'status': 'available',
          'models': [
            {
              'name': 'model-canary',
              'reasoningEfforts': ['high'],
            },
          ],
        },
      ),
    ];
    controller.selectedConversationAgentId = 'codex';

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 760,
            height: 520,
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
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('conversation-model-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Model · model-canary').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('conversation-reasoning-select')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reasoning · high').last);
    await tester.pumpAndSettle();

    expect(controller.selectedConversationModel, 'model-canary');
    expect(controller.selectedConversationReasoningEffort, 'high');
    expect(tester.takeException(), isNull);
  });

  testWidgets('agent messages collapse additional metadata blocks', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'antigravity',
        label: 'Antigravity',
        kind: 'native-history',
        status: 'detected',
        configured: false,
        confidence: 0.9,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'antigravity';
    controller.selectedConversationSessionId = 'session-metadata';
    controller.conversationSessionsByAgent = {
      'antigravity': const [
        AgentConversationSession(
          id: 'session-metadata',
          agentId: 'antigravity',
          title: 'Metadata rendering',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'antigravity',
          nativeSessionId: 'antigravity-session',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-agent',
              role: 'assistant',
              text:
                  'Visible answer.\n\n<ADDITIONAL_METADATA>\nThe current local time is hidden.\nActive Document: hidden.md\n</ADDITIONAL_METADATA>\n\nNext visible line.',
              createdAt: '2026-06-15T00:00:00Z',
            ),
          ],
        ),
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 760,
            height: 520,
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

    await tester.pumpAndSettle();

    expect(
      find.textContaining('Visible answer', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('Next visible line', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('ADDITIONAL_METADATA', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('Active Document', findRichText: true),
      findsNothing,
    );
    expect(find.text('Details'), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Active Document', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('ADDITIONAL_METADATA', findRichText: true),
      findsNothing,
    );
  });

  test(
    'splitMessageDisplayBlocks extracts recommended plugins and metadata',
    () {
      final display = splitMessageDisplayBlocks('''
Visible answer.

<recommended_plugins>
Here is a list of plugins that are available but not installed.

- Atlassian Rovo (atlassian-rovo@openai-curated-remote)
- Google Drive (google-drive@openai-curated-remote)
</recommended_plugins>

<additional_metadata>
Hidden detail.
</additional_metadata>
''');

      expect(display.body.trim(), 'Visible answer.');
      expect(display.recommendedPluginsBlocks, hasLength(1));
      expect(
        display.recommendedPluginsBlocks.first,
        contains('Atlassian Rovo'),
      );
      expect(display.recommendedPluginsBlocks.first, contains('Google Drive'));
      expect(display.metadataBlocks, ['Hidden detail.']);
    },
  );

  test('recommendedPluginsCount counts markdown bullet items', () {
    expect(recommendedPluginsCount(const []), 0);
    expect(recommendedPluginsCount(const ['- One\n- Two\n* Three']), 3);
    expect(
      recommendedPluginsCount(const [
        'Intro text\n- Plugin A (id-a)\n- Plugin B (id-b)',
        '- Plugin C',
      ]),
      3,
    );
  });

  testWidgets('agent messages collapse recommended plugins by default', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'antigravity',
        label: 'Antigravity',
        kind: 'native-history',
        status: 'detected',
        configured: false,
        confidence: 0.9,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'antigravity';
    controller.selectedConversationSessionId = 'session-plugins';
    controller.conversationSessionsByAgent = {
      'antigravity': const [
        AgentConversationSession(
          id: 'session-plugins',
          agentId: 'antigravity',
          title: 'Recommended plugins',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'antigravity',
          nativeSessionId: 'antigravity-session',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-agent',
              role: 'assistant',
              text:
                  'Visible answer.\n\n<recommended_plugins>\nHere is a list of plugins that are available but not installed.\n\n- Atlassian Rovo (atlassian-rovo@openai-curated-remote)\n- Google Drive (google-drive@openai-curated-remote)\n</recommended_plugins>',
              createdAt: '2026-06-15T00:00:00Z',
            ),
          ],
        ),
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 760,
            height: 520,
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

    await tester.pumpAndSettle();

    expect(
      find.textContaining('Visible answer', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('recommended_plugins', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('Atlassian Rovo', findRichText: true),
      findsNothing,
    );
    expect(find.text('Recommended Plugins · 2'), findsOneWidget);

    await tester.tap(find.text('Recommended Plugins · 2'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Atlassian Rovo', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Google Drive', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('recommended_plugins', findRichText: true),
      findsNothing,
    );
  });

  test('agent tab wheel direction maps up to forward and down to back', () {
    expect(
      agentTabWheelTargetOffset(
        currentOffset: 100,
        minScrollExtent: 0,
        maxScrollExtent: 600,
        scrollDeltaY: -120,
        step: 184,
      ),
      284,
    );
    expect(
      agentTabWheelTargetOffset(
        currentOffset: 284,
        minScrollExtent: 0,
        maxScrollExtent: 600,
        scrollDeltaY: 120,
        step: 184,
      ),
      100,
    );
    expect(
      agentTabWheelTargetOffset(
        currentOffset: 560,
        minScrollExtent: 0,
        maxScrollExtent: 600,
        scrollDeltaY: -120,
        step: 184,
      ),
      600,
    );
  });

  test('agent tab width shrinks between browser-style bounds', () {
    expect(
      agentTabWidthFor(
        availableWidth: 800,
        tabCount: 4,
        minWidth: 104,
        maxWidth: 172,
      ),
      172,
    );
    expect(
      agentTabWidthFor(
        availableWidth: 600,
        tabCount: 4,
        minWidth: 104,
        maxWidth: 172,
      ),
      150,
    );
    expect(
      agentTabWidthFor(
        availableWidth: 500,
        tabCount: 6,
        minWidth: 104,
        maxWidth: 172,
      ),
      104,
    );
  });

  test('agent orchestration uses scanned model catalogs without fallback', () {
    final missingCatalogTarget = TargetCandidate(
      target: 'antigravity',
      label: 'Antigravity',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 0.9,
      adapterStatus: 'implemented',
    );
    expect(agentOrchestrationCommanderModels(missingCatalogTarget), isEmpty);
    expect(
      agentOrchestrationModelLibraryCandidates([missingCatalogTarget]),
      isEmpty,
    );

    final antigravity = TargetCandidate(
      target: 'antigravity',
      label: 'Antigravity',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 0.9,
      adapterStatus: 'implemented',
      modelCatalog: const {
        'status': 'available',
        'models': [
          {'name': 'Gemini 3.5 Flash (Medium)', 'reasoningEfforts': []},
          {'name': 'Claude Opus 4.6 (Thinking)', 'reasoningEfforts': []},
        ],
      },
    );
    expect(agentOrchestrationCommanderModels(antigravity), [
      'Gemini 3.5 Flash (Medium)',
      'Claude Opus 4.6 (Thinking)',
    ]);

    final codex = TargetCandidate(
      target: 'codex',
      label: 'Codex',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 0.9,
      adapterStatus: 'implemented',
      adapterCapabilities: const {
        'conversationDriver': 'implemented',
        'conversationReadiness': 'ready',
      },
      supportedActions: const ['runtime.message.send'],
      modelCatalog: const {
        'status': 'available',
        'models': [
          {
            'name': 'gpt-5.5',
            'displayName': 'GPT-5.5',
            'reasoningEfforts': ['high'],
          },
        ],
      },
    );
    expect(agentOrchestrationCommanderModels(codex), ['gpt-5.5']);
    expect(agentOrchestrationModelDisplayName(codex, 'gpt-5.5'), 'GPT-5.5');
    expect(agentOrchestrationReasoningEffortsForModel(codex, 'gpt-5.5'), [
      'high',
    ]);

    final realReasoningTarget = TargetCandidate(
      target: 'claude-code',
      label: 'Claude Code',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 0.9,
      adapterStatus: 'implemented',
      adapterCapabilities: const {
        'conversationDriver': 'implemented',
        'conversationReadiness': 'ready',
      },
      supportedActions: const ['runtime.message.send'],
      modelCatalog: const {
        'status': 'available',
        'models': [
          {
            'name': 'deepseek-v4-flash',
            'reasoningEfforts': ['thinking-fast', 'thinking-deep'],
          },
        ],
      },
    );
    expect(agentOrchestrationReasoningEffortsFor(realReasoningTarget), [
      'thinking-fast',
      'thinking-deep',
    ]);
    expect(
      agentOrchestrationModelLibraryCandidates([
        realReasoningTarget,
      ]).map((entry) => entry.key),
      containsAll([
        const AgentModelLibraryEntry(
          agentId: 'claude-code',
          modelName: 'deepseek-v4-flash',
          reasoningEffort: 'thinking-fast',
        ).key,
        const AgentModelLibraryEntry(
          agentId: 'claude-code',
          modelName: 'deepseek-v4-flash',
          reasoningEffort: 'thinking-deep',
        ).key,
      ]),
    );
  });

  testWidgets('wide agent workspace uses a draggable split divider', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'claude-code',
        label: 'Claude Code',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'claude-code';
    controller.selectedConversationSessionId = 'session-1';
    controller.conversationSessionsByAgent = {
      'claude-code': const [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'claude-code',
          title: 'Resizable split conversation',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'claude-code',
          nativeSessionId: 'claude-session',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-1',
              role: 'assistant',
              text: 'Split pane body',
              createdAt: '2026-06-15T00:00:00Z',
            ),
          ],
        ),
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 520,
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
    await tester.pumpAndSettle();

    final historyFinder = find.byType(HistorySessionPanel);
    final splitPageFinder = find.byKey(const Key('conversation-split-page'));
    final dividerFinder = find.byKey(const Key('conversation-split-divider'));
    expect(historyFinder, findsOneWidget);
    expect(splitPageFinder, findsOneWidget);
    expect(
      find.ancestor(of: splitPageFinder, matching: find.byType(ClipRRect)),
      findsNothing,
    );
    expect(dividerFinder, findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(AgentConversationTabBar)).dy,
      tester.getTopLeft(splitPageFinder).dy,
    );
    expect(
      tester.getTopLeft(find.byType(Divider).at(0)).dy,
      tester.getTopLeft(find.byType(Divider).at(1)).dy,
    );
    expect(find.text('Resizable split conversation'), findsWidgets);
    expect(find.text('Claude Code · 1 messages'), findsNothing);

    final initialWidth = tester.getSize(historyFinder).width;
    expect(initialWidth, 260);

    await tester.drag(dividerFinder, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(historyFinder).width, greaterThan(initialWidth));

    await tester.drag(dividerFinder, const Offset(-900, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(historyFinder).width, greaterThanOrEqualTo(260));
  });

  testWidgets('agent message list defaults to latest messages', (tester) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'codex';
    controller.selectedConversationSessionId = 'session-1';
    controller.conversationSessionsByAgent = {
      'codex': [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'codex',
          title: 'Long imported Codex conversation',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'codex',
          nativeSessionId: 'codex-session',
          sourceKind: 'native-agent-history',
          messages: [
            for (var index = 0; index < 18; index++)
              AgentConversationMessage(
                id: 'message-$index',
                role: index.isEven ? 'user' : 'assistant',
                text: index == 0
                    ? 'Oldest imported prompt'
                    : index == 17
                    ? 'Newest imported answer'
                    : 'Imported message $index',
                createdAt: '2026-06-15T00:00:00Z',
              ),
          ],
        ),
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 420,
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

    await tester.pumpAndSettle();

    expect(find.text('Newest imported answer'), findsWidgets);
    expect(find.text('Oldest imported prompt'), findsNothing);
  });

  testWidgets('agent message list renders subagent output as collapsed card', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'codex';
    controller.selectedConversationSessionId = 'session-1';
    controller.conversationSessionsByAgent = {
      'codex': const [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'codex',
          title: 'Run security scan',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:03Z',
          adapterId: 'codex',
          nativeSessionId: 'codex-session',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-user',
              role: 'user',
              text: 'Run security scan',
              createdAt: '2026-06-15T00:00:00Z',
            ),
            AgentConversationMessage(
              id: 'message-worker',
              role: 'subagent',
              cardType: 'subagent',
              cardTitle: 'discovery worker round-05/worker-03',
              text: 'Worker preview line',
              createdAt: '2026-06-15T00:00:01Z',
              childMessages: [
                AgentConversationMessage(
                  id: 'message-worker-output',
                  role: 'agent',
                  text: 'Detailed worker result',
                  createdAt: '2026-06-15T00:00:02Z',
                ),
              ],
            ),
            AgentConversationMessage(
              id: 'message-agent',
              role: 'agent',
              text: 'Coordinator response',
              createdAt: '2026-06-15T00:00:03Z',
            ),
          ],
        ),
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 760,
            height: 520,
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

    await tester.pumpAndSettle();

    expect(find.text('discovery worker round-05/worker-03'), findsOneWidget);
    expect(find.text('Subagent task · 1 messages'), findsOneWidget);
    expect(find.text('Worker preview line'), findsOneWidget);
    expect(find.text('Detailed worker result'), findsNothing);

    await tester.tap(find.text('discovery worker round-05/worker-03'));
    await tester.pumpAndSettle();

    expect(find.text('Detailed worker result'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop agent tabs shrink without arrow controls', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      for (final target in [
        'claude-code',
        'codex',
        'code',
        'antigravity',
        'opencode',
        'kilo-code',
      ])
        TargetCandidate(
          target: target,
          label: target == 'code' ? 'VS Code' : target,
          kind: 'cli',
          status: 'detected',
          configured: false,
          confidence: 0.72,
          adapterStatus: 'implemented',
        ),
    ];
    controller.selectedConversationAgentId = 'claude-code';

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 520,
            height: 360,
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

    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(
      find.byKey(const ValueKey('agent-tab-fixed-lico-default-orchestrator')),
      findsOneWidget,
    );
    expect(find.text('VS Code'), findsNothing);
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.byType(ReorderableDelayedDragStartListener), findsWidgets);
    expect(find.text('Default'), findsOneWidget);
    final firstTabFinder = find.byKey(
      const ValueKey('agent-tab-drag-claude-code'),
    );
    final defaultTabFinder = find.byKey(
      const ValueKey('agent-tab-fixed-lico-default-orchestrator'),
    );
    final firstTabSize = tester.getSize(firstTabFinder);
    expect(firstTabSize.width, lessThan(172));
    expect(firstTabSize.width, greaterThanOrEqualTo(104));
    expect(tester.getTopLeft(defaultTabFinder).dx, 0);
    expect(
      tester.getTopLeft(firstTabFinder).dx,
      greaterThanOrEqualTo(firstTabSize.width),
    );
    expect(find.byKey(const Key('agent-tab-refresh-button')), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('agent workspace uses Chinese labels for Chinese locale', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'codex';

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
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 520,
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

    expect(find.text('历史对话'), findsNothing);
    expect(find.text('搜索历史对话'), findsNothing);
    expect(find.text('0 条对话'), findsNothing);
    expect(find.byTooltip('归档当前智能体对话'), findsOneWidget);
    expect(find.byTooltip('新对话'), findsOneWidget);
    expect(find.byTooltip('收起历史对话'), findsOneWidget);
    expect(find.text('查看'), findsNothing);
    expect(find.text('计划'), findsNothing);
    expect(find.text('Conversation history'), findsNothing);
  });

  testWidgets('default agent tab renders orchestration controls', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationDriver': 'implemented',
          'conversationReadiness': 'ready',
        },
        supportedActions: const ['runtime.message.send'],
        modelCatalog: const {
          'status': 'available',
          'models': [
            {'name': 'gpt-5.5', 'displayName': 'GPT-5.5'},
            {'name': 'gpt-5.4', 'displayName': 'GPT-5.4'},
          ],
        },
      ),
      TargetCandidate(
        target: 'claude-code',
        label: 'Claude Code',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationDriver': 'implemented',
          'conversationReadiness': 'ready',
        },
        supportedActions: const ['runtime.message.send'],
        modelCatalog: const {
          'status': 'available',
          'models': [
            {
              'providerId': 'deepseek',
              'provider': 'DeepSeek',
              'name': 'deepseek-v4-flash',
              'reasoningEfforts': ['thinking-fast', 'thinking-deep'],
            },
            {
              'providerId': 'deepseek',
              'provider': 'DeepSeek',
              'name': 'deepseek-v4-pro',
              'reasoningEfforts': ['thinking-fast', 'thinking-deep'],
            },
          ],
        },
      ),
    ];
    await controller.selectConversationAgent(agentOrchestrationTargetId);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 980,
            height: 560,
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

    await tester.pumpAndSettle();

    IconButton sendButton() {
      return tester
          .widgetList<IconButton>(find.byType(IconButton))
          .firstWhere((button) => button.tooltip == 'Send');
    }

    expect(find.text('Default'), findsWidgets);
    expect(
      find.byKey(const Key('agent-orchestration-policy-select')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-policy-edit')),
      findsOneWidget,
    );
    expect(find.text('Configure a policy first'), findsWidgets);
    expect(sendButton().onPressed, isNull);

    await tester.tap(find.byKey(const Key('agent-orchestration-policy-edit')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('agent-orchestration-policy-rule-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-dialog-policy-select')),
      findsOneWidget,
    );
    expect(find.text('Default Policy'), findsWidgets);
    expect(find.text('Commander'), findsOneWidget);
    expect(find.text('Model Library'), findsOneWidget);
    expect(
      find.byKey(const Key('agent-orchestration-commander-agent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-commander-model')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-commander-reasoning')),
      findsOneWidget,
    );
    expect(find.text('Claude Code'), findsWidgets);
    expect(find.text('deepseek-v4-flash'), findsWidgets);
    expect(
      find.byKey(const Key('agent-orchestration-model-library')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-model-library-agent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-model-library-model')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-model-library-reasoning')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('agent-orchestration-model-library-add')),
    );
    await tester.pump();
    expect(
      find.byKey(
        const Key(
          'agent-orchestration-model-library-claude-code-deepseek-v4-flash-thinking-fast',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'agent-orchestration-model-library-claude-code-deepseek-v4-flash-low',
        ),
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const Key('agent-orchestration-policy-rename')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('agent-orchestration-policy-name-field')),
      'Review Policy',
    );
    await tester.tap(
      find.byKey(const Key('agent-orchestration-policy-rename-save')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Review Policy'), findsWidgets);

    await tester.tap(find.byKey(const Key('agent-orchestration-save-policy')));
    await tester.pumpAndSettle();

    expect(controller.agentOrchestrationPolicyConfigured, isTrue);
    expect(controller.agentOrchestrationPolicy.label, 'Review Policy');
    expect(controller.agentOrchestrationPolicy.commanderAgentId, 'claude-code');
    expect(
      controller.agentOrchestrationPolicy.commanderModelName,
      'deepseek-v4-flash',
    );
    expect(
      controller.agentOrchestrationPolicy.commanderReasoningEffort,
      'thinking-fast',
    );
    expect(controller.agentOrchestrationPolicy.modelLibrary, hasLength(1));
    expect(
      controller.agentOrchestrationPolicy.modelLibrary.map(
        (entry) => entry.key,
      ),
      containsAll([
        const AgentModelLibraryEntry(
          agentId: 'claude-code',
          modelName: 'deepseek-v4-flash',
          reasoningEffort: 'thinking-fast',
        ).key,
      ]),
    );
    expect(find.text('Review Policy'), findsWidgets);
    expect(find.text('Message Default'), findsOneWidget);
    expect(sendButton().onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile agent empty state hides manual add target actions', (
    tester,
  ) async {
    final controller = FutureClientController();
    addTearDown(controller.dispose);

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
        ).copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 760,
            child: AgentConversationWorkspace(
              controller: controller,
              targets: const [],
              scanning: false,
              adding: false,
              onAddTarget: () {},
              allowManualTargetActions: false,
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('选择一个智能体查看历史并对话'), findsOneWidget);
    expect(find.byType(AgentConversationTabBar), findsNothing);
    expect(find.text('添加目标'), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('mobile runtime suppresses agent tabs under desktop theme', (
    tester,
  ) async {
    final controller = FutureClientController(
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'codex';

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
            width: 390,
            height: 760,
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

    expect(find.byType(AgentConversationTabBar), findsNothing);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('添加目标'), findsNothing);
  });
}
