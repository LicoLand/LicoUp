import 'package:flutter/material.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('semantic session preserves layers without flattening authority', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-1',
      'agentId': 'codex',
      'adapterId': 'codex',
      'title': 'Checklist',
      'createdAt': '2026-01-15T10:00:00Z',
      'updatedAt': '2026-01-15T10:00:11Z',
      'native': true,
      'readOnly': true,
      'messages': [
        {
          'id': 'm1',
          'layer': 'thread',
          'role': 'user',
          'text': 'Please summarize the open checklist.',
          'createdAt': '2026-01-15T10:00:00Z',
        },
        {
          'id': 'm2',
          'layer': 'execution',
          'role': 'tool_call',
          'cardType': 'tool-call',
          'cardTitle': 'Read tracker',
          'text': 'Invocation details are hidden.',
          'createdAt': '2026-01-15T10:00:06Z',
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
            'id': 'thread-user-1',
            'layer': 'thread',
            'role': 'user',
            'eventKind': 'user-message',
            'text': 'Please summarize the open checklist.',
            'createdAt': '2026-01-15T10:00:00Z',
          },
        ],
        'execution': [
          {
            'id': 'exec-tool-1',
            'layer': 'execution',
            'eventKind': 'tool-call',
            'title': 'Read tracker',
            'summary': 'Invocation details are hidden.',
            'createdAt': '2026-01-15T10:00:06Z',
            'collapsed': true,
            'sourceItemType': 'tool-use',
          },
        ],
        'artifacts': [
          {
            'id': 'artifact-summary-1',
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
          'nativeSessionId': 'fixture-session-001',
          'importMode': 'precise-adapter',
          'sourceEvidence': {
            'kind': 'jsonl',
            'pathRef': 'fixture://codex/session-001.jsonl',
            'contentHash':
                'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
            'byteLength': 2048,
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
              'pathRef': 'fixture://codex/session-001.jsonl',
              'contentHash':
                  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
              'byteLength': 2048,
            },
          ],
        },
      },
    });

    expect(session.readOnly, isTrue);
    expect(session.semantic, isNotNull);
    expect(session.threadMessages, hasLength(1));
    expect(
      session.threadMessages.single.kind,
      AgentConversationMessageKind.user,
    );
    expect(session.executionMessages, hasLength(1));
    expect(
      session.executionMessages.single.kind,
      AgentConversationMessageKind.toolCall,
    );
    expect(session.artifacts, hasLength(1));
    expect(session.artifacts.single.ref, 'summary.md');
    expect(session.hasDiagnostics, isTrue);
    expect(session.semantic!.hideAuditInDefaultView, isTrue);
    expect(session.semantic!.hideRawInDefaultView, isTrue);
    expect(
      session.messages.any(
        (message) => message.layer == AgentConversationSemanticLayer.raw,
      ),
      isFalse,
    );
  });

  testWidgets('diagnostics reveal audit and raw only when expanded', (
    tester,
  ) async {
    final semantic = AgentConversationSession.fromJson({
      'id': 'session-ui',
      'agentId': 'codex',
      'adapterId': 'codex',
      'title': 'UI semantic',
      'createdAt': '2026-01-15T10:00:00Z',
      'updatedAt': '2026-01-15T10:00:11Z',
      'native': true,
      'readOnly': true,
      'messages': [
        {
          'id': 'm1',
          'layer': 'thread',
          'role': 'user',
          'text': 'Hello thread',
          'createdAt': '2026-01-15T10:00:00Z',
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
            'id': 't1',
            'layer': 'thread',
            'role': 'user',
            'eventKind': 'user-message',
            'text': 'Hello thread',
            'createdAt': '2026-01-15T10:00:00Z',
          },
        ],
        'execution': <Map<String, dynamic>>[],
        'artifacts': [
          {
            'id': 'a1',
            'layer': 'artifacts',
            'kind': 'index',
            'label': 'Conversation index',
            'ref': 'conversation-index.md',
          },
        ],
        'audit': {
          'adapterId': 'codex',
          'hostApp': 'codex',
          'sourceKind': 'jsonl',
          'nativeSessionId': 'ui-session',
          'sourceEvidence': {
            'kind': 'jsonl',
            'pathRef': 'fixture://codex/ui-session.jsonl',
            'contentHash':
                'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
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
              'pathRef': 'fixture://codex/ui-session.jsonl',
              'contentHash':
                  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
            },
          ],
        },
      },
    });

    expect(semantic.artifacts.single.label, 'Conversation index');
    expect(find.text('Hello thread'), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Diagnostics'))),
    );
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(
      find.textContaining('fixture://codex/ui-session.jsonl'),
      findsNothing,
    );
  });
}
