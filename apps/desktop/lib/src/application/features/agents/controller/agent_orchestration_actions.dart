part of 'package:flutter_client/src/application/controller/future_client_controller.dart';

extension FutureClientAgentOrchestrationActions on FutureClientController {
  bool get selectedConversationIsOrchestration =>
      isAgentOrchestrationTargetId(selectedConversationAgentId);

  List<TargetCandidate> get orchestrationAvailableTargets {
    return scannedTargets
        .where((target) => target.isConversationAgent && target.canRelayRuntime)
        .toList(growable: false);
  }

  List<AgentOrchestrationPolicy> get agentOrchestrationPolicies {
    return [effectiveAgentOrchestrationPolicy];
  }

  AgentOrchestrationPolicy get effectiveAgentOrchestrationPolicy {
    return normalizeAgentOrchestrationPolicy(
      scannedTargets,
      agentOrchestrationPolicy,
    );
  }

  bool get agentOrchestrationPolicyConfigured {
    return effectiveAgentOrchestrationPolicy.configured;
  }

  List<String> get effectiveAgentOrchestrationSelectedAgentIds {
    final policy = effectiveAgentOrchestrationPolicy;
    final rule = selectAgentOrchestrationRule(
      targets: scannedTargets,
      policy: policy,
      prompt: '',
    );
    if (rule == null) {
      return const [];
    }
    return agentOrchestrationRuleEntries(
      rule,
      agentOrchestrationDispatchModelLibrary(policy),
      fillDefaults: false,
    ).map((entry) => entry.agentId).toSet().toList(growable: false);
  }

  String get effectiveAgentOrchestrationPrimaryAgentId {
    final policy = effectiveAgentOrchestrationPolicy;
    final rule = selectAgentOrchestrationRule(
      targets: scannedTargets,
      policy: policy,
      prompt: '',
    );
    if (rule == null) {
      return '';
    }
    final entries = agentOrchestrationRuleEntries(
      rule,
      agentOrchestrationDispatchModelLibrary(policy),
      fillDefaults: false,
    );
    return entries.isEmpty ? '' : entries.first.agentId;
  }

  String agentOrchestrationPolicyDisplayLabel(AgentOrchestrationPolicy policy) {
    final base = policy.label.trim().isEmpty
        ? _strings.defaultPolicy
        : policy.label.trim();
    return policy.configured ? base : '$base (${_strings.notConfigured})';
  }

  void selectAgentOrchestrationPolicy(String policyId) {
    if (policyId.trim() == agentOrchestrationPolicy.id) {
      return;
    }
    _setLocalizedStatusMessage(
      '当前仅内置默认策略。',
      'Only the default policy is currently available.',
    );
    statusCaption = 'Agent orchestration';
    _notifyStateChanged();
  }

