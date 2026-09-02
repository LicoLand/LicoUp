const _conversationMethods = <String>{
  'agent.conversation.open',
  'agent.conversation.history',
  'agent.conversation.cleanup',
  'agent.conversation.capabilities',
  'agent.conversation.cancel',
  'agent.conversation.steer',
  'agent.conversation.active',
};

const _persistentConversationMethods = <String>{
  'agent.conversation.cancel',
  'agent.conversation.steer',
  'agent.conversation.active',
};

const _clientMethods = <String>{
  'catalog.status',
  'catalog.invalidate',
  'catalog.refresh',
  'catalog.receipt',
  'catalog.purge',
  'catalog.reconnect',
  'catalog.list',
  'catalog.observe',
  'state.get',
  'state.set',
  'client.conversation.execute',
};

bool validStdioRpcStructuredMethod(String method) =>
    _conversationMethods.contains(method) || _clientMethods.contains(method);

bool stdioRpcMethodUsesConversationLane(String method) =>
    _persistentConversationMethods.contains(method);

bool stdioRpcMethodIsUnboundedClientTurn(
  String method,
  Map<String, dynamic> params,
) {
  if (method != 'client.conversation.execute' ||
      params['action'] != 'conversation.message.post') {
    return false;
  }
  final mentioned = params['mentionedMembershipIds'];
  return mentioned is List &&
      mentioned.any((value) => value is String && value.trim().isNotEmpty);
}

bool stdioRpcMethodIsInFlightControl(String method) =>
    method == 'agent.conversation.cancel' ||
    method == 'agent.conversation.steer';
