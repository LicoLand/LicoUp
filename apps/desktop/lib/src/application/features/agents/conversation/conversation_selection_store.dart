import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/application/features/agents/agent_product_names.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_target_catalog.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Owns the selected target/session and per-tab presentation state without
/// depending on catalog loading, dispatch, or refresh scheduling.
mixin ConversationSelectionStore on AgentWorkspaceCoordinator {
  @override
  TargetCandidate? get selectedConversationAgent {
    if (selectedConversationIsOrchestration) {
      return agentOrchestrationTargetCandidate(
        label: agentWorkspaceStrings.defaultLabel,
      );
    }
    for (final target in scannedTargets) {
      if (target.target == selectedConversationAgentId) {
        return target;
      }
    }
    return null;
  }

  @override
  List<AgentConversationSession> get selectedConversationSessions =>
      conversationSessionsByAgent[selectedConversationAgentId] ?? const [];

  bool get selectedConversationSessionsHasMore =>
      conversationSessionsHasMoreByAgent[selectedConversationAgentId] ?? false;

  bool get isLoadingMoreSelectedConversationSessions =>
      conversationSessionLoadMoreTargets.contains(selectedConversationAgentId);

  @override
  AgentConversationTabActivity conversationTabActivityFor(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return AgentConversationTabActivity.none;
    }
    return conversationTabActivityByAgent[normalized] ??
        AgentConversationTabActivity.none;
  }

  @override
  void setConversationTabActivity(
    String agentId,
    AgentConversationTabActivity activity,
  ) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return;
    }
    final current =
        conversationTabActivityByAgent[normalized] ??
        AgentConversationTabActivity.none;
    if (current == activity) {
      if (activity != AgentConversationTabActivity.none ||
          !conversationTabActivityByAgent.containsKey(normalized)) {
        return;
      }
    }
    final next = <String, AgentConversationTabActivity>{
      ...conversationTabActivityByAgent,
    };
    if (activity == AgentConversationTabActivity.none) {
      next.remove(normalized);
    } else {
      next[normalized] = activity;
    }
    conversationTabActivityByAgent = Map.unmodifiable(next);
  }

  /// Clears unread completion when the user opens that agent tab. Approval
  /// state remains until the next send resolves it.
  @override
  void acknowledgeConversationTabWorkFinished(String agentId) {
    if (conversationTabActivityFor(agentId) ==
        AgentConversationTabActivity.workFinished) {
      setConversationTabActivity(agentId, AgentConversationTabActivity.none);
    }
  }

  @override
  void recordConversationTabSendOutcome({
    required String agentId,
    required bool ok,
    Map<String, dynamic> result = const <String, dynamic>{},
    String failureCode = '',
  }) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return;
    }
    if (ok) {
      _setConversationSendError(normalized, '');
      setConversationTabActivity(
        normalized,
        AgentConversationTabActivity.workFinished,
      );
      return;
    }
    final code = failureCode.trim().isNotEmpty
        ? failureCode.trim()
        : runtimeAdapterFailureCode(result);
    _setConversationSendError(normalized, code);
    final needsApproval =
        agentConversationResultNeedsApproval(result) ||
        code.toLowerCase().contains('user_interaction');
    setConversationTabActivity(
      normalized,
      needsApproval
          ? AgentConversationTabActivity.needsApproval
          : AgentConversationTabActivity.none,
    );
  }

  @override
  String conversationSendErrorFor(String agentId) =>
      (conversationSendErrorsByAgent[agentId.trim()] ?? '').trim();

  @override
  void clearConversationSendError(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return;
    }
    _setConversationSendError(normalized, '');
  }

  void _setConversationSendError(String agentId, String errorCode) {
    final next = <String, String>{...conversationSendErrorsByAgent};
    final normalizedCode = errorCode.trim();
    if (normalizedCode.isEmpty) {
      next.remove(agentId);
    } else {
      next[agentId] = normalizedCode;
    }
    conversationSendErrorsByAgent = Map.unmodifiable(next);
  }

  @override
  String get selectedConversationModel =>
      (conversationModelsByAgent[selectedConversationAgentId] ?? '').trim();

  /// The model the agent falls back to when no explicit model is selected,
  /// as discovered from the agent's own configuration. Empty when unknown.
  String get selectedConversationDefaultModel {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return '';
    }
    return (agent.modelCatalog['defaultModel'] ?? '').toString().trim();
  }

  @override
  String get selectedConversationReasoningEffort =>
      (conversationReasoningEffortsByAgent[selectedConversationAgentId] ?? '')
          .trim();

  List<String> get selectedConversationModelOptions {
    final agent = selectedConversationAgent;
    if (agent == null) return const [];
    final models = agent.modelCatalog['models'];
    if (models is! List) return const [];
    return List<String>.unmodifiable([
      for (final model in models)
        if (model is Map && (model['name'] ?? '').toString().trim().isNotEmpty)
          (model['name'] ?? '').toString().trim(),
    ]);
  }

  /// The model the conversation actually runs on: the explicit selection, or
  /// the agent's own discovered default when the selection is left on Auto.
  String get selectedConversationEffectiveModel {
    final selected = selectedConversationModel;
    return selected.isNotEmpty ? selected : selectedConversationDefaultModel;
  }

  /// Reasoning-effort catalog for the effective model. Model and effort are
  /// independent first-class runtime controls, so an Auto model selection still
  /// resolves the efforts the agent would actually run with.
  List<String> get selectedConversationReasoningEffortOptions {
    final agent = selectedConversationAgent;
    if (agent == null) return const [];
    return agentOrchestrationReasoningEffortsForModel(
      agent,
      selectedConversationEffectiveModel,
    );
  }

  void selectConversationModel(String model) {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return;
    }
    final normalized = model.trim();
    if (normalized.isNotEmpty &&
        !selectedConversationModelOptions.contains(normalized)) {
      lastError = 'native_agent_model_not_discovered';
      agentWorkspaceNotifyActiveConversationChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }
    conversationModelsByAgent = {
      ...conversationModelsByAgent,
      agent.target: normalized,
    };
    final reasoning = selectedConversationReasoningEffort;
    if (reasoning.isNotEmpty &&
        !selectedConversationReasoningEffortOptions.contains(reasoning)) {
      conversationReasoningEffortsByAgent = {
        ...conversationReasoningEffortsByAgent,
        agent.target: '',
      };
    }
    lastError = '';
    agentWorkspaceNotifyActiveConversationChanged();
    agentWorkspaceNotifyStateChanged();
  }

  void selectConversationReasoningEffort(String reasoningEffort) {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return;
    }
    final normalized = reasoningEffort.trim();
    if (normalized.isNotEmpty &&
        !selectedConversationReasoningEffortOptions.contains(normalized)) {
      lastError = 'native_agent_reasoning_effort_not_discovered';
      agentWorkspaceNotifyActiveConversationChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }
    conversationReasoningEffortsByAgent = {
      ...conversationReasoningEffortsByAgent,
      agent.target: normalized,
    };
    lastError = '';
    agentWorkspaceNotifyActiveConversationChanged();
    agentWorkspaceNotifyStateChanged();
  }

  /// Lico Agent profile for the selected conversation (`base` or `plan`).
  /// Empty means the runtime default (base).
  @override
  String get selectedConversationLicoProfile {
    final agent = selectedConversationAgent;
    if (agent == null || agentProductId(agent.target) != 'lico-agent') {
      return '';
    }
    final stored = (conversationLicoProfilesByAgent[agent.target] ?? '').trim();
    return stored == 'plan' ? 'plan' : 'base';
  }

  bool get selectedConversationSupportsLicoProfile =>
      selectedConversationAgent != null &&
      agentProductId(selectedConversationAgent!.target) == 'lico-agent';

  void selectConversationLicoProfile(String profile) {
    final agent = selectedConversationAgent;
    if (agent == null || agentProductId(agent.target) != 'lico-agent') {
      return;
    }
    final normalized = profile.trim().toLowerCase() == 'plan' ? 'plan' : 'base';
    conversationLicoProfilesByAgent = {
      ...conversationLicoProfilesByAgent,
      agent.target: normalized,
    };
    if (normalized == 'plan') {
      unawaited(_ensureActivePlanDocument());
    }
    lastError = '';
    agentWorkspaceNotifyActiveConversationChanged();
    agentWorkspaceNotifyStateChanged();
  }

  Future<void> _ensureActivePlanDocument() async {
    try {
      final portable = agentWorkspacePortableData;
      if (portable is! PortableDataRoot) return;
      final clientDir = await portable.clientDirectory();
      final plansDir = Directory(p.join(clientDir.path, 'plans'));
      await plansDir.create(recursive: true);
      final file = File(p.join(plansDir.path, 'active-plan.md'));
      if (!await file.exists()) {
        await file.writeAsString('');
      }
    } catch (_) {
      // Optional plan file must not block profile selection.
    }
  }

  @override
  AgentConversationSession? get selectedConversationSession {
    if (preparingNewConversation) {
      return null;
    }
    final selectedId = selectedConversationSessionId.trim();
    if (selectedId.isNotEmpty) {
      for (final session in selectedConversationSessions) {
        if (session.id == selectedId) {
          return session;
        }
      }
      return null;
    }
    return selectedConversationSessions.isNotEmpty
        ? selectedConversationSessions.first
        : null;
  }
}
