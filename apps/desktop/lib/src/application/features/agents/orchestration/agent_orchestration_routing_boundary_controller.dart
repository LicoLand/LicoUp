import 'dart:async';
import 'dart:convert';

import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/application/features/routing/engine/route_evaluator.dart';
import 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/route_history.dart';
import 'package:flutter_client/src/contracts/routing/routing_dispatch_plan.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

/// Message-boundary route switching and distillation lane integration.
mixin AgentOrchestrationRoutingBoundaryController on AgentWorkspaceCoordinator {
  @override
  Future<TaskRouteSwitchResult?> evaluateOrchestrationRoutingBoundary({
    required String taskId,
    required String trigger,
    String pendingUserText = '',
    RoutingPolicyDocument? policySnapshot,
  }) async {
    final previous = orchestrationRoutingBoundaryTail;
    final gate = Completer<void>();
    orchestrationRoutingBoundaryTail = gate.future;
    await previous.catchError((_) {});
    try {
      final routingModule = await agentWorkspaceEnsureRoutingModuleReady();
      final coordinator = routingModule.coordinator;
      final policy = policySnapshot ?? routingModule.activePolicy;
      if (coordinator == null ||
          policy.isEmpty ||
          coordinator.sessionFor(taskId) == null) {
        return null;
      }
      final localSession =
          (conversationSessionsByAgent[agentOrchestrationTargetId] ?? const [])
              .where((session) => session.id == taskId)
              .firstOrNull;
      final turns = <DistillationConversationTurn>[
        for (final message in localSession?.messages ?? const [])
          if (message.isDefaultThreadVisible && message.text.trim().isNotEmpty)
            DistillationConversationTurn(
              role: message.role,
              text: message.text,
            ),
      ];
      final signals = const RouteEvaluator().evaluate(
        targets: scannedTargets,
        circuitBreakerStates: agentOrchestrationCircuitStates,
      );
      return await coordinator.evaluateAtMessageBoundary(
        taskId: taskId,
        policy: policy,
        signals: signals,
        task: RoutingTaskMetadata(prompt: pendingUserText),
        turns: turns,
        send: sendDistillationLaneRequest,
        openTargetSession: openRoutedTargetSession,
        switchReason: trigger,
        isDistillerReady: (agentId) =>
            routingTarget(agentId)?.canRelayRuntime == true,
      );
    } catch (_) {
      return null;
    } finally {
      gate.complete();
    }
  }

  Future<DistillationLaneResponse> sendDistillationLaneRequest(
    DistillationLaneRequest request,
  ) async {
    final target = routingTarget(request.agentId);
    final bind = routingBind(request.agentId);
    final opened = await conversationGateway.openOrResume(
      agentId: request.agentId,
      sessionId: request.sessionId,
      bind: bind,
    );
    final result = await conversationGateway.send(
      agentId: request.agentId,
      text: request.text,
      sessionId: opened.sessionId,
      bind: bind,
      conversationReadiness: target?.conversationReadiness ?? 'unverified',
    );
    final usage = routingUsage(result.raw);
    return DistillationLaneResponse(
      ok: result.ok,
      text: routingTurnText(result.raw),
      errorMessage: result.errorCode,
      sessionId: result.sessionId,
      promptTokens: usage.$1,
      completionTokens: usage.$2,
    );
  }

  Future<String> openRoutedTargetSession({
    required String agentId,
    required DistillationPackage package,
    required String sourceSessionId,
    required String resumeSessionId,
  }) async {
    final target = routingTarget(agentId);
    final bind = routingBind(agentId);
    final opened = await conversationGateway.openOrResume(
      agentId: agentId,
      sessionId: resumeSessionId,
      bind: bind,
    );
    final result = await conversationGateway.send(
      agentId: agentId,
      text: 'Lico Arc routed handoff:\n${jsonEncode(package.toJson())}',
      sessionId: opened.sessionId,
      bind: bind,
      conversationReadiness: target?.conversationReadiness ?? 'unverified',
    );
    if (!result.ok || result.sessionId.trim().isEmpty) {
      throw StateError('Routed target session could not be established.');
    }
    return result.sessionId.trim();
  }

  RoutingDispatchRoute routingRouteForAgent({
    required RoutingDispatchPlan plan,
    required String agentId,
  }) {
    for (final route in plan.routes) {
      if (route.agentId == agentId) return route;
    }
    final policyAgent =
        (agentWorkspaceRoutingModule?.activePolicy.agents ?? const [])
            .where((agent) => agent.id == agentId)
            .firstOrNull;
    final target = routingTarget(agentId);
    return RoutingDispatchRoute(
      agentId: agentId,
      agentLabel: target?.label ?? agentId,
      role: policyAgent?.coordinator == true ? 'primary' : 'routed',
      modelName: policyAgent?.modelName ?? '',
      reasoningEffort: policyAgent?.reasoningEffort ?? '',
      priority: policyAgent?.priority ?? 0,
      coordinator: policyAgent?.coordinator ?? false,
      reason: 'active-route-session',
    );
  }

  TargetCandidate? routingTarget(String agentId) {
    for (final target in scannedTargets) {
      if (target.target == agentId) return target;
    }
    return null;
  }

  AgentDispatchBind routingBind(String agentId, {RoutingDispatchRoute? route}) {
    final target = routingTarget(agentId);
    final policyAgent =
        (agentWorkspaceRoutingModule?.activePolicy.agents ?? const [])
            .where((agent) => agent.id == agentId)
            .firstOrNull;
    return AgentDispatchBind(
      model: route?.modelName ?? policyAgent?.modelName ?? '',
      reasoningEffort:
          route?.reasoningEffort ?? policyAgent?.reasoningEffort ?? '',
      binaryPath: target?.binaryPath ?? '',
    );
  }

  String routingTurnText(Map<String, dynamic> raw) {
    for (final key in const ['text', 'outputText', 'finalMessage', 'message']) {
      final value = raw[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    final output = raw['output'];
    if (output is String) return output;
    if (output is Map) {
      return routingTurnText(Map<String, dynamic>.from(output));
    }
    return '';
  }

  String mergeOrchestrationProgressiveText(String current, String incoming) {
    if (current.isEmpty || incoming.startsWith(current)) return incoming;
    if (current.endsWith(incoming)) return current;
    return '$current$incoming';
  }

  (int, int) routingUsage(Map<String, dynamic> raw) {
    final usage = raw['usage'];
    if (usage is! Map) return (0, 0);
    int value(String primary, String alternate) =>
        int.tryParse((usage[primary] ?? usage[alternate] ?? 0).toString()) ?? 0;
    return (
      value('promptTokens', 'inputTokens'),
      value('completionTokens', 'outputTokens'),
    );
  }
}