  Future<void> saveAgentOrchestrationPolicy(
    AgentOrchestrationPolicy policy,
  ) async {
    agentOrchestrationPolicy = normalizeAgentOrchestrationPolicy(
      scannedTargets,
      policy.copyWith(
        id: policy.id.trim().isEmpty
            ? defaultAgentOrchestrationPolicyId
            : policy.id.trim(),
        label: policy.label.trim().isEmpty
            ? _strings.defaultPolicy
            : policy.label.trim(),
      ),
    );
    final selected = {
      for (final rule in agentOrchestrationPolicy.rules)
        for (final entry in agentOrchestrationRuleEntries(
          rule,
          agentOrchestrationDispatchModelLibrary(agentOrchestrationPolicy),
          fillDefaults: false,
        ))
          entry.agentId,
      for (final entry in agentOrchestrationDispatchModelLibrary(
        agentOrchestrationPolicy,
      ))
        entry.agentId,
    };
    agentOrchestrationCircuitBrokenAgentIds =
        agentOrchestrationCircuitBrokenAgentIds
            .where(selected.contains)
            .toSet();
    _setLocalizedStatusMessage(
      '正在保存默认编排策略。',
      'Saving the default orchestration policy.',
    );
    statusCaption = 'Agent orchestration';
    _ensureOrchestrationConversationSession();
    _notifyStateChanged();
    try {
      await agentOrchestrationPolicyStore.save(
        portableData,
        agentOrchestrationPolicy,
      );
      _setLocalizedStatusMessage(
        agentOrchestrationPolicy.configured ? '默认编排策略已保存。' : '默认编排策略已清空。',
        agentOrchestrationPolicy.configured
            ? 'Default orchestration policy saved.'
            : 'Default orchestration policy cleared.',
      );
      statusCaption = 'Agent orchestration';
    } catch (error) {
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '默认编排策略保存失败。',
        'Failed to save the default orchestration policy.',
      );
      statusCaption = 'Agent orchestration';
    } finally {
      _notifyStateChanged();
    }
  }

  AgentOrchestrationRule createAgentOrchestrationDraftRule({
    AgentOrchestrationStrategy strategy = AgentOrchestrationStrategy.fallback,
  }) {
    final policy = effectiveAgentOrchestrationPolicy;
    return defaultAgentOrchestrationRule(
      scannedTargets,
      strategy: strategy,
      modelLibrary: agentOrchestrationDispatchModelLibrary(policy),
    );
  }

  void resetAgentOrchestrationCircuitBreakers() {
    if (agentOrchestrationCircuitBrokenAgentIds.isEmpty) {
      return;
    }
    agentOrchestrationCircuitBrokenAgentIds = const {};
    _setLocalizedStatusMessage(
      '已重置默认编排链路熔断状态。',
      'Reset the default orchestration circuit breakers.',
    );
    statusCaption = 'Agent orchestration';
    _notifyStateChanged();
  }

  AgentDispatchPlan previewAgentDispatchPlan(String prompt) {
    final policy = effectiveAgentOrchestrationPolicy;
    return resolveAgentDispatchPlan(
      targets: scannedTargets,
      rule: selectAgentOrchestrationRule(
        targets: scannedTargets,
        policy: policy,
        prompt: prompt,
      ),
      prompt: prompt,
      modelLibrary: agentOrchestrationDispatchModelLibrary(policy),
      usageReport: agentUsageReport,
      allowanceOverrides: agentAllowanceOverrides,
      circuitBrokenAgentIds: agentOrchestrationCircuitBrokenAgentIds,
    );
  }

  void _syncAgentOrchestrationPolicy() {
    agentOrchestrationPolicy = normalizeAgentOrchestrationPolicy(
      scannedTargets,
      agentOrchestrationPolicy,
    );
    final selected = {
      for (final rule in agentOrchestrationPolicy.rules)
        for (final entry in agentOrchestrationRuleEntries(
          rule,
          agentOrchestrationDispatchModelLibrary(agentOrchestrationPolicy),
          fillDefaults: false,
        ))
          entry.agentId,
      for (final entry in agentOrchestrationDispatchModelLibrary(
        agentOrchestrationPolicy,
      ))
        entry.agentId,
    };
    agentOrchestrationCircuitBrokenAgentIds =
        agentOrchestrationCircuitBrokenAgentIds
            .where(selected.contains)
            .toSet();
  }

  void _ensureOrchestrationConversationSession() {
    if (!selectedConversationIsOrchestration) {
      return;
    }
    final existing =
        conversationSessionsByAgent[agentOrchestrationTargetId] ?? const [];
    if (existing.isNotEmpty) {
      selectedConversationSessionId =
          selectedConversationSessionId.trim().isEmpty
          ? existing.first.id
          : selectedConversationSessionId;
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final session = AgentConversationSession(
      id: 'default-orchestration-${DateTime.now().toUtc().microsecondsSinceEpoch}',
      agentId: agentOrchestrationTargetId,
      title: '默认智能体编排',
      createdAt: now,
      updatedAt: now,
      adapterId: 'lico-local-orchestrator',
      sourceKind: 'local-orchestration',
      native: false,
      readOnly: false,
      messageCount: 0,
      messages: const [],
    );
    conversationSessionsByAgent = {
      ...conversationSessionsByAgent,
      agentOrchestrationTargetId: [session],
    };
    selectedConversationSessionId = session.id;
  }

  Future<void> _sendOrchestratedConversationMessage(String text) async {
    if (!agentOrchestrationPolicyConfigured) {
      lastError = 'default orchestration policy not configured';
      _setLocalizedStatusMessage(
        '默认编排策略未配置，请先编辑策略。',
        'Configure the default orchestration policy before sending.',
      );
      statusCaption = 'Agent orchestration';
      _notifyStateChanged();
      return;
    }
    isSendingConversationMessage = true;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在按默认编排策略分发消息。',
      'Dispatching the message with the default orchestration policy.',
    );
    statusCaption = 'Agent orchestration';
    _notifyStateChanged();

    final plan = previewAgentDispatchPlan(text);
    final outcomes = <_AgentDispatchOutcome>[];
    final newlyCircuitBroken = <String>{};

    try {
      if (plan.blocked) {
        newlyCircuitBroken.addAll(
          plan.skipped
              .where((skip) => skip.circuitBroken)
              .map((skip) => skip.agentId),
        );
        agentOrchestrationCircuitBrokenAgentIds = {
          ...agentOrchestrationCircuitBrokenAgentIds,
          ...newlyCircuitBroken,
        };
        _appendOrchestrationConversationMessages(
          userText: text,
          plan: plan,
          outcomes: outcomes,
          skipped: plan.skipped,
        );
        lastError = 'default orchestration dispatch blocked';
        _setLocalizedStatusMessage(
          '默认编排无可用链路，已回传熔断状态。',
          'No default orchestration route is available; circuit-breaker status was returned.',
        );
        statusCaption = 'Agent orchestration';
        return;
      }

      for (final route in plan.routes) {
        _setLocalizedStatusMessage(
          '正在分发给 ${route.agentLabel}（${route.role}，优先级 ${route.priority}）。',
          'Dispatching to ${route.agentLabel} (${route.role}, priority ${route.priority}).',
        );
        _notifyStateChanged();
        try {
          final target = scannedTargets.where(
            (candidate) => candidate.target == route.agentId,
          );
          final readiness = target.isEmpty
              ? 'unverified'
              : target.first.conversationReadiness;
          final result = (await conversationService.send(
            runner: agentService,
            agentId: route.agentId,
            text: _dispatchPromptForRoute(
              plan: plan,
              route: route,
              userText: text,
            ),
            sessionId: '',
            bind: AgentDispatchBind(
              model: route.modelName,
              reasoningEffort: route.reasoningEffort,
              binaryPath: target.isEmpty ? '' : target.first.binaryPath ?? '',
            ),
            conversationReadiness: readiness,
          )).raw;
          final ok = result['ok'] == true;
          outcomes.add(
            _AgentDispatchOutcome(
              route: route,
              ok: ok,
              status: ok ? 'sent' : 'failed',
            ),
          );
          if (!ok) {
            newlyCircuitBroken.add(route.agentId);
          }
          if (plan.strategy == AgentOrchestrationStrategy.fallback && ok) {
            break;
          }
        } catch (error) {
          debugPrint('Failed to dispatch orchestrated message: $error');
          newlyCircuitBroken.add(route.agentId);
          outcomes.add(
            _AgentDispatchOutcome(route: route, ok: false, status: 'failed'),
          );
        }
      }

      agentOrchestrationCircuitBrokenAgentIds = {
        ...agentOrchestrationCircuitBrokenAgentIds,
        ...newlyCircuitBroken,
        ...plan.skipped
            .where((skip) => skip.circuitBroken)
            .map((skip) => skip.agentId),
      };
      _appendOrchestrationConversationMessages(
        userText: text,
        plan: plan,
        outcomes: outcomes,
        skipped: plan.skipped,
      );
      final okCount = outcomes.where((outcome) => outcome.ok).length;
      if (okCount == 0) {
        lastError = 'default orchestration dispatch failed';
        _setLocalizedStatusMessage(
          '默认编排分发失败，后续链路已熔断或降级。',
          'Default orchestration dispatch failed; subsequent routes were circuit-broken or degraded.',
        );
      } else if (newlyCircuitBroken.isNotEmpty || plan.skipped.isNotEmpty) {
        _setLocalizedStatusMessage(
          '默认编排已分发 $okCount 条，部分链路已降级或熔断。',
          'Default orchestration dispatched $okCount routes; some routes were degraded or circuit-broken.',
        );
      } else {
        _setLocalizedStatusMessage(
          '默认编排已分发 $okCount 条链路。',
          'Default orchestration dispatched $okCount routes.',
        );
      }
      statusCaption = 'Agent orchestration';
    } finally {
      isSendingConversationMessage = false;
      _notifyStateChanged();
    }
  }

  void _appendOrchestrationConversationMessages({
    required String userText,
    required AgentDispatchPlan plan,
    required List<_AgentDispatchOutcome> outcomes,
    required List<AgentDispatchSkip> skipped,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final previous =
        conversationSessionsByAgent[agentOrchestrationTargetId] ?? const [];
    final selectedSession = _preparingNewConversation
        ? null
        : selectedConversationSession;
    final existing = selectedSession?.agentId == agentOrchestrationTargetId
        ? selectedSession
        : previous.isNotEmpty
        ? previous.first
        : null;
    final sessionId =
        existing?.id ??
        'default-orchestration-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final messages = <AgentConversationMessage>[
      ...?existing?.messages,
      AgentConversationMessage(
        id: 'orchestration-user-${DateTime.now().toUtc().microsecondsSinceEpoch}',
        role: 'user',
        text: userText,
        createdAt: now,
      ),
      AgentConversationMessage(
        id: 'orchestration-status-${DateTime.now().toUtc().microsecondsSinceEpoch}',
        role: 'agent',
        text: _orchestrationStatusMessage(
          plan: plan,
          outcomes: outcomes,
          skipped: skipped,
        ),
        createdAt: now,
      ),
    ];
    final session = AgentConversationSession(
      id: sessionId,
      nativeSessionId: sessionId,
      agentId: agentOrchestrationTargetId,
      title: _orchestrationSessionTitle(userText, existing),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      adapterId: 'lico-local-orchestrator',
      sourceKind: 'local-orchestration',
      native: false,
      readOnly: false,
      messageCount: messages.length,
      messages: List.unmodifiable(messages),
    );
    conversationSessionsByAgent = {
      ...conversationSessionsByAgent,
      agentOrchestrationTargetId: _insertConversationSessionByUpdatedAt(
        previous.where((item) => item.id != session.id).toList(growable: false),
        session,
      ),
    };
    selectedConversationSessionId = session.id;
    _preparingNewConversation = false;
  }

  String _dispatchPromptForRoute({
    required AgentDispatchPlan plan,
    required AgentDispatchRoute route,
    required String userText,
  }) {
    final strategy = _strategyStatusLabel(plan.strategy);
    final policy = effectiveAgentOrchestrationPolicy;
    final commander = _orchestrationCommanderStatus(policy);
    final peers = plan.routes
        .map((item) {
          final model = _routeModelStatus(item);
          final reasoning = _reasoningEffortStatusLabel(item.reasoningEffort);
          return '- ${item.agentLabel}$model / 思考强度：$reasoning: ${item.role}, 优先级 ${item.priority}';
        })
        .join('\n');
    final coordinator = route.coordinator
        ? '你是主智能体，负责统筹任务和合并结果。'
        : '你是被主智能体调度的工作智能体，只处理分配给你的角色。';
    return '''
你位于 Lico Arc 默认多智能体编排链路中。
策略：$strategy
指挥官：$commander
当前角色：${route.role}
优先级：${route.priority}
模型：${_routeModelStatus(route).isEmpty ? '未指定' : _routeModelStatus(route).substring(3)}
思考强度：${_reasoningEffortStatusLabel(route.reasoningEffort)}
$coordinator

本次链路：
$peers

原始请求：
$userText
''';
  }

  String _orchestrationCommanderStatus(AgentOrchestrationPolicy policy) {
    if (policy.commanderAgentId.trim().isEmpty) {
      return '未指定';
    }
    var label = policy.commanderAgentId;
    for (final target in scannedTargets) {
      if (target.target == policy.commanderAgentId) {
        label = target.label;
        break;
      }
    }
    final model = policy.commanderModelName.trim();
    final modelLabel = _modelDisplayNameFor(policy.commanderAgentId, model);
    final reasoning = _reasoningEffortStatusLabel(
      policy.commanderReasoningEffort,
    );
    if (modelLabel.isEmpty) {
      return label;
    }
    return policy.commanderReasoningEffort.trim().isEmpty
        ? '$label / $modelLabel'
        : '$label / $modelLabel / 思考强度：$reasoning';
  }

  String _orchestrationStatusMessage({
    required AgentDispatchPlan plan,
    required List<_AgentDispatchOutcome> outcomes,
    required List<AgentDispatchSkip> skipped,
  }) {
    final buffer = StringBuffer()
      ..writeln('策略：${_strategyStatusLabel(plan.strategy)}')
      ..writeln(
        '主智能体：${plan.primaryAgentId.isEmpty ? '未就绪' : plan.primaryAgentId}',
      )
      ..writeln();
    if (outcomes.isNotEmpty) {
      buffer.writeln('分发结果：');
      for (final outcome in outcomes) {
        final model = _routeModelStatus(outcome.route);
        final reasoning = _reasoningEffortStatusLabel(
          outcome.route.reasoningEffort,
        );
        final state = outcome.ok ? '已发送' : '失败，后续熔断';
        buffer.writeln(
          '- ${outcome.route.agentLabel}$model · 思考强度：$reasoning · ${outcome.route.role} · $state',
        );
      }
      buffer.writeln();
    }
    if (skipped.isNotEmpty) {
      buffer.writeln('降级/熔断：');
      for (final skip in skipped) {
        buffer.writeln(
          '- ${skip.agentLabel}: ${_skipReasonLabel(skip.reason)}',
        );
      }
      buffer.writeln();
    }
    if (outcomes.isEmpty && skipped.isEmpty) {
      buffer.writeln('没有可用智能体路线。');
    }
    return buffer.toString().trim();
  }

  String _orchestrationSessionTitle(
    String userText,
    AgentConversationSession? existing,
  ) {
    if (existing != null &&
        existing.messages.isNotEmpty &&
        existing.title.trim().isNotEmpty) {
      return existing.title;
    }
    final compact = userText
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .characters
        .take(36)
        .toString();
    return compact.isEmpty ? '默认智能体编排' : compact;
  }

  String _strategyStatusLabel(AgentOrchestrationStrategy strategy) {
    return switch (strategy) {
      AgentOrchestrationStrategy.fallback => '顺序降级',
      AgentOrchestrationStrategy.dynamicAllocation => '动态分配',
    };
  }

  String _skipReasonLabel(String reason) {
    return switch (reason) {
      'quota-insufficient' => '额度不足，已跳过并熔断',
      'circuit-open' => '熔断中，已跳过',
      'model-library-excluded' => '不在模型库中，已跳过',
      _ => '不可用，已跳过',
    };
  }

  String _routeModelStatus(AgentDispatchRoute route) {
    final model = route.modelName.trim().isNotEmpty
        ? route.modelName.trim()
        : route.modelHint.trim();
    final modelLabel = _modelDisplayNameFor(route.agentId, model);
    return modelLabel.isEmpty ? '' : ' / $modelLabel';
  }

  String _modelDisplayNameFor(String agentId, String modelName) {
    final normalized = modelName.trim();
    if (normalized.isEmpty) {
      return '';
    }
    for (final target in scannedTargets) {
      if (target.target == agentId) {
        return agentOrchestrationModelDisplayName(target, normalized);
      }
    }
    return normalized;
  }

  String _reasoningEffortStatusLabel(String value) {
    return switch (value.trim().toLowerCase()) {
      '' => '未指定',
      'low' => '低',
      'medium' => '中',
      'high' => '高',
      _ => value.trim(),
    };
  }
}

class _AgentDispatchOutcome {
  const _AgentDispatchOutcome({
    required this.route,
    required this.ok,
    required this.status,
  });

  final AgentDispatchRoute route;
  final bool ok;
  final String status;
}
