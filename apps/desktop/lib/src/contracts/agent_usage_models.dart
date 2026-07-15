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
  var meteredTotalBytes = 0;
  var estimatedHistoricalBytes = 0;
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
    meteredTotalBytes += agent.meteredTotalBytes;
    estimatedHistoricalBytes += agent.estimatedHistoricalBytes;
  }
  return {
    'agentCount': agentCount,
    'sessionCount': sessionCount,
    'messageCount': messageCount,
    'promptTokens': promptTokens,
    'cachedInputTokens': cachedInputTokens,
    'completionTokens': completionTokens,
    'totalTokens': totalTokens,
    'meteredTotalBytes': meteredTotalBytes,
    'estimatedHistoricalBytes': estimatedHistoricalBytes,
    'attribution': _trafficAttribution(
      meteredTotalBytes,
      estimatedHistoricalBytes,
    ),
    'confidence': _trafficConfidence(agents),
  };
}

class AgentUsageReport {
  static const currentSchemaVersion = 2;

  const AgentUsageReport({
    required this.schemaVersion,
    required this.generatedAt,
    required this.summary,
    required this.agents,
    required this.warnings,
  });

  final int schemaVersion;
  final String generatedAt;
  final Map<String, dynamic> summary;
  final List<AgentUsageAgentSummary> agents;
  final List<String> warnings;

  static void validateEnvelope(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != currentSchemaVersion) {
      throw const FormatException('Unsupported agent usage report schema.');
    }
  }

  int get agentCount => _int(summary['agentCount']);
  int get totalTokens => _int(summary['totalTokens']);
  int get meteredTotalBytes => _int(summary['meteredTotalBytes']);
  int get estimatedHistoricalBytes => _int(summary['estimatedHistoricalBytes']);
  String get attribution => (summary['attribution'] ?? '').toString();
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
  }) {
    return AgentUsageReport(
      schemaVersion: schemaVersion,
      generatedAt: generatedAt ?? this.generatedAt,
      summary: summary ?? this.summary,
      agents: agents ?? this.agents,
      warnings: warnings ?? this.warnings,
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
    );
  }
}

class AgentUsageAgentSummary {
  const AgentUsageAgentSummary({
    required this.agentId,
    required this.label,
    required this.status,
    required this.history,
    required this.traffic,
    required this.allowances,
    required this.confidence,
  });

  final String agentId;
  final String label;
  final String status;
  final Map<String, dynamic> history;
  final Map<String, dynamic> traffic;
  final List<AgentUsageAllowance> allowances;
  final String confidence;

  int get sessionCount => _int(history['sessionCount']);
  int get messageCount => _int(history['messageCount']);
  int get totalTokens => _int(history['totalTokens']);
  int get promptTokens => _int(history['promptTokens']);
  int get cachedInputTokens => _int(history['cachedInputTokens']);
  int get completionTokens => _int(history['completionTokens']);
  int get meteredTotalBytes => _int(traffic['meteredTotalBytes']);
  int get estimatedHistoricalBytes => _int(traffic['estimatedHistoricalBytes']);
  String get attribution => (traffic['attribution'] ?? '').toString();

  factory AgentUsageAgentSummary.placeholder({
    required String agentId,
    required String label,
  }) {
    return AgentUsageAgentSummary(
      agentId: agentId,
      label: label,
      status: 'pending',
      history: const {},
      traffic: const {},
      allowances: const [],
      confidence: '',
    );
  }

  factory AgentUsageAgentSummary.fromJson(Map<String, dynamic> json) {
    return AgentUsageAgentSummary(
      agentId: (json['agentId'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      history: _map(json['history']),
      traffic: _map(json['traffic']),
      allowances: json['allowances'] is List
          ? (json['allowances'] as List)
                .whereType<Map<String, dynamic>>()
                .map(AgentUsageAllowance.fromJson)
                .toList()
          : const [],
      confidence: (json['confidence'] ?? '').toString(),
    );
  }
}

class AgentUsageAllowance {
  const AgentUsageAllowance({
    required this.kind,
    required this.label,
    required this.provider,
    required this.period,
    required this.status,
    required this.value,
    required this.unit,
    required this.source,
    required this.message,
  });

  final String kind;
  final String label;
  final String provider;
  final String period;
  final String status;
  final String value;
  final String unit;
  final String source;
  final String message;

  factory AgentUsageAllowance.fromJson(Map<String, dynamic> json) {
    return AgentUsageAllowance(
      kind: (json['kind'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      provider: (json['provider'] ?? '').toString(),
      period: (json['period'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      value: (json['value'] ?? '').toString(),
      unit: (json['unit'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      message: (json['message'] ?? '').toString(),
    );
  }
}

String _trafficAttribution(int meteredBytes, int estimatedBytes) {
  if (meteredBytes > 0 && estimatedBytes > 0) {
    return 'mixed';
  }
  if (meteredBytes > 0) {
    return 'process-metered';
  }
  if (estimatedBytes > 0) {
    return 'history-estimated';
  }
  return '';
}

String _trafficConfidence(List<AgentUsageAgentSummary> agents) {
  if (agents.any((agent) => agent.confidence == 'high')) {
    return 'high';
  }
  if (agents.any((agent) => agent.confidence == 'medium')) {
    return 'medium';
  }
  if (agents.any((agent) => agent.confidence == 'low')) {
    return 'low';
  }
  return '';
}
