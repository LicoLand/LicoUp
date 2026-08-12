import 'package:flutter/foundation.dart';

/// One restored Adaptive Flywheel editor capsule.
///
/// Strategy bindings persist one callable Agent, model, and reasoning effort
/// per actor slot. The id keeps the original capsule interaction stable while
/// the binding value remains owned by the native strategy store.
@immutable
final class DailyConversationAgentAssignment {
  const DailyConversationAgentAssignment({
    this.id = '',
    this.agentId = '',
    this.modelName = '',
    this.reasoningEffort = '',
    this.fast = false,
  });

  final String id;
  final String agentId;
  final String modelName;
  final String reasoningEffort;
  final bool fast;

  bool get configured => agentId.trim().isNotEmpty;

  DailyConversationAgentAssignment copyWith({
    String? id,
    String? agentId,
    String? modelName,
    String? reasoningEffort,
    bool? fast,
  }) {
    return DailyConversationAgentAssignment(
      id: id ?? this.id,
      agentId: agentId ?? this.agentId,
      modelName: modelName ?? this.modelName,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      fast: fast ?? this.fast,
    );
  }
}
