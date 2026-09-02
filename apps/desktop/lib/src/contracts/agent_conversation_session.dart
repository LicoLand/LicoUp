import 'dart:convert';

import 'agent_conversation_message.dart';
import 'agent_conversation_message_parser.dart';
import 'agent_conversation_privacy_projection.dart';
import 'agent_conversation_semantic.dart';

final class AgentConversationMessagePage {
  const AgentConversationMessagePage({
    required this.start,
    required this.endExclusive,
    required this.returned,
    required this.total,
    required this.hasEarlier,
    required this.nextBefore,
  });

  const AgentConversationMessagePage.empty()
    : start = 0,
      endExclusive = 0,
      returned = 0,
      total = 0,
      hasEarlier = false,
      nextBefore = '';

  final int start;
  final int endExclusive;
  final int returned;
  final int total;
  final bool hasEarlier;
  final String nextBefore;

  factory AgentConversationMessagePage.fromJson(
    Object? raw, {
    required int messageCount,
    required int sourceMessageCount,
    required String firstMessageId,
  }) {
    if (raw == null) {
      final total = sourceMessageCount < messageCount
          ? messageCount
          : sourceMessageCount;
      final start = total - messageCount;
      return AgentConversationMessagePage(
        start: start,
        endExclusive: total,
        returned: messageCount,
        total: total,
        hasEarlier: start > 0,
        nextBefore: start > 0 ? firstMessageId : '',
      );
    }
    if (raw is! Map) {
      throw const FormatException('native_history_message_page_invalid');
    }
    final page = Map<String, dynamic>.from(raw);
    int integer(String key) => switch (page[key]) {
      final int value => value,
      final num value => value.toInt(),
      _ => -1,
    };
    final start = integer('start');
    final endExclusive = integer('endExclusive');
    final returned = integer('returned');
    final total = integer('total');
    final hasEarlier = page['hasEarlier'];
    final nextBefore = (page['nextBefore'] ?? '').toString().trim();
    if (start < 0 ||
        endExclusive < start ||
        returned < 0 ||
        total < endExclusive ||
        returned != messageCount ||
        endExclusive - start != returned ||
        hasEarlier is! bool ||
        (hasEarlier && (start == 0 || nextBefore.isEmpty)) ||
        (!hasEarlier && start != 0)) {
      throw const FormatException('native_history_message_page_invalid');
    }
    return AgentConversationMessagePage(
      start: start,
      endExclusive: endExclusive,
      returned: returned,
      total: total,
      hasEarlier: hasEarlier,
      nextBefore: hasEarlier ? nextBefore : '',
    );
  }

  Map<String, dynamic> toJson() => {
    'start': start,
    'endExclusive': endExclusive,
    'returned': returned,
    'total': total,
    'hasEarlier': hasEarlier,
    if (nextBefore.isNotEmpty) 'nextBefore': nextBefore,
  };
}

class AgentConversationSession {
  const AgentConversationSession({
    required this.id,
    required this.agentId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
    this.semantic,
    this.adapterId = '',
    this.nativeSessionId = '',
    this.parentSessionId = '',
    this.lineageRootId = '',
    this.sourceKind = '',
    this.importMode = '',
    this.sourceTool = '',
    this.sourceClient = '',
    this.sourceClientLabel = '',
    this.hostApp = '',
    this.hostAppLabel = '',
    this.sourceLabel = '',
    this.sourcePath = '',
    this.workingDirectory = '',
    this.native = true,
    this.readOnly = true,
    this.messageCount = 0,
    this.sourceMessageCount = 0,
    this.messagePage = const AgentConversationMessagePage.empty(),
    this.historyTruncated = false,
    this.messageTreeTruncated = false,
    this.running = false,
    String cachedPreview = '',
  }) : _preview = cachedPreview;

  final String id;
  final String agentId;
  final String title;
  final String createdAt;
  final String updatedAt;
  final String adapterId;
  final String nativeSessionId;
  final String parentSessionId;
  final String lineageRootId;
  final String sourceKind;
  final String importMode;
  final String sourceTool;
  final String sourceClient;
  final String sourceClientLabel;
  final String hostApp;
  final String hostAppLabel;
  final String sourceLabel;
  final String sourcePath;
  final String workingDirectory;
  final bool native;
  final bool readOnly;
  final int messageCount;
  final int sourceMessageCount;
  final AgentConversationMessagePage messagePage;
  final bool historyTruncated;
  final bool messageTreeTruncated;

  /// True only when the native adapter has current evidence that this
  /// conversation owns an in-flight turn.
  final bool running;
  final List<AgentConversationMessage> messages;
  final AgentSemanticConversation? semantic;
  final String _preview;

