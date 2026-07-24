import 'package:licoup/src/contracts/agent_conversation_models.dart';

List<AgentConversationSession> sortConversationSessionsByUpdatedAt(
  List<AgentConversationSession> sessions,
) {
  final byId = <String, AgentConversationSession>{};
  final byNativeId = <String, String>{};
  for (final session in sessions) {
    if (session.id.isEmpty) {
      continue;
    }
    // Defensive deduplication: the sidecar may re-emit the same native session
    // with a freshly assigned id after a refresh or load-more, so collapse by
    // nativeSessionId when it is available.
    final nativeId = session.nativeSessionId.trim();
    if (nativeId.isNotEmpty) {
      final previousId = byNativeId[nativeId];
      if (previousId != null && previousId != session.id) {
        byId.remove(previousId);
      }
      byNativeId[nativeId] = session.id;
    }
    byId[session.id] = session;
  }
  final entries = byId.values
      .map(
        (session) =>
            (session: session, sortTime: conversationSessionSortTime(session)),
      )
      .toList(growable: false);
  entries.sort((left, right) {
    final timeCompare = right.sortTime.compareTo(left.sortTime);
    return timeCompare != 0
        ? timeCompare
        : left.session.id.compareTo(right.session.id);
  });
  return List<AgentConversationSession>.unmodifiable(
    entries.map((entry) => entry.session),
  );
}

List<AgentConversationSession> mergeConversationSessionsByUpdatedAt(
  List<AgentConversationSession> existing,
  List<AgentConversationSession> incoming,
) {
  return sortConversationSessionsByUpdatedAt([...existing, ...incoming]);
}

List<AgentConversationSession> insertConversationSessionByUpdatedAt(
  List<AgentConversationSession> sessions,
  AgentConversationSession session,
) {
  return sortConversationSessionsByUpdatedAt([...sessions, session]);
}

int compareConversationSessionUpdatedAt(
  AgentConversationSession left,
  AgentConversationSession right,
) {
  final leftTime = conversationSessionSortTime(left);
  final rightTime = conversationSessionSortTime(right);
  final timeCompare = rightTime.compareTo(leftTime);
  if (timeCompare != 0) {
    return timeCompare;
  }
  return left.id.compareTo(right.id);
}

int conversationSessionSortTime(AgentConversationSession session) {
  final updatedAt = DateTime.tryParse(session.updatedAt);
  final createdAt = DateTime.tryParse(session.createdAt);
  return (updatedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
      .toUtc()
      .millisecondsSinceEpoch;
}

bool conversationSessionListsEquivalent(
  List<AgentConversationSession> left,
  List<AgentConversationSession> right,
) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (!conversationSessionsEquivalent(left[index], right[index])) {
      return false;
    }
  }
  return true;
}

bool conversationSessionsEquivalent(
  AgentConversationSession? left,
  AgentConversationSession? right,
) {
  if (identical(left, right)) {
    return true;
  }
  if (left == null ||
      right == null ||
      left.id != right.id ||
      left.agentId != right.agentId ||
      left.title != right.title ||
      left.createdAt != right.createdAt ||
      left.updatedAt != right.updatedAt ||
      left.adapterId != right.adapterId ||
      left.nativeSessionId != right.nativeSessionId ||
      left.parentSessionId != right.parentSessionId ||
      left.lineageRootId != right.lineageRootId ||
      left.sourceKind != right.sourceKind ||
      left.importMode != right.importMode ||
      left.sourceTool != right.sourceTool ||
      left.sourceClient != right.sourceClient ||
      left.sourceClientLabel != right.sourceClientLabel ||
      left.hostApp != right.hostApp ||
      left.hostAppLabel != right.hostAppLabel ||
      left.sourceLabel != right.sourceLabel ||
      left.sourcePath != right.sourcePath ||
      left.workingDirectory != right.workingDirectory ||
      left.native != right.native ||
      left.readOnly != right.readOnly ||
      left.messageCount != right.messageCount ||
      left.sourceMessageCount != right.sourceMessageCount ||
      left.historyTruncated != right.historyTruncated ||
      left.messageTreeTruncated != right.messageTreeTruncated ||
      !conversationMessageListsEquivalent(left.messages, right.messages)) {
    return false;
  }
  return conversationSemanticEquivalent(left.semantic, right.semantic);
}

