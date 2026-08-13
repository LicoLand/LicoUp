import 'client_controller_scenario_dependencies.dart';

const Map<String, dynamic> parityReadyAdapterCapabilities = {
  'conversationDriver': 'implemented',
  'conversationProtocol': 'test-native-protocol',
  'conversationReadiness': 'ready',
};

Map<String, dynamic> conversationSessionJson({
  required String id,
  required String agentId,
  required String text,
  String nativeSessionId = '',
  String createdAt = '2026-06-12T00:00:00Z',
  String updatedAt = '2026-06-12T00:00:01Z',
  String workingDirectory = '',
  bool running = false,
}) {
  return {
    'id': id,
    'agentId': agentId,
    'adapterId': agentId,
    'nativeSessionId': nativeSessionId.isEmpty ? id : nativeSessionId,
    'sourceKind': '$agentId-native-history',
    'importMode': 'precise-adapter',
    'sourceTool': agentId,
    'sourcePath': 'test-data/$agentId/history.jsonl',
    'workingDirectory': workingDirectory.isEmpty
        ? '/workspace/$agentId'
        : workingDirectory,
    'title': text,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'native': true,
    'readOnly': true,
    if (running) 'running': true,
    'messageCount': 2,
    'messages': [
      {
        'id': 'msg-user-$id',
        'role': 'user',
        'text': text,
        'createdAt': createdAt,
      },
      {
        'id': 'msg-agent-$id',
        'role': 'agent',
        'text': '原生智能体历史响应',
        'createdAt': updatedAt,
      },
    ],
  };
}

TargetCandidate agentArchiveTarget() {
  return TargetCandidate(
    target: 'claude-code',
    label: 'Claude Code',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'implemented',
  );
}
