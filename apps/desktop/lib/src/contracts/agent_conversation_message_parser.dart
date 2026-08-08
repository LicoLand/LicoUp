import 'agent_conversation_message.dart';
import 'agent_conversation_privacy_projection.dart';

const int _maxConversationMessagesPerSession = 2000;
const int _maxConversationMessageTreeNodes = 4096;
const int _maxConversationMessageTreeDepth = 16;

final class _ConversationMessageParseBudget {
  _ConversationMessageParseBudget(this.remaining);

  int remaining;
  bool truncated = false;

  bool consume() {
    if (remaining <= 0) {
      truncated = true;
      return false;
    }
    remaining -= 1;
    return true;
  }

  void markTruncated() {
    truncated = true;
  }
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
  return _parseAgentConversationMessage(
    json,
    agentId: agentId,
    adapterId: adapterId,
    sourceClient: sourceClient,
    sourceTool: sourceTool,
    hostApp: hostApp,
    identityScope: identityScope,
    treePath: 'message-0',
    depth: 0,
    consumeBudget: false,
    budget: _ConversationMessageParseBudget(_maxConversationMessageTreeNodes),
  )!;
}

AgentConversationMessage? _parseAgentConversationMessage(
  Map<String, dynamic> json, {
  required String agentId,
  required String adapterId,
  required String sourceClient,
  required String sourceTool,
  required String hostApp,
  required String identityScope,
  required String treePath,
  required int depth,
  required bool consumeBudget,
  required _ConversationMessageParseBudget budget,
}) {
  if (depth > _maxConversationMessageTreeDepth) {
    budget.markTruncated();
    return null;
  }
  if (consumeBudget && !budget.consume()) {
    return null;
  }
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
  final rawChildMessages = (json['messages'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList(growable: false);
  final parsedChildMessages = <AgentConversationMessage>[];
  var childMessagesTruncated = false;
  if (rawChildMessages.isNotEmpty &&
      depth >= _maxConversationMessageTreeDepth) {
    childMessagesTruncated = true;
    budget.markTruncated();
  } else {
    for (var index = 0; index < rawChildMessages.length; index += 1) {
      final parsed = _parseAgentConversationMessage(
        rawChildMessages[index],
        agentId: agentId,
        adapterId: adapterId,
        sourceClient: sourceClient,
        sourceTool: sourceTool,
        hostApp: hostApp,
        identityScope: identityScope,
        treePath: '$treePath/$index',
        depth: depth + 1,
        consumeBudget: true,
        budget: budget,
      );
      if (parsed == null) {
        childMessagesTruncated = true;
        continue;
      }
      if (parsed.childMessagesTruncated) {
        childMessagesTruncated = true;
      }
      if (parsed.isDisplayable) {
        parsedChildMessages.add(parsed);
      }
    }
  }
  final childMessages = List<AgentConversationMessage>.unmodifiable(
    parsedChildMessages,
  );
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
    childMessagesTruncated:
        childMessagesTruncated || json['childMessagesTruncated'] == true,
    childMessages: childMessages,
    images: parseAgentConversationImageAttachments(json['images']),
  );
}

/// Largest inline base64 payload accepted for one image attachment
/// (~4.5 MiB decoded); larger payloads are dropped as unrenderable.
const int maxConversationImageBase64Chars = 6000000;

/// Most image attachments carried by one message.
const int maxConversationMessageImages = 4;

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
    if (images.length >= maxConversationMessageImages) {
      break;
    }
    if (entry is! Map) {
      continue;
    }
    final data = (entry['data'] ?? '').toString().trim();
    final path = (entry['path'] ?? '').toString().trim();
    if (data.isEmpty && path.isEmpty) {
      continue;
    }
    if (data.length > maxConversationImageBase64Chars) {
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
  final firstRetained = rawMessages.length > _maxConversationMessagesPerSession
      ? rawMessages.length - _maxConversationMessagesPerSession
      : 0;
  final budget = _ConversationMessageParseBudget(
    _maxConversationMessageTreeNodes,
  );
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
  for (var index = firstRetained; index < rawMessages.length; index += 1) {
    final parsed = _parseAgentConversationMessage(
      rawMessages[index],
      agentId: agentId,
      adapterId: adapterId,
      sourceClient: sourceClient,
      sourceTool: sourceTool,
      hostApp: hostApp,
      identityScope: identityScope,
      treePath: 'message-$index',
      depth: 0,
      consumeBudget: false,
      budget: budget,
    );
    if (parsed != null && parsed.isDisplayable) {
      parsedMessages.add(parsed);
    }
  }
  return AgentConversationMessageParseResult(
    messages: List<AgentConversationMessage>.unmodifiable(parsedMessages),
    historyTruncated: firstRetained > 0,
    messageTreeTruncated: budget.truncated,
  );
}