bool conversationMessageListsEquivalent(
  List<AgentConversationMessage> left,
  List<AgentConversationMessage> right,
) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    final leftMessage = left[index];
    final rightMessage = right[index];
    if (!identical(leftMessage, rightMessage) &&
        (leftMessage.id != rightMessage.id ||
            leftMessage.role != rightMessage.role ||
            leftMessage.text != rightMessage.text ||
            leftMessage.createdAt != rightMessage.createdAt ||
            leftMessage.layer != rightMessage.layer ||
            leftMessage.cardType != rightMessage.cardType ||
            leftMessage.cardTitle != rightMessage.cardTitle ||
            leftMessage.cardSubtitle != rightMessage.cardSubtitle ||
            leftMessage.collapsed != rightMessage.collapsed ||
            leftMessage.providerSummary != rightMessage.providerSummary ||
            leftMessage.stableIdentity != rightMessage.stableIdentity ||
            leftMessage.childMessagesTruncated !=
                rightMessage.childMessagesTruncated ||
            !conversationMessageListsEquivalent(
              leftMessage.childMessages,
              rightMessage.childMessages,
            ))) {
      return false;
    }
  }
  return true;
}

bool conversationSemanticEquivalent(
  AgentSemanticConversation? left,
  AgentSemanticConversation? right,
) {
  if (identical(left, right)) {
    return true;
  }
  if (left == null ||
      right == null ||
      left.schemaVersion != right.schemaVersion ||
      left.readOnly != right.readOnly ||
      !conversationMessageListsEquivalent(left.thread, right.thread) ||
      !conversationMessageListsEquivalent(left.execution, right.execution) ||
      !conversationArtifactListsEquivalent(left.artifacts, right.artifacts) ||
      !conversationAuditEquivalent(left.audit, right.audit) ||
      !conversationEvidenceListsEquivalent(
        left.rawEvidence,
        right.rawEvidence,
      )) {
    return false;
  }
  return true;
}

bool conversationArtifactListsEquivalent(
  List<AgentSemanticArtifactRef> left,
  List<AgentSemanticArtifactRef> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    final a = left[index];
    final b = right[index];
    if (a.id != b.id ||
        a.kind != b.kind ||
        a.label != b.label ||
        a.ref != b.ref ||
        a.contentHash != b.contentHash) {
      return false;
    }
  }
  return true;
}

bool conversationEvidenceListsEquivalent(
  List<AgentSemanticEvidenceRef> left,
  List<AgentSemanticEvidenceRef> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (!conversationEvidenceEquivalent(left[index], right[index])) {
      return false;
    }
  }
  return true;
}

bool conversationEvidenceEquivalent(
  AgentSemanticEvidenceRef left,
  AgentSemanticEvidenceRef right,
) {
  return left.kind == right.kind &&
      left.pathRef == right.pathRef &&
      left.contentHash == right.contentHash &&
      left.byteLength == right.byteLength;
}

bool conversationAuditEquivalent(
  AgentSemanticAudit left,
  AgentSemanticAudit right,
) {
  return left.adapterId == right.adapterId &&
      left.adapterLabel == right.adapterLabel &&
      left.hostApp == right.hostApp &&
      left.hostAppLabel == right.hostAppLabel &&
      left.sourceClient == right.sourceClient &&
      left.sourceKind == right.sourceKind &&
      left.nativeSessionId == right.nativeSessionId &&
      conversationEvidenceEquivalent(
        left.sourceEvidence,
        right.sourceEvidence,
      ) &&
      stringListsEquivalent(left.parseWarnings, right.parseWarnings) &&
      left.redactionStatus == right.redactionStatus &&
      left.validationStatus == right.validationStatus &&
      left.createdAt == right.createdAt &&
      left.updatedAt == right.updatedAt;
}

bool stringListsEquivalent(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

String relayConversationMessageId(String agentId, String role) {
  return 'mobile-relay-$agentId-$role-${DateTime.now().toUtc().microsecondsSinceEpoch}';
}

String secureAgentRelayReplyText(Map<String, dynamic> result) {
  final opened = agentRelayMap(result['result'])?['openedResult'];
  final openedMap = agentRelayMap(opened);
  final execution = agentRelayMap(openedMap?['execution']);
  final output = agentRelayMap(execution?['output']);
  final nestedOutput = output?['output'];
  final nestedMap = agentRelayMap(nestedOutput);
  final candidates = [
    nestedMap?['content'],
    nestedMap?['output'],
    nestedOutput,
    output?['content'],
    output?['result'],
    output?['stdout'],
    output?['text'],
  ];
  for (final candidate in candidates) {
    final text = candidate?.toString().trim() ?? '';
    if (text.isNotEmpty && text != 'true') {
      return text;
    }
  }
  return '';
}

String secureAgentRelayNativeSessionId(Map<String, dynamic> result) {
  final opened = agentRelayMap(result['result'])?['openedResult'];
  final openedMap = agentRelayMap(opened);
  final execution = agentRelayMap(openedMap?['execution']);
  final output = agentRelayMap(execution?['output']);
  final runtimeOutput = agentRelayMap(output?['output']);
  for (final candidate in [
    runtimeOutput?['nativeSessionId'],
    runtimeOutput?['threadId'],
    runtimeOutput?['sessionId'],
  ]) {
    final value = candidate?.toString().trim() ?? '';
    if (value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

Map<String, dynamic>? agentRelayMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return null;
}
