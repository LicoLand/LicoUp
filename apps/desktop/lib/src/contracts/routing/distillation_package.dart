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
  bool get hasDecisions => decisions.any((d) => d.trim().isNotEmpty);
  bool get hasConstraints => constraints.any((c) => c.trim().isNotEmpty);
}

@immutable
class FidelityCheckResult {
  const FidelityCheckResult({
    required this.passed,
    required this.checkedSections,
    required this.missingSections,
    this.message = '',
  });

  final bool passed;
  final List<String> checkedSections;
  final List<String> missingSections;
  final String message;
}

sealed class DistillationResult {
  const DistillationResult();
}

class DistillationSuccess extends DistillationResult {
  const DistillationSuccess({
    required this.package,
    required this.fidelity,
  });

  final DistillationPackage package;
  final FidelityCheckResult fidelity;
}

class DistillationFailure extends DistillationResult {
  const DistillationFailure({
    required this.reason,
    this.retriesExhausted = false,
    this.distillerUnavailable = false,
  });

  final String reason;
  final bool retriesExhausted;
  final bool distillerUnavailable;
}
