import 'support/agents_workspace_test_harness.dart';

void registerAgentsWorkspaceRendererProcessCardScenarios() {
  testWidgets('semantic artifacts and diagnostics stay behind default thread', (
    tester,
  ) async {
    final controller = ClientController();
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
    controller.selectedConversationSessionId = 'session-semantic';
    controller.conversationSessionsByAgent = {
      'codex': [
        AgentConversationSession.fromJson({
          'id': 'session-semantic',
          'agentId': 'codex',
          'adapterId': 'codex',
          'title': 'Semantic layers',
          'createdAt': '2026-01-15T10:00:00Z',
          'updatedAt': '2026-01-15T10:00:11Z',
          'native': true,
          'readOnly': true,
          'messages': [
            {
              'id': 'message-user',
              'layer': 'thread',
              'role': 'user',
              'text': 'Show the clean thread only.',
              'createdAt': '2026-01-15T10:00:01Z',
            },
            {
              'id': 'message-tool',
              'layer': 'execution',
              'role': 'tool_call',
              'cardType': 'tool-call',
              'cardTitle': 'Read file',
              'text': 'Invocation details are hidden.',
              'createdAt': '2026-01-15T10:00:02Z',
              'collapsed': true,
            },
          ],
          'semantic': {
            'schemaVersion': 1,
            'kind': 'semantic-conversation',
            'readOnly': true,
            'privacyDefaults': {
              'defaultView': 'thread',
              'hideRawInDefaultView': true,
              'hideAuditInDefaultView': true,
              'redactPaths': true,
              'redactTokens': true,
              'redactFullCommandPayloads': true,
            },
            'thread': [
              {
                'id': 'thread-1',
                'layer': 'thread',
                'role': 'user',
                'eventKind': 'user-message',
                'text': 'Show the clean thread only.',
                'createdAt': '2026-01-15T10:00:01Z',
              },
            ],
            'execution': [
              {
                'id': 'exec-1',
                'layer': 'execution',
                'eventKind': 'tool-call',
                'title': 'Read file',
                'summary': 'Invocation details are hidden.',
                'createdAt': '2026-01-15T10:00:02Z',
                'collapsed': true,
              },
            ],
            'artifacts': [
              {
                'id': 'artifact-1',
                'layer': 'artifacts',
                'kind': 'summary',
                'label': 'Archive summary',
                'ref': 'summary.md',
              },
            ],
            'audit': {
              'adapterId': 'codex',
              'hostApp': 'codex',
              'sourceKind': 'jsonl',
              'nativeSessionId': 'semantic-ui',
              'sourceEvidence': {
                'kind': 'jsonl',
                'pathRef': 'fixture://codex/semantic-ui.jsonl',
                'contentHash':
                    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
              },
              'parseWarnings': <String>[],
              'redactionStatus': 'applied',
              'validationStatus': 'ok',
              'createdAt': '2026-01-15T10:00:00Z',
              'updatedAt': '2026-01-15T10:00:11Z',
            },
            'raw': {
              'evidenceRefs': [
                {
                  'kind': 'jsonl',
                  'pathRef': 'fixture://codex/semantic-ui.jsonl',
                  'contentHash':
                      'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
                },
              ],
            },
          },
        }),
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
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

    expect(find.text('Show the clean thread only.'), findsWidgets);
    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.textContaining('Archive summary'), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(
      find.textContaining('fixture://codex/semantic-ui.jsonl'),
      findsNothing,
    );

    await tester.tap(find.text('Diagnostics'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.textContaining('fixture://codex/semantic-ui.jsonl'),
      findsWidgets,
    );
    expect(find.textContaining('Redaction: applied'), findsOneWidget);
  });

  testWidgets('structured events converge into one accessible process card', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final controller = ClientController();
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
              'text': jsonEncode({
                'cmd':
                    'read ${['', 'workspace', 'private', 'source.rs'].join('/')}',
                'access_token': ['fixture', 'value'].join('-'),
              }),
              'createdAt': '2026-06-15T00:00:02Z',
            },
            {
              'id': 'message-reasoning',
              'role': 'reasoning',
              'providerSummary': true,
              'text':
                  'Inspected the adapter under ${['', 'workspace', 'private', 'project'].join('/')} and verified cleanup; api_key=${['fixture', 'value'].join('-')}.',
              'createdAt': '2026-06-15T00:00:03Z',
            },
            {
              'id': 'message-metadata',
              'role': 'metadata',
              'text': jsonEncode({
                'cwd': ['', 'workspace', 'private', 'project'].join('/'),
                'api_key': ['fixture', 'value'].join('-'),
              }),
              'createdAt': '2026-06-15T00:00:04Z',
            },
            {
              'id': 'message-error',
              'role': 'error',
              'text':
                  'Operation failed under ${['', 'workspace', 'private', 'project'].join('/')} with api_key=${['fixture', 'value'].join('-')}',
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
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
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
      findsNothing,
    );
    expect(
      find.textContaining('read workspace-source.rs', findRichText: true),
      findsWidgets,
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
    expect(
      find.textContaining('/workspace/private', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('private-thread', findRichText: true),
      findsWidgets,
    );
    expect(find.textContaining('{"', findRichText: true), findsWidgets);
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
}

void main() => registerAgentsWorkspaceRendererProcessCardScenarios();