  List<AgentConversationMessage> get threadMessages {
    final semanticThread = semantic?.thread;
    if (semanticThread != null && semanticThread.isNotEmpty) {
      return semanticThread;
    }
    return messages
        .where((message) => message.isDefaultThreadVisible)
        .toList(growable: false);
  }

  List<AgentConversationMessage> get executionMessages {
    final semanticExecution = semantic?.execution;
    if (semanticExecution != null && semanticExecution.isNotEmpty) {
      return semanticExecution;
    }
    return messages
        .where((message) => message.isDefaultExecutionVisible)
        .toList(growable: false);
  }

  List<AgentSemanticArtifactRef> get artifacts =>
      semantic?.artifacts ?? const <AgentSemanticArtifactRef>[];

  bool get hasDiagnostics =>
      semantic != null &&
      (semantic!.audit.adapterId.isNotEmpty ||
          semantic!.rawEvidence.isNotEmpty ||
          semantic!.audit.parseWarnings.isNotEmpty);

  String get preview {
    return _preview.isNotEmpty
        ? _preview
        : _agentConversationSessionPreview(messages, semantic);
  }

  AgentConversationSession withWorkingDirectory(String value) {
    return AgentConversationSession(
      id: id,
      agentId: agentId,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: messages,
      semantic: semantic,
      adapterId: adapterId,
      nativeSessionId: nativeSessionId,
      parentSessionId: parentSessionId,
      lineageRootId: lineageRootId,
      sourceKind: sourceKind,
      importMode: importMode,
      sourceTool: sourceTool,
      sourceClient: sourceClient,
      sourceClientLabel: sourceClientLabel,
      hostApp: hostApp,
      hostAppLabel: hostAppLabel,
      sourceLabel: sourceLabel,
      sourcePath: sourcePath,
      workingDirectory: value,
      native: native,
      readOnly: readOnly,
      messageCount: messageCount,
      sourceMessageCount: sourceMessageCount,
      messagePage: messagePage,
      historyTruncated: historyTruncated,
      messageTreeTruncated: messageTreeTruncated,
      running: running,
      cachedPreview: _preview,
    );
  }

  AgentConversationSession withTitle(String value) {
    return AgentConversationSession(
      id: id,
      agentId: agentId,
      title: value,
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: messages,
      semantic: semantic,
      adapterId: adapterId,
      nativeSessionId: nativeSessionId,
      parentSessionId: parentSessionId,
      lineageRootId: lineageRootId,
      sourceKind: sourceKind,
      importMode: importMode,
      sourceTool: sourceTool,
      sourceClient: sourceClient,
      sourceClientLabel: sourceClientLabel,
      hostApp: hostApp,
      hostAppLabel: hostAppLabel,
      sourceLabel: sourceLabel,
      sourcePath: sourcePath,
      workingDirectory: workingDirectory,
      native: native,
      readOnly: readOnly,
      messageCount: messageCount,
      sourceMessageCount: sourceMessageCount,
      messagePage: messagePage,
      historyTruncated: historyTruncated,
      messageTreeTruncated: messageTreeTruncated,
      running: running,
      cachedPreview: _preview,
    );
  }

