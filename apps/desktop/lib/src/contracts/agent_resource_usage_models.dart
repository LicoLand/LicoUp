int _mapInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _mapIntOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value.toString());
}

Map<String, dynamic> _mapOf(Object? value) {
  return value is Map<String, dynamic> ? value : const {};
}

/// One matched process with sampled resource counters.
final class AgentResourceProcess {
  const AgentResourceProcess({
    required this.pid,
    required this.name,
    required this.rssBytes,
    this.diskReadBytes,
    this.diskWriteBytes,
  });

  factory AgentResourceProcess.fromJson(Object? raw) {
    final map = _mapOf(raw);
    return AgentResourceProcess(
      pid: _mapInt(map['pid']),
      name: (map['name'] ?? '').toString(),
      rssBytes: _mapInt(map['rssBytes']),
      diskReadBytes: _mapIntOrNull(map['diskReadBytes']),
      diskWriteBytes: _mapIntOrNull(map['diskWriteBytes']),
    );
  }

  final int pid;
  final String name;
  final int rssBytes;
  final int? diskReadBytes;
  final int? diskWriteBytes;
}

/// One agent's aggregated resource usage at one scan instant.
final class AgentResourceUsageAgent {
  const AgentResourceUsageAgent({
    required this.target,
    required this.label,
    required this.running,
    required this.processes,
    required this.totalRssBytes,
    this.totalDiskReadBytes,
    this.totalDiskWriteBytes,
  });

  factory AgentResourceUsageAgent.fromJson(Object? raw) {
    final map = _mapOf(raw);
    final processes = (map['processes'] as List? ?? const [])
        .map(AgentResourceProcess.fromJson)
        .toList(growable: false);
    return AgentResourceUsageAgent(
      target: (map['target'] ?? '').toString(),
      label: (map['label'] ?? '').toString(),
      running: map['running'] == true,
      processes: processes,
      totalRssBytes: _mapInt(map['totalRssBytes']),
      totalDiskReadBytes: _mapIntOrNull(map['totalDiskReadBytes']),
      totalDiskWriteBytes: _mapIntOrNull(map['totalDiskWriteBytes']),
    );
  }

  final String target;
  final String label;
  final bool running;
  final List<AgentResourceProcess> processes;
  final int totalRssBytes;
  final int? totalDiskReadBytes;
  final int? totalDiskWriteBytes;
}

/// One `licoup resource-usage scan` report.
final class AgentResourceUsageReport {
  static const currentSchemaVersion = 1;

  const AgentResourceUsageReport({
    required this.schemaVersion,
    required this.generatedAt,
    required this.agents,
    required this.summary,
  });

  factory AgentResourceUsageReport.fromJson(Object? raw) {
    final map = _mapOf(raw);
    return AgentResourceUsageReport(
      schemaVersion: _mapInt(map['schemaVersion']),
      generatedAt: (map['generatedAt'] ?? '').toString(),
      agents: (map['agents'] as List? ?? const [])
          .map(AgentResourceUsageAgent.fromJson)
          .toList(growable: false),
      summary: _mapOf(map['summary']),
    );
  }

  final int schemaVersion;
  final String generatedAt;
  final List<AgentResourceUsageAgent> agents;
  final Map<String, dynamic> summary;
}
