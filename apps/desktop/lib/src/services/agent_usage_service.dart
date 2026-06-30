import 'agent_service.dart';

class AgentUsageReport {
  const AgentUsageReport({
    required this.generatedAt,
    required this.summary,
    required this.agents,
    required this.warnings,
  });

  final String generatedAt;
  final Map<String, dynamic> summary;
  final List<AgentUsageAgentSummary> agents;
  final List<String> warnings;

  int get agentCount => _int(summary['agentCount']);
  int get totalTokens => _int(summary['totalTokens']);
  int get meteredTotalBytes => _int(summary['meteredTotalBytes']);
  int get estimatedHistoricalBytes => _int(summary['estimatedHistoricalBytes']);
  String get attribution => (summary['attribution'] ?? '').toString();
  String get confidence => (summary['confidence'] ?? '').toString();

  AgentUsageAgentSummary? agent(String agentId) {
    for (final agent in agents) {
      if (agent.agentId == agentId) {
        return agent;
      }
    }
    return null;
  }

  factory AgentUsageReport.fromJson(Map<String, dynamic> json) {
    return AgentUsageReport(
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
}

class AgentUsageAgentSummary {
  const AgentUsageAgentSummary({
    required this.agentId,
    required this.label,
    required this.status,
    required this.history,
    required this.traffic,
    required this.confidence,
  });

  final String agentId;
  final String label;
  final String status;
  final Map<String, dynamic> history;
  final Map<String, dynamic> traffic;
  final String confidence;

  int get sessionCount => _int(history['sessionCount']);
  int get messageCount => _int(history['messageCount']);
  int get totalTokens => _int(history['totalTokens']);
  int get promptTokens => _int(history['promptTokens']);
  int get completionTokens => _int(history['completionTokens']);
  int get meteredTotalBytes => _int(traffic['meteredTotalBytes']);
  int get estimatedHistoricalBytes => _int(traffic['estimatedHistoricalBytes']);
  String get attribution => (traffic['attribution'] ?? '').toString();

  factory AgentUsageAgentSummary.fromJson(Map<String, dynamic> json) {
    return AgentUsageAgentSummary(
      agentId: (json['agentId'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      history: _map(json['history']),
      traffic: _map(json['traffic']),
      confidence: (json['confidence'] ?? '').toString(),
    );
  }
}

class AgentUsageService {
  const AgentUsageService();

  Future<AgentUsageReport> scan({
    required AgentService agentService,
    String agentId = '',
    int observeMs = 0,
  }) async {
    final args = ['agent-usage', 'scan'];
    if (agentId.trim().isNotEmpty) {
      args.addAll(['--agent', agentId.trim()]);
    }
    if (observeMs > 0) {
      args.addAll(['--observe-ms', observeMs.toString()]);
    }
    final output = await agentService.runCli(args);
    return AgentUsageReport.fromJson(output);
  }

  Future<List<AgentUsageReport>> reports({
    required AgentService agentService,
    String agentId = '',
    int limit = 10,
  }) async {
    final args = ['agent-usage', 'report', '--limit', limit.toString()];
    if (agentId.trim().isNotEmpty) {
      args.addAll(['--agent', agentId.trim()]);
    }
    final output = await agentService.runCli(args);
    if (output['reports'] is! List) {
      return const [];
    }
    return (output['reports'] as List)
        .whereType<Map<String, dynamic>>()
        .map(AgentUsageReport.fromJson)
        .toList();
  }
}

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
