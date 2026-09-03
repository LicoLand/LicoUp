import 'agent_conversation_message.dart';
import 'agent_conversation_privacy_projection.dart';

final class _PendingConversationMessage {
  _PendingConversationMessage({
    required this.json,
    required this.treePath,
    required this.children,
  });

  final Map<String, dynamic> json;
  final String treePath;
  final List<Object?> children;
  final List<AgentConversationMessage> parsedChildren = [];
  int nextChild = 0;
}

AgentConversationMessage parseAgentConversationMessage(
  Map<String, dynamic> json, {
  String agentId = '',
  String adapterId = '',
  String sourceClient = '',
  String sourceTool = '',
  String hostApp = '',
}) {
  final identityScope = [
    agentId,
    adapterId,
    sourceClient,
    sourceTool,
    hostApp,
  ].join('|');
  return _parseAgentConversationMessageTree(
    json,
    agentId: agentId,
    adapterId: adapterId,
    sourceClient: sourceClient,
    sourceTool: sourceTool,
    hostApp: hostApp,
    identityScope: identityScope,
    treePath: 'message-0',
  );
}

AgentConversationMessage _parseAgentConversationMessageTree(
  Map<String, dynamic> json, {
  required String agentId,
  required String adapterId,
  required String sourceClient,
  required String sourceTool,
  required String hostApp,
  required String identityScope,
  required String treePath,
}) {
  final pending = <_PendingConversationMessage>[
    _pendingConversationMessage(json, treePath),
  ];
  while (pending.isNotEmpty) {
    final current = pending.last;
    if (current.nextChild < current.children.length) {
      final childIndex = current.nextChild;
      current.nextChild += 1;
      final rawChild = current.children[childIndex];
      if (rawChild is! Map) {
        throw const FormatException('native_history_message_child_invalid');
      }
      Map<String, dynamic> child;
      try {
        child = Map<String, dynamic>.from(rawChild);
      } on Object {
        throw const FormatException('native_history_message_child_invalid');
      }
      pending.add(
        _pendingConversationMessage(child, '${current.treePath}/$childIndex'),
      );
      continue;
    }
    final parsed = _buildAgentConversationMessage(
      current.json,
      agentId: agentId,
      adapterId: adapterId,
      sourceClient: sourceClient,
      sourceTool: sourceTool,
      hostApp: hostApp,
      identityScope: identityScope,
      treePath: current.treePath,
      childMessages: current.parsedChildren,
    );
    pending.removeLast();
    if (pending.isEmpty) {
      return parsed;
    }
    if (parsed.isDisplayable) {
      pending.last.parsedChildren.add(parsed);
    }
  }
  throw const FormatException('native_history_message_tree_invalid');
}

_PendingConversationMessage _pendingConversationMessage(
  Map<String, dynamic> json,
  String treePath,
) {
  final rawChildren = json['messages'];
  if (rawChildren != null && rawChildren is! List) {
    throw const FormatException('native_history_message_children_invalid');
  }
  return _PendingConversationMessage(
    json: json,
    treePath: treePath,
    children: rawChildren is List ? rawChildren : const [],
  );
}

