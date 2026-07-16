Map<String, dynamic> buildFakeConversationSession({
  required String id,
  required String agentId,
  required String agentLabel,
  required String text,
}) {
  return {
    'id': id,
    'agentId': agentId,
    'title': text,
    'createdAt': '2026-06-12T00:00:00Z',
    'updatedAt': '2026-06-12T00:00:01Z',
    'messages': [
      {
        'id': 'msg-user-$id',
        'role': 'user',
        'text': text,
        'createdAt': '2026-06-12T00:00:00Z',
      },
      {
        'id': 'msg-agent-$id',
        'role': 'agent',
        'text': '本机展示：已记录给 $agentLabel 的消息，尚未连接真实智能体运行时。',
        'createdAt': '2026-06-12T00:00:01Z',
      },
    ],
  };
}
