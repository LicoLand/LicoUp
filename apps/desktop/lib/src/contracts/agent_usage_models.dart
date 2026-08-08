Map<String, dynamic> _map(Object? value) {
  return value is Map<String, dynamic>
      ? Map<String, dynamic>.from(value)
      : const {};
}

int _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

Map<String, dynamic> _summaryFromAgents(List<AgentUsageAgentSummary> agents) {
  var agentCount = 0;
  var sessionCount = 0;
  var messageCount = 0;
  var promptTokens = 0;
  var cachedInputTokens = 0;
  var completionTokens = 0;
  var totalTokens = 0;
  for (final agent in agents) {
    if (agent.status != 'pending') {
      agentCount += 1;
    }
    sessionCount += agent.sessionCount;
    messageCount += agent.messageCount;
    promptTokens += agent.promptTokens;
    cachedInputTokens += agent.cachedInputTokens;
    completionTokens += agent.completionTokens;
    totalTokens += agent.totalTokens;
  }
  return {
    'agentCount': agentCount,
    'sessionCount': sessionCount,
    'messageCount': messageCount,
    'promptTokens': promptTokens,
    'cachedInputTokens': cachedInputTokens,
    'completionTokens': completionTokens,
    'totalTokens': totalTokens,
    'confidence': _tokenConfidence(agents),
  };
}

class AgentUsageReport {
  static const currentSchemaVersion = 6;
  static const currentMode = 'local-token-usage';
  static const currentTokenSourceMode = 'native-metadata-first-incremental';

  const AgentUsageReport({
    required this.schemaVersion,
    required this.generatedAt,
    required this.summary,
    required this.agents,
    required this.warnings,
    this.mode = currentMode,
    this.tokenSourceMode = currentTokenSourceMode,
    this.window = const {},
  });

  final int schemaVersion;
  final String generatedAt;
  final Map<String, dynamic> summary;
  final List<AgentUsageAgentSummary> agents;
  final List<String> warnings;
  final String mode;
  final String tokenSourceMode;
  final Map<String, dynamic> window;

  static void validateEnvelope(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != currentSchemaVersion) {
      throw const FormatException('Unsupported agent usage report schema.');
    }
    if (json['mode'] != currentMode ||
        json['tokenSourceMode'] != currentTokenSourceMode) {
      throw const FormatException('Unsupported agent usage report mode.');
    }
  }

  int get agentCount => _int(summary['agentCount']);
  int get totalTokens => _int(summary['totalTokens']);
  int get windowDays {
    final value = _int(window['days'] ?? summary['windowDays']);
    return value == 0 ? 30 : value.clamp(1, 365).toInt();
  }

  String get confidence => (summary['confidence'] ?? '').toString();

  bool isFresh({DateTime? now, Duration maxAge = const Duration(hours: 1)}) {
    final generated = DateTime.tryParse(generatedAt)?.toUtc();
    if (generated == null) {
      return false;
    }
    final age = (now ?? DateTime.now()).toUtc().difference(generated);
    return !age.isNegative && age <= maxAge;
  }

  AgentUsageReport copyWith({
    String? generatedAt,
    Map<String, dynamic>? summary,
    List<AgentUsageAgentSummary>? agents,
    List<String>? warnings,
    Map<String, dynamic>? window,
  }) {
    return AgentUsageReport(
      schemaVersion: schemaVersion,
      generatedAt: generatedAt ?? this.generatedAt,
      summary: summary ?? this.summary,
      agents: agents ?? this.agents,
      warnings: warnings ?? this.warnings,
      mode: mode,
      tokenSourceMode: tokenSourceMode,
      window: window ?? this.window,
    );
  }

  AgentUsageAgentSummary? agent(String agentId) {
    for (final agent in agents) {
      if (agent.agentId == agentId) {
        return agent;
      }
    }
    return null;
  }

  factory AgentUsageReport.fromJson(Map<String, dynamic> json) {
    validateEnvelope(json);
    final schemaVersion = _int(json['schemaVersion']);
    return AgentUsageReport(
      schemaVersion: schemaVersion,
      generatedAt: (json['generatedAt'] ?? '').toString(),
      summary: _map(json['summary']),
      agents: json['agents'] is List
          ? (json['agents'] as List)
                .whereType<Map<String, dynamic>>()
                .map(AgentUsageAgentSummary.fromJson)
                .toList()
          : const [],
      warnings: json['warnings'] is List
          ? (json['warnings'] as List)
                .map((value) => value is Map ? value['code'] : value)
                .map((value) => value.toString())
                .where((value) => value.isNotEmpty)
                .toList()
          : const [],
      mode: (json['mode'] ?? '').toString(),
      tokenSourceMode: (json['tokenSourceMode'] ?? '').toString(),
      window: _map(json['window']),
    );
  }

  factory AgentUsageReport.fromAgents({
    required String generatedAt,
    required List<AgentUsageAgentSummary> agents,
    List<String> warnings = const [],
  }) {
    return AgentUsageReport(
      schemaVersion: currentSchemaVersion,
      generatedAt: generatedAt,
      summary: _summaryFromAgents(agents),
      agents: List.unmodifiable(agents),
      warnings: List.unmodifiable(warnings),
      mode: currentMode,
      tokenSourceMode: currentTokenSourceMode,
    );
  }
}

class AgentUsageAgentSummary {
  const AgentUsageAgentSummary({
    required this.agentId,
    required this.label,
    required this.status,
    required this.history,
    required this.confidence,
  });

  final String agentId;
  final String label;
  final String status;
  final Map<String, dynamic> history;
  final String confidence;

  int get sessionCount => _int(history['sessionCount']);
  int get messageCount => _int(history['messageCount']);
  int get totalTokens => _int(history['totalTokens']);
  int get promptTokens => _int(history['promptTokens']);
  int get cachedInputTokens => _int(history['cachedInputTokens']);
  int get completionTokens => _int(history['completionTokens']);

  factory AgentUsageAgentSummary.placeholder({
    required String agentId,
    required String label,
  }) {
    return AgentUsageAgentSummary(
      agentId: agentId,
      label: label,
      status: 'pending',
      history: const {},
      confidence: '',
    );
  }

  factory AgentUsageAgentSummary.fromJson(Map<String, dynamic> json) {
    return AgentUsageAgentSummary(
      agentId: (json['agentId'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      history: _map(json['history']),
      confidence: (json['confidence'] ?? '').toString(),
    );
  }
}

String _tokenConfidence(List<AgentUsageAgentSummary> agents) {
  final hasHigh = agents.any((agent) => agent.confidence == 'high');
  final hasMedium = agents.any((agent) => agent.confidence == 'medium');
  final hasLow = agents.any((agent) => agent.confidence == 'low');
  if (hasMedium || (hasHigh && hasLow)) {
    return 'medium';
  }
  if (hasHigh) {
    return 'high';
  }
  if (hasLow) {
    return 'low';
  }
  return '';
}
