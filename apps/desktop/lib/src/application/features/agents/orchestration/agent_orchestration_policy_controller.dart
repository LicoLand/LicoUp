import 'dart:async';

import 'package:flutter_client/src/application/features/agents/policy/routing_circuit_breaker_registry.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/application/features/routing/controller/routing_policy_editor_adapter.dart';
import 'package:flutter_client/src/application/features/routing/engine/routing_dispatch_engine.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_flags.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/routing/routing_dispatch_plan.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

/// Policy editing, optional-module lifecycle, and circuit-breaker state.
mixin AgentOrchestrationPolicyController on AgentWorkspaceCoordinator {
  bool get routingModuleIncluded => kRoutingModuleIncluded;

  @override
  bool get routingModuleAvailable =>
      kRoutingModuleIncluded &&
      (agentWorkspaceRoutingModule?.isEnabled ?? true);

  @override
  bool get selectedConversationIsOrchestration =>
      routingModuleAvailable &&
      isAgentOrchestrationTargetId(selectedConversationAgentId);

  Set<String> get agentOrchestrationOpenCircuitAgentIds {
    final breaker =
        (agentWorkspaceRoutingModule?.activePolicy ??
                emptyRoutingPolicyDocument)
            .routing
            .circuitBreaker;
    final now = DateTime.now().toUtc();
    return RoutingCircuitBreakerRegistry.openAgentIds(
      agentOrchestrationCircuitStates,
      allowedFails: breaker.allowedFails,
      cooldown: Duration(seconds: breaker.cooldownSeconds),
      now: now,
    );
  }

  List<TargetCandidate> get orchestrationAvailableTargets {
    if (!routingModuleAvailable) return const [];
    return scannedTargets
        .where((target) => target.isConversationAgent && target.canRelayRuntime)
        .toList(growable: false);
  }

  List<AgentOrchestrationPolicy> get agentOrchestrationPolicies {
    if (!routingModuleAvailable) return const [];
    return [effectiveAgentOrchestrationPolicy];
  }

  AgentOrchestrationPolicy get effectiveAgentOrchestrationPolicy {
    return normalizeAgentOrchestrationPolicy(
      scannedTargets,
      agentOrchestrationPolicy,
    );
  }

  bool get agentOrchestrationPolicyConfigured =>
      effectiveAgentOrchestrationPolicy.configured;

  List<String> get effectiveAgentOrchestrationSelectedAgentIds {
    return agentOrchestrationDispatchModelLibrary(
      effectiveAgentOrchestrationPolicy,
    ).map((entry) => entry.agentId).toSet().toList(growable: false);
  }

  @override
  String get effectiveAgentOrchestrationPrimaryAgentId {
    final entries = agentOrchestrationDispatchModelLibrary(
      effectiveAgentOrchestrationPolicy,
    );
    return entries.isEmpty ? '' : entries.first.agentId;
  }

  String agentOrchestrationPolicyDisplayLabel(AgentOrchestrationPolicy policy) {
    final base = policy.label.trim().isEmpty
        ? agentWorkspaceStrings.defaultPolicy
        : policy.label.trim();
    return policy.configured
        ? base
        : '$base (${agentWorkspaceStrings.notConfigured})';
  }

  void selectAgentOrchestrationPolicy(String policyId) {
    if (policyId.trim() == agentOrchestrationPolicy.id) return;
    agentWorkspaceSetLocalizedStatusMessage(
      '当前仅内置默认策略。',
      'Only the default policy is currently available.',
    );
    statusCaption = 'Agent orchestration';
    agentWorkspaceNotifyStateChanged();
  }

  Future<void> saveAgentOrchestrationPolicy(
    AgentOrchestrationPolicy policy,
  ) async {
    if (!routingModuleAvailable) {
      throw StateError('routing_module_excluded');
    }
    agentOrchestrationPolicy = normalizeAgentOrchestrationPolicy(
      scannedTargets,
      policy.copyWith(
        id: policy.id.trim().isEmpty
            ? defaultAgentOrchestrationPolicyId
            : policy.id.trim(),
        label: policy.label.trim().isEmpty
            ? agentWorkspaceStrings.defaultPolicy
            : policy.label.trim(),
      ),
    );
    final selected = {
      for (final entry in agentOrchestrationDispatchModelLibrary(
        agentOrchestrationPolicy,
      ))
        entry.agentId,
    };
    agentOrchestrationCircuitStates =
        RoutingCircuitBreakerRegistry.retainAgents(
          agentOrchestrationCircuitStates,
          selected,
        );
    agentWorkspaceSetLocalizedStatusMessage(
      '正在保存默认编排策略。',
      'Saving the default orchestration policy.',
    );
    statusCaption = 'Agent orchestration';
    ensureOrchestrationConversationSession();
    agentWorkspaceNotifyStateChanged();
    try {
      final editedPolicy = agentOrchestrationPolicy;
      final routingModule = await agentWorkspaceEnsureRoutingModuleReady();
      agentOrchestrationPolicy = editedPolicy;
      if (editedPolicy.configured) {
        await routingModule.savePolicy(
          routingPolicyFromEditor(
            editedPolicy,
            basePolicy: routingModule.activePolicy,
          ),
        );
      } else {
        await routingModule.clearPolicy();
      }
      await Future<void>.delayed(Duration.zero);
      final taskId = activeOrchestrationTaskId;
      final coordinator = routingModule.coordinator;
      if (taskId.isNotEmpty && coordinator?.sessionFor(taskId) != null) {
        coordinator!.queuePolicy(routingModule.activePolicy);
      }
      agentOrchestrationPolicy = editedPolicy;
      agentWorkspaceSetLocalizedStatusMessage(
        agentOrchestrationPolicy.configured ? '默认编排策略已保存。' : '默认编排策略已清空。',
        agentOrchestrationPolicy.configured
            ? 'Default orchestration policy saved.'
            : 'Default orchestration policy cleared.',
      );
      statusCaption = 'Agent orchestration';
    } catch (_) {
      lastError = 'agent_orchestration_policy_save_failed';
      agentWorkspaceSetLocalizedStatusMessage(
        '默认编排策略保存失败。',
        'Failed to save the default orchestration policy.',
      );
      statusCaption = 'Agent orchestration';
    } finally {
      agentWorkspaceNotifyStateChanged();
    }
  }

  void resetAgentOrchestrationCircuitBreakers() {
    if (!routingModuleAvailable || agentOrchestrationCircuitStates.isEmpty) {
      return;
    }
    agentOrchestrationCircuitStates = const {};
    agentWorkspaceSetLocalizedStatusMessage(
      '已重置默认编排链路熔断状态。',
      'Reset the default orchestration circuit breakers.',
    );
    statusCaption = 'Agent orchestration';
    agentWorkspaceNotifyStateChanged();
  }

  bool recordOrchestrationRouteFailure(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) return false;
    final breaker =
        (agentWorkspaceRoutingModule?.activePolicy ??
                emptyRoutingPolicyDocument)
            .routing
            .circuitBreaker;
    final update = RoutingCircuitBreakerRegistry.recordFailure(
      agentOrchestrationCircuitStates,
      normalized,
      allowedFails: breaker.allowedFails,
      cooldown: Duration(seconds: breaker.cooldownSeconds),
      now: DateTime.now().toUtc(),
    );
    agentOrchestrationCircuitStates = update.states;
    return update.isOpen;
  }

  void recordOrchestrationRouteSuccess(String agentId) {
    agentOrchestrationCircuitStates =
        RoutingCircuitBreakerRegistry.recordSuccess(
          agentOrchestrationCircuitStates,
          agentId.trim(),
        );
  }

  RoutingDispatchPlan previewRoutingDispatchPlan(
    String prompt, {
    RoutingPolicyDocument? policySnapshot,
  }) {
    return planRoutingDispatch(
      targets: scannedTargets,
      policy:
          policySnapshot ??
          agentWorkspaceRoutingModule?.activePolicy ??
          emptyRoutingPolicyDocument,
      task: RoutingTaskMetadata(prompt: prompt),
      circuitBreakerStates: agentOrchestrationCircuitStates,
    );
  }

  Future<void> setRoutingModuleEnabled(bool enabled) async {
    if (!kRoutingModuleIncluded) return;
    if (enabled) {
      final registration =
          agentWorkspaceRoutingModule ??
          await agentWorkspaceEnsureRoutingModuleReady();
      await registration.enable();
      agentWorkspaceRoutingModule = registration;
      await agentWorkspaceBindRoutingModulePolicyEvents(registration);
      agentOrchestrationPolicy = orchestrationEditorFromRoutingPolicy(
        registration.activePolicy,
      );
      agentWorkspaceNotifyStateChanged();
      return;
    }
    final wasOrchestration = isAgentOrchestrationTargetId(
      selectedConversationAgentId,
    );
    await agentWorkspaceUnbindRoutingModulePolicyEvents();
    await agentWorkspaceRoutingModule?.deactivate();
    agentOrchestrationPolicy = const AgentOrchestrationPolicy();
    agentOrchestrationCircuitStates = const {};
    if (wasOrchestration) {
      agentWorkspaceSelectDefaultConversationAgent(preferDirectAgent: true);
    }
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();
  }

  Future<void> unloadRoutingModule() async {
    if (!kRoutingModuleIncluded) return;
    final wasOrchestration = isAgentOrchestrationTargetId(
      selectedConversationAgentId,
    );
    await agentWorkspaceUnbindRoutingModulePolicyEvents();
    await agentWorkspaceRoutingModule?.unload();
    agentOrchestrationPolicy = const AgentOrchestrationPolicy();
    agentOrchestrationCircuitStates = const {};
    conversationSessionsByAgent = Map.unmodifiable({
      for (final entry in conversationSessionsByAgent.entries)
        if (!isAgentOrchestrationTargetId(entry.key)) entry.key: entry.value,
    });
    if (wasOrchestration) {
      agentWorkspaceSelectDefaultConversationAgent(preferDirectAgent: true);
    }
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();
  }

  @override
  void syncAgentOrchestrationPolicy() {
    if (!routingModuleAvailable) {
      agentOrchestrationPolicy = const AgentOrchestrationPolicy();
      agentOrchestrationCircuitStates = const {};
      return;
    }
    final activeRoutingPolicy = agentWorkspaceRoutingModule?.activePolicy;
    agentOrchestrationPolicy = normalizeAgentOrchestrationPolicy(
      scannedTargets,
      activeRoutingPolicy == null
          ? agentOrchestrationPolicy
          : orchestrationEditorFromRoutingPolicy(activeRoutingPolicy),
    );
    final selected = {
      for (final entry in agentOrchestrationDispatchModelLibrary(
        agentOrchestrationPolicy,
      ))
        entry.agentId,
    };
    agentOrchestrationCircuitStates =
        RoutingCircuitBreakerRegistry.retainAgents(
          agentOrchestrationCircuitStates,
          selected,
        );
  }
}
