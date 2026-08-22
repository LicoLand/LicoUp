Map<String, dynamic> _map(Object? value) {
  return value is Map<String, dynamic>
      ? Map<String, dynamic>.from(value)
      : const {};
}

/// Current numeric-only Adaptive Flywheel Graph usage projection. A missing
/// projection is valid; any present projection must match this exact schema.
const String agentUsageWorkflowReportSchema = 'licoup.graph-usage-report.v2';
const int agentUsageWorkflowLedgerSchemaVersion = 2;
const String agentUsageWorkflowResultKind = 'graph-run-usage';

String _safeCode(Object? value, {int maxLength = 256}) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.length > maxLength) {
    return '';
  }
  // Public workflow codes are bounded identifiers.  Reject locations and
  // control text at the model boundary so a future widget cannot accidentally
  // turn a private native binding into visible content.
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:@+\-]{0,255}$').hasMatch(text)) {
    return '';
  }
  return text;
}

String _safeLabel(Object? value, {int maxLength = 256}) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.length > maxLength) {
    return '';
  }
  if (text.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    return '';
  }
  return text;
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

int _nonNegativeInt(Object? value) => _int(value).clamp(0, 0x7fffffff).toInt();

Object? _first(Map<String, dynamic> value, List<String> keys) {
  for (final key in keys) {
    if (value.containsKey(key)) return value[key];
  }
  return null;
}

/// Numeric components shared by agent, workflow, and dispatch projections.
/// Workflow values never retain provider payloads, labels, or native paths.
class AgentUsageTokenTotals {
  const AgentUsageTokenTotals({
    this.promptTokens = 0,
    this.cachedInputTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.exactCount = 0,
    this.estimatedCount = 0,
  });

  final int promptTokens;
  final int cachedInputTokens;
  final int completionTokens;
  final int totalTokens;
  final int exactCount;
  final int estimatedCount;

  int get recordCount => exactCount + estimatedCount;
  int get exactRecords => exactCount;
  int get estimatedRecords => estimatedCount;
  double get coverage => exactCoverage;

  double get exactCoverage {
    if (recordCount <= 0) return 0;
    return (exactCount / recordCount).clamp(0.0, 1.0).toDouble();
  }

  AgentUsageTokenTotals operator +(AgentUsageTokenTotals other) {
    final prompt = promptTokens + other.promptTokens;
    final cached = (cachedInputTokens + other.cachedInputTokens)
        .clamp(0, prompt)
        .toInt();
    final completion = completionTokens + other.completionTokens;
    return AgentUsageTokenTotals(
      promptTokens: prompt,
      cachedInputTokens: cached,
      completionTokens: completion,
      totalTokens: prompt + completion,
      exactCount: exactCount + other.exactCount,
      estimatedCount: estimatedCount + other.estimatedCount,
    );
  }

  AgentUsageTokenTotals copyWith({
    int? promptTokens,
    int? cachedInputTokens,
    int? completionTokens,
    int? totalTokens,
    int? exactCount,
    int? estimatedCount,
  }) {
    final prompt = (promptTokens ?? this.promptTokens).clamp(0, 0x7fffffff);
    final completion = (completionTokens ?? this.completionTokens).clamp(
      0,
      0x7fffffff,
    );
    return AgentUsageTokenTotals(
      promptTokens: prompt.toInt(),
      cachedInputTokens: (cachedInputTokens ?? this.cachedInputTokens)
          .clamp(0, prompt)
          .toInt(),
      completionTokens: completion.toInt(),
      totalTokens: totalTokens == null
          ? prompt.toInt() + completion.toInt()
          : totalTokens.clamp(0, 0x7fffffff).toInt(),
      exactCount: (exactCount ?? this.exactCount).clamp(0, 0x7fffffff).toInt(),
      estimatedCount: (estimatedCount ?? this.estimatedCount)
          .clamp(0, 0x7fffffff)
          .toInt(),
    );
  }

