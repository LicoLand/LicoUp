import 'dart:convert';

import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_fixtures.dart';

void registerMobileRelaySessionListScenarios() {
  test('secure agent session list extracts exact native projections', () {
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      result: {
        'ok': true,
        'result': {
          'openedResult': {
            'execution': {
              'outcome': 'result',
              'output': {
                'ok': true,
                'commandKind': 'agent.sessions.list',
                'output': {
                  'ok': true,
                  'mode': 'native-history',
                  'importMode': 'precise-adapter',
                  'readOnly': true,
                  'agentId': 'codex',
                  'sessions': [
                    {
                      'id': 'codex-projection-1',
                      'nativeSessionId': 'codex-native-thread-1',
                      'agentId': 'codex',
                      'adapterId': 'codex',
                      'native': true,
                      'readOnly': true,
                      'title': 'Native session',
                      'createdAt': '2026-07-10T00:00:00Z',
                      'updatedAt': '2026-07-10T00:00:01Z',
                      'sourcePath': [
                        '',
                        'private',
                        'native',
                        'history.jsonl',
                      ].join('/'),
                      'workingDirectory': [
                        '',
                        'private',
                        'native',
                        'workspace',
                      ].join('/'),
                      'messages': [
                        {
                          'id': 'tool-message-1',
                          'role': 'tool',
                          'text': 'Tool call details are hidden.',
                          'createdAt': '2026-07-10T00:00:01Z',
                          'cardType': 'tool_call',
                          'cardTitle': 'Tool call',
                          'cardSubtitle': 'redacted',
                          'collapsed': false,
                          'arguments': {
                            'path': [
                              '',
                              'private',
                              'native',
                              'workspace',
                              'secret.txt',
                            ].join('/'),
                          },
                          'messages': [
                            {
                              'id': 'reasoning-child-1',
                              'role': 'reasoning',
                              'text': 'Reasoning content is hidden.',
                              'createdAt': '2026-07-10T00:00:01Z',
                              'cardType': 'reasoning',
                              'cardTitle': 'Reasoning',
                              'collapsed': true,
                              'metadata': {
                                'token': [
                                  'private',
                                  'token',
                                  'canary',
                                ].join('-'),
                              },
                            },
                          ],
                        },
                      ],
                    },
                  ],
                  'page': {'hasMore': false},
                },
              },
            },
          },
        },
      },
    );

    expect(resolved['ok'], isTrue);
    expect(resolved['agentId'], 'codex');
    expect(resolved['hasMore'], isFalse);
    final sessions = resolved['sessions'] as List;
    expect(sessions, hasLength(1));
    expect(sessions.single['id'], 'codex-projection-1');
    expect(sessions.single['nativeSessionId'], 'codex-native-thread-1');
    expect(sessions.single, isNot(contains('sourcePath')));
    expect(sessions.single, isNot(contains('workingDirectory')));
    final messages = sessions.single['messages'] as List;
    expect(messages.single['cardType'], 'tool_call');
    expect(messages.single['cardTitle'], 'Tool call');
    expect(messages.single['collapsed'], isFalse);
    expect(messages.single, isNot(contains('arguments')));
    final children = messages.single['messages'] as List;
    expect(children.single['cardType'], 'reasoning');
    expect(children.single, isNot(contains('metadata')));
    expect(jsonEncode(sessions), isNot(contains('private-token-canary')));
    expect(
      jsonEncode(sessions),
      isNot(contains(['', 'private', 'native'].join('/'))),
    );
  });

  test(
    'secure agent session list deterministically reduces native duplicates',
    () {
      final resolved = resolveSecureAgentSessionListResult(
        agentId: 'codex',
        result: secureAgentSessionListRelayResult([
          secureAgentSessionFixture(
            id: 'archive-projection',
            nativeSessionId: 'shared-native-thread',
            updatedAt: '2026-07-10T00:00:01Z',
            text: 'Archived conversation copy',
            sourcePath: ['', 'private', 'archive', 'history.jsonl'].join('/'),
          ),
          secureAgentSessionFixture(
            id: 'active-projection',
            nativeSessionId: 'shared-native-thread',
            updatedAt: '2026-07-10T00:00:02Z',
            text: 'Current conversation copy',
            sourcePath: ['', 'private', 'active', 'history.jsonl'].join('/'),
          ),
        ]),
      );

      expect(resolved['ok'], isTrue);
      final sessions = resolved['sessions'] as List;
      expect(sessions, hasLength(1));
      expect(sessions.single['id'], 'active-projection');
      expect(sessions.single['nativeSessionId'], 'shared-native-thread');
      expect(sessions.single['sourcePath'], isNull);
      expect(
        sessions.single['messages'].single['text'],
        'Current conversation copy',
      );
    },
  );

  test('secure agent session list rejects oversized decrypted history', () {
    final oversizedText = List<String>.filled(
      2 * 1024 * 1024,
      'x',
      growable: false,
    ).join();
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      result: secureAgentSessionListRelayResult([
        secureAgentSessionFixture(
          id: 'oversized-projection',
          nativeSessionId: 'oversized-native-thread',
          updatedAt: '2026-07-10T00:00:01Z',
          text: oversizedText,
        ),
      ]),
    );

    expect(resolved, const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_payload_too_large',
    });
  });

  test('secure agent session list fails closed without native continuity', () {
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      result: const {
        'ok': true,
        'result': {
          'openedResult': {
            'execution': {
              'outcome': 'result',
              'output': {
                'ok': true,
                'commandKind': 'agent.sessions.list',
                'output': {
                  'ok': true,
                  'mode': 'native-history',
                  'importMode': 'precise-adapter',
                  'readOnly': true,
                  'agentId': 'codex',
                  'sessions': [
                    {
                      'id': 'projection-without-native-id',
                      'nativeSessionId': '',
                      'agentId': 'codex',
                      'native': true,
                      'readOnly': true,
                    },
                  ],
                  'page': {'hasMore': false},
                },
              },
            },
          },
        },
      },
    );

    expect(resolved, const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_result_invalid',
    });
  });

  test('secure agent session list redacts an unsafe relay failure', () {
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      result: const {
        'ok': false,
        'errorCode': 'unsafe private error detail',
        'error': 'private-session-history-canary',
      },
    );

    expect(resolved, const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_list_failed',
    });
    expect(jsonEncode(resolved), isNot(contains('private-session-history')));
  });

  test('secure agent session describe extracts an exact native projection', () {
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      commandKind: 'agent.sessions.describe',
      result: secureAgentSessionListRelayResult(
        [
          secureAgentSessionFixture(
            id: 'codex-projection-exact',
            nativeSessionId: 'codex-native-exact',
            updatedAt: '2026-07-10T00:00:01Z',
            text: 'Exact older conversation',
          ),
        ],
        commandKind: 'agent.sessions.describe',
        hasMore: false,
      ),
    );

    expect(resolved['ok'], isTrue);
    expect(resolved['hasMore'], isFalse);
    final sessions = resolved['sessions'] as List;
    expect(sessions, hasLength(1));
    expect(sessions.single['nativeSessionId'], 'codex-native-exact');
  });

  test('secure agent session list preserves hasMore paging signal', () {
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      result: secureAgentSessionListRelayResult([
        secureAgentSessionFixture(
          id: 'codex-projection-page',
          nativeSessionId: 'codex-native-page',
          updatedAt: '2026-07-10T00:00:01Z',
          text: 'Paged conversation',
        ),
      ], hasMore: true),
    );

    expect(resolved['ok'], isTrue);
    expect(resolved['hasMore'], isTrue);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerMobileRelaySessionListScenarios();
}
