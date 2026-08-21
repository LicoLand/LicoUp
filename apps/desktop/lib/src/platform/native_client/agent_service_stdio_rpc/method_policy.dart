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
  'strategy.execute',
};

bool validStdioRpcStructuredMethod(String method) =>
    _conversationMethods.contains(method) || _clientMethods.contains(method);

bool stdioRpcMethodUsesConversationLane(
  String method, [
  Map<String, dynamic>? params,
]) {
  if (method == 'strategy.execute') {
    final action = params?['action']?.toString() ?? '';
    return const {
      'strategy.run.start',
      'strategy.run.resume',
      'strategy.run.retry',
    }.contains(action);
  }
  return _persistentConversationMethods.contains(method);
}

bool stdioRpcMethodIsUnboundedClientTurn(
  String method,
  Map<String, dynamic> params,
) {
  return method == 'client.conversation.execute' &&
      params['action'] == 'conversation.dispatch.after-post';
}

bool stdioRpcMethodIsInFlightControl(String method) =>
    method == 'agent.conversation.cancel' ||
    method == 'agent.conversation.steer';
