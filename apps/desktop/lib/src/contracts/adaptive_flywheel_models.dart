import 'package:licoup/src/contracts/generated/strategy.g.dart'
    show
        StrategyFailureCode,
        StrategyWorkflowDiagnostic,
        StrategyWorkflowDiagnosticStage,
        strategyWorkflowMaxDiagnostics;

typedef AdaptiveFlywheelDiagnostic = StrategyWorkflowDiagnostic;

final class AdaptiveFlywheelFailure implements Exception {
  const AdaptiveFlywheelFailure({
    required this.code,
    required this.recovery,
    this.retryable = false,
    this.stage = '',
    this.diagnostics = const [],
  });

  factory AdaptiveFlywheelFailure.fromJson(Map<String, dynamic> json) {
    final failureCode = StrategyFailureCode.fromWire(json['code']);
    return AdaptiveFlywheelFailure(
      code: failureCode == StrategyFailureCode.unknown
          ? 'strategy_operation_failed'
          : failureCode.wireName,
      recovery: json['recovery'] is String ? json['recovery'] as String : '',
      retryable: json['retryable'] == true,
      stage: json['stage'] is String ? json['stage'] as String : '',
      diagnostics: _maps(json['diagnostics'])
          .take(strategyWorkflowMaxDiagnostics)
          .map(StrategyWorkflowDiagnostic.fromJson)
          .toList(growable: false),
    );
  }

  final String code;
  final String recovery;
  final bool retryable;
  final String stage;
  final List<AdaptiveFlywheelDiagnostic> diagnostics;

  @override
  String toString() {
    if (diagnostics.isEmpty) return recovery.isEmpty ? code : recovery;
    final details = diagnostics
        .map((diagnostic) {
          final location = diagnostic.path.isEmpty
              ? ''
              : ' @ ${diagnostic.path}';
          final stage =
              diagnostic.stage == StrategyWorkflowDiagnosticStage.unknown
              ? ''
              : ' [${diagnostic.stage.wireName}]';
          final facts = <String>[
            if (diagnostic.membershipId.isNotEmpty)
              'membership=${diagnostic.membershipId}',
            if (diagnostic.actual != null) 'actual=${diagnostic.actual}',
            if (diagnostic.limit != null) 'limit=${diagnostic.limit}',
            if (diagnostic.line != null) 'line=${diagnostic.line}',
            if (diagnostic.column != null) 'column=${diagnostic.column}',
          ];
          final suffix = facts.isEmpty ? '' : ' (${facts.join(', ')})';
          return '${diagnostic.code.wireName}$stage$location$suffix';
        })
        .join('\n');
    final summary = recovery.isEmpty ? code : '$code: $recovery';
    return '$summary\n$details';
  }
}

final class AdaptiveFlywheelDefinition {
  const AdaptiveFlywheelDefinition({
    required this.id,
    required this.name,
    required this.version,
    required this.revisionDigest,
    required this.semanticsDigest,
    this.authorized = false,
  });

