import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

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
  bool get hasDecisions => decisions.any((d) => d.trim().isNotEmpty);
  bool get hasConstraints => constraints.any((c) => c.trim().isNotEmpty);
  bool get hasOpenItems => openItems.any((i) => i.trim().isNotEmpty);

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
    this.message = '',
  });

  final bool passed;
  final List<String> checkedSections;
  final List<String> missingSections;
  final String message;

  Map<String, dynamic> toJson() {
    return {
      'passed': passed,
      'checkedSections': checkedSections,
      'missingSections': missingSections,
      'message': message,
    };
  }
}

sealed class DistillationResult {
  const DistillationResult();
}

class DistillationSuccess extends DistillationResult {
  const DistillationSuccess({
    required this.package,
    required this.fidelity,
    this.usage = const DistillationUsage(),
    this.distillerAgentId = '',
    this.audit = const DistillationAuditRecord.empty(),
  });

  final DistillationPackage package;
  final FidelityCheckResult fidelity;
  final DistillationUsage usage;
  final String distillerAgentId;
  final DistillationAuditRecord audit;
}

class DistillationFailure extends DistillationResult {
  const DistillationFailure({
    required this.reason,
    this.retriesExhausted = false,
    this.distillerUnavailable = false,
    this.usage = const DistillationUsage(),
    this.audit = const DistillationAuditRecord.empty(),
  });

  final String reason;
  final bool retriesExhausted;
  final bool distillerUnavailable;
  final DistillationUsage usage;
  final DistillationAuditRecord audit;
}

/// Token / call cost reported for distillation sends (V-003-G).
@immutable
class DistillationUsage {
  const DistillationUsage({
    this.dispatchCallCount = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
  });

  final int dispatchCallCount;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  DistillationUsage operator +(DistillationUsage other) {
    return DistillationUsage(
      dispatchCallCount: dispatchCallCount + other.dispatchCallCount,
      promptTokens: promptTokens + other.promptTokens,
      completionTokens: completionTokens + other.completionTokens,
      totalTokens: totalTokens + other.totalTokens,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dispatchCallCount': dispatchCallCount,
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'totalTokens': totalTokens,
    };
  }
}

/// Audit record: package + fidelity + source refs only — never raw source text.
@immutable
class DistillationAuditRecord {
  const DistillationAuditRecord({
    required this.sourceSessionId,
    required this.sourceAgentId,
    required this.distillerAgentId,
    required this.package,
    required this.fidelity,
    required this.usage,
    required this.createdAt,
  });

  const DistillationAuditRecord.empty()
    : sourceSessionId = '',
      sourceAgentId = '',
      distillerAgentId = '',
      package = null,
      fidelity = null,
      usage = const DistillationUsage(),
      createdAt = '';

  final String sourceSessionId;
  final String sourceAgentId;
  final String distillerAgentId;
  final DistillationPackage? package;
  final FidelityCheckResult? fidelity;
  final DistillationUsage usage;
  final String createdAt;

  bool get isEmpty => sourceSessionId.isEmpty && package == null;

  Map<String, dynamic> toJson() {
    return {
      'sourceSessionId': sourceSessionId,
      'sourceAgentId': sourceAgentId,
      'distillerAgentId': distillerAgentId,
      if (package != null) 'package': package!.toJson(),
      if (fidelity != null) 'fidelity': fidelity!.toJson(),
      'usage': usage.toJson(),
      'createdAt': createdAt,
    };
  }
}

/// One message (or summary line) supplied as distillation input.
@immutable
class DistillationConversationTurn {
  const DistillationConversationTurn({
    required this.role,
    required this.text,
  });

  final String role;
  final String text;
}

/// Content classes detected in the source conversation for fidelity gating.
@immutable
class DistillationSourceContentClasses {
  const DistillationSourceContentClasses({
    this.hasObjective = false,
    this.hasCurrentState = false,
    this.hasDecisions = false,
    this.hasConstraints = false,
    this.hasOpenItems = false,
  });

  final bool hasObjective;
  final bool hasCurrentState;
  final bool hasDecisions;
  final bool hasConstraints;
  final bool hasOpenItems;

  factory DistillationSourceContentClasses.detect(
    List<DistillationConversationTurn> turns,
  ) {
    final joined = turns.map((t) => t.text).join('\n').toLowerCase();
    return DistillationSourceContentClasses(
      hasObjective:
          joined.contains('goal:') ||
          joined.contains('objective:') ||
          joined.contains('goals:'),
      hasCurrentState:
          joined.contains('current state:') ||
          joined.contains('status:') ||
          joined.contains('progress:'),
      hasDecisions:
          joined.contains('decision:') ||
          joined.contains('decided:') ||
          joined.contains('we chose'),
      hasConstraints:
          joined.contains('constraint:') ||
          joined.contains('must not') ||
          joined.contains('must:'),
      hasOpenItems:
          joined.contains('open:') ||
          joined.contains('todo:') ||
          joined.contains('remaining:'),
    );
  }
}

@immutable
class DistillationRequest {
  const DistillationRequest({
    required this.sourceSessionId,
    required this.sourceAgentId,
    required this.turns,
    this.targetAgentId = '',
    this.distillerSessionId = '',
    this.isDistillerReady,
    this.now,
  });

  final String sourceSessionId;
  final String sourceAgentId;
  final List<DistillationConversationTurn> turns;
  final String targetAgentId;
  final String distillerSessionId;

