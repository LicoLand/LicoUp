import 'agent_conversation_message.dart';
import 'agent_conversation_message_parser.dart';
import 'agent_conversation_privacy_projection.dart';
import 'agent_conversation_semantic.dart';

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
    this.historyTruncated = false,
    this.messageTreeTruncated = false,
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
  final bool historyTruncated;
  final bool messageTreeTruncated;
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
      historyTruncated: historyTruncated,
      messageTreeTruncated: messageTreeTruncated,
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
      historyTruncated: historyTruncated,
      messageTreeTruncated: messageTreeTruncated,
      cachedPreview: _preview,
    );
  }

  factory AgentConversationSession.fromJson(Map<String, dynamic> json) {
    final agentId = (json['agentId'] ?? '').toString();
    final adapterId = (json['adapterId'] ?? '').toString();
    final sourceClient = (json['sourceClient'] ?? '').toString();
    final sourceTool = (json['sourceTool'] ?? '').toString();
    final hostApp = (json['hostApp'] ?? '').toString();
    final rawMessages = (json['messages'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
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
      historyTruncated:
          parsedMessages.historyTruncated || json['historyTruncated'] == true,
      messageTreeTruncated:
          parsedMessages.messageTreeTruncated ||
          json['messageTreeTruncated'] == true,
      messages: messages,
      semantic: semantic,
      cachedPreview: preview,
    );
  }

  Map<String, dynamic> toJson() {
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
      if (sourceMessageCount > 0) 'sourceMessageCount': sourceMessageCount,
      if (historyTruncated) 'historyTruncated': true,
      if (messageTreeTruncated) 'messageTreeTruncated': true,
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