  factory AgentUsageTokenTotals.fromJson(
    Object? raw, {
    String? accuracy,
    bool countRecordWhenCoverageMissing = false,
  }) {
    final value = _map(raw);
    final prompt = _nonNegativeInt(
      _first(value, const ['promptTokens', 'prompt_tokens']),
    );
    final cached = _nonNegativeInt(
      _first(value, const ['cachedInputTokens', 'cached_input_tokens']),
    ).clamp(0, prompt).toInt();
    final completion = _nonNegativeInt(
      _first(value, const ['completionTokens', 'completion_tokens']),
    );
    final totalValue = _first(value, const ['totalTokens', 'total_tokens']);
    final total = totalValue == null
        ? prompt + completion
        : _nonNegativeInt(totalValue);
    var exact = _nonNegativeInt(
      _first(value, const ['exactCount', 'exactRecords', 'exact_records']),
    );
    var estimated = _nonNegativeInt(
      _first(value, const [
        'estimatedCount',
        'estimatedRecords',
        'estimated_records',
      ]),
    );
    if (exact == 0 && estimated == 0 && countRecordWhenCoverageMissing) {
      final normalized = (accuracy ?? '').trim().toLowerCase();
      if (normalized == 'estimated') {
        estimated = 1;
      } else if (normalized == 'exact' || prompt > 0 || completion > 0) {
        exact = 1;
      }
    }
    return AgentUsageTokenTotals(
      promptTokens: prompt,
      cachedInputTokens: cached,
      completionTokens: completion,
      totalTokens: total,
      exactCount: exact,
      estimatedCount: estimated,
    ).copyWith();
  }

  Map<String, dynamic> toJson() => {
    'promptTokens': promptTokens,
    'cachedInputTokens': cachedInputTokens,
    'completionTokens': completionTokens,
    'totalTokens': totalTokens,
    'exactCount': exactCount,
    'estimatedCount': estimatedCount,
    'coverage': exactCoverage,
  };
}

/// One numeric-only durable command from a topology-neutral Graph run.
class AgentUsageWorkflowCommand {
  const AgentUsageWorkflowCommand({
    required this.commandId,
    required this.stateId,
    required this.membershipId,
    required this.kind,
    required this.status,
    required this.attempt,
    required this.agentId,
    required this.model,
    required this.accuracy,
    required this.usage,
  });

  final String commandId;
  final String stateId;
  final String? membershipId;
  final String kind;
  final String status;
  final int attempt;
  final String? agentId;
  final String? model;
  final String accuracy;
  final AgentUsageTokenTotals usage;

