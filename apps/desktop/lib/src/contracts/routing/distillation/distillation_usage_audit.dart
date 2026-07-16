import 'package:flutter/foundation.dart';

import 'distillation_package_models.dart';

/// Token and call cost reported for distillation sends.
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

/// Package, fidelity, usage, and source references only; never source turns.
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
