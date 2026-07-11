import 'dart:async';

import 'package:flutter_client/src/application/features/routing/broker/distillation_broker.dart';
import 'package:flutter_client/src/application/features/routing/engine/route_planner.dart';
import 'package:flutter_client/src/backend/features/routing/services/route_history_store.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/route_history.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

/// Coordinates mid-task re-routing with distilled handoffs (REQ-MAR-004).
///
/// Owns no routing logic itself — sequences [RoutePlanner] and
/// [DistillationBroker] through their interfaces. Switch evaluation is
/// event-driven at message boundaries; in-flight streams are never interrupted.
class TaskRouteCoordinator {
  TaskRouteCoordinator({
    required RouteHistoryStore historyStore,
    RoutePlanner planner = const DefaultRoutePlanner(),
    DistillationBroker? broker,
    DateTime Function()? now,
  }) : _history = historyStore,
       _planner = planner,
       _broker = broker ?? DefaultDistillationBroker(),
       _now = now ?? DateTime.now;

  final RouteHistoryStore _history;
  final RoutePlanner _planner;
  final DistillationBroker _broker;
  final DateTime Function() _now;

  final Map<String, TaskRouteSession> _sessions = {};
  final Map<String, Completer<void>> _distillationLocks = {};
  RoutingPolicyDocument? _pendingPolicy;
  bool _policyQueued = false;

  RouteHistoryStore get history => _history;

  TaskRouteSession? sessionFor(String taskId) => _sessions[taskId];

  TaskRouteSession bindSession({
    required String taskId,
    required String agentId,
    required String sessionId,
  }) {
    final session = TaskRouteSession(
      taskId: taskId,
      currentAgentId: agentId,
      currentSessionId: sessionId,
    );
    _sessions[taskId] = session;
    return session;
  }

  /// Mark whether a task currently has an in-flight streamed message.
  void setStreaming(String taskId, bool streaming) {
    final current = _sessions[taskId];
    if (current == null) {
      return;
    }
    _sessions[taskId] = current.copyWith(streaming: streaming);
  }

  /// Queue a policy snapshot that arrived during distillation.
  void queuePolicy(RoutingPolicyDocument policy) {
    _pendingPolicy = policy;
    _policyQueued = true;
  }

  RoutingPolicyDocument? takeQueuedPolicy() {
    if (!_policyQueued) {
      return null;
    }
    _policyQueued = false;
    final policy = _pendingPolicy;
    _pendingPolicy = null;
    return policy;
  }

  bool get hasQueuedPolicy => _policyQueued;