  factory AgentUsageWorkflowCommand.fromJson(Map<String, dynamic> json) {
    final accuracy = _safeCode(json['accuracy']).toLowerCase();
    return AgentUsageWorkflowCommand(
      commandId: _safeCode(json['commandId']),
      stateId: _safeCode(json['stateId']),
      membershipId: _optionalSafeCode(json['membershipId']),
      kind: _safeCode(json['kind']),
      status: _safeCode(json['status']),
      attempt: _nonNegativeInt(json['attempt']),
      agentId: _optionalSafeCode(json['agentId']),
      model: _optionalSafeLabel(json['model']),
      accuracy: switch (accuracy) {
        'estimated' => 'estimated',
        'exact' => 'exact',
        _ => 'unknown',
      },
      usage: AgentUsageTokenTotals.fromJson(
        json['usage'],
        accuracy: accuracy,
        countRecordWhenCoverageMissing:
            accuracy == 'exact' || accuracy == 'estimated',
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'commandId': commandId,
    'stateId': stateId,
    if (membershipId != null) 'membershipId': membershipId,
    'kind': kind,
    'status': status,
    'attempt': attempt,
    if (agentId != null) 'agentId': agentId,
    if (model != null) 'model': model,
    'accuracy': accuracy,
    'usage': usage.toJson(),
  };
}

String? _optionalSafeCode(Object? value) {
  final code = _safeCode(value);
  return code.isEmpty ? null : code;
}

String? _optionalSafeLabel(Object? value) {
  final label = _safeLabel(value);
  return label.isEmpty ? null : label;
}

/// One immutable Graph run projection. Commands are flat durable identities;
/// the usage surface does not infer Plan, Task, Role, dispatch or topology.
class AgentUsageWorkflow {
  const AgentUsageWorkflow({
    required this.runId,
    required this.revisionDigest,
    required this.conversationId,
    required this.assistantMembershipId,
    required this.status,
    required this.totals,
    required this.commands,
  });

  final String runId;
  final String revisionDigest;
  final String? conversationId;
  final String? assistantMembershipId;
  final String status;
  final AgentUsageTokenTotals totals;
  final List<AgentUsageWorkflowCommand> commands;

  int get totalTokens => totals.totalTokens;
  int get promptTokens => totals.promptTokens;
  int get cachedInputTokens => totals.cachedInputTokens;
  int get completionTokens => totals.completionTokens;
  int get exactCount => totals.exactCount;
  int get estimatedCount => totals.estimatedCount;
  double get exactCoverage => totals.exactCoverage;

  factory AgentUsageWorkflow.fromJson(Map<String, dynamic> json) {
    final commands = _parseWorkflowCommands(json['commands']);
    final derived = commands.fold<AgentUsageTokenTotals>(
      const AgentUsageTokenTotals(),
      (total, command) => total + command.usage,
    );
    final reported = AgentUsageTokenTotals.fromJson(json['totals']);
    return AgentUsageWorkflow(
      runId: _safeCode(json['runId']),
      revisionDigest: _safeCode(json['revisionDigest']),
      conversationId: _optionalSafeCode(json['conversationId']),
      assistantMembershipId: _optionalSafeCode(json['assistantMembershipId']),
      status: _safeCode(json['status']),
      totals: _totalsWithDerivedCoverage(reported, derived),
      commands: commands,
    );
  }

  Map<String, dynamic> toJson() => {
    'runId': runId,
    'revisionDigest': revisionDigest,
    if (conversationId != null) 'conversationId': conversationId,
    if (assistantMembershipId != null)
      'assistantMembershipId': assistantMembershipId,
    'status': status,
    'totals': totals.toJson(),
    'commands': [for (final command in commands) command.toJson()],
  };
}

List<AgentUsageWorkflowCommand> _parseWorkflowCommands(Object? value) {
  if (value is! List) return const [];
  final commands = <AgentUsageWorkflowCommand>[];
  for (final item in value) {
    if (item is! Map) continue;
    final command = AgentUsageWorkflowCommand.fromJson(
      Map<String, dynamic>.from(item),
    );
    if (command.commandId.isEmpty ||
        command.stateId.isEmpty ||
        command.kind.isEmpty ||
        command.status.isEmpty) {
      continue;
    }
    commands.add(command);
  }
  return List.unmodifiable(commands);
}

AgentUsageTokenTotals _totalsWithDerivedCoverage(
  AgentUsageTokenTotals reported,
  AgentUsageTokenTotals derived,
) {
  final hasReportedNumbers =
      reported.promptTokens > 0 ||
      reported.cachedInputTokens > 0 ||
      reported.completionTokens > 0 ||
      reported.totalTokens > 0;
  final base = hasReportedNumbers ? reported : derived;
  final hasReportedCoverage =
      reported.exactCount > 0 || reported.estimatedCount > 0;
  return base.copyWith(
    exactCount: hasReportedCoverage ? reported.exactCount : derived.exactCount,
    estimatedCount: hasReportedCoverage
        ? reported.estimatedCount
        : derived.estimatedCount,
  );
}

class _AgentUsageWorkflowEnvelope {
  const _AgentUsageWorkflowEnvelope({
    required this.workflows,
    required this.summary,
  });

  final List<AgentUsageWorkflow> workflows;
  final AgentUsageTokenTotals summary;
}

_AgentUsageWorkflowEnvelope _parseWorkflowEnvelope(Map<String, dynamic> json) {
  if (!json.containsKey('workflow')) {
    return const _AgentUsageWorkflowEnvelope(
      workflows: [],
      summary: AgentUsageTokenTotals(),
    );
  }
  final nested = json['workflow'];
  if (nested is! Map) {
    throw const FormatException('Invalid workflow usage envelope.');
  }
  final envelope = Map<String, dynamic>.from(nested);
  if (envelope['schemaVersion'] != agentUsageWorkflowReportSchema ||
      envelope['ledgerSchemaVersion'] !=
          agentUsageWorkflowLedgerSchemaVersion ||
      envelope['resultKind'] != agentUsageWorkflowResultKind) {
    throw const FormatException('Unsupported workflow usage report schema.');
  }
  final workflows = _parseWorkflowCollection(envelope['runs']);
  final summary = AgentUsageTokenTotals.fromJson(envelope['summary']);
  final derived = workflows.fold<AgentUsageTokenTotals>(
    const AgentUsageTokenTotals(),
    (total, workflow) => total + workflow.totals,
  );
  return _AgentUsageWorkflowEnvelope(
    workflows: workflows,
    summary: _totalsWithDerivedCoverage(summary, derived),
  );
}

List<AgentUsageWorkflow> _parseWorkflowCollection(Object? value) {
  if (value is! List) {
    throw const FormatException('Invalid Graph usage run collection.');
  }
  final workflows = <AgentUsageWorkflow>[];
  for (final item in value) {
    if (item is! Map) continue;
    final workflow = AgentUsageWorkflow.fromJson(
      Map<String, dynamic>.from(item),
    );
    if (workflow.runId.isEmpty || workflow.revisionDigest.isEmpty) continue;
    workflows.add(workflow);
  }
  return List.unmodifiable(workflows);
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
    this.workflows = const [],
    this.workflowSummary = const AgentUsageTokenTotals(),
    this.mode = currentMode,
    this.tokenSourceMode = currentTokenSourceMode,
    this.window = const {},
  });

