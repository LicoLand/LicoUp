import 'package:flutter/foundation.dart';

@immutable
class DistillationPackage {
  const DistillationPackage({
    required this.objective,
    required this.currentState,
    required this.decisions,
    required this.constraints,
    required this.openItems,
    required this.sourceSessionId,
    required this.sourceAgentId,
    required this.createdAt,
  });

  final String objective;
  final String currentState;
  final List<String> decisions;
  final List<String> constraints;
  final List<String> openItems;
  final String sourceSessionId;
  final String sourceAgentId;
  final String createdAt;

  bool get hasObjective => objective.trim().isNotEmpty;
  bool get hasCurrentState => currentState.trim().isNotEmpty;
  bool get hasDecisions => decisions.any((item) => item.trim().isNotEmpty);
  bool get hasConstraints => constraints.any((item) => item.trim().isNotEmpty);
  bool get hasOpenItems => openItems.any((item) => item.trim().isNotEmpty);

  int get estimatedLength {
    final buffer = StringBuffer()
      ..write(objective)
      ..write(currentState)
      ..writeAll(decisions)
      ..writeAll(constraints)
      ..writeAll(openItems);
    return buffer.length;
  }

  Map<String, dynamic> toJson() {
    return {
      'objective': objective,
      'currentState': currentState,
      'decisions': decisions,
      'constraints': constraints,
      'openItems': openItems,
      'sourceSessionId': sourceSessionId,
      'sourceAgentId': sourceAgentId,
      'createdAt': createdAt,
    };
  }

  factory DistillationPackage.fromJson(Map<String, dynamic> json) {
    return DistillationPackage(
      objective: _string(json['objective']),
      currentState: _string(json['currentState']),
      decisions: _stringList(json['decisions']),
      constraints: _stringList(json['constraints']),
      openItems: _stringList(json['openItems']),
      sourceSessionId: _string(json['sourceSessionId']),
      sourceAgentId: _string(json['sourceAgentId']),
      createdAt: _string(json['createdAt']),
    );
  }
}

@immutable
class FidelityCheckResult {
  const FidelityCheckResult({
    required this.passed,
    required this.checkedSections,
    required this.missingSections,
    this.groundedSections = const [],
    this.uncoveredSections = const [],
    this.message = '',
  });

  final bool passed;
  final List<String> checkedSections;
  final List<String> missingSections;
  final List<String> groundedSections;
  final List<String> uncoveredSections;
  final String message;

  Map<String, dynamic> toJson() {
    return {
      'passed': passed,
      'checkedSections': checkedSections,
      'missingSections': missingSections,
      'groundedSections': groundedSections,
      'uncoveredSections': uncoveredSections,
      'message': message,
    };
  }
}

String _string(Object? value) => value?.toString().trim() ?? '';

List<String> _stringList(Object? value) {
  if (value is! List) {
    if (value is String && value.trim().isNotEmpty) {
      return [value.trim()];
    }
    return const [];
  }
  return [
    for (final item in value)
      if (item.toString().trim().isNotEmpty) item.toString().trim(),
  ];
}
