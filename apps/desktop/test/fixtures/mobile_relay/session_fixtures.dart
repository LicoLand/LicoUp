Map<String, dynamic> secureAgentSessionListRelayResult(
  List<Map<String, dynamic>> sessions, {
  String commandKind = 'agent.sessions.list',
  bool hasMore = false,
}) {
  return {
    'ok': true,
    'result': {
      'openedResult': {
        'execution': {
          'outcome': 'result',
          'output': {
            'ok': true,
            'commandKind': commandKind,
            'output': {
              'ok': true,
              'mode': 'native-history',
              'importMode': 'precise-adapter',
              'readOnly': true,
              'agentId': 'codex',
              'sessions': sessions,
              'page': {'hasMore': hasMore},
            },
          },
        },
      },
    },
  };
}

Map<String, dynamic> secureAgentSessionFixture({
  required String id,
  required String nativeSessionId,
  required String updatedAt,
  required String text,
  String sourcePath = '',
}) {
  return {
    'id': id,
    'nativeSessionId': nativeSessionId,
    'agentId': 'codex',
    'adapterId': 'codex',
    'native': true,
    'readOnly': true,
    'title': text.isEmpty ? 'Native session' : text.substring(0, 1),
    'createdAt': '2026-07-10T00:00:00Z',
    'updatedAt': updatedAt,
    if (sourcePath.isNotEmpty) 'sourcePath': sourcePath,
    'workingDirectory': ['', 'private', 'native', 'workspace'].join('/'),
    'messages': [
      {
        'id': '$id-message',
        'role': 'assistant',
        'text': text,
        'createdAt': updatedAt,
      },
    ],
  };
}
