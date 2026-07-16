import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_conversation_controller.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_dispatch_models.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_presentation.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_routing_boundary_controller.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/contracts/agent_conversation_tab_activity.dart';
import 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/routing/routing_dispatch_plan.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

/// Dispatch strategy execution over a precomputed routing plan.
mixin AgentOrchestrationDispatchController
    on
        AgentWorkspaceCoordinator,
        AgentOrchestrationPolicyController,
        AgentOrchestrationPresentation,
        AgentOrchestrationConversationController,
        AgentOrchestrationRoutingBoundaryController {
  @override
  Future<void> sendOrchestratedConversationMessage(String text) async {
    if (!agentOrchestrationPolicyConfigured) {
      lastError = 'default orchestration policy not configured';
      agentWorkspaceSetLocalizedStatusMessage(
        '默认编排策略未配置，请先编辑策略。',
        'Configure the default orchestration policy before sending.',
      );
      statusCaption = 'Agent orchestration';
      agentWorkspaceNotifyStateChanged();
      return;
    }
    isSendingConversationMessage = true;
    sendingConversationSessionId = selectedConversationSession?.id.trim() ?? '';
    sendingConversationNativeSessionId =
        selectedConversationSession?.nativeSessionId.trim() ?? '';
    lastError = '';
    agentWorkspaceSetLocalizedStatusMessage(
      '正在按默认编排策略分发消息。',
      'Dispatching the message with the default orchestration policy.',
    );
    statusCaption = 'Agent orchestration';
    agentWorkspaceNotifyStateChanged();

    ensureOrchestrationConversationSession();
    sendingConversationSessionId =
        selectedConversationSession?.id.trim() ?? sendingConversationSessionId;
    final routingModule = await agentWorkspaceEnsureRoutingModuleReady();
    final coordinator = routingModule.coordinator;
    final orchestrationSession = selectedConversationSession;
    if (coordinator == null || orchestrationSession == null) {
      lastError = 'routing module unavailable';
      agentWorkspaceSetLocalizedStatusMessage(
        '默认编排路由尚未就绪。',
        'The orchestration route is not ready.',
      );
      statusCaption = 'Agent orchestration';
      isSendingConversationMessage = false;
      sendingConversationSessionId = '';
      sendingConversationNativeSessionId = '';
      agentWorkspaceNotifyStateChanged();
      return;
    }
    final taskId = orchestrationSession.id;
    final pendingPolicy = coordinator.takeQueuedPolicy();
    final messagePolicy = pendingPolicy ?? routingModule.activePolicy;
    var plan = previewRoutingDispatchPlan(text, policySnapshot: messagePolicy);
    final outcomes = <OrchestrationDispatchOutcome>[];
    final newlyCircuitBroken = <String>{};
    var orchestrationTurnId = '';

    try {
      if (plan.blocked) {
        orchestrationTurnId = beginOrchestrationConversationTurn(text);
        appendOrchestrationExecutionStatus(
          turnId: orchestrationTurnId,
          plan: plan,
          outcomes: outcomes,
          skipped: plan.skipped,
        );
        lastError = 'default orchestration dispatch blocked';
        agentWorkspaceSetLocalizedStatusMessage(
          '默认编排无可用链路，已回传熔断状态。',
          'No default orchestration route is available; circuit-breaker status was returned.',
        );
        statusCaption = 'Agent orchestration';
        return;
      }

      var routeSession = coordinator.sessionFor(taskId);
      if (routeSession != null) {
        await evaluateOrchestrationRoutingBoundary(
          taskId: taskId,
          trigger: pendingPolicy == null ? 'message-boundary' : 'policy-reload',
          pendingUserText: text,
          policySnapshot: messagePolicy,
        );
        routeSession = coordinator.sessionFor(taskId);
        plan = previewRoutingDispatchPlan(text, policySnapshot: messagePolicy);
      }
      orchestrationTurnId = beginOrchestrationConversationTurn(text);
      coordinator.setStreaming(taskId, true);

      if (const {
        'serial-all',
        'parallel-all',
        'coordinator-workers',
      }.contains(plan.strategy)) {
        Future<MapEntry<RoutingDispatchRoute, OrchestrationRouteResult>>
        dispatchScheduled(
          RoutingDispatchRoute route, {
          String? scheduledText,
        }) async {
          final branchSessionId = coordinator.resumeSessionIdForAgent(
            taskId: taskId,
            agentId: route.agentId,
          );
          final result = await dispatchOrchestrationRoute(
            route: route,
            plan: plan,
            text: scheduledText ?? text,
            sessionId: branchSessionId.isEmpty ? null : branchSessionId,
            orchestrationTurnId: orchestrationTurnId,
          );
          return MapEntry(route, result);
        }

        final scheduled =
            <MapEntry<RoutingDispatchRoute, OrchestrationRouteResult>>[];
        if (plan.strategy == 'serial-all') {
          for (final route in plan.routes) {
            scheduled.add(await dispatchScheduled(route));
          }
        } else if (plan.strategy == 'parallel-all') {
          const maximumParallelRoutes = 4;
          for (
            var offset = 0;
            offset < plan.routes.length;
            offset += maximumParallelRoutes
          ) {
            final end = offset + maximumParallelRoutes < plan.routes.length
                ? offset + maximumParallelRoutes
                : plan.routes.length;
            scheduled.addAll(
              await Future.wait(
                plan.routes
                    .sublist(offset, end)
                    .map((route) => dispatchScheduled(route)),
              ),
            );
          }
        } else {
          final coordinatorRoute = plan.routes.firstWhere(
            (route) => route.coordinator,
            orElse: () => plan.routes.first,
          );
          final workers = plan.routes
              .where((route) => route.agentId != coordinatorRoute.agentId)
              .toList(growable: false);
          const maximumParallelWorkers = 4;
          for (
            var offset = 0;
            offset < workers.length;
            offset += maximumParallelWorkers
          ) {
            final end = offset + maximumParallelWorkers < workers.length
                ? offset + maximumParallelWorkers
                : workers.length;
            scheduled.addAll(
              await Future.wait(
                workers
                    .sublist(offset, end)
                    .map((route) => dispatchScheduled(route)),
              ),
            );
          }
          final workerBrief = scheduled
              .map((entry) {
                final reply = truncateOrchestrationText(
                  entry.value.replyText.trim(),
                  1200,
                );
                return '${entry.key.agentId}: ${entry.value.turn.ok ? reply : '[failed:${entry.value.turn.errorCode}]'}';
              })
              .join('\n');
          scheduled.add(
            await dispatchScheduled(
              coordinatorRoute,
              scheduledText:
                  '$text\n\nWorker results to verify and synthesize:\n$workerBrief',
            ),
          );
        }
        for (final entry in scheduled) {
          final route = entry.key;
          final result = entry.value;
          outcomes.add(
            OrchestrationDispatchOutcome(
              route: route,
              ok: result.turn.ok,
              status: result.turn.ok ? 'replied' : 'failed',
              replyText: result.replyText,
            ),
          );
          recordConversationTabSendOutcome(
            agentId: route.agentId,
            ok: result.turn.ok,
            result: result.turn.raw,
            errorCode: result.turn.errorCode,
          );
          if (result.turn.ok && result.turn.sessionId.trim().isNotEmpty) {
            recordOrchestrationRouteSuccess(route.agentId);
            coordinator.recordDispatchSession(
              taskId: taskId,
              agentId: route.agentId,
              sessionId: result.turn.sessionId,
            );
          } else if (recordOrchestrationRouteFailure(route.agentId)) {
            newlyCircuitBroken.add(route.agentId);
          }
        }
      } else if (routeSession == null) {
        for (final route in plan.routes) {
          final result = await dispatchOrchestrationRoute(
            route: route,
            plan: plan,
            text: text,
            orchestrationTurnId: orchestrationTurnId,
          );
          outcomes.add(
            OrchestrationDispatchOutcome(
              route: route,
              ok: result.turn.ok,
              status: result.turn.ok ? 'replied' : 'failed',
              replyText: result.replyText,
            ),
          );
          recordConversationTabSendOutcome(
            agentId: route.agentId,
            ok: result.turn.ok,
            result: result.turn.raw,
            errorCode: result.turn.errorCode,
          );
          if (result.turn.ok && result.turn.sessionId.trim().isNotEmpty) {
            recordOrchestrationRouteSuccess(route.agentId);
            coordinator.recordDispatchSession(
              taskId: taskId,
              agentId: route.agentId,
              sessionId: result.turn.sessionId,
            );
            break;
          }
          if (recordOrchestrationRouteFailure(route.agentId)) {
            newlyCircuitBroken.add(route.agentId);
          }
          if (plan.strategy != 'priority-fallback' ||
              routingFailureDisposition(result.turn) !=
                  RoutingDispatchFailureDisposition.transientKnown) {
            break;
          }
        }
      } else {
        final route = routingRouteForAgent(
          plan: plan,
          agentId: routeSession.currentAgentId,
        );
        final result = await dispatchOrchestrationRoute(
          route: route,
          plan: plan,
          text: text,
          sessionId: routeSession.currentSessionId,
          orchestrationTurnId: orchestrationTurnId,
        );
        outcomes.add(
          OrchestrationDispatchOutcome(
            route: route,
            ok: result.turn.ok,
            status: result.turn.ok ? 'replied' : 'failed',
            replyText: result.replyText,
          ),
        );
        recordConversationTabSendOutcome(
          agentId: route.agentId,
          ok: result.turn.ok,
          result: result.turn.raw,
          errorCode: result.turn.errorCode,
        );
        if (result.turn.ok && result.turn.sessionId.trim().isNotEmpty) {
          recordOrchestrationRouteSuccess(route.agentId);
          coordinator.recordDispatchSession(
            taskId: taskId,
            agentId: route.agentId,
            sessionId: result.turn.sessionId,
          );
        } else if (recordOrchestrationRouteFailure(route.agentId)) {
          newlyCircuitBroken.add(route.agentId);
        }
      }
      final okCount = outcomes.where((outcome) => outcome.ok).length;
      if (okCount == 0 ||
          newlyCircuitBroken.isNotEmpty ||
          plan.skipped.isNotEmpty) {
        appendOrchestrationExecutionStatus(
          turnId: orchestrationTurnId,
          plan: plan,
          outcomes: outcomes,
          skipped: plan.skipped,
        );
      }
      if (okCount > 0) {
        recordConversationTabSendOutcome(
          agentId: agentOrchestrationTargetId,
          ok: true,
        );
      } else if (outcomes.any(
        (outcome) =>
            conversationTabActivityFor(outcome.route.agentId) ==
            AgentConversationTabActivity.needsApproval,
      )) {
        setConversationTabActivity(
          agentOrchestrationTargetId,
          AgentConversationTabActivity.needsApproval,
        );
      } else {
        setConversationTabActivity(
          agentOrchestrationTargetId,
          AgentConversationTabActivity.none,
        );
      }
      if (okCount == 0) {
        lastError = 'default orchestration dispatch failed';
        agentWorkspaceSetLocalizedStatusMessage(
          '默认编排分发失败，后续链路已熔断或降级。',
          'Default orchestration dispatch failed; subsequent routes were circuit-broken or degraded.',
        );
      } else if (newlyCircuitBroken.isNotEmpty || plan.skipped.isNotEmpty) {
        agentWorkspaceSetLocalizedStatusMessage(
          '默认编排已分发 $okCount 条，部分链路已降级或熔断。',
          'Default orchestration dispatched $okCount routes; some routes were degraded or circuit-broken.',
        );
      } else {
        agentWorkspaceSetLocalizedStatusMessage(
          '默认编排已分发 $okCount 条链路。',
          'Default orchestration dispatched $okCount routes.',
        );
      }
      statusCaption = 'Agent orchestration';
    } finally {
      coordinator.setStreaming(taskId, false);
      isSendingConversationMessage = false;
      sendingConversationSessionId = '';
      sendingConversationNativeSessionId = '';
      agentWorkspaceNotifyStateChanged();
    }
  }

  Future<OrchestrationRouteResult> dispatchOrchestrationRoute({
    required RoutingDispatchRoute route,
    required RoutingDispatchPlan plan,
    required String text,
    required String orchestrationTurnId,
    String? sessionId,
  }) async {
    agentWorkspaceSetLocalizedStatusMessage(
      '正在分发给 ${route.agentLabel}（${route.role}，优先级 ${route.priority}）。',
      'Dispatching to ${route.agentLabel} (${route.role}, priority ${route.priority}).',
    );
    agentWorkspaceNotifyStateChanged();
    try {
      final target = routingTarget(route.agentId);
      final bind = routingBind(route.agentId, route: route);
      final opened = sessionId == null
          ? await conversationGateway.openOrResume(
              agentId: route.agentId,
              bind: bind,
            )
          : await conversationGateway.openOrResume(
              agentId: route.agentId,
              sessionId: sessionId,
              bind: bind,
            );
      var replyText = '';
      AgentDispatchTurnResult? turn;
      final assistantMessageId = '$orchestrationTurnId-${route.agentId}';
      await for (final event in conversationGateway.sendStreaming(
        agentId: route.agentId,
        text: dispatchPromptForRoute(plan: plan, route: route, userText: text),
        sessionId: opened.sessionId,
        bind: bind,
        conversationReadiness: target?.conversationReadiness ?? 'unverified',
      )) {
        if (event.kind == 'agent.message.chunk' ||
            event.kind == 'agent.message.completed') {
          final chunk = (event.payload['text'] ?? '').toString();
          if (chunk.isNotEmpty) {
            replyText = event.kind == 'agent.message.completed'
                ? chunk
                : mergeOrchestrationProgressiveText(replyText, chunk);
            upsertOrchestrationAssistantReply(
              messageId: assistantMessageId,
              route: route,
              text: replyText,
            );
          }
          continue;
        }
        if (event.kind == 'dispatch.turn.completed' ||
            event.kind == 'dispatch.turn.failed') {
          final raw = Map<String, dynamic>.from(event.payload);
          final ok = raw['ok'] == true;
          final nested = raw['error'];
          final rawCode = nested is Map
              ? (nested['code'] ?? '')
              : (raw['code'] ?? '');
          turn = AgentDispatchTurnResult(
            ok: ok,
            sessionId: event.sessionId,
            turnId: event.turnId,
            status: (raw['turnStatus'] ?? raw['status'] ?? '').toString(),
            errorCode: ok ? '' : rawCode.toString(),
            errorMessage: ok
                ? ''
                : (nested is Map ? (nested['message'] ?? '') : '').toString(),
            raw: raw,
          );
          final terminalText = routingTurnText(raw);
          if (terminalText.isNotEmpty) {
            replyText = terminalText;
            upsertOrchestrationAssistantReply(
              messageId: assistantMessageId,
              route: route,
              text: replyText,
            );
          }
          continue;
        }
        publishOrchestrationStreamActivity(
          turnId: orchestrationTurnId,
          route: route,
          event: event,
        );
      }
      final completedTurn =
          turn ??
          AgentDispatchTurnResult(
            ok: false,
            sessionId: opened.sessionId,
            errorCode: 'dispatch_stream_incomplete',
            raw: const {'ok': false, 'code': 'dispatch_stream_incomplete'},
          );
      if (completedTurn.ok && replyText.trim().isEmpty) {
        return OrchestrationRouteResult(
          turn: AgentDispatchTurnResult(
            ok: false,
            sessionId: completedTurn.sessionId,
            turnId: completedTurn.turnId,
            status: completedTurn.status,
            errorCode: 'dispatch_reply_missing',
            raw: completedTurn.raw,
          ),
          replyText: '',
        );
      }
      return OrchestrationRouteResult(
        turn: completedTurn,
        replyText: replyText,
      );
    } catch (_) {
      return OrchestrationRouteResult(
        turn: AgentDispatchTurnResult(
          ok: false,
          sessionId: sessionId ?? '',
          errorCode: 'orchestration_lane_exception',
        ),
        replyText: '',
      );
    }
  }
}