  /// Evaluate a switch at a message boundary.
  ///
  /// Returns [TaskRouteSwitchSkipped] when the route is unchanged, streaming
  /// is active, or the minimum switch interval has not elapsed.
  Future<TaskRouteSwitchResult> evaluateAtMessageBoundary({
    required String taskId,
    required RoutingPolicyDocument policy,
    required RoutingSignals signals,
    required RoutingTaskMetadata task,
    required List<DistillationConversationTurn> turns,
    required DispatchLaneSend send,
    required Future<String> Function({
      required String agentId,
      required DistillationPackage package,
      required String sourceSessionId,
    })
    openTargetSession,
    String switchReason = 'message-boundary',
    bool Function(String agentId)? isDistillerReady,
  }) async {
    final session = _sessions[taskId];
    if (session == null) {
      throw StateError('Task $taskId is not bound.');
    }

    if (session.streaming) {
      return TaskRouteSwitchSkipped(
        reason: 'streaming_in_progress',
        session: session,
      );
    }

    final decision = _planner.plan(
      task: task,
      policy: policy,
      signals: signals,
    );
    if (decision.blocked || decision.chosenAgentId == session.currentAgentId) {
      return TaskRouteSwitchSkipped(
        reason: decision.blocked ? 'route_blocked' : 'route_unchanged',
        session: session,
      );
    }

    final minInterval = Duration(
      seconds: policy.routing.switchPolicy.minimumIntervalSeconds,
    );
    final lastSwitch = session.lastSwitchAt;
    if (lastSwitch != null && _now().difference(lastSwitch) < minInterval) {
      return TaskRouteSwitchSkipped(
        reason: 'switch_interval_bounded',
        session: session,
      );
    }

    // Serialize distillation per task so policy swaps queue safely.
    final prior = _distillationLocks[taskId];
    final gate = Completer<void>();
    _distillationLocks[taskId] = gate;
    if (prior != null) {
      await prior.future;
    }

    try {
      // If a policy arrived while waiting, callers may re-enter; we still
      // distill against the policy passed for this evaluation.
      final distillResult = await _broker.distill(
        request: DistillationRequest(
          sourceSessionId: session.currentSessionId,
          sourceAgentId: session.currentAgentId,
          targetAgentId: decision.chosenAgentId,
          turns: turns,
          isDistillerReady: isDistillerReady,
          now: _now,
        ),
        policy: policy,
        send: send,
      );

      if (distillResult is DistillationFailure) {
        final entry = RouteHistoryEntry(
          taskId: taskId,
          timestamp: _now().toUtc().toIso8601String(),
          sourceAgentId: session.currentAgentId,
          targetAgentId: decision.chosenAgentId,
          sourceSessionId: session.currentSessionId,
          targetSessionId: '',
          decision: decision,
          switchReason: switchReason,
          failed: true,
          failureReason: distillResult.reason,
        );
        await _history.append(entry);
        // Stay on source agent.
        return TaskRouteSwitchFailed(
          reason: distillResult.reason,
          session: session,
          entry: entry,
        );
      }

      final success = distillResult as DistillationSuccess;

      // Target readiness hard-check after distillation.
      final targetSignal = signals[decision.chosenAgentId];
      if (targetSignal == null || !targetSignal.ready) {
        final entry = RouteHistoryEntry(
          taskId: taskId,
          timestamp: _now().toUtc().toIso8601String(),
          sourceAgentId: session.currentAgentId,
          targetAgentId: decision.chosenAgentId,
          sourceSessionId: session.currentSessionId,
          targetSessionId: '',
          decision: decision,
          switchReason: switchReason,
          distillationPackage: success.package,
          failed: true,
          failureReason: 'target_not_ready',
        );
        await _history.append(entry);
        return TaskRouteSwitchFailed(
          reason: 'target_not_ready',
          session: session,
          entry: entry,
        );
      }

      final targetSessionId = await openTargetSession(
        agentId: decision.chosenAgentId,
        package: success.package,
        sourceSessionId: session.currentSessionId,
      );

      final updated = session.copyWith(
        currentAgentId: decision.chosenAgentId,
        currentSessionId: targetSessionId,
        lastSwitchAt: _now(),
      );
      _sessions[taskId] = updated;

      final entry = RouteHistoryEntry(
        taskId: taskId,
        timestamp: _now().toUtc().toIso8601String(),
        sourceAgentId: session.currentAgentId,
        targetAgentId: decision.chosenAgentId,
        sourceSessionId: session.currentSessionId,
        targetSessionId: targetSessionId,
        decision: decision,
        switchReason: switchReason,
        distillationPackage: success.package,
      );
      await _history.append(entry);

      return TaskRouteSwitchCompleted(
        session: updated,
        entry: entry,
        decision: decision,
        package: success.package,
      );
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
      if (_distillationLocks[taskId] == gate) {
        _distillationLocks.remove(taskId);
      }
    }
  }

  /// Whether the source session remains addressable after a switch.
  bool isSessionResumable({
    required String taskId,
    required String sessionId,
  }) {
    final history = _history.entriesFor(taskId);
    if (history.any((e) => e.sourceSessionId == sessionId) ||
        history.any((e) => e.targetSessionId == sessionId)) {
      return true;
    }
    final current = _sessions[taskId];
    return current?.currentSessionId == sessionId;
  }
}
