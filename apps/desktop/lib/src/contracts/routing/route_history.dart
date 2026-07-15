import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';

/// One append-only route history entry for a task (REQ-MAR-004).
@immutable
class RouteHistoryEntry {
  const RouteHistoryEntry({
    required this.taskId,
    required this.timestamp,
    required this.sourceAgentId,
    required this.targetAgentId,
    required this.sourceSessionHandle,
    required this.targetSessionHandle,
    required this.decision,
    this.switchReason = '',
    this.distillationDigest = '',
    this.failed = false,
    this.failureDigest = '',
  });

  final String taskId;
  final String timestamp;
  final String sourceAgentId;
  final String targetAgentId;
  final String sourceSessionHandle;
  final String targetSessionHandle;
  final RouteDecisionRecord decision;
  final String switchReason;
  final String distillationDigest;
  final bool failed;
  final String failureDigest;

  Map<String, dynamic> toJson() {
    return {
      'taskId': taskId,
      'timestamp': timestamp,
      'sourceAgentId': sourceAgentId,
      'targetAgentId': targetAgentId,
      'sourceSessionHandle': sourceSessionHandle,
      'targetSessionHandle': targetSessionHandle,
      'distillationDigest': distillationDigest,
      'switchReason': switchReason,
      'failed': failed,
      'failureDigest': failureDigest,
      'decision': {
        'chosenAgentId': decision.chosenAgentId,
        'chosenAgentLabel': decision.chosenAgentLabel,
        'policyId': decision.policyId,
        'policyVersion': decision.policyVersion,
        'timestamp': decision.timestamp,
        'alternatives': [
          for (final c in decision.alternatives)
            {'agentId': c.agentId, 'priority': c.priority, 'reason': c.reason},
        ],
        'excluded': [
          for (final e in decision.excluded)
            {'agentId': e.agentId, 'reason': e.reason},
        ],
      },
    };
  }
}

/// Mutable per-task routing session state held by the coordinator.
@immutable
class TaskRouteSession {
  const TaskRouteSession({
    required this.taskId,
    required this.currentAgentId,
    required this.currentSessionId,
    required this.currentSessionHandle,
    this.lastSwitchAt,
    this.streaming = false,
  });

  final String taskId;
  final String currentAgentId;
  final String currentSessionId;
  final String currentSessionHandle;
  final DateTime? lastSwitchAt;
  final bool streaming;

  TaskRouteSession copyWith({
    String? currentAgentId,
    String? currentSessionId,
    String? currentSessionHandle,
    DateTime? lastSwitchAt,
    bool? streaming,
    bool clearLastSwitchAt = false,
  }) {
    return TaskRouteSession(
      taskId: taskId,
      currentAgentId: currentAgentId ?? this.currentAgentId,
      currentSessionId: currentSessionId ?? this.currentSessionId,
      currentSessionHandle: currentSessionHandle ?? this.currentSessionHandle,
      lastSwitchAt: clearLastSwitchAt
          ? null
          : (lastSwitchAt ?? this.lastSwitchAt),
      streaming: streaming ?? this.streaming,
    );
  }
}

/// Outcome of evaluating a mid-task switch at a message boundary.
sealed class TaskRouteSwitchResult {
  const TaskRouteSwitchResult();
}

class TaskRouteSwitchSkipped extends TaskRouteSwitchResult {
  const TaskRouteSwitchSkipped({required this.reason, required this.session});

  final String reason;
  final TaskRouteSession session;
}

class TaskRouteSwitchCompleted extends TaskRouteSwitchResult {
  const TaskRouteSwitchCompleted({
    required this.session,
    required this.entry,
    required this.decision,
    required this.package,
  });

  final TaskRouteSession session;
  final RouteHistoryEntry entry;
  final RouteDecisionRecord decision;
  final DistillationPackage package;
}

class TaskRouteSwitchFailed extends TaskRouteSwitchResult {
  const TaskRouteSwitchFailed({
    required this.reason,
    required this.session,
    required this.entry,
  });

  final String reason;
  final TaskRouteSession session;
  final RouteHistoryEntry entry;
}