  factory AdaptiveFlywheelDefinition.fromJson(Map<String, dynamic> json) =>
      AdaptiveFlywheelDefinition(
        id: (json['definitionId'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        version: (json['version'] ?? '').toString(),
        revisionDigest: (json['revisionDigest'] ?? '').toString(),
        semanticsDigest: (json['semanticsDigest'] ?? '').toString(),
        authorized: json['authorized'] == true,
      );

  final String id;
  final String name;
  final String version;
  final String revisionDigest;
  final String semanticsDigest;
  final bool authorized;
}

final class AdaptiveFlywheelSlot {
  const AdaptiveFlywheelSlot({
    required this.id,
    required this.kind,
    required this.label,
    required this.required,
    this.entry = false,
  });

  factory AdaptiveFlywheelSlot.fromJson(Map<String, dynamic> json) =>
      AdaptiveFlywheelSlot(
        id: (json['id'] ?? '').toString(),
        kind: (json['kind'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
        required: json['required'] != false,
        entry: json['entry'] == true,
      );

  final String id;
  final String kind;
  final String label;
  final bool required;
  final bool entry;
}

final class AdaptiveFlywheelBinding {
  const AdaptiveFlywheelBinding({
    required this.slotId,
    required this.valueId,
    this.ordinal = 0,
    this.model = '',
    this.reasoningEffort = '',
    this.revision = 0,
  });

  factory AdaptiveFlywheelBinding.fromJson(Map<String, dynamic> json) =>
      AdaptiveFlywheelBinding(
        slotId: (json['slotId'] ?? '').toString(),
        ordinal: (json['ordinal'] as num?)?.toInt() ?? 0,
        valueId: (json['valueId'] ?? '').toString(),
        model: (json['model'] ?? '').toString(),
        reasoningEffort: (json['reasoningEffort'] ?? '').toString(),
        revision: (json['revision'] as num?)?.toInt() ?? 0,
      );

  final String slotId;
  final int ordinal;
  final String valueId;
  final String model;
  final String reasoningEffort;
  final int revision;
}

final class AdaptiveFlywheelGraphState {
  const AdaptiveFlywheelGraphState({
    required this.id,
    required this.kind,
    required this.label,
  });

  factory AdaptiveFlywheelGraphState.fromJson(Map<String, dynamic> json) =>
      AdaptiveFlywheelGraphState(
        id: (json['id'] ?? '').toString(),
        kind: (json['kind'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
      );

  final String id;
  final String kind;
  final String label;
}

final class AdaptiveFlywheelGraphEdge {
  const AdaptiveFlywheelGraphEdge({
    required this.from,
    required this.to,
    required this.event,
    this.guardLabel = '',
  });

  factory AdaptiveFlywheelGraphEdge.fromJson(Map<String, dynamic> json) =>
      AdaptiveFlywheelGraphEdge(
        from: (json['from'] ?? '').toString(),
        to: (json['to'] ?? '').toString(),
        event: (json['event'] ?? '').toString(),
        guardLabel: _guardLabel(json['guard']),
      );

  final String from;
  final String to;
  final String event;
  final String guardLabel;
}

String _guardLabel(Object? guard) {
  if (guard is! Map) return '';
  final path = (guard['path'] ?? '').toString().trim();
  if (path.isEmpty) return '';
  final segments = path.split('.').where((part) => part.isNotEmpty);
  final name = segments.isEmpty ? '' : segments.last;
  if (name.isEmpty) return '';
  final equals = guard['equals'];
  if (equals != null && equals.toString().isNotEmpty) {
    return '$name=$equals';
  }
  return name;
}

final class AdaptiveFlywheelInspection {
  const AdaptiveFlywheelInspection({
    required this.status,
    required this.currentStates,
    required this.neighborStates,
    required this.allowedOperations,
    required this.bindings,
    required this.slots,
    required this.states,
    required this.edges,
    required this.initialState,
    required this.diagnosticCode,
  });

  factory AdaptiveFlywheelInspection.fromJson(Map<String, dynamic> json) {
    final projection = _stringMap(json['projection']);
    final workflow = _stringMap(json['workflow']);
    return AdaptiveFlywheelInspection(
      status: (projection['status'] ?? 'pending').toString(),
      currentStates: _strings(projection['currentStates']),
      neighborStates: _strings(projection['neighborStates']),
      allowedOperations: _strings(projection['allowedOperations']),
      bindings: _bindingsBySlot(_maps(projection['bindings'])),
      slots: _maps(
        workflow['actorSlots'],
      ).map(AdaptiveFlywheelSlot.fromJson).toList(growable: false),
      states: _maps(
        workflow['states'],
      ).map(AdaptiveFlywheelGraphState.fromJson).toList(growable: false),
      edges: _maps(
        workflow['transitions'],
      ).map(AdaptiveFlywheelGraphEdge.fromJson).toList(growable: false),
      initialState: (workflow['initial'] ?? '').toString(),
      diagnosticCode: (_stringMap(projection['diagnostic'])['code'] ?? '')
          .toString(),
    );
  }

  final String status;
  final List<String> currentStates;
  final List<String> neighborStates;
  final List<String> allowedOperations;
  final Map<String, List<AdaptiveFlywheelBinding>> bindings;
  final List<AdaptiveFlywheelSlot> slots;
  final List<AdaptiveFlywheelGraphState> states;
  final List<AdaptiveFlywheelGraphEdge> edges;
  final String initialState;
  final String diagnosticCode;

  bool get authorized => allowedOperations.contains('strategy.run.start');

  AdaptiveFlywheelSlot? get entrySlot {
    for (final slot in slots) {
      if (slot.kind == 'actor' && slot.entry) return slot;
    }
    return null;
  }
}

Map<String, List<AdaptiveFlywheelBinding>> _bindingsBySlot(
  List<Map<String, dynamic>> rows,
) {
  final grouped = <String, List<AdaptiveFlywheelBinding>>{};
  for (final row in rows) {
    final binding = AdaptiveFlywheelBinding.fromJson(row);
    if (binding.slotId.isEmpty) continue;
    grouped
        .putIfAbsent(binding.slotId, () => <AdaptiveFlywheelBinding>[])
        .add(binding);
  }
  for (final chain in grouped.values) {
    chain.sort((a, b) => a.ordinal.compareTo(b.ordinal));
  }
  return grouped;
}

Map<String, dynamic> adaptiveFlywheelStringMap(Object? value) =>
    _stringMap(value);

List<Map<String, dynamic>> adaptiveFlywheelMaps(Object? value) => _maps(value);

Map<String, dynamic> _stringMap(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : const <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.map(_stringMap).toList(growable: false)
    : const <Map<String, dynamic>>[];

List<String> _strings(Object? value) => value is List
    ? value.map((item) => item.toString()).toList(growable: false)
    : const <String>[];