  /// Readiness probe for a candidate distiller agent id.
  final bool Function(String agentId)? isDistillerReady;

  /// Clock injection for deterministic tests.
  final DateTime Function()? now;

  DistillationSourceContentClasses get contentClasses =>
      DistillationSourceContentClasses.detect(turns);
}

/// Request issued through the injected dispatch-lane callback.
@immutable
class DistillationLaneRequest {
  const DistillationLaneRequest({
    required this.agentId,
    required this.text,
    required this.sessionId,
    this.corrective = false,
  });

  final String agentId;
  final String text;
  final String sessionId;
  final bool corrective;
}

/// Response from the injected dispatch-lane callback.
@immutable
class DistillationLaneResponse {
  const DistillationLaneResponse({
    required this.ok,
    this.text = '',
    this.errorMessage = '',
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  final bool ok;
  final String text;
  final String errorMessage;
  final int promptTokens;
  final int completionTokens;

  int get totalTokens => promptTokens + completionTokens;

  DistillationUsage get usage => DistillationUsage(
    dispatchCallCount: 1,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    totalTokens: totalTokens,
  );
}

/// Callback matching the parent dispatch lane send path (Architecture.md).
typedef DispatchLaneSend =
    Future<DistillationLaneResponse> Function(DistillationLaneRequest request);

/// Distillation handoff orchestrator.
abstract class DistillationBroker {
  Future<DistillationResult> distill({
    required DistillationRequest request,
    required RoutingPolicyDocument policy,
    required DispatchLaneSend send,
  });
}

/// Structural fidelity check against the policy contract and source classes.
FidelityCheckResult checkDistillationFidelity({
  required DistillationPackage package,
  required RoutingFidelityContract contract,
  required DistillationSourceContentClasses sourceClasses,
}) {
  final checked = <String>[];
  final missing = <String>[];

  for (final section in contract.requiredSections) {
    checked.add(section);
    final requiredBySource = switch (section) {
      'objective' => sourceClasses.hasObjective,
      'currentState' => sourceClasses.hasCurrentState,
      'decisions' => sourceClasses.hasDecisions,
      'constraints' => sourceClasses.hasConstraints,
      'openItems' => sourceClasses.hasOpenItems,
      _ => true,
    };
    if (!requiredBySource) {
      continue;
    }
    final present = switch (section) {
      'objective' => package.hasObjective,
      'currentState' => package.hasCurrentState,
      'decisions' => package.hasDecisions,
      'constraints' => package.hasConstraints,
      'openItems' => package.hasOpenItems,
      _ => _sectionNonEmpty(package, section),
    };
    if (!present) {
      missing.add(section);
    }
  }

  if (package.estimatedLength > contract.maxPackageLength) {
    return FidelityCheckResult(
      passed: false,
      checkedSections: List.unmodifiable(checked),
      missingSections: List.unmodifiable(missing),
      message:
          'Package length ${package.estimatedLength} exceeds maxPackageLength ${contract.maxPackageLength}.',
    );
  }

  if (missing.isNotEmpty) {
    return FidelityCheckResult(
      passed: false,
      checkedSections: List.unmodifiable(checked),
      missingSections: List.unmodifiable(missing),
      message: 'Missing required sections: ${missing.join(', ')}.',
    );
  }

  return FidelityCheckResult(
    passed: true,
    checkedSections: List.unmodifiable(checked),
    missingSections: const [],
    message: 'Fidelity check passed.',
  );
}

/// Parse a distiller agent response into a [DistillationPackage].
DistillationPackage? parseDistillationPackageResponse(
  String response, {
  required String sourceSessionId,
  required String sourceAgentId,
  required String createdAt,
}) {
  final trimmed = response.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  // Prefer a fenced JSON block when present.
  final fence = RegExp(
    r'```(?:json)?\s*(\{[\s\S]*?\})\s*```',
    multiLine: true,
  ).firstMatch(trimmed);
  final candidate = fence?.group(1) ?? _extractJsonObject(trimmed);
  if (candidate == null) {
    return null;
  }

  try {
    final decoded = jsonDecode(candidate);
    if (decoded is! Map) {
      return null;
    }
    final map = Map<String, dynamic>.from(decoded);
    return DistillationPackage(
      objective: _string(map['objective']),
      currentState: _string(map['currentState']),
      decisions: _stringList(map['decisions']),
      constraints: _stringList(map['constraints']),
      openItems: _stringList(map['openItems']),
      sourceSessionId: _string(
        map['sourceSessionId'],
        fallback: sourceSessionId,
      ),
      sourceAgentId: _string(map['sourceAgentId'], fallback: sourceAgentId),
      createdAt: _string(map['createdAt'], fallback: createdAt),
    );
  } on FormatException {
    return null;
  }
}

bool _sectionNonEmpty(DistillationPackage package, String section) {
  final json = package.toJson()[section];
  if (json is String) {
    return json.trim().isNotEmpty;
  }
  if (json is List) {
    return json.any((e) => e.toString().trim().isNotEmpty);
  }
  return false;
}

String? _extractJsonObject(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) {
    return null;
  }
  return text.substring(start, end + 1);
}

String _string(Object? value, {String fallback = ''}) {
  if (value == null) {
    return fallback;
  }
  final text = value.toString().trim();
  return text.isEmpty ? fallback : text;
}

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
