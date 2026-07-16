enum AgentConversationMessageKind {
  user,
  assistant,
  toolCall,
  toolResult,
  reasoning,
  metadata,
  error,
  event,
  subagent,
}

enum AgentConversationSemanticLayer { thread, execution, artifacts, audit, raw }

AgentConversationSemanticLayer? agentConversationSemanticLayerFor(
  String? value,
) {
  return switch ((value ?? '').trim().toLowerCase()) {
    'thread' => AgentConversationSemanticLayer.thread,
    'execution' => AgentConversationSemanticLayer.execution,
    'artifacts' => AgentConversationSemanticLayer.artifacts,
    'audit' => AgentConversationSemanticLayer.audit,
    'raw' => AgentConversationSemanticLayer.raw,
    _ => null,
  };
}

class AgentConversationMessage {
  const AgentConversationMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.layer,
    this.cardType = '',
    this.cardTitle = '',
    this.cardSubtitle = '',
    this.collapsed = true,
    this.providerSummary = false,
    this.stableIdentity = '',
    this.childMessagesTruncated = false,
    this.childMessages = const [],
  });

  final String id;
  final String role;
  final String text;
  final String createdAt;
  final AgentConversationSemanticLayer? layer;
  final String cardType;
  final String cardTitle;
  final String cardSubtitle;
  final bool collapsed;
  final bool providerSummary;
  final String stableIdentity;
  final bool childMessagesTruncated;
  final List<AgentConversationMessage> childMessages;

  AgentConversationMessageKind get kind =>
      agentConversationMessageKindFor(role: role, cardType: cardType);

  AgentConversationSemanticLayer get resolvedLayer {
    if (layer != null) {
      return layer!;
    }
    if (isSubagentCard || isStructuredEvent) {
      return AgentConversationSemanticLayer.execution;
    }
    if (kind == AgentConversationMessageKind.user ||
        kind == AgentConversationMessageKind.assistant) {
      return AgentConversationSemanticLayer.thread;
    }
    return AgentConversationSemanticLayer.execution;
  }

  bool get isSubagentCard => kind == AgentConversationMessageKind.subagent;

  bool get isStructuredEvent => switch (kind) {
    AgentConversationMessageKind.toolCall ||
    AgentConversationMessageKind.toolResult ||
    AgentConversationMessageKind.reasoning ||
    AgentConversationMessageKind.metadata ||
    AgentConversationMessageKind.error ||
    AgentConversationMessageKind.event => true,
    _ => false,
  };

  bool get isDisplayable =>
      (!_messageRoleIsInternal(role) ||
          (isStructuredEvent && cardType.trim().isNotEmpty)) &&
      (text.trim().isNotEmpty || isSubagentCard || isStructuredEvent);

  bool get isDefaultThreadVisible =>
      resolvedLayer == AgentConversationSemanticLayer.thread &&
      (kind == AgentConversationMessageKind.user ||
          kind == AgentConversationMessageKind.assistant);

  bool get isDefaultExecutionVisible =>
      resolvedLayer == AgentConversationSemanticLayer.execution ||
      isStructuredEvent ||
      isSubagentCard;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': role,
      'text': text,
      'createdAt': createdAt,
      if (layer != null) 'layer': layer!.name,
      if (cardType.isNotEmpty) 'cardType': cardType,
      if (cardTitle.isNotEmpty) 'cardTitle': cardTitle,
      if (cardSubtitle.isNotEmpty) 'cardSubtitle': cardSubtitle,
      if (!collapsed) 'collapsed': collapsed,
      if (providerSummary) 'providerSummary': true,
      if (childMessagesTruncated) 'childMessagesTruncated': true,
      if (childMessages.isNotEmpty)
        'messages': childMessages.map((message) => message.toJson()).toList(),
    };
  }
}

AgentConversationMessageKind agentConversationMessageKindFor({
  required String role,
  String cardType = '',
}) {
  final hasProviderCardType = cardType.trim().isNotEmpty;
  final normalizedCard = _normalizeConversationSemantic(cardType);
  final normalizedRole = _normalizeConversationSemantic(role);
  final semantic = normalizedCard.isEmpty ? normalizedRole : normalizedCard;
  if (semantic == 'subagent') {
    return AgentConversationMessageKind.subagent;
  }
  if (_toolResultConversationSemantic(semantic) ||
      _toolResultConversationSemantic(normalizedRole)) {
    return AgentConversationMessageKind.toolResult;
  }
  if (_toolCallConversationSemantic(semantic) ||
      _toolCallConversationSemantic(normalizedRole)) {
    return AgentConversationMessageKind.toolCall;
  }
  if (_reasoningConversationSemantic(semantic) ||
      _reasoningConversationSemantic(normalizedRole)) {
    return AgentConversationMessageKind.reasoning;
  }
  if (_metadataConversationSemantic(semantic) ||
      _metadataConversationSemantic(normalizedRole)) {
    return AgentConversationMessageKind.metadata;
  }
  if (_errorConversationSemantic(semantic) ||
      _errorConversationSemantic(normalizedRole)) {
    return AgentConversationMessageKind.error;
  }
  if (hasProviderCardType) {
    // A non-empty presentation type is provider/runtime-owned structured
    // data. Unknown types fail closed as events instead of inheriting an
    // assistant role and bypassing the structured redaction boundary.
    return AgentConversationMessageKind.event;
  }
  if (normalizedRole == 'user' || normalizedRole == 'human') {
    return AgentConversationMessageKind.user;
  }
  if ({
    'agent',
    'assistant',
    'model',
    'ai',
    'planner-response',
    'generic',
  }.contains(normalizedRole)) {
    return AgentConversationMessageKind.assistant;
  }
  return AgentConversationMessageKind.event;
}

String _normalizeConversationSemantic(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

bool _toolCallConversationSemantic(String value) {
  return {
        'tool',
        'tool-call',
        'tool-use',
        'function',
        'function-call',
        'run-command',
        'view-file',
        'list-directory',
        'grep-search',
        'read-url-content',
        'generate-image',
        'code-action',
      }.contains(value) ||
      value.contains('tool-call') ||
      value.contains('tool-use') ||
      value.contains('function-call');
}

bool _toolResultConversationSemantic(String value) {
  if ({
    'tool-result',
    'tool-output',
    'function-result',
    'function-output',
    'function-call-output',
  }.contains(value)) {
    return true;
  }
  final ownsToolSemantic = value.contains('tool') || value.contains('function');
  return ownsToolSemantic &&
      const [
        'result',
        'output',
        'complete',
        'completed',
        'response',
        'end',
      ].any(value.contains);
}

bool _reasoningConversationSemantic(String value) {
  return {
        'reasoning',
        'analysis',
        'thinking',
        'redacted-thinking',
      }.contains(value) ||
      value.contains('reasoning') ||
      value.contains('analysis') ||
      value.contains('thinking');
}

bool _errorConversationSemantic(String value) {
  return {'error', 'failure', 'failed', 'exception'}.contains(value) ||
      value.contains('error') ||
      value.contains('failure') ||
      value.contains('failed') ||
      value.contains('exception');
}

bool _metadataConversationSemantic(String value) {
  return value == 'metadata' ||
      value.contains('metadata') ||
      const {
        'image',
        'image-url',
        'document',
        'attachment',
        'input-json-delta',
      }.contains(value);
}

bool _messageRoleIsInternal(String role) {
  final normalized = role.toLowerCase().trim();
  return normalized == 'system' ||
      normalized == 'developer' ||
      normalized == 'subagent_prompt';
}
