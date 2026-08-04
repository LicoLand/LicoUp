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
    this.participantAgentId = '',
    this.participantLabel = '',
    this.participantRole = '',
    this.childMessagesTruncated = false,
    this.childMessages = const [],
    this.images = const [],
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
  final String participantAgentId;
  final String participantLabel;
  final String participantRole;
  final bool childMessagesTruncated;
  final List<AgentConversationMessage> childMessages;

  /// Typed image attachments carried by the message (for example a pasted
  /// screenshot in a native agent history). Rendered locally only — inline
  /// base64 payloads decode in memory; file-path sources currently render a
  /// graceful unavailable placeholder until a platform-root byte provider
  /// exists. Nothing is fetched over the network.
  final List<AgentConversationImageAttachment> images;

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

  AgentConversationMessage withParticipantDefaults({
    required String agentId,
    required String label,
    required String role,
  }) {
    if (kind == AgentConversationMessageKind.user || isSubagentCard) {
      return this;
    }
    final resolvedAgentId = participantAgentId.trim().isNotEmpty
        ? participantAgentId
        : agentId.trim();
    final resolvedLabel = participantLabel.trim().isNotEmpty
        ? participantLabel
        : label.trim();
    final resolvedRole = participantRole.trim().isNotEmpty
        ? participantRole
        : role.trim();
    if (resolvedAgentId == participantAgentId &&
        resolvedLabel == participantLabel &&
        resolvedRole == participantRole) {
      return this;
    }
    return AgentConversationMessage(
      id: id,
      role: this.role,
      text: text,
      createdAt: createdAt,
      layer: layer,
      cardType: cardType,
      cardTitle: cardTitle,
      cardSubtitle: cardSubtitle,
      collapsed: collapsed,
      providerSummary: providerSummary,
      stableIdentity: stableIdentity,
      participantAgentId: resolvedAgentId,
      participantLabel: resolvedLabel,
      participantRole: resolvedRole,
      childMessagesTruncated: childMessagesTruncated,
      childMessages: childMessages,
      images: images,
    );
  }

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
      if (participantAgentId.isNotEmpty)
        'participantAgentId': participantAgentId,
      if (participantLabel.isNotEmpty) 'participantLabel': participantLabel,
      if (participantRole.isNotEmpty) 'participantRole': participantRole,
      if (childMessagesTruncated) 'childMessagesTruncated': true,
      if (images.isNotEmpty)
        'images': [for (final image in images) image.toJson()],
      if (childMessages.isNotEmpty)
        'messages': childMessages.map((message) => message.toJson()).toList(),
    };
  }
}

/// Parses a conversation message timestamp from ISO-8601 or numeric epoch
/// strings. Native history adapters often store millisecond epochs that
/// [DateTime.tryParse] cannot read.
DateTime? parseAgentConversationTimestamp(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final iso = DateTime.tryParse(trimmed);
  if (iso != null) {
    return iso.toLocal();
  }
  final epoch = int.tryParse(trimmed);
  if (epoch == null || epoch <= 0) {
    return null;
  }
  final absolute = epoch.abs();
  final seconds = absolute >= 1000000000000000
      ? epoch ~/ 1000000
      : absolute >= 10000000000
      ? epoch ~/ 1000
      : epoch;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
      .toLocal();
}

/// One typed image attachment on a conversation message. Exactly one of
/// [dataBase64] (inline payload) or [filePath] (local file) carries the
/// image source; both may be empty when the source is unavailable.
final class AgentConversationImageAttachment {
  const AgentConversationImageAttachment({
    this.mediaType = 'image/png',
    this.dataBase64 = '',
    this.filePath = '',
    this.name = '',
  });

  final String mediaType;
  final String dataBase64;
  final String filePath;
  final String name;

  Map<String, dynamic> toJson() {
    return {
      if (mediaType.isNotEmpty) 'mediaType': mediaType,
      if (dataBase64.isNotEmpty) 'data': dataBase64,
      if (filePath.isNotEmpty) 'path': filePath,
      if (name.isNotEmpty) 'name': name,
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