AgentConversationMessage _buildAgentConversationMessage(
  Map<String, dynamic> json, {
  required String agentId,
  required String adapterId,
  required String sourceClient,
  required String sourceTool,
  required String hostApp,
  required String identityScope,
  required String treePath,
  required List<AgentConversationMessage> childMessages,
}) {
  final role = (json['role'] ?? 'system').toString();
  final rawCardType = (json['cardType'] ?? '').toString();
  final rawText = (json['text'] ?? '').toString();
  final createdAt = (json['createdAt'] ?? '').toString();
  final rawId = (json['id'] ?? '').toString().trim();
  final layer = agentConversationSemanticLayerFor(
    (json['layer'] ?? '').toString(),
  );
  final stableIdentity = stableConversationIdentity(
    rawId.isNotEmpty
        ? '$identityScope|id:$rawId|$role|$rawCardType|$createdAt'
        : '$identityScope|path:$treePath|$role|$rawCardType|$createdAt',
  );
  final projectedId = rawId.isNotEmpty ? rawId : 'projected-$stableIdentity';
  final kind = agentConversationMessageKindFor(
    role: role,
    cardType: rawCardType,
  );
  final providerSummary =
      kind == AgentConversationMessageKind.reasoning &&
      json['providerSummary'] == true;
  return AgentConversationMessage(
    id: projectedId,
    role: role,
    text: visibleConversationMessageText(
      role,
      rawText,
      kind: kind,
      agentId: agentId,
      adapterId: adapterId,
      sourceClient: sourceClient,
      sourceTool: sourceTool,
      hostApp: hostApp,
      providerSummary: providerSummary,
    ),
    createdAt: createdAt,
    layer: layer,
    cardType: rawCardType.trim().isEmpty
        ? (isInternalConversationRole(role)
              ? ''
              : defaultConversationCardType(kind))
        : sanitizeStructuredLabel(rawCardType),
    cardTitle: sanitizeStructuredLabel(
      (json['cardTitle'] ?? '').toString(),
      fallback: defaultConversationCardTitle(kind),
    ),
    cardSubtitle: sanitizeStructuredLabel(
      (json['cardSubtitle'] ?? '').toString(),
      fallback: defaultConversationCardSubtitle(kind),
    ),
    collapsed: json.containsKey('collapsed')
        ? json['collapsed'] != false
        : conversationCardCollapsedByDefault(kind),
    providerSummary: providerSummary,
    stableIdentity: stableIdentity,
    participantAgentId: sanitizeStructuredLabel(
      (json['participantAgentId'] ?? '').toString(),
    ),
    participantLabel: sanitizeStructuredLabel(
      (json['participantLabel'] ?? '').toString(),
    ),
    participantRole: sanitizeStructuredLabel(
      (json['participantRole'] ?? '').toString(),
    ),
    childMessagesTruncated: false,
    childMessages: List<AgentConversationMessage>.unmodifiable(childMessages),
    images: parseAgentConversationImageAttachments(json['images']),
    deliveryState: (json['deliveryState'] ?? '').toString() == 'failed'
        ? AgentConversationMessageDeliveryState.failed
        : AgentConversationMessageDeliveryState.ordinary,
  );
}

/// Parses the typed image-attachment channel of a projected message. Entries
/// without a usable source (neither inline data nor a file path) are dropped;
/// names pass through the same structured-label sanitization as card labels.
List<AgentConversationImageAttachment> parseAgentConversationImageAttachments(
  Object? raw,
) {
  if (raw is! List) {
    return const [];
  }
  final images = <AgentConversationImageAttachment>[];
  for (final entry in raw) {
    if (entry is! Map) {
      continue;
    }
    final data = (entry['data'] ?? '').toString().trim();
    final path = (entry['path'] ?? '').toString().trim();
    if (data.isEmpty && path.isEmpty) {
      continue;
    }
    images.add(
      AgentConversationImageAttachment(
        mediaType: (entry['mediaType'] ?? '').toString().trim().isEmpty
            ? 'image/png'
            : (entry['mediaType'] ?? '').toString().trim(),
        dataBase64: data,
        filePath: path,
        name: sanitizeStructuredLabel((entry['name'] ?? '').toString()),
      ),
    );
  }
  return List<AgentConversationImageAttachment>.unmodifiable(images);
}

final class AgentConversationMessageParseResult {
  const AgentConversationMessageParseResult({
    required this.messages,
    required this.historyTruncated,
    required this.messageTreeTruncated,
  });

  final List<AgentConversationMessage> messages;
  final bool historyTruncated;
  final bool messageTreeTruncated;
}

AgentConversationMessageParseResult parseAgentConversationMessages(
  List<Map<String, dynamic>> rawMessages, {
  String sessionId = '',
  String nativeSessionId = '',
  String agentId = '',
  String adapterId = '',
  String sourceClient = '',
  String sourceTool = '',
  String hostApp = '',
}) {
  final identityScope = [
    sessionId,
    nativeSessionId,
    agentId,
    adapterId,
    sourceClient,
    sourceTool,
    hostApp,
  ].join('|');
  final parsedMessages = <AgentConversationMessage>[];
  for (var index = 0; index < rawMessages.length; index += 1) {
    final parsed = _parseAgentConversationMessageTree(
      rawMessages[index],
      agentId: agentId,
      adapterId: adapterId,
      sourceClient: sourceClient,
      sourceTool: sourceTool,
      hostApp: hostApp,
      identityScope: identityScope,
      treePath: 'message-$index',
    );
    if (parsed.isDisplayable) {
      parsedMessages.add(parsed);
    }
  }
  return AgentConversationMessageParseResult(
    messages: List<AgentConversationMessage>.unmodifiable(parsedMessages),
    historyTruncated: false,
    messageTreeTruncated: false,
  );
}