  AgentConversationSession mergeExactMessagePage(
    AgentConversationSession incoming, {
    bool allowMessageRevisions = false,
  }) {
    final expectedNative = nativeSessionId.trim();
    final incomingNative = incoming.nativeSessionId.trim();
    if (agentId.trim() != incoming.agentId.trim() ||
        expectedNative.isEmpty ||
        incomingNative != expectedNative) {
      throw const FormatException('native_history_session_identity_mismatch');
    }
    if (messages.isEmpty && messagePage.returned == 0) {
      // A browse placeholder without accumulated page state cannot overlap or
      // gap against the incoming exact page; adopt it wholesale. Remote browse
      // rows legitimately carry zeroed page facts with no preview messages.
      return incoming;
    }
    if (!allowMessageRevisions &&
        messagePage.total != incoming.messagePage.total) {
      throw const FormatException('native_history_session_identity_mismatch');
    }
    if (incoming.messagePage.endExclusive < messagePage.start ||
        messagePage.endExclusive < incoming.messagePage.start) {
      throw const FormatException('native_history_message_page_gap');
    }

    final currentByIdentity = <String, AgentConversationMessage>{
      for (final message in messages) _messageIdentity(message): message,
    };
    final incomingByIdentity = <String, AgentConversationMessage>{
      for (final message in incoming.messages)
        _messageIdentity(message): message,
    };
    for (final message in incoming.messages) {
      final identity = _messageIdentity(message);
      final previous = currentByIdentity[identity];
      if (previous != null &&
          !allowMessageRevisions &&
          jsonEncode(previous.toJson()) != jsonEncode(message.toJson())) {
        throw const FormatException('native_history_message_page_overlap');
      }
    }

    final merged = <AgentConversationMessage>[];
    final seen = <String>{};
    void append(Iterable<AgentConversationMessage> source) {
      for (final message in source) {
        final identity = _messageIdentity(message);
        if (!seen.add(identity)) continue;
        final revised = allowMessageRevisions
            ? incomingByIdentity[identity]
            : null;
        merged.add(revised ?? message);
      }
    }

    if (incoming.messagePage.start < messagePage.start) {
      append(incoming.messages);
      append(messages);
    } else {
      append(messages);
      append(incoming.messages);
    }
    final start = messagePage.start < incoming.messagePage.start
        ? messagePage.start
        : incoming.messagePage.start;
    final end = messagePage.endExclusive > incoming.messagePage.endExclusive
        ? messagePage.endExclusive
        : incoming.messagePage.endExclusive;
    if (merged.length != end - start) {
      throw const FormatException('native_history_message_page_overlap');
    }
    final page = AgentConversationMessagePage(
      start: start,
      endExclusive: end,
      returned: merged.length,
      total: messagePage.total > incoming.messagePage.total
          ? messagePage.total
          : incoming.messagePage.total,
      hasEarlier: start > 0,
      nextBefore: start > 0 && merged.isNotEmpty ? merged.first.id : '',
    );
    return _copyFrom(
      incoming,
      messages: List<AgentConversationMessage>.unmodifiable(merged),
      messagePage: page,
      sourceMessageCount: page.total,
    );
  }

  /// Applies newer catalog metadata while retaining the exact pages already
  /// accumulated for this native identity.
  AgentConversationSession retainExactMessagesAcrossPreview(
    AgentConversationSession preview,
  ) {
    if (nativeSessionId.trim().isEmpty ||
        nativeSessionId.trim() != preview.nativeSessionId.trim() ||
        agentId.trim() != preview.agentId.trim()) {
      return preview;
    }
    return _copyFrom(
      preview,
      messages: messages,
      messagePage: messagePage,
      sourceMessageCount: sourceMessageCount,
    );
  }

  AgentConversationSession _copyFrom(
    AgentConversationSession metadata, {
    required List<AgentConversationMessage> messages,
    required AgentConversationMessagePage messagePage,
    required int sourceMessageCount,
  }) {
    return AgentConversationSession(
      id: metadata.id,
      agentId: metadata.agentId,
      title: metadata.title,
      createdAt: metadata.createdAt,
      updatedAt: metadata.updatedAt,
      messages: messages,
      semantic: metadata.semantic ?? semantic,
      adapterId: metadata.adapterId,
      nativeSessionId: metadata.nativeSessionId,
      parentSessionId: metadata.parentSessionId,
      lineageRootId: metadata.lineageRootId,
      sourceKind: metadata.sourceKind,
      importMode: metadata.importMode,
      sourceTool: metadata.sourceTool,
      sourceClient: metadata.sourceClient,
      sourceClientLabel: metadata.sourceClientLabel,
      hostApp: metadata.hostApp,
      hostAppLabel: metadata.hostAppLabel,
      sourceLabel: metadata.sourceLabel,
      sourcePath: metadata.sourcePath,
      workingDirectory: metadata.workingDirectory.trim().isNotEmpty
          ? metadata.workingDirectory
          : workingDirectory,
      native: metadata.native,
      readOnly: metadata.readOnly,
      messageCount: messages.length,
      sourceMessageCount: sourceMessageCount,
      messagePage: messagePage,
      historyTruncated: false,
      messageTreeTruncated: false,
      running: metadata.running,
    );
  }

