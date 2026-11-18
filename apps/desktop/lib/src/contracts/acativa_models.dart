import 'package:licoup/src/contracts/generated/strategy.g.dart'
    show
        StrategyFailureCode,
        StrategyWorkflowDiagnostic,
        StrategyWorkflowDiagnosticStage,
        strategyWorkflowMaxDiagnostics;

typedef AcativaDiagnostic = StrategyWorkflowDiagnostic;

final class AcativaFailure implements Exception {
  const AcativaFailure({
    required this.code,
    required this.recovery,
    this.retryable = false,
    this.stage = '',
    this.diagnostics = const [],
  });

  factory AcativaFailure.fromJson(Map<String, dynamic> json) {
    final failureCode = StrategyFailureCode.fromWire(json['code']);
    return AcativaFailure(
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
  final List<AcativaDiagnostic> diagnostics;

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

final class AcativaDefinition {
  const AcativaDefinition({
    required this.id,
    required this.name,
    required this.version,
    required this.revisionDigest,
    required this.semanticsDigest,
    this.authorized = false,
  });

  factory AcativaDefinition.fromJson(Map<String, dynamic> json) =>
      AcativaDefinition(
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

final class AcativaSlot {
  const AcativaSlot({
    required this.id,
    required this.kind,
    required this.label,
    required this.required,
    this.entry = false,
  });

  factory AcativaSlot.fromJson(Map<String, dynamic> json) => AcativaSlot(
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

final class AcativaBinding {
  const AcativaBinding({
    required this.slotId,
    required this.valueId,
    this.ordinal = 0,
    this.model = '',
    this.reasoningEffort = '',
    this.revision = 0,
  });

  factory AcativaBinding.fromJson(Map<String, dynamic> json) => AcativaBinding(
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

final class AcativaGraphState {
  const AcativaGraphState({
    required this.id,
    required this.kind,
    required this.label,
  });

  factory AcativaGraphState.fromJson(Map<String, dynamic> json) =>
      AcativaGraphState(
        id: (json['id'] ?? '').toString(),
        kind: (json['kind'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
      );

  final String id;
  final String kind;
  final String label;
}

final class AcativaGraphEdge {
  const AcativaGraphEdge({
    required this.from,
    required this.to,
    required this.event,
    this.mode = 'flow',
    this.guardLabel = '',
  });

  factory AcativaGraphEdge.fromJson(Map<String, dynamic> json) =>
      AcativaGraphEdge(
        from: (json['from'] ?? '').toString(),
        to: (json['to'] ?? '').toString(),
        event: (json['event'] ?? '').toString(),
        mode: _transitionMode(json['mode']),
        guardLabel: _guardLabel(json['guard']),
      );

  final String from;
  final String to;
  final String event;
  final String mode;
  final String guardLabel;

  bool get callback => mode == 'callback';
}

String _transitionMode(Object? value) {
  final mode = (value ?? '').toString().trim();
  return mode == 'callback' ? 'callback' : 'flow';
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

final class AcativaInspection {
  const AcativaInspection({
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
    this.modelDisplayNames = const {},
  });

  factory AcativaInspection.fromJson(Map<String, dynamic> json) {
    final projection = _stringMap(json['projection']);
    final workflow = _stringMap(json['workflow']);
    return AcativaInspection(
      status: (projection['status'] ?? 'pending').toString(),
      currentStates: _strings(projection['currentStates']),
      neighborStates: _strings(projection['neighborStates']),
      allowedOperations: _strings(projection['allowedOperations']),
      bindings: _bindingsBySlot(_maps(projection['bindings'])),
      slots: _maps(
        workflow['actorSlots'],
      ).map(AcativaSlot.fromJson).toList(growable: false),
      states: _maps(
        workflow['states'],
      ).map(AcativaGraphState.fromJson).toList(growable: false),
      edges: _maps(
        workflow['transitions'],
      ).map(AcativaGraphEdge.fromJson).toList(growable: false),
      initialState: (workflow['initial'] ?? '').toString(),
      modelDisplayNames: Map.unmodifiable({
        for (final entry in _stringMap(json['modelDisplayNames']).entries)
          if (entry.value is String) entry.key: entry.value as String,
      }),
      diagnosticCode: (_stringMap(projection['diagnostic'])['code'] ?? '')
          .toString(),
    );
  }

  final String status;
  final List<String> currentStates;
  final List<String> neighborStates;
  final List<String> allowedOperations;
  final Map<String, List<AcativaBinding>> bindings;
  final List<AcativaSlot> slots;
  final List<AcativaGraphState> states;
  final List<AcativaGraphEdge> edges;
  final String initialState;
  final String diagnosticCode;
  final Map<String, String> modelDisplayNames;

  bool get authorized => allowedOperations.contains('strategy.run.start');

  AcativaSlot? get entrySlot {
    for (final slot in slots) {
      if (slot.kind == 'actor' && slot.entry) return slot;
    }
    return null;
  }
}

Map<String, List<AcativaBinding>> _bindingsBySlot(
  List<Map<String, dynamic>> rows,
) {
  final grouped = <String, List<AcativaBinding>>{};
  for (final row in rows) {
    final binding = AcativaBinding.fromJson(row);
    if (binding.slotId.isEmpty) continue;
    grouped.putIfAbsent(binding.slotId, () => <AcativaBinding>[]).add(binding);
  }
  for (final chain in grouped.values) {
    chain.sort((a, b) => a.ordinal.compareTo(b.ordinal));
  }
  return grouped;
}

Map<String, dynamic> acativaStringMap(Object? value) => _stringMap(value);

List<Map<String, dynamic>> acativaMaps(Object? value) => _maps(value);

Map<String, dynamic> _stringMap(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : const <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.map(_stringMap).toList(growable: false)
    : const <Map<String, dynamic>>[];

List<String> _strings(Object? value) => value is List
    ? value.map((item) => item.toString()).toList(growable: false)
    : const <String>[];
