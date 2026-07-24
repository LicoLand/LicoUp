import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/platform/native_client/orchestrator_ipc/client.dart';

/// Thin editor-to-backend boundary. Policy validation, storage, compilation,
/// activation, and revision ownership all remain in the native orchestrator.
mixin AgentOrchestrationPolicyController on AgentWorkspaceCoordinator {
  bool get orchestrationAvailable => !agentWorkspaceMobileRuntime;

  @override
  bool get selectedConversationIsOrchestration =>
      orchestrationAvailable &&
      isAgentOrchestrationTargetId(selectedConversationAgentId);

  List<TargetCandidate> get orchestrationAvailableTargets {
    if (!orchestrationAvailable) return const [];
    return scannedTargets
        .where((target) => target.isConversationAgent && target.canRelayRuntime)
        .toList(growable: false);
  }

  List<AgentOrchestrationPolicy> get agentOrchestrationPolicies {
    if (!orchestrationAvailable) return const [];
    return [effectiveAgentOrchestrationPolicy];
  }

  AgentOrchestrationPolicy get effectiveAgentOrchestrationPolicy {
    if (orchestrationPolicyDraft.isNotEmpty) {
      return sanitizeOrchestrationPolicyEditorDraft(
        scannedTargets,
        AgentOrchestrationPolicy.fromBackendPolicy(orchestrationPolicyDraft),
      );
    }
    return sanitizeOrchestrationPolicyEditorDraft(
      scannedTargets,
      const AgentOrchestrationPolicy(),
    );
  }

  bool get agentOrchestrationPolicyConfigured =>
      orchestrationPolicyConfigured &&
      effectiveAgentOrchestrationPolicy.configured;

  bool get orchestrationPolicyConfigured =>
      activeOrchestrationPolicyRevision.isNotEmpty;

  Map<String, Object?> get effectiveOrchestrationPolicy =>
      orchestrationPolicyDraft;

  Set<String> get agentOrchestrationOpenCircuitAgentIds => const {};

  String agentOrchestrationPolicyDisplayLabel(AgentOrchestrationPolicy policy) {
    final base = policy.label.trim().isEmpty
        ? agentWorkspaceStrings.defaultPolicy
        : policy.label.trim();
    return policy.configured
        ? base
        : '$base (${agentWorkspaceStrings.notConfigured})';
  }

  void selectAgentOrchestrationPolicy(String policyId) {
    if (policyId.trim() == effectiveAgentOrchestrationPolicy.id) return;
    agentWorkspaceSetLocalizedStatusMessage(
      '当前仅内置默认策略。',
      'Only the default policy is currently available.',
    );
    statusCaption = 'Agent orchestration';
    agentWorkspaceNotifyStateChanged();
  }

  void selectOrchestrationPolicy(String policyRevision) {
    if (policyRevision.trim() != activeOrchestrationPolicyRevision) {
      throw const OrchestratorClientException(
        code: 'policy_revision_unavailable',
      );
    }
  }

  Future<void> saveAgentOrchestrationPolicy(
    AgentOrchestrationPolicy policy,
  ) async {
    if (!orchestrationAvailable) {
      throw const OrchestratorClientException(code: 'service_unavailable');
    }
    final draft = sanitizeOrchestrationPolicyEditorDraft(scannedTargets, policy);
    try {
      if (!draft.configured ||
          orchestrationEditorOrderedEntries(draft).isEmpty) {
        orchestrationPolicyDraft = const {};
        activeOrchestrationPolicyRevision = '';
        agentWorkspaceSetLocalizedStatusMessage(
          '默认编排策略已清空。',
          'Default orchestration policy cleared.',
        );
        statusCaption = 'Agent orchestration';
        agentWorkspaceNotifyStateChanged();
        return;
      }
      await saveOrchestrationPolicy(draft.toBackendPolicy());
      agentWorkspaceSetLocalizedStatusMessage(
        '默认编排策略已保存。',
        'Default orchestration policy saved.',
      );
      statusCaption = 'Agent orchestration';
    } on OrchestratorClientException catch (error) {
      lastError = error.code;
      agentWorkspaceSetLocalizedStatusMessage(
        '默认编排策略保存失败。',
        'Failed to save the default orchestration policy.',
      );
      statusCaption = 'Agent orchestration';
      agentWorkspaceNotifyStateChanged();
      rethrow;
    }
  }

  Future<OrchestratorPolicyProjection> saveOrchestrationPolicy(
    Map<String, Object?> policy,
  ) async {
    final next = Map<String, Object?>.unmodifiable(policy);
    final policyId = (next['id'] ?? '').toString().trim();
    if (policyId.isEmpty) {
      throw const OrchestratorClientException(code: 'policy_schema_invalid');
    }
    final NativeOrchestratorClient client = orchestratorClient;
    final registered = await client.registerPolicy(
      policy: next,
      idempotencyKey: 'policy-register-$policyId',
    );
    final activated = await client.activatePolicy(
      policyRevision: registered.policyRevision,
      idempotencyKey: 'policy-activate-${registered.policyRevision}',
    );
    orchestrationPolicyDraft = next;
    activeOrchestrationPolicyRevision = activated.policyRevision;
    agentWorkspaceNotifyStateChanged();
    return activated;
  }

  void resetAgentOrchestrationCircuitBreakers() {
    // Circuit breakers are owned by the native orchestrator; the GUI no longer
    // keeps a local breaker registry.
  }
}
