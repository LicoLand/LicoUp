part of 'package:flutter_client/src/application/controller/client_controller.dart';

List<AgentConversationSession> _sortConversationSessionsByUpdatedAt(
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
            (session: session, sortTime: _conversationSessionSortTime(session)),
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

List<AgentConversationSession> _mergeConversationSessionsByUpdatedAt(
  List<AgentConversationSession> existing,
  List<AgentConversationSession> incoming,
) {
  return _sortConversationSessionsByUpdatedAt([...existing, ...incoming]);
}

List<AgentConversationSession> _insertConversationSessionByUpdatedAt(
  List<AgentConversationSession> sessions,
  AgentConversationSession session,
) {
  return _sortConversationSessionsByUpdatedAt([...sessions, session]);
}

int _compareConversationSessionUpdatedAt(
  AgentConversationSession left,
  AgentConversationSession right,
) {
  final leftTime = _conversationSessionSortTime(left);
  final rightTime = _conversationSessionSortTime(right);
  final timeCompare = rightTime.compareTo(leftTime);
  if (timeCompare != 0) {
    return timeCompare;
  }
  return left.id.compareTo(right.id);
}

int _conversationSessionSortTime(AgentConversationSession session) {
  final updatedAt = DateTime.tryParse(session.updatedAt);
  final createdAt = DateTime.tryParse(session.createdAt);
  return (updatedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
      .toUtc()
      .millisecondsSinceEpoch;
}

bool _conversationSessionListsEquivalent(
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
    if (!_conversationSessionsEquivalent(left[index], right[index])) {
      return false;
    }
  }
  return true;
}

bool _conversationSessionsEquivalent(
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
      !_conversationMessageListsEquivalent(left.messages, right.messages)) {
    return false;
  }
  return _conversationSemanticEquivalent(left.semantic, right.semantic);
}

bool _conversationMessageListsEquivalent(
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
            !_conversationMessageListsEquivalent(
              leftMessage.childMessages,
              rightMessage.childMessages,
            ))) {
      return false;
    }
  }
  return true;
}

bool _conversationSemanticEquivalent(
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
      !_conversationMessageListsEquivalent(left.thread, right.thread) ||
      !_conversationMessageListsEquivalent(left.execution, right.execution) ||
      !_conversationArtifactListsEquivalent(left.artifacts, right.artifacts) ||
      !_conversationAuditEquivalent(left.audit, right.audit) ||
      !_conversationEvidenceListsEquivalent(
        left.rawEvidence,
        right.rawEvidence,
      )) {
    return false;
  }
  return true;
}

bool _conversationArtifactListsEquivalent(
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

bool _conversationEvidenceListsEquivalent(
  List<AgentSemanticEvidenceRef> left,
  List<AgentSemanticEvidenceRef> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (!_conversationEvidenceEquivalent(left[index], right[index])) {
      return false;
    }
  }
  return true;
}

bool _conversationEvidenceEquivalent(
  AgentSemanticEvidenceRef left,
  AgentSemanticEvidenceRef right,
) {
  return left.kind == right.kind &&
      left.pathRef == right.pathRef &&
      left.contentHash == right.contentHash &&
      left.byteLength == right.byteLength;
}

bool _conversationAuditEquivalent(
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
      _conversationEvidenceEquivalent(
        left.sourceEvidence,
        right.sourceEvidence,
      ) &&
      _stringListsEquivalent(left.parseWarnings, right.parseWarnings) &&
      left.redactionStatus == right.redactionStatus &&
      left.validationStatus == right.validationStatus &&
      left.createdAt == right.createdAt &&
      left.updatedAt == right.updatedAt;
}

bool _stringListsEquivalent(List<String> left, List<String> right) {
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

String _relayConversationMessageId(String agentId, String role) {
  return 'mobile-relay-$agentId-$role-${DateTime.now().toUtc().microsecondsSinceEpoch}';
}

String _secureAgentRelayReplyText(Map<String, dynamic> result) {
  final opened = _agentRelayMap(result['result'])?['openedResult'];
  final openedMap = _agentRelayMap(opened);
  final execution = _agentRelayMap(openedMap?['execution']);
  final output = _agentRelayMap(execution?['output']);
  final nestedOutput = output?['output'];
  final nestedMap = _agentRelayMap(nestedOutput);
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

String _secureAgentRelayNativeSessionId(Map<String, dynamic> result) {
  final opened = _agentRelayMap(result['result'])?['openedResult'];
  final openedMap = _agentRelayMap(opened);
  final execution = _agentRelayMap(openedMap?['execution']);
  final output = _agentRelayMap(execution?['output']);
  final runtimeOutput = _agentRelayMap(output?['output']);
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

Map<String, dynamic>? _agentRelayMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return null;
}