  factory AgentConversationSession.fromJson(Map<String, dynamic> json) {
    final agentId = (json['agentId'] ?? '').toString();
    final adapterId = (json['adapterId'] ?? '').toString();
    final sourceClient = (json['sourceClient'] ?? '').toString();
    final sourceTool = (json['sourceTool'] ?? '').toString();
    final hostApp = (json['hostApp'] ?? '').toString();
    final rawMessageValues = json['messages'];
    if (rawMessageValues != null && rawMessageValues is! List) {
      throw const FormatException('native_history_messages_invalid');
    }
    final rawMessages = <Map<String, dynamic>>[];
    for (final rawMessage
        in rawMessageValues is List ? rawMessageValues : const <Object?>[]) {
      if (rawMessage is! Map) {
        throw const FormatException('native_history_message_invalid');
      }
      try {
        rawMessages.add(Map<String, dynamic>.from(rawMessage));
      } on Object {
        throw const FormatException('native_history_message_invalid');
      }
    }
    final parsedMessages = parseAgentConversationMessages(
      rawMessages,
      sessionId: (json['id'] ?? '').toString(),
      nativeSessionId: (json['nativeSessionId'] ?? '').toString(),
      agentId: agentId,
      adapterId: adapterId,
      sourceClient: sourceClient,
      sourceTool: sourceTool,
      hostApp: hostApp,
    );
    final messages = parsedMessages.messages;
    final rawTitle = (json['title'] ?? 'Native agent history').toString();
    final declaredMessageCount = switch (json['sourceMessageCount'] ??
        json['messageCount']) {
      final int value when value >= 0 => value,
      final num value when value >= 0 => value.toInt(),
      _ => rawMessages.length,
    };
    final sourceMessageCount = declaredMessageCount > rawMessages.length
        ? declaredMessageCount
        : rawMessages.length;
    final messageIdentities = <String>{};
    for (final message in messages) {
      final identity = message.id.trim().isNotEmpty
          ? message.id.trim()
          : message.stableIdentity.trim();
      if (identity.isEmpty || !messageIdentities.add(identity)) {
        throw const FormatException(
          'native_history_message_identity_duplicate',
        );
      }
    }
    final messagePage = AgentConversationMessagePage.fromJson(
      json['messagePage'],
      messageCount: messages.length,
      sourceMessageCount: sourceMessageCount,
      firstMessageId: messages.isEmpty ? '' : messages.first.id,
    );
    if (messagePage.total != sourceMessageCount) {
      throw const FormatException('native_history_message_total_mismatch');
    }
    final semanticJson = (json['semantic'] as Map?)?.cast<String, dynamic>();
    final semantic = semanticJson == null
        ? null
        : AgentSemanticConversation.fromJson(
            semanticJson,
            agentId: agentId,
            adapterId: adapterId,
            sourceClient: sourceClient,
            sourceTool: sourceTool,
            hostApp: hostApp,
          );
    final preview = _agentConversationSessionPreview(messages, semantic);
    return AgentConversationSession(
      id: (json['id'] ?? '').toString(),
      agentId: agentId,
      title: visibleAgentConversationTitle(
        rawTitle,
        messages,
        agentId: agentId,
        adapterId: adapterId,
        sourceClient: sourceClient,
        sourceTool: sourceTool,
        hostApp: hostApp,
      ),
      createdAt: (json['createdAt'] ?? '').toString(),
      updatedAt: (json['updatedAt'] ?? '').toString(),
      adapterId: adapterId,
      nativeSessionId: (json['nativeSessionId'] ?? '').toString(),
      parentSessionId: (json['parentSessionId'] ?? '').toString(),
      lineageRootId: (json['lineageRootId'] ?? '').toString(),
      sourceKind: (json['sourceKind'] ?? '').toString(),
      importMode: (json['importMode'] ?? '').toString(),
      sourceTool: sourceTool,
      sourceClient: sourceClient,
      sourceClientLabel: (json['sourceClientLabel'] ?? '').toString(),
      hostApp: hostApp,
      hostAppLabel: (json['hostAppLabel'] ?? '').toString(),
      sourceLabel: (json['sourceLabel'] ?? '').toString(),
      sourcePath: (json['sourcePath'] ?? '').toString(),
      workingDirectory: (json['workingDirectory'] ?? '').toString(),
      native: json['native'] != false,
      readOnly: json['readOnly'] != false,
      messageCount: messages.length,
      sourceMessageCount: sourceMessageCount,
      messagePage: messagePage,
      historyTruncated:
          parsedMessages.historyTruncated || json['historyTruncated'] == true,
      messageTreeTruncated:
          parsedMessages.messageTreeTruncated ||
          json['messageTreeTruncated'] == true,
      running: json['running'] == true,
      messages: messages,
      semantic: semantic,
      cachedPreview: preview,
    );
  }