  final int schemaVersion;
  final String generatedAt;
  final Map<String, dynamic> summary;
  final List<AgentUsageAgentSummary> agents;
  final List<String> warnings;
  final List<AgentUsageWorkflow> workflows;
  final AgentUsageTokenTotals workflowSummary;
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
  int get workflowTotalTokens => workflowSummary.totalTokens;
  List<AgentUsageWorkflow> get workflowReports => workflows;
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
    List<AgentUsageWorkflow>? workflows,
    AgentUsageTokenTotals? workflowSummary,
    Map<String, dynamic>? window,
  }) {
    return AgentUsageReport(
      schemaVersion: schemaVersion,
      generatedAt: generatedAt ?? this.generatedAt,
      summary: summary ?? this.summary,
      agents: agents ?? this.agents,
      warnings: warnings ?? this.warnings,
      workflows: workflows ?? this.workflows,
      workflowSummary: workflowSummary ?? this.workflowSummary,
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
    final workflow = _parseWorkflowEnvelope(json);
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
      workflows: workflow.workflows,
      workflowSummary: workflow.summary,
      mode: (json['mode'] ?? '').toString(),
      tokenSourceMode: (json['tokenSourceMode'] ?? '').toString(),
      window: _map(json['window']),
    );
  }

  factory AgentUsageReport.fromAgents({
    required String generatedAt,
    required List<AgentUsageAgentSummary> agents,
    List<String> warnings = const [],
    List<AgentUsageWorkflow> workflows = const [],
  }) {
    final List<AgentUsageWorkflow> workflowList = List.unmodifiable(workflows);
    return AgentUsageReport(
      schemaVersion: currentSchemaVersion,
      generatedAt: generatedAt,
      summary: _summaryFromAgents(agents),
      agents: List.unmodifiable(agents),
      warnings: List.unmodifiable(warnings),
      workflows: workflowList,
      workflowSummary: workflowList.fold<AgentUsageTokenTotals>(
        const AgentUsageTokenTotals(),
        (total, workflow) => total + workflow.totals,
      ),
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
