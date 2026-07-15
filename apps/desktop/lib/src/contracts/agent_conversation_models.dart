import 'dart:convert';

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
      (!_internalConversationRole(role) ||
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

  factory AgentConversationMessage.fromJson(
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
    return AgentConversationMessage._fromJson(
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

  static AgentConversationMessage? _fromJson(
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
    final stableIdentity = _stableConversationIdentity(
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
        final parsed = AgentConversationMessage._fromJson(
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
      text: _visibleConversationMessageText(
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
          ? (_internalConversationRole(role)
                ? ''
                : _defaultConversationCardType(kind))
          : _sanitizeStructuredLabel(rawCardType),
      cardTitle: _sanitizeStructuredLabel(
        (json['cardTitle'] ?? '').toString(),
        fallback: _defaultConversationCardTitle(kind),
      ),
      cardSubtitle: _sanitizeStructuredLabel(
        (json['cardSubtitle'] ?? '').toString(),
        fallback: _defaultConversationCardSubtitle(kind),
      ),
      collapsed: json.containsKey('collapsed')
          ? json['collapsed'] != false
          : _conversationCardCollapsedByDefault(kind),
      providerSummary: providerSummary,
      stableIdentity: stableIdentity,
      childMessagesTruncated:
          childMessagesTruncated || json['childMessagesTruncated'] == true,
      childMessages: childMessages,
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
      if (childMessagesTruncated) 'childMessagesTruncated': true,
      if (childMessages.isNotEmpty)
        'messages': childMessages.map((message) => message.toJson()).toList(),
    };
  }
}

class AgentSemanticArtifactRef {
  const AgentSemanticArtifactRef({
    required this.id,
    required this.kind,
    required this.label,
    this.ref = '',
    this.contentHash = '',
  });

  final String id;
  final String kind;
  final String label;
  final String ref;
  final String contentHash;

  factory AgentSemanticArtifactRef.fromJson(Map<String, dynamic> json) {
    return AgentSemanticArtifactRef(
      id: (json['id'] ?? '').toString(),
      kind: (json['kind'] ?? 'document').toString(),
      label: (json['label'] ?? 'Artifact').toString(),
      ref: (json['ref'] ?? '').toString(),
      contentHash: (json['contentHash'] ?? '').toString(),
    );
  }
}

class AgentSemanticEvidenceRef {
  const AgentSemanticEvidenceRef({
    required this.kind,
    required this.pathRef,
    required this.contentHash,
    this.byteLength = 0,
  });

  final String kind;
  final String pathRef;
  final String contentHash;
  final int byteLength;

  factory AgentSemanticEvidenceRef.fromJson(Map<String, dynamic> json) {
    final bytes = json['byteLength'];
    return AgentSemanticEvidenceRef(
      kind: (json['kind'] ?? 'unknown').toString(),
      pathRef: (json['pathRef'] ?? '').toString(),
      contentHash: (json['contentHash'] ?? '').toString(),
      byteLength: bytes is int
          ? bytes
          : bytes is num
          ? bytes.toInt()
          : 0,
    );
  }
}

class AgentSemanticAudit {
  const AgentSemanticAudit({
    required this.adapterId,
    required this.hostApp,
    required this.sourceKind,
    required this.nativeSessionId,
    required this.sourceEvidence,
    required this.parseWarnings,
    required this.redactionStatus,
    required this.validationStatus,
    required this.createdAt,
    required this.updatedAt,
    this.adapterLabel = '',
    this.hostAppLabel = '',
    this.sourceClient = '',
  });

  final String adapterId;
  final String adapterLabel;
  final String hostApp;
  final String hostAppLabel;
  final String sourceClient;
  final String sourceKind;
  final String nativeSessionId;
  final AgentSemanticEvidenceRef sourceEvidence;
  final List<String> parseWarnings;
  final String redactionStatus;
  final String validationStatus;
  final String createdAt;
  final String updatedAt;

  factory AgentSemanticAudit.fromJson(Map<String, dynamic> json) {
    final evidenceJson =
        (json['sourceEvidence'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    return AgentSemanticAudit(
      adapterId: (json['adapterId'] ?? '').toString(),
      adapterLabel: (json['adapterLabel'] ?? '').toString(),
      hostApp: (json['hostApp'] ?? '').toString(),
      hostAppLabel: (json['hostAppLabel'] ?? '').toString(),
      sourceClient: (json['sourceClient'] ?? '').toString(),
      sourceKind: (json['sourceKind'] ?? '').toString(),
      nativeSessionId: (json['nativeSessionId'] ?? '').toString(),
      sourceEvidence: AgentSemanticEvidenceRef.fromJson(evidenceJson),
      parseWarnings: (json['parseWarnings'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      redactionStatus: (json['redactionStatus'] ?? 'applied').toString(),
      validationStatus: (json['validationStatus'] ?? 'unchecked').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
      updatedAt: (json['updatedAt'] ?? '').toString(),
    );
  }
}

class AgentSemanticConversation {
  const AgentSemanticConversation({
    required this.thread,
    required this.execution,
    required this.artifacts,
    required this.audit,
    required this.rawEvidence,
    this.schemaVersion = 1,
    this.readOnly = true,
  });

  final int schemaVersion;
  final bool readOnly;
  final List<AgentConversationMessage> thread;
  final List<AgentConversationMessage> execution;
  final List<AgentSemanticArtifactRef> artifacts;
  final AgentSemanticAudit audit;
  final List<AgentSemanticEvidenceRef> rawEvidence;

  bool get hideAuditInDefaultView => true;
  bool get hideRawInDefaultView => true;

  factory AgentSemanticConversation.fromJson(
    Map<String, dynamic> json, {
    String agentId = '',
    String adapterId = '',
    String sourceClient = '',
    String sourceTool = '',
    String hostApp = '',
  }) {
    AgentConversationMessage? parseEvent(
      Map<String, dynamic> event, {
      required String fallbackRole,
      required String fallbackCardType,
      required AgentConversationSemanticLayer layer,
    }) {
      final role = (event['role'] ?? fallbackRole).toString();
      final text = (event['text'] ?? event['summary'] ?? '').toString();
      return AgentConversationMessage.fromJson(
        {
          ...event,
          'role': role,
          'text': text,
          'cardType': (event['cardType'] ?? fallbackCardType).toString(),
          'cardTitle': (event['cardTitle'] ?? event['title'] ?? '').toString(),
          'layer': layer.name,
        },
        agentId: agentId,
        adapterId: adapterId,
        sourceClient: sourceClient,
        sourceTool: sourceTool,
        hostApp: hostApp,
      );
    }

    final thread = (json['thread'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .map(
          (event) => parseEvent(
            event,
            fallbackRole: (event['role'] ?? 'assistant').toString(),
            fallbackCardType: '',
            layer: AgentConversationSemanticLayer.thread,
          ),
        )
        .whereType<AgentConversationMessage>()
        .where((message) => message.isDisplayable)
        .toList(growable: false);
    final execution = (json['execution'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .map((event) {
          final eventKind = (event['eventKind'] ?? 'event').toString();
          final fallbackRole = switch (eventKind) {
            'tool-call' || 'terminal' => 'tool_call',
            'tool-result' => 'tool_result',
            'reasoning' => 'reasoning',
            'error' => 'error',
            _ => 'event',
          };
          final fallbackCard = switch (eventKind) {
            'tool-call' || 'terminal' => 'tool-call',
            'tool-result' => 'tool-result',
            'reasoning' => 'reasoning',
            'error' => 'error',
            _ => 'event',
          };
          return parseEvent(
            event,
            fallbackRole: fallbackRole,
            fallbackCardType: fallbackCard,
            layer: AgentConversationSemanticLayer.execution,
          );
        })
        .whereType<AgentConversationMessage>()
        .where((message) => message.isDisplayable)
        .toList(growable: false);
    final artifacts = (json['artifacts'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) =>
              AgentSemanticArtifactRef.fromJson(item.cast<String, dynamic>()),
        )
        .toList(growable: false);
    final auditJson =
        (json['audit'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final rawRefs =
        ((json['raw'] as Map?)?['evidenceRefs'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) => AgentSemanticEvidenceRef.fromJson(
                item.cast<String, dynamic>(),
              ),
            )
            .toList(growable: false);
    return AgentSemanticConversation(
      schemaVersion: switch (json['schemaVersion']) {
        final int value => value,
        final num value => value.toInt(),
        _ => 1,
      },
      readOnly: json['readOnly'] != false,
      thread: List<AgentConversationMessage>.unmodifiable(thread),
      execution: List<AgentConversationMessage>.unmodifiable(execution),
      artifacts: List<AgentSemanticArtifactRef>.unmodifiable(artifacts),
      audit: AgentSemanticAudit.fromJson(auditJson),
      rawEvidence: List<AgentSemanticEvidenceRef>.unmodifiable(rawRefs),
    );
  }
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

  factory AgentConversationSession.fromJson(Map<String, dynamic> json) {
    final agentId = (json['agentId'] ?? '').toString();
    final adapterId = (json['adapterId'] ?? '').toString();
    final sourceClient = (json['sourceClient'] ?? '').toString();
    final sourceTool = (json['sourceTool'] ?? '').toString();
    final hostApp = (json['hostApp'] ?? '').toString();
    final rawMessages = (json['messages'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final firstRetained =
        rawMessages.length > _maxConversationMessagesPerSession
        ? rawMessages.length - _maxConversationMessagesPerSession
        : 0;
    final budget = _ConversationMessageParseBudget(
      _maxConversationMessageTreeNodes,
    );
    final identityScope = [
      (json['id'] ?? '').toString(),
      (json['nativeSessionId'] ?? '').toString(),
      agentId,
      adapterId,
      sourceClient,
      sourceTool,
      hostApp,
    ].join('|');
    final parsedMessages = <AgentConversationMessage>[];
    for (var index = firstRetained; index < rawMessages.length; index += 1) {
      final parsed = AgentConversationMessage._fromJson(
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
    final messages = List<AgentConversationMessage>.unmodifiable(
      parsedMessages,
    );
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
      title: _visibleConversationTitle(
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
      historyTruncated: firstRetained > 0 || json['historyTruncated'] == true,
      messageTreeTruncated:
          budget.truncated || json['messageTreeTruncated'] == true,
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

String _visibleConversationMessageText(
  String role,
  String text, {
  required AgentConversationMessageKind kind,
  String agentId = '',
  String adapterId = '',
  String sourceClient = '',
  String sourceTool = '',
  String hostApp = '',
  bool providerSummary = false,
}) {
  if (_structuredConversationMessageKind(kind)) {
    return _visibleStructuredConversationText(
      kind,
      text,
      providerSummary: providerSummary,
    );
  }
  if (_internalConversationRole(role)) {
    return '';
  }
  final normalizedRole = role.toLowerCase().trim();
  final visible =
      _isAntigravityConversation(
        agentId: agentId,
        adapterId: adapterId,
        sourceClient: sourceClient,
        sourceTool: sourceTool,
        hostApp: hostApp,
      )
      ? _visibleAntigravityMessageText(normalizedRole, text)
      : normalizedRole == 'user' || normalizedRole == 'human'
      ? _extractUserAuthoredText(text)
      : _stripGeneratedContextBlocks(text);
  return _finalizeVisibleConversationText(visible);
}

String _finalizeVisibleConversationText(String visible) {
  final trimmed = visible.trim();
  if (trimmed.isEmpty ||
      _generatedControlText(trimmed) ||
      _generatedOperationalNoticeText(trimmed) ||
      _generatedStructuredResultText(trimmed) ||
      _generatedAutomationChecklistText(trimmed) ||
      _antigravitySystemBoilerplateText(trimmed) ||
      _backgroundContextPromptText(trimmed)) {
    return '';
  }
  return trimmed;
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

bool _structuredConversationMessageKind(AgentConversationMessageKind kind) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall ||
    AgentConversationMessageKind.toolResult ||
    AgentConversationMessageKind.reasoning ||
    AgentConversationMessageKind.metadata ||
    AgentConversationMessageKind.error ||
    AgentConversationMessageKind.event => true,
    _ => false,
  };
}

String _visibleStructuredConversationText(
  AgentConversationMessageKind kind,
  String text, {
  bool providerSummary = false,
}) {
  if (kind == AgentConversationMessageKind.reasoning && !providerSummary) {
    return '';
  }
  if (kind == AgentConversationMessageKind.metadata) {
    return '';
  }
  if (kind == AgentConversationMessageKind.toolCall) {
    return '';
  }
  final trimmed = text.trim();
  if (trimmed.isEmpty ||
      _looksLikeRawStructuredPayload(trimmed) ||
      (kind == AgentConversationMessageKind.reasoning &&
          _looksLikeRawReasoningTrace(trimmed))) {
    return '';
  }
  final redacted = _redactStructuredConversationText(
    trimmed,
  ).replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  if (redacted.isEmpty || !_structuredProjectionIsSafe(redacted)) {
    return '';
  }
  return _truncateStructuredConversationText(redacted);
}

bool _looksLikeRawReasoningTrace(String text) {
  final normalized = text.trim().toLowerCase();
  return normalized.contains('<think>') ||
      normalized.contains('</think>') ||
      normalized.contains('chain of thought') ||
      normalized.contains('chain-of-thought') ||
      normalized.startsWith('analysis:') ||
      normalized.startsWith('scratchpad:') ||
      RegExp(
        r'(^|\n)(?:thought|internal reasoning|step-by-step reasoning)\s*\d*\s*:',
      ).hasMatch(normalized);
}

bool _looksLikeRawStructuredPayload(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('```json') &&
      !trimmed.startsWith('```JSON') &&
      !(trimmed.startsWith('{') && trimmed.endsWith('}')) &&
      !(trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    return false;
  }
  final candidate = trimmed.startsWith('```')
      ? trimmed
            .replaceFirst(RegExp(r'^```json\s*', caseSensitive: false), '')
            .replaceFirst(RegExp(r'\s*```$'), '')
      : trimmed;
  try {
    final decoded = jsonDecode(candidate);
    return decoded is Map || decoded is List;
  } catch (_) {
    return candidate.startsWith('{') || candidate.startsWith('[');
  }
}

String _redactStructuredConversationText(String text) {
  const operationalIdPlaceholder = 'LICOSAFEOPERATIONINDEX';
  final operationalIds = <String>[];
  final protected = text.replaceAllMapped(
    RegExp(r'\bround-[0-9]+/worker-[0-9]+\b', caseSensitive: false),
    (match) {
      operationalIds.add(match.group(0)!);
      return '$operationalIdPlaceholder${operationalIds.length - 1}';
    },
  );
  final redacted = protected
      .replaceAll(
        RegExp(r'\bbearer\s+[a-z0-9._~+/-]+=*', caseSensitive: false),
        'Bearer [redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''(?<![a-z0-9])((?:(?:[a-z][a-z0-9]*)[_-])*(?:api[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token|id[_-]?token|session[_-]?id|thread[_-]?id|conversation[_-]?id|native[_-]?(?:session|thread)[_-]?id|authorization|password|passwd|token|secret|key|cookie|credential))\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}: [redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''(?<![a-z0-9])([a-z][a-z0-9_.-]{1,80})(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
          caseSensitive: false,
        ),
        (match) => _structuredKeyIsSensitive(match.group(1)!)
            ? '${match.group(1)}: [redacted]'
            : match.group(0)!,
      )
      .replaceAllMapped(
        RegExp(
          r'''(?<![a-z0-9])([a-z][a-z0-9]{1,48}(?:apikey|secretaccesskey|accesskey|clientsecret|accesstoken|refreshtoken|idtoken|sessionid|threadid|conversationid|password|passwd|token|secret|cookie|credential))\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}: [redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b((?:resume|load|open|restore|continue|delete|close|for)\s+(?:the\s+)?(?:session|thread|conversation)(?:\s+(?:id|identifier))?\s+)([a-z0-9._:-]{3,})''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b((?:session|thread|conversation)(?:\s+(?:id|identifier))?\s*(?::|=|\bis\b)\s*)([a-z0-9][a-z0-9._:-]{2,})''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b((?:session|thread|conversation)(?:\s+(?:id|identifier))?\s+)(?=[a-z0-9._:-]{4,}\b)(?=[^\s,;]*[-_:0-9])([a-z0-9._:-]+)''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[redacted]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[credentials hidden]@',
      )
      .replaceAll(
        RegExp(
          r'''file:///(?:[^\s"'<>/]+/)*[^\s"'<>]+|(?<![:/\w])/(?:[^\s"'<>/]+/)*[^\s"'<>]+|[a-z]:\\[^\s"'<>]*|\\\\[^\s"'<>\\]+\\[^\s"'<>]*|~[/\\][^\s"'<>]*|(?:^|(?<=\s))\.\.?[/\\][^\s"'<>]+|(?<![:/\w])(?:[a-z0-9_.-]+[/\\])+[a-z0-9_.-]+(?=[\s"'<>),.;:]|$)''',
          caseSensitive: false,
        ),
        '[local path hidden]',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b((?:cwd|path|directory|dir|project|workspace|folder|file)(?:\s*(?:[:=]|is|at|under|in))?\s+)([a-z0-9_.-]+[/\\][a-z0-9_./\\-]+)''',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[local path hidden]',
      )
      .replaceAll(RegExp(r'\b[a-zA-Z0-9_-]{40,}\b'), '[opaque value hidden]');
  return redacted.replaceAllMapped(
    RegExp('$operationalIdPlaceholder([0-9]+)'),
    (match) {
      final index = int.tryParse(match.group(1) ?? '');
      return index != null && index < operationalIds.length
          ? operationalIds[index]
          : '[operation id hidden]';
    },
  );
}

bool _structuredKeyIsSensitive(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return const {
        'authorization',
        'password',
        'passwd',
        'cookie',
        'credential',
        'apikey',
        'clientsecret',
        'secretaccesskey',
        'accesskeyid',
        'privatekey',
        'accesstoken',
        'refreshtoken',
        'idtoken',
        'sessionid',
        'threadid',
        'conversationid',
        'nativesessionid',
        'nativethreadid',
      }.contains(normalized) ||
      normalized.contains('token') ||
      normalized.contains('secret') ||
      normalized.contains('password') ||
      normalized.contains('passwd') ||
      normalized.contains('credential') ||
      normalized.contains('accesskey') ||
      normalized.endsWith('sessionid') ||
      normalized.endsWith('threadid') ||
      normalized.endsWith('conversationid');
}

bool _structuredProjectionIsSafe(String value) {
  var candidate = value
      .replaceAll(
        RegExp(
          r'''(?<![a-z0-9])[a-z][a-z0-9_.-]{0,80}\s*:\s*\[redacted\]''',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(
          r'\[(?:local path hidden|credentials hidden|opaque value hidden|redacted)\]',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(r'\bround-[0-9]+/worker-[0-9]+\b', caseSensitive: false),
        '',
      );
  candidate = candidate.trim();
  if (candidate.isEmpty) {
    return true;
  }
  if (RegExp(r'''[/\\=@{}\[\]"'`]''').hasMatch(candidate)) {
    return false;
  }
  if (RegExp(
    r'''\b(?:session|thread|conversation|cwd|path|directory|workspace|project|folder|file|authorization|credential|password|passwd|cookie|token|secret|api.?key|access.?key|private.?key|signing.?key)\b''',
    caseSensitive: false,
  ).hasMatch(candidate)) {
    return false;
  }
  if (RegExp(
    r'\b[a-z0-9]+(?:[-_:][a-z0-9]+){3,}\b',
    caseSensitive: false,
  ).hasMatch(candidate)) {
    return false;
  }
  return true;
}

String _stableConversationIdentity(String value) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}

String _truncateStructuredConversationText(String value) {
  const maxCharacters = 1200;
  final characters = value.runes.toList(growable: false);
  if (characters.length <= maxCharacters) {
    return value;
  }
  return '${String.fromCharCodes(characters.take(maxCharacters))}\n…';
}

String _sanitizeStructuredLabel(String value, {String fallback = ''}) {
  final singleLine = _redactStructuredConversationText(
    value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim(),
  );
  if (singleLine.isEmpty ||
      _looksLikeRawStructuredPayload(singleLine) ||
      !_structuredProjectionIsSafe(singleLine)) {
    return fallback;
  }
  final runes = singleLine.runes.toList(growable: false);
  return runes.length <= 96
      ? singleLine
      : '${String.fromCharCodes(runes.take(93))}…';
}

String _defaultConversationCardType(AgentConversationMessageKind kind) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall => 'tool-call',
    AgentConversationMessageKind.toolResult => 'tool-result',
    AgentConversationMessageKind.reasoning => 'reasoning',
    AgentConversationMessageKind.metadata => 'metadata',
    AgentConversationMessageKind.error => 'error',
    AgentConversationMessageKind.event => 'event',
    AgentConversationMessageKind.subagent => 'subagent',
    _ => '',
  };
}

String _defaultConversationCardTitle(AgentConversationMessageKind kind) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall => 'Tool call',
    AgentConversationMessageKind.toolResult => 'Tool result',
    AgentConversationMessageKind.reasoning => 'Reasoning',
    AgentConversationMessageKind.metadata => 'Metadata',
    AgentConversationMessageKind.error => 'Error',
    AgentConversationMessageKind.event => 'Native event',
    _ => '',
  };
}

String _defaultConversationCardSubtitle(AgentConversationMessageKind kind) {
  return switch (kind) {
    AgentConversationMessageKind.reasoning ||
    AgentConversationMessageKind.metadata => 'Sensitive details hidden',
    AgentConversationMessageKind.toolCall => 'Native agent activity',
    AgentConversationMessageKind.toolResult => 'Native agent result',
    AgentConversationMessageKind.error => 'Native agent error',
    AgentConversationMessageKind.event => 'Native agent event',
    _ => '',
  };
}

bool _conversationCardCollapsedByDefault(AgentConversationMessageKind kind) {
  return kind != AgentConversationMessageKind.error;
}

bool _isAntigravityConversation({
  required String agentId,
  required String adapterId,
  required String sourceClient,
  required String sourceTool,
  required String hostApp,
}) {
  final evidence = [
    agentId,
    adapterId,
    sourceClient,
    sourceTool,
    hostApp,
  ].join(' ').toLowerCase();
  return evidence.contains('antigravity');
}

String _visibleAntigravityMessageText(String normalizedRole, String text) {
  if (_hiddenAntigravityRole(normalizedRole)) {
    return '';
  }
  final visible = normalizedRole == 'user' || normalizedRole == 'human'
      ? _extractAntigravityUserRequest(text)
      : _stripAntigravitySystemMessages(text);
  final generic = normalizedRole == 'user' || normalizedRole == 'human'
      ? _extractUserAuthoredText(visible)
      : _stripGeneratedContextBlocks(visible);
  return _stripAntigravityArtifactNoise(_stripAntigravityProtocolTags(generic));
}

bool _hiddenAntigravityRole(String normalizedRole) {
  return switch (normalizedRole) {
    'user' ||
    'human' ||
    'planner_response' ||
    'agent' ||
    'assistant' ||
    'generic' => false,
    _ => true,
  };
}

String _extractAntigravityUserRequest(String text) {
  final cleaned = _stripAntigravitySystemMessages(text);
  final requests = _antigravityUserRequestRegex()
      .allMatches(cleaned)
      .map((match) => match.group(1) ?? '')
      .map(_stripAntigravityProtocolTags)
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (requests.isNotEmpty) {
    return requests.join('\n\n');
  }
  return _stripAntigravityProtocolTags(cleaned);
}

String _stripAntigravitySystemMessages(String text) {
  var cleaned = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(_antigravitySystemBlockRegex(), '\n');
  final paragraphs = cleaned.split(RegExp(r'\n\s*\n'));
  cleaned = paragraphs
      .where((paragraph) => !_antigravitySystemBoilerplateText(paragraph))
      .join('\n\n');
  cleaned = cleaned
      .split('\n')
      .where((line) => !_antigravitySystemBoilerplateText(line))
      .join('\n');
  return _stripAntigravityProtocolTags(cleaned);
}

String _stripAntigravityProtocolTags(String text) {
  return text.replaceAll(_antigravityProtocolTagRegex(), '').trim();
}

String _stripAntigravityArtifactNoise(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  if (_looksLikeAntigravityArtifactDump(lines)) {
    return '';
  }
  return lines
      .where((line) => !_antigravityInternalEventLine(line))
      .map(_stripAntigravityLineGutter)
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

bool _looksLikeAntigravityArtifactDump(List<String> lines) {
  final nonBlank = lines.where((line) => line.trim().isNotEmpty).length;
  if (nonBlank < 6) {
    return false;
  }
  final gutterLines = lines
      .where((line) => _antigravityLineGutterRegex().hasMatch(line))
      .length;
  return gutterLines >= 4 && gutterLines / nonBlank >= 0.35;
}

String _stripAntigravityLineGutter(String line) {
  if (RegExp(r'^\s*\d+[.)]\s+\S').hasMatch(line)) {
    return line.trimRight();
  }
  final match = _antigravityLineGutterRegex().firstMatch(line);
  if (match == null) {
    return line.trimRight();
  }
  final indent = match.group(1) ?? '';
  final content = match.group(2) ?? '';
  return '$indent$content'.trimRight();
}

bool _antigravityInternalEventLine(String line) {
  final normalized = line.trim().toLowerCase();
  return normalized == 'conversation_history' ||
      normalized == 'user_input' ||
      normalized == 'planner_response' ||
      normalized == 'list_directory' ||
      normalized == 'view_file' ||
      normalized == 'grep_search' ||
      normalized == 'run_command' ||
      normalized == 'code_action' ||
      normalized == 'generate_image' ||
      normalized == 'read_url_content';
}

RegExp _antigravityUserRequestRegex() => RegExp(
  r'<\s*USER[_-]?REQUEST\b[^>]*>([\s\S]*?)<\s*/\s*USER[_-]?REQUEST\s*>',
  caseSensitive: false,
);

RegExp _antigravitySystemBlockRegex() => RegExp(
  r'<\s*SYSTEM[_-]?MESSAGE\b[^>]*>[\s\S]*?<\s*/\s*SYSTEM[_-]?MESSAGE\s*>',
  caseSensitive: false,
);

RegExp _antigravityProtocolTagRegex() => RegExp(
  r'</?\s*(?:USER[_-]?REQUEST|SYSTEM[_-]?MESSAGE)\b[^>]*>',
  caseSensitive: false,
);

RegExp _antigravityLineGutterRegex() =>
    RegExp(r'^(\s*)\d{1,6}\s*(?:[│|:]\s?|\s{2,})(.*)$');

bool _internalConversationRole(String role) {
  final normalized = role.toLowerCase().trim();
  return normalized == 'system' ||
      normalized == 'developer' ||
      normalized == 'subagent_prompt';
}

String _extractUserAuthoredText(String text) {
  final codexRequestIndex = _findCaseInsensitive(
    text,
    '## My request for Codex:',
  );
  if (codexRequestIndex >= 0) {
    return _stripGeneratedContextBlocks(
      text.substring(codexRequestIndex + '## My request for Codex:'.length),
    );
  }
  final plainRequestIndex = _findCaseInsensitive(text, 'My request for Codex:');
  if (plainRequestIndex >= 0) {
    return _stripGeneratedContextBlocks(
      text.substring(plainRequestIndex + 'My request for Codex:'.length),
    );
  }
  return _stripGeneratedContextBlocks(text);
}

String _stripGeneratedContextBlocks(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final visible = <String>[];
  String? closeMarker;
  for (final line in lines) {
    final lower = line.trimLeft().toLowerCase();
    final close = closeMarker;
    if (close != null) {
      if (_lineContainsContextClose(lower, close)) {
        closeMarker = null;
        final after = _trailingTextAfterContextClose(line, close);
        if (after != null && after.trim().isNotEmpty) {
          visible.add(after);
        }
      }
      continue;
    }
    if (lower.startsWith('# files mentioned by the user:')) {
      continue;
    }
    final nextClose = _generatedContextBlockCloseMarker(lower);
    if (nextClose != null) {
      if (_lineContainsContextClose(lower, nextClose)) {
        final after = _trailingTextAfterContextClose(line, nextClose);
        if (after != null && after.trim().isNotEmpty) {
          visible.add(after);
        }
      } else {
        closeMarker = nextClose;
      }
      continue;
    }
    visible.add(line);
  }
  return visible.join('\n');
}

String? _trailingTextAfterContextClose(String line, String closeMarker) {
  final lower = line.toLowerCase();
  final close = closeMarker.toLowerCase();
  final index = lower.indexOf(close);
  if (index < 0) {
    return null;
  }
  return line.substring(index + closeMarker.length);
}

String? _generatedContextBlockCloseMarker(String lowerLine) {
  for (final entry in _generatedContextBlockCloseMarkers.entries) {
    if (lowerLine.startsWith(entry.key)) {
      return entry.value;
    }
  }
  return null;
}

const _generatedContextBlockCloseMarkers = <String, String>{
  '<command-name': '</command-name>',
  '<command': '</command>',
  '<image': '</image>',
  '<system_message': '</system_message>',
  '<system-message': '</system-message>',
  '<environment_context': '</environment_context>',
  '<app-context': '</app-context>',
  '<apps_instructions': '</apps_instructions>',
  '<apps-instructions': '</apps-instructions>',
  '<skills_instructions': '</skills_instructions>',
  '<plugins_instructions': '</plugins_instructions>',
  '<recommended_plugins': '</recommended_plugins>',
  '<additional_metadata': '</additional_metadata>',
  '<collaboration_mode': '</collaboration_mode>',
  '<permissions instructions': '</permissions instructions>',
  '<system': '</system>',
  '<developer': '</developer>',
  '<instructions': '</instructions>',
  '<local-command-caveat': '</local-command-caveat>',
  '<local-command-output': '</local-command-output>',
  '<local-command-stdout': '</local-command-stdout>',
  '<local-command-stderr': '</local-command-stderr>',
};

bool _lineContainsContextClose(String lowerLine, String closeMarker) {
  return lowerLine.contains(closeMarker) ||
      _compactContextMarker(
        lowerLine,
      ).contains(_compactContextMarker(closeMarker));
}

String _compactContextMarker(String value) {
  return value.replaceAll(RegExp(r'[_\-\s]'), '');
}

bool _generatedControlText(String text) {
  final lower = text.trimLeft().toLowerCase();
  return lower.startsWith('<local-command-caveat>') ||
      lower.startsWith('<command-name') ||
      lower.startsWith('<command') ||
      lower.startsWith('<local-command-output>') ||
      lower.startsWith('<local-command-stdout>') ||
      lower.startsWith('<local-command-stderr>') ||
      lower.startsWith('<local-command-exit-code>') ||
      lower.startsWith('<local-command-timeout>') ||
      lower.startsWith('<environment_context>') ||
      lower.startsWith('<apps_instructions>') ||
      lower.startsWith('<apps-instructions>') ||
      lower.startsWith('<recommended_plugins') ||
      lower.startsWith('<additional_metadata') ||
      lower.startsWith('<plugins_instructions') ||
      _generatedOperationalNoticeText(text) ||
      _generatedStructuredResultText(text) ||
      _generatedAutomationChecklistText(text) ||
      _backgroundContextPromptText(text) ||
      (lower.contains('<local-command-caveat>') &&
          lower.contains('do not respond'));
}

bool _generatedOperationalNoticeText(String text) {
  final lower = text.trimLeft().toLowerCase();
  return _antigravitySystemBoilerplateText(text) ||
      lower.contains('auto mode cannot determine the safety of') ||
      lower.contains('wait briefly and then try this action again') ||
      lower.contains('do not require the classifier and can still be used') ||
      lower.startsWith('the classifier is blocking ') ||
      (lower.contains('temporarily unavailable') &&
          lower.contains('classifier')) ||
      (lower.contains('temporarily unavailable') &&
          lower.contains('auto mode cannot determine'));
}

bool _antigravitySystemBoilerplateText(String text) {
  final lower = text.trim().toLowerCase();
  if (lower.isEmpty) {
    return false;
  }
  return (lower.contains('<system_message>') &&
          lower.contains('not actually sent by the user')) ||
      (lower.contains('not actually sent by the user') &&
          lower.contains('important information to pay attention')) ||
      lower.startsWith('the following is a <system_message>') ||
      lower.startsWith('the following is a <system-message>');
}

bool _generatedStructuredResultText(String text) {
  final normalized = text.trimLeft();
  final lower = normalized.toLowerCase();
  final firstLine = normalized
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '')
      .toLowerCase();
  final startsLikeStructuredResult =
      firstLine.startsWith('"ok":') ||
      firstLine.startsWith("'ok':") ||
      firstLine.startsWith('ok:') ||
      (firstLine.startsWith('{') &&
          (lower.contains('"ok"') || lower.contains("'ok'")));
  if (!startsLikeStructuredResult) {
    return false;
  }
  return lower.contains('"ok": true') ||
      lower.contains("'ok': true") ||
      lower.contains('ok: true') ||
      lower.contains('"command"') ||
      lower.contains('"args"') ||
      lower.contains('"sideeffects"') ||
      lower.contains('"requiredservices"') ||
      lower.contains('"timeoutclass"') ||
      lower.contains('"flakepolicy"') ||
      lower.contains('"profiles"') ||
      lower.contains('"artifacts"') ||
      lower.contains('node --test') ||
      lower.contains('npm run ');
}

bool _generatedAutomationChecklistText(String text) {
  final lower = text.trimLeft().toLowerCase();
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((line) => line.trimLeft().toLowerCase())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  final checklistLines = lines
      .where(
        (line) =>
            line.startsWith('- [ ]') ||
            line.startsWith('- [x]') ||
            line.startsWith('* [ ]') ||
            line.startsWith('* [x]'),
      )
      .length;
  if (checklistLines < 2) {
    return false;
  }
  return lower.contains('classifier') ||
      lower.contains('sandbox') ||
      lower.contains('approval policy') ||
      lower.contains('tool call') ||
      lower.contains('local command') ||
      lower.contains('execution adapter') ||
      lower.contains('sideeffects') ||
      lower.contains('requiredservices') ||
      lower.contains('timeoutclass');
}

bool _backgroundContextPromptText(String text) {
  final lower = text.trimLeft().toLowerCase();
  return _antigravitySystemBoilerplateText(text) ||
      lower.startsWith('# agents.md instructions') ||
      lower.startsWith('agents.md instructions') ||
      lower.startsWith('<instructions>') ||
      lower.startsWith('you are codex, a coding agent') ||
      lower.startsWith('you are chatgpt') ||
      _looksLikeDelegatedAgentPrompt(text) ||
      lower.startsWith('knowledge cutoff:') ||
      lower.startsWith('current date:') ||
      lower.startsWith('filesystem sandboxing defines') ||
      lower.startsWith('sandbox_mode') ||
      lower.startsWith('<system') ||
      lower.startsWith('<system_message') ||
      lower.startsWith('<system-message') ||
      lower.startsWith('<developer') ||
      lower.startsWith('<app-context') ||
      lower.startsWith('<apps_instructions') ||
      lower.startsWith('<apps-instructions') ||
      lower.startsWith('<environment_context') ||
      lower.startsWith('<skills_instructions') ||
      lower.startsWith('<plugins_instructions') ||
      lower.startsWith('<collaboration_mode');
}

bool _looksLikeDelegatedAgentPrompt(String text) {
  final first = text
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '')
      .toLowerCase();
  if (first.startsWith('you are a')) {
    final rest = first.substring('you are a'.length);
    final digits = RegExp(r'^\d+').stringMatch(rest) ?? '';
    if (digits.isNotEmpty && rest.substring(digits.length).startsWith(':')) {
      return true;
    }
  }
  if (first.startsWith('you are agent a')) {
    final rest = first.substring('you are agent a'.length);
    final digits = RegExp(r'^\d+').stringMatch(rest) ?? '';
    if (digits.isNotEmpty && rest.substring(digits.length).startsWith(':')) {
      return true;
    }
  }
  return first.startsWith('you are ') &&
      first.contains(' worker') &&
      (first.contains(' round-') ||
          first.contains('worker-') ||
          first.contains('codex security') ||
          first.contains('you are not the coordinator') ||
          first.contains('worker-local'));
}

String _visibleConversationTitle(
  String rawTitle,
  List<AgentConversationMessage> messages, {
  String agentId = '',
  String adapterId = '',
  String sourceClient = '',
  String sourceTool = '',
  String hostApp = '',
}) {
  final decodedTitle =
      _isAntigravityConversation(
        agentId: agentId,
        adapterId: adapterId,
        sourceClient: sourceClient,
        sourceTool: sourceTool,
        hostApp: hostApp,
      )
      ? _extractAntigravityUserRequest(rawTitle)
      : rawTitle;
  final cleanTitle = _oneLineConversationTitle(
    _stripGeneratedContextBlocks(decodedTitle),
  );
  if (cleanTitle.isNotEmpty &&
      !_generatedControlText(cleanTitle) &&
      !_backgroundContextPromptText(cleanTitle) &&
      !_generatedStatusTitle(cleanTitle)) {
    return cleanTitle;
  }
  for (final message in messages) {
    final role = message.role.toLowerCase().trim();
    if (role == 'user' || role == 'human') {
      final title = _oneLineConversationTitle(
        _stripGeneratedContextBlocks(message.text),
      );
      if (title.isNotEmpty &&
          !_generatedControlText(title) &&
          !_backgroundContextPromptText(title) &&
          !_generatedStatusTitle(title)) {
        return title;
      }
    }
  }
  return 'Native agent history';
}

String _oneLineConversationTitle(String value) {
  final line = value
      .trim()
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  if (line.length <= 120) {
    return line;
  }
  return '${line.substring(0, 117)}...';
}

bool _generatedStatusTitle(String value) {
  final lower = value.trimLeft().toLowerCase();
  return lower.startsWith('updated ') ||
      lower.startsWith('created ') ||
      lower.startsWith('deleted ') ||
      lower.startsWith('renamed ') ||
      lower.startsWith('moved ') ||
      lower.startsWith('indexed ') ||
      lower.startsWith('the conversation has been cleared') ||
      lower.startsWith('conversation has been cleared');
}

int _findCaseInsensitive(String text, String pattern) {
  return text.toLowerCase().indexOf(pattern.toLowerCase());
}