  Map<String, dynamic> toJson() {
    final effectiveSourceMessageCount = sourceMessageCount > 0
        ? sourceMessageCount
        : messages.length;
    final effectiveMessagePage = messagePage.total > 0 || messages.isEmpty
        ? messagePage
        : AgentConversationMessagePage.fromJson(
            null,
            messageCount: messages.length,
            sourceMessageCount: effectiveSourceMessageCount,
            firstMessageId: messages.first.id,
          );
    return {
      'id': id,
      'agentId': agentId,
      'title': title,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'adapterId': adapterId,
      'nativeSessionId': nativeSessionId,
      'parentSessionId': parentSessionId,
      'lineageRootId': lineageRootId,
      'sourceKind': sourceKind,
      'importMode': importMode,
      'sourceTool': sourceTool,
      'sourceClient': sourceClient,
      'sourceClientLabel': sourceClientLabel,
      'hostApp': hostApp,
      'hostAppLabel': hostAppLabel,
      'sourceLabel': sourceLabel,
      'sourcePath': sourcePath,
      'workingDirectory': workingDirectory,
      'native': native,
      'readOnly': readOnly,
      'messageCount': messageCount == 0 ? messages.length : messageCount,
      if (effectiveSourceMessageCount > 0)
        'sourceMessageCount': effectiveSourceMessageCount,
      'messagePage': effectiveMessagePage.toJson(),
      if (historyTruncated) 'historyTruncated': true,
      if (messageTreeTruncated) 'messageTreeTruncated': true,
      if (running) 'running': true,
      'messages': messages.map((message) => message.toJson()).toList(),
      if (semantic != null)
        'semantic': {
          'schemaVersion': semantic!.schemaVersion,
          'kind': 'semantic-conversation',
          'readOnly': semantic!.readOnly,
          'privacyDefaults': {
            'defaultView': 'thread',
            'hideRawInDefaultView': true,
            'hideAuditInDefaultView': true,
            'redactPaths': true,
            'redactTokens': true,
            'redactFullCommandPayloads': true,
          },
          'thread': semantic!.thread
              .map((message) => message.toJson())
              .toList(),
          'execution': semantic!.execution
              .map((message) => message.toJson())
              .toList(),
          'artifacts': semantic!.artifacts
              .map(
                (artifact) => {
                  'id': artifact.id,
                  'layer': 'artifacts',
                  'kind': artifact.kind,
                  'label': artifact.label,
                  if (artifact.ref.isNotEmpty) 'ref': artifact.ref,
                  if (artifact.contentHash.isNotEmpty)
                    'contentHash': artifact.contentHash,
                },
              )
              .toList(),
          'audit': {
            'adapterId': semantic!.audit.adapterId,
            'adapterLabel': semantic!.audit.adapterLabel,
            'hostApp': semantic!.audit.hostApp,
            'hostAppLabel': semantic!.audit.hostAppLabel,
            'sourceClient': semantic!.audit.sourceClient,
            'sourceKind': semantic!.audit.sourceKind,
            'nativeSessionId': semantic!.audit.nativeSessionId,
            'importMode': 'precise-adapter',
            'sourceEvidence': {
              'kind': semantic!.audit.sourceEvidence.kind,
              'pathRef': semantic!.audit.sourceEvidence.pathRef,
              'contentHash': semantic!.audit.sourceEvidence.contentHash,
              'byteLength': semantic!.audit.sourceEvidence.byteLength,
            },
            'parseWarnings': semantic!.audit.parseWarnings,
            'redactionStatus': semantic!.audit.redactionStatus,
            'validationStatus': semantic!.audit.validationStatus,
            'createdAt': semantic!.audit.createdAt,
            'updatedAt': semantic!.audit.updatedAt,
          },
          'raw': {
            'evidenceRefs': semantic!.rawEvidence
                .map(
                  (evidence) => {
                    'kind': evidence.kind,
                    'pathRef': evidence.pathRef,
                    'contentHash': evidence.contentHash,
                    'byteLength': evidence.byteLength,
                  },
                )
                .toList(),
          },
        },
    };
  }
}

String _messageIdentity(AgentConversationMessage message) {
  final native = message.id.trim();
  return native.isNotEmpty ? native : message.stableIdentity.trim();
}

String _agentConversationSessionPreview(
  List<AgentConversationMessage> messages,
  AgentSemanticConversation? semantic,
) {
  final semanticThread = semantic?.thread;
  final preferred = semanticThread != null && semanticThread.isNotEmpty
      ? semanticThread
      : messages;
  if (preferred.isEmpty) {
    return 'No native messages yet';
  }
  for (var index = preferred.length - 1; index >= 0; index -= 1) {
    final message = preferred[index];
    if ((message.kind == AgentConversationMessageKind.user ||
            message.kind == AgentConversationMessageKind.assistant) &&
        message.text.trim().isNotEmpty) {
      return message.text;
    }
  }
  return 'Native agent activity';
}
