import 'agent_conversation_message.dart';
import 'agent_conversation_message_parser.dart';

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
      return parseAgentConversationMessage(
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
