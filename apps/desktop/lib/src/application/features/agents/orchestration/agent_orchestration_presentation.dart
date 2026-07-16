import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_dispatch_models.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/routing/routing_dispatch_plan.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

String truncateOrchestrationText(String value, int maximumRunes) =>
    String.fromCharCodes(value.runes.take(maximumRunes));

/// User-facing orchestration prompts and bounded status projections.
mixin AgentOrchestrationPresentation
    on AgentWorkspaceCoordinator, AgentOrchestrationPolicyController {
  String dispatchPromptForRoute({
    required RoutingDispatchPlan plan,
    required RoutingDispatchRoute route,
    required String userText,
  }) {
    final strategy = strategyStatusLabel(plan.strategy);
    final policy = effectiveAgentOrchestrationPolicy;
    final commander = orchestrationCommanderStatus(policy);
    final peers = plan.routes
        .map((item) {
          final model = routeModelStatus(item);
          final reasoning = reasoningEffortStatusLabel(item.reasoningEffort);
          return '- ${item.agentLabel}$model / 思考强度：$reasoning: ${item.role}, 优先级 ${item.priority}';
        })
        .join('\n');
    final coordinator = plan.strategy == 'coordinator-workers'
        ? (route.coordinator
              ? '你是主智能体；请核验给出的工作结果并生成最终综合答复。'
              : '你是工作智能体，只处理分配给你的角色；结果将交给主智能体核验。')
        : '你是独立执行节点，只处理分配给你的角色；Lico Arc 会按策略展示各节点结果。';
    final modelStatus = routeModelStatus(route);
    return '''
你位于 Lico Arc 默认多智能体编排链路中。
策略：$strategy
指挥官：$commander
当前角色：${route.role}
优先级：${route.priority}
模型：${modelStatus.isEmpty ? '未指定' : modelStatus.substring(3)}
思考强度：${reasoningEffortStatusLabel(route.reasoningEffort)}
$coordinator

本次链路：
$peers

原始请求：
$userText
''';
  }

  String orchestrationCommanderStatus(AgentOrchestrationPolicy policy) {
    if (policy.commanderAgentId.trim().isEmpty) return '未指定';
    var label = policy.commanderAgentId;
    for (final target in scannedTargets) {
      if (target.target == policy.commanderAgentId) {
        label = target.label;
        break;
      }
    }
    final modelLabel = modelDisplayNameFor(
      policy.commanderAgentId,
      policy.commanderModelName.trim(),
    );
    final reasoning = reasoningEffortStatusLabel(
      policy.commanderReasoningEffort,
    );
    if (modelLabel.isEmpty) return label;
    return policy.commanderReasoningEffort.trim().isEmpty
        ? '$label / $modelLabel'
        : '$label / $modelLabel / 思考强度：$reasoning';
  }

  String orchestrationStatusMessage({
    required RoutingDispatchPlan plan,
    required List<OrchestrationDispatchOutcome> outcomes,
    required List<RoutingDispatchSkip> skipped,
  }) {
    final buffer = StringBuffer()
      ..writeln('策略：${strategyStatusLabel(plan.strategy)}')
      ..writeln(
        '主智能体：${plan.primaryAgentId.isEmpty ? '未就绪' : plan.primaryAgentId}',
      )
      ..writeln();
    if (outcomes.isNotEmpty) {
      buffer.writeln('分发结果：');
      for (final outcome in outcomes) {
        final model = routeModelStatus(outcome.route);
        final reasoning = reasoningEffortStatusLabel(
          outcome.route.reasoningEffort,
        );
        final state = outcome.ok ? '已回复' : '失败，后续熔断';
        buffer.writeln(
          '- ${outcome.route.agentLabel}$model · 思考强度：$reasoning · ${outcome.route.role} · $state',
        );
      }
      buffer.writeln();
    }
    if (skipped.isNotEmpty) {
      buffer.writeln('降级/熔断：');
      for (final skip in skipped) {
        buffer.writeln('- ${skip.agentLabel}: ${skipReasonLabel(skip.reason)}');
      }
      buffer.writeln();
    }
    if (outcomes.isEmpty && skipped.isEmpty) {
      buffer.writeln('没有可用智能体路线。');
    }
    return buffer.toString().trim();
  }

  String orchestrationSessionTitle(
    String userText,
    AgentConversationSession? existing,
  ) {
    if (existing != null &&
        existing.messages.isNotEmpty &&
        existing.title.trim().isNotEmpty) {
      return existing.title;
    }
    final compact = truncateOrchestrationText(
      userText.replaceAll(RegExp(r'\s+'), ' ').trim(),
      36,
    );
    return compact.isEmpty ? '默认智能体编排' : compact;
  }

  String strategyStatusLabel(String strategy) {
    return switch (strategy) {
      'priority-fallback' || 'fallback' => '顺序降级',
      'serial-all' => '串行协作',
      'parallel-all' => '并行协作',
      'coordinator-workers' => '指挥官汇总',
      _ => strategy,
    };
  }

  RoutingDispatchFailureDisposition routingFailureDisposition(
    AgentDispatchTurnResult turn,
  ) {
    return RoutingDispatchFailureFacts.fromEnvelope(
      ok: turn.ok,
      errorCode: turn.errorCode,
      envelope: turn.raw,
    ).disposition;
  }

  String skipReasonLabel(String reason) {
    return switch (reason) {
      'circuit-open' || 'circuit_broken' => '熔断中，已跳过',
      'not_ready' => '未就绪，已跳过',
      'model-library-excluded' => '不在模型库中，已跳过',
      _ => '不可用，已跳过',
    };
  }

  String routeModelStatus(RoutingDispatchRoute route) {
    final modelLabel = modelDisplayNameFor(route.agentId, route.modelName);
    return modelLabel.isEmpty ? '' : ' / $modelLabel';
  }

  String modelDisplayNameFor(String agentId, String modelName) {
    final normalized = modelName.trim();
    if (normalized.isEmpty) return '';
    for (final target in scannedTargets) {
      if (target.target == agentId) {
        return agentOrchestrationModelDisplayName(target, normalized);
      }
    }
    return normalized;
  }

  String reasoningEffortStatusLabel(String value) {
    return switch (value.trim().toLowerCase()) {
      '' => '未指定',
      'low' => '低',
      'medium' => '中',
      'high' => '高',
      _ => value.trim(),
    };
  }
}
