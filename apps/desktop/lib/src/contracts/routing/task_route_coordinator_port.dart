import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/route_history.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

typedef OpenTargetRouteSession =
    Future<String> Function({
      required String agentId,
      required DistillationPackage package,
      required String sourceSessionId,
      required String resumeSessionId,
    });

/// Application-facing port for task routing coordination.
///
/// Registrations and their consumers depend on this contract while the
/// application layer owns the concrete sequencing and persistence adapters.
abstract interface class TaskRouteCoordinatorPort {
  TaskRouteSession? sessionFor(String taskId);

  String resumeSessionIdForAgent({
    required String taskId,
    required String agentId,
  });

  TaskRouteSession bindSession({
    required String taskId,
    required String agentId,
    required String sessionId,
  });

  TaskRouteSession recordDispatchSession({
    required String taskId,
    required String agentId,
    required String sessionId,
  });

  void setStreaming(String taskId, bool streaming);

  void queuePolicy(RoutingPolicyDocument policy);

  RoutingPolicyDocument? takeQueuedPolicy();

  bool get hasQueuedPolicy;

  Future<TaskRouteSwitchResult> evaluateAtMessageBoundary({
    required String taskId,
    required RoutingPolicyDocument policy,
    required RoutingSignals signals,
    required RoutingTaskMetadata task,
    required List<DistillationConversationTurn> turns,
    required DispatchLaneSend send,
    required OpenTargetRouteSession openTargetSession,
    String switchReason = 'message-boundary',
    bool Function(String agentId)? isDistillerReady,
  });

  bool isSessionResumable({required String taskId, required String sessionId});
}
