const _conversationMethods = <String>{
  'agent.conversation.open',
  'agent.conversation.history',
  'agent.conversation.cleanup',
  'agent.conversation.capabilities',
  'agent.conversation.cancel',
  'agent.conversation.steer',
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
};

bool validStdioRpcStructuredMethod(String method) =>
    _conversationMethods.contains(method) || _clientMethods.contains(method);

bool stdioRpcMethodUsesConversationLane(String method) =>
    _conversationMethods.contains(method);

bool stdioRpcMethodIsInFlightControl(String method) =>
    method == 'agent.conversation.cancel' ||
    method == 'agent.conversation.steer';
