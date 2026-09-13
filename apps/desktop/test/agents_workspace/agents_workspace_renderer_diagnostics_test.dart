import 'support/agents_workspace_test_harness.dart';

void main() {
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
}
