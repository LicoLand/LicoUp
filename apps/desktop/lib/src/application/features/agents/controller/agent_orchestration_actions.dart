part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientAgentOrchestrationActions on ClientController {
  bool get routingModuleIncluded => kRoutingModuleIncluded;

  bool get routingModuleAvailable =>
      kRoutingModuleIncluded && (_routingModule?.isEnabled ?? true);

  bool get selectedConversationIsOrchestration =>
      routingModuleAvailable &&
      isAgentOrchestrationTargetId(selectedConversationAgentId);

  Set<String> get agentOrchestrationOpenCircuitAgentIds {
    final breaker = (_routingModule?.activePolicy ?? emptyRoutingPolicyDocument)
        .routing
        .circuitBreaker;
    final now = DateTime.now().toUtc();
    return Set.unmodifiable({
      for (final entry in agentOrchestrationCircuitStates.entries)
        if (entry.value.isOpen(
          allowedFails: breaker.allowedFails,
          cooldown: Duration(seconds: breaker.cooldownSeconds),
          now: now,
        ))
          entry.key,
    });
  }

  List<TargetCandidate> get orchestrationAvailableTargets {
    if (!routingModuleAvailable) {
      return const [];
    }
    return scannedTargets
        .where((target) => target.isConversationAgent && target.canRelayRuntime)
        .toList(growable: false);
  }

  List<AgentOrchestrationPolicy> get agentOrchestrationPolicies {
    if (!routingModuleAvailable) {
      return const [];
    }
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
    return agentOrchestrationDispatchModelLibrary(
      policy,
    ).map((entry) => entry.agentId).toSet().toList(growable: false);
  }

  String get effectiveAgentOrchestrationPrimaryAgentId {
    final entries = agentOrchestrationDispatchModelLibrary(
      effectiveAgentOrchestrationPolicy,
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
            ? _strings.defaultPolicy
            : policy.label.trim(),
      ),
    );
    final selected = {
      for (final entry in agentOrchestrationDispatchModelLibrary(
        agentOrchestrationPolicy,
      ))
        entry.agentId,
    };
    agentOrchestrationCircuitStates = Map.unmodifiable({
      for (final entry in agentOrchestrationCircuitStates.entries)
        if (selected.contains(entry.key)) entry.key: entry.value,
    });
    _setLocalizedStatusMessage(
      '正在保存默认编排策略。',
      'Saving the default orchestration policy.',
    );
    statusCaption = 'Agent orchestration';
    _ensureOrchestrationConversationSession();
    _notifyStateChanged();
    try {
      final editedPolicy = agentOrchestrationPolicy;
      final routingModule = await _ensureRoutingModuleReady();
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
      // Store and registration events cross two asynchronous broadcast
      // streams. Drain them before queuing the authoritative post-save
      // snapshot so an older event cannot overwrite the next message boundary.
      await Future<void>.delayed(Duration.zero);
      final taskId = _activeOrchestrationTaskId;
      final coordinator = routingModule.coordinator;
      if (taskId.isNotEmpty && coordinator?.sessionFor(taskId) != null) {
        coordinator!.queuePolicy(routingModule.activePolicy);
      }
      agentOrchestrationPolicy = editedPolicy;
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

  void resetAgentOrchestrationCircuitBreakers() {
    if (!routingModuleAvailable) {
      return;
    }
    if (agentOrchestrationCircuitStates.isEmpty) {
      return;
    }
    agentOrchestrationCircuitStates = const {};
    _setLocalizedStatusMessage(
      '已重置默认编排链路熔断状态。',
      'Reset the default orchestration circuit breakers.',
    );
    statusCaption = 'Agent orchestration';
    _notifyStateChanged();
  }

  bool _recordOrchestrationRouteFailure(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return false;
    }
    final breaker = (_routingModule?.activePolicy ?? emptyRoutingPolicyDocument)
        .routing
        .circuitBreaker;
    final now = DateTime.now().toUtc();
    final previous =
        agentOrchestrationCircuitStates[normalized] ??
        const RoutingCircuitBreakerState();
    final failedAt = previous.lastFailureAt;
    final cooldown = Duration(seconds: breaker.cooldownSeconds);
    final expired =
        previous.failureCount > breaker.allowedFails &&
        failedAt != null &&
        !now.isBefore(failedAt.toUtc().add(cooldown));
    final next = (expired ? const RoutingCircuitBreakerState() : previous)
        .recordFailure(now);
    agentOrchestrationCircuitStates = Map.unmodifiable({
      ...agentOrchestrationCircuitStates,
      normalized: next,
    });
    return next.isOpen(
      allowedFails: breaker.allowedFails,
      cooldown: cooldown,
      now: now,
    );
  }

  void _recordOrchestrationRouteSuccess(String agentId) {
    final normalized = agentId.trim();
    if (!agentOrchestrationCircuitStates.containsKey(normalized)) {
      return;
    }
    agentOrchestrationCircuitStates = Map.unmodifiable({
      for (final entry in agentOrchestrationCircuitStates.entries)
        if (entry.key != normalized) entry.key: entry.value,
    });
  }

  RoutingDispatchPlan previewRoutingDispatchPlan(
    String prompt, {
    RoutingPolicyDocument? policySnapshot,
  }) {
    final routingPolicy =
        policySnapshot ??
        _routingModule?.activePolicy ??
        emptyRoutingPolicyDocument;
    return planRoutingDispatch(
      targets: scannedTargets,
      policy: routingPolicy,
      task: RoutingTaskMetadata(prompt: prompt),
      usageReport: agentUsageReport,
      allowanceOverrides: agentAllowanceOverrides,
      circuitBreakerStates: agentOrchestrationCircuitStates,
    );
  }

  /// Production runtime toggle for the optional routing module.
  ///
  /// Direct single-agent dispatch does not depend on this registration and
  /// remains available while routing is disabled.
  Future<void> setRoutingModuleEnabled(bool enabled) async {
    if (!kRoutingModuleIncluded) {
      return;
    }
    if (enabled) {
      final registration = _routingModule ?? await _ensureRoutingModuleReady();
      await registration.enable();
      _routingModule = registration;
      await _bindRoutingModulePolicyEvents(registration);
      agentOrchestrationPolicy = orchestrationEditorFromRoutingPolicy(
        registration.activePolicy,
      );
      _notifyStateChanged();
      return;
    }
    final wasOrchestration = isAgentOrchestrationTargetId(
      selectedConversationAgentId,
    );
    await _routingPolicySubscription?.cancel();
    _routingPolicySubscription = null;
    await _routingModule?.deactivate();
    agentOrchestrationPolicy = const AgentOrchestrationPolicy();
    agentOrchestrationCircuitStates = const {};
    if (wasOrchestration) {
      _selectDefaultConversationAgent(preferDirectAgent: true);
    }
    _notifyConversationStructureChanged();
    _notifyStateChanged();
  }

  /// Removes every module-owned setting and state artifact before a clean
  /// optional-module re-enable.
  Future<void> unloadRoutingModule() async {
    if (!kRoutingModuleIncluded) {
      return;
    }
    final wasOrchestration = isAgentOrchestrationTargetId(
      selectedConversationAgentId,
    );
    await _routingPolicySubscription?.cancel();
    _routingPolicySubscription = null;
    await _routingModule?.unload();
    agentOrchestrationPolicy = const AgentOrchestrationPolicy();
    agentOrchestrationCircuitStates = const {};
    conversationSessionsByAgent = Map.unmodifiable({
      for (final entry in conversationSessionsByAgent.entries)
        if (!isAgentOrchestrationTargetId(entry.key)) entry.key: entry.value,
    });
    if (wasOrchestration) {
      _selectDefaultConversationAgent(preferDirectAgent: true);
    }
    _notifyConversationStructureChanged();
    _notifyStateChanged();
  }

  void _syncAgentOrchestrationPolicy() {
    if (!routingModuleAvailable) {
      agentOrchestrationPolicy = const AgentOrchestrationPolicy();
      agentOrchestrationCircuitStates = const {};
      return;
    }
    agentOrchestrationPolicy = normalizeAgentOrchestrationPolicy(
      scannedTargets,
      agentOrchestrationPolicy,
    );
    final selected = {
      for (final entry in agentOrchestrationDispatchModelLibrary(
        agentOrchestrationPolicy,
      ))
        entry.agentId,
    };
    agentOrchestrationCircuitStates = Map.unmodifiable({
      for (final entry in agentOrchestrationCircuitStates.entries)
        if (selected.contains(entry.key)) entry.key: entry.value,
    });
  }

  void _ensureOrchestrationConversationSession() {
    if (!kRoutingModuleIncluded || !selectedConversationIsOrchestration) {
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

  String get _activeOrchestrationTaskId {
    final selected = selectedConversationSession;
    if (selected?.agentId == agentOrchestrationTargetId) {
      return selected!.id;
    }
    final sessions =
        conversationSessionsByAgent[agentOrchestrationTargetId] ?? const [];
    return sessions.isEmpty ? '' : sessions.first.id;
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
    sendingConversationSessionId = selectedConversationSession?.id.trim() ?? '';
    sendingConversationNativeSessionId =
        selectedConversationSession?.nativeSessionId.trim() ?? '';
    lastError = '';
    _setLocalizedStatusMessage(
      '正在按默认编排策略分发消息。',
      'Dispatching the message with the default orchestration policy.',
    );
    statusCaption = 'Agent orchestration';
    _notifyStateChanged();

    _ensureOrchestrationConversationSession();
    sendingConversationSessionId =
        selectedConversationSession?.id.trim() ?? sendingConversationSessionId;
    final routingModule = await _ensureRoutingModuleReady();
    final coordinator = routingModule.coordinator;
    final orchestrationSession = selectedConversationSession;
    if (coordinator == null || orchestrationSession == null) {
      lastError = 'routing module unavailable';
      _setLocalizedStatusMessage(
        '默认编排路由尚未就绪。',
        'The orchestration route is not ready.',
      );
      statusCaption = 'Agent orchestration';
      isSendingConversationMessage = false;
      sendingConversationSessionId = '';
      sendingConversationNativeSessionId = '';
      _notifyStateChanged();
      return;
    }
    final taskId = orchestrationSession.id;
    final pendingPolicy = coordinator.takeQueuedPolicy();
    final messagePolicy = pendingPolicy ?? routingModule.activePolicy;
    var plan = previewRoutingDispatchPlan(text, policySnapshot: messagePolicy);
    final outcomes = <_RoutingDispatchOutcome>[];
    final newlyCircuitBroken = <String>{};
    var orchestrationTurnId = '';

    try {
      if (plan.blocked) {
        orchestrationTurnId = _beginOrchestrationConversationTurn(text);
        _appendOrchestrationExecutionStatus(
          turnId: orchestrationTurnId,
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

      var routeSession = coordinator.sessionFor(taskId);
      if (routeSession != null) {
        await _evaluateOrchestrationRoutingBoundary(
          taskId: taskId,
          trigger: pendingPolicy == null ? 'message-boundary' : 'policy-reload',
          pendingUserText: text,
          policySnapshot: messagePolicy,
        );
        routeSession = coordinator.sessionFor(taskId);
        plan = previewRoutingDispatchPlan(text, policySnapshot: messagePolicy);
      }
      orchestrationTurnId = _beginOrchestrationConversationTurn(text);
      coordinator.setStreaming(taskId, true);

      if (const {
        'serial-all',
        'parallel-all',
        'coordinator-workers',
      }.contains(plan.strategy)) {
        Future<MapEntry<RoutingDispatchRoute, _OrchestrationRouteResult>>
        dispatchScheduled(
          RoutingDispatchRoute route, {
          String? scheduledText,
        }) async {
          final branchSessionId = coordinator.resumeSessionIdForAgent(
            taskId: taskId,
            agentId: route.agentId,
          );
          final result = await _dispatchOrchestrationRoute(
            route: route,
            plan: plan,
            text: scheduledText ?? text,
            sessionId: branchSessionId.isEmpty ? null : branchSessionId,
            orchestrationTurnId: orchestrationTurnId,
          );
          return MapEntry(route, result);
        }

        final scheduled =
            <MapEntry<RoutingDispatchRoute, _OrchestrationRouteResult>>[];
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
                final reply = entry.value.replyText
                    .trim()
                    .characters
                    .take(1200)
                    .toString();
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
            _RoutingDispatchOutcome(
              route: route,
              ok: result.turn.ok,
              status: result.turn.ok ? 'replied' : 'failed',
              replyText: result.replyText,
            ),
          );
          _recordConversationTabSendOutcome(
            agentId: route.agentId,
            ok: result.turn.ok,
            result: result.turn.raw,
            errorCode: result.turn.errorCode,
          );
          if (result.turn.ok && result.turn.sessionId.trim().isNotEmpty) {
            _recordOrchestrationRouteSuccess(route.agentId);
            coordinator.recordDispatchSession(
              taskId: taskId,
              agentId: route.agentId,
              sessionId: result.turn.sessionId,
            );
          } else if (_recordOrchestrationRouteFailure(route.agentId)) {
            newlyCircuitBroken.add(route.agentId);
          }
        }
      } else if (routeSession == null) {
        for (final route in plan.routes) {
          final result = await _dispatchOrchestrationRoute(
            route: route,
            plan: plan,
            text: text,
            orchestrationTurnId: orchestrationTurnId,
          );
          outcomes.add(
            _RoutingDispatchOutcome(
              route: route,
              ok: result.turn.ok,
              status: result.turn.ok ? 'replied' : 'failed',
              replyText: result.replyText,
            ),
          );
          _recordConversationTabSendOutcome(
            agentId: route.agentId,
            ok: result.turn.ok,
            result: result.turn.raw,
            errorCode: result.turn.errorCode,
          );
          if (result.turn.ok && result.turn.sessionId.trim().isNotEmpty) {
            _recordOrchestrationRouteSuccess(route.agentId);
            coordinator.recordDispatchSession(
              taskId: taskId,
              agentId: route.agentId,
              sessionId: result.turn.sessionId,
            );
            break;
          }
          if (_recordOrchestrationRouteFailure(route.agentId)) {
            newlyCircuitBroken.add(route.agentId);
          }
          if (plan.strategy != 'priority-fallback' ||
              _routingFailureDisposition(result.turn) !=
                  RoutingDispatchFailureDisposition.transientKnown) {
            break;
          }
        }
      } else {
        final route = _routingRouteForAgent(
          plan: plan,
          agentId: routeSession.currentAgentId,
        );
        final result = await _dispatchOrchestrationRoute(
          route: route,
          plan: plan,
          text: text,
          sessionId: routeSession.currentSessionId,
          orchestrationTurnId: orchestrationTurnId,
        );
        outcomes.add(
          _RoutingDispatchOutcome(
            route: route,
            ok: result.turn.ok,
            status: result.turn.ok ? 'replied' : 'failed',
            replyText: result.replyText,
          ),
        );
        _recordConversationTabSendOutcome(
          agentId: route.agentId,
          ok: result.turn.ok,
          result: result.turn.raw,
          errorCode: result.turn.errorCode,
        );
        if (result.turn.ok && result.turn.sessionId.trim().isNotEmpty) {
          _recordOrchestrationRouteSuccess(route.agentId);
          coordinator.recordDispatchSession(
            taskId: taskId,
            agentId: route.agentId,
            sessionId: result.turn.sessionId,
          );
        } else {
          if (_recordOrchestrationRouteFailure(route.agentId)) {
            newlyCircuitBroken.add(route.agentId);
          }
        }
      }
      final okCount = outcomes.where((outcome) => outcome.ok).length;
      if (okCount == 0 ||
          newlyCircuitBroken.isNotEmpty ||
          plan.skipped.isNotEmpty) {
        _appendOrchestrationExecutionStatus(
          turnId: orchestrationTurnId,
          plan: plan,
          outcomes: outcomes,
          skipped: plan.skipped,
        );
      }
      if (okCount > 0) {
        _recordConversationTabSendOutcome(
          agentId: agentOrchestrationTargetId,
          ok: true,
        );
      } else if (outcomes.any(
        (outcome) =>
            conversationTabActivityFor(outcome.route.agentId) ==
            AgentConversationTabActivity.needsApproval,
      )) {
        _setConversationTabActivity(
          agentOrchestrationTargetId,
          AgentConversationTabActivity.needsApproval,
        );
      } else {
        _setConversationTabActivity(
          agentOrchestrationTargetId,
          AgentConversationTabActivity.none,
        );
      }
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
      coordinator.setStreaming(taskId, false);
      isSendingConversationMessage = false;
      sendingConversationSessionId = '';
      sendingConversationNativeSessionId = '';
      _notifyStateChanged();
    }
  }

  Future<_OrchestrationRouteResult> _dispatchOrchestrationRoute({
    required RoutingDispatchRoute route,
    required RoutingDispatchPlan plan,
    required String text,
    required String orchestrationTurnId,
    String? sessionId,
  }) async {
    _setLocalizedStatusMessage(
      '正在分发给 ${route.agentLabel}（${route.role}，优先级 ${route.priority}）。',
      'Dispatching to ${route.agentLabel} (${route.role}, priority ${route.priority}).',
    );
    _notifyStateChanged();
    try {
      final target = _routingTarget(route.agentId);
      final bind = _routingBind(route.agentId, route: route);
      final opened = sessionId == null
          ? await conversationService.openOrResume(
              runner: agentService,
              agentId: route.agentId,
              bind: bind,
            )
          : await conversationService.openOrResume(
              runner: agentService,
              agentId: route.agentId,
              sessionId: sessionId,
              bind: bind,
            );
      var replyText = '';
      AgentDispatchTurnResult? turn;
      final assistantMessageId = '$orchestrationTurnId-${route.agentId}';
      await for (final event in conversationService.sendStreaming(
        runner: agentService,
        agentId: route.agentId,
        text: _dispatchPromptForRoute(plan: plan, route: route, userText: text),
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
                : _mergeOrchestrationProgressiveText(replyText, chunk);
            _upsertOrchestrationAssistantReply(
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
          final terminalText = _routingTurnText(raw);
          if (terminalText.isNotEmpty) {
            replyText = terminalText;
            _upsertOrchestrationAssistantReply(
              messageId: assistantMessageId,
              route: route,
              text: replyText,
            );
          }
          continue;
        }
        _publishOrchestrationStreamActivity(
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
        return _OrchestrationRouteResult(
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
      return _OrchestrationRouteResult(
        turn: completedTurn,
        replyText: replyText,
      );
    } catch (_) {
      debugPrint('orchestration_dispatch_failed category=lane_exception');
      return _OrchestrationRouteResult(
        turn: AgentDispatchTurnResult(
          ok: false,
          sessionId: sessionId ?? '',
          errorCode: 'orchestration_lane_exception',
        ),
        replyText: '',
      );
    }
  }

  Future<TaskRouteSwitchResult?> _evaluateOrchestrationRoutingBoundary({
    required String taskId,
    required String trigger,
    String pendingUserText = '',
    RoutingPolicyDocument? policySnapshot,
  }) async {
    final previous = _orchestrationRoutingBoundaryTail;
    final gate = Completer<void>();
    _orchestrationRoutingBoundaryTail = gate.future;
    await previous.catchError((_) {});
    try {
      final routingModule = await _ensureRoutingModuleReady();
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
        usageReport: agentUsageReport,
        allowanceOverrides: agentAllowanceOverrides,
        circuitBreakerStates: agentOrchestrationCircuitStates,
      );
      return await coordinator.evaluateAtMessageBoundary(
        taskId: taskId,
        policy: policy,
        signals: signals,
        task: RoutingTaskMetadata(prompt: pendingUserText),
        turns: turns,
        send: _sendDistillationLaneRequest,
        openTargetSession: _openRoutedTargetSession,
        switchReason: trigger,
        isDistillerReady: (agentId) =>
            _routingTarget(agentId)?.canRelayRuntime == true,
      );
    } catch (_) {
      debugPrint('orchestration_boundary_failed category=routing_exception');
      return null;
    } finally {
      gate.complete();
    }
  }

  Future<DistillationLaneResponse> _sendDistillationLaneRequest(
    DistillationLaneRequest request,
  ) async {
    final target = _routingTarget(request.agentId);
    final bind = _routingBind(request.agentId);
    final opened = await conversationService.openOrResume(
      runner: agentService,
      agentId: request.agentId,
      sessionId: request.sessionId,
      bind: bind,
    );
    final result = await conversationService.send(
      runner: agentService,
      agentId: request.agentId,
      text: request.text,
      sessionId: opened.sessionId,
      bind: bind,
      conversationReadiness: target?.conversationReadiness ?? 'unverified',
    );
    final usage = _routingUsage(result.raw);
    return DistillationLaneResponse(
      ok: result.ok,
      text: _routingTurnText(result.raw),
      errorMessage: result.errorCode,
      sessionId: result.sessionId,
      promptTokens: usage.$1,
      completionTokens: usage.$2,
    );
  }

  Future<String> _openRoutedTargetSession({
    required String agentId,
    required DistillationPackage package,
    required String sourceSessionId,
    required String resumeSessionId,
  }) async {
    final target = _routingTarget(agentId);
    final bind = _routingBind(agentId);
    final opened = await conversationService.openOrResume(
      runner: agentService,
      agentId: agentId,
      sessionId: resumeSessionId,
      bind: bind,
    );
    final result = await conversationService.send(
      runner: agentService,
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

  RoutingDispatchRoute _routingRouteForAgent({
    required RoutingDispatchPlan plan,
    required String agentId,
  }) {
    for (final route in plan.routes) {
      if (route.agentId == agentId) {
        return route;
      }
    }
    final policyAgent = (_routingModule?.activePolicy.agents ?? const [])
        .where((agent) => agent.id == agentId)
        .firstOrNull;
    final target = _routingTarget(agentId);
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

  TargetCandidate? _routingTarget(String agentId) {
    for (final target in scannedTargets) {
      if (target.target == agentId) {
        return target;
      }
    }
    return null;
  }

  AgentDispatchBind _routingBind(
    String agentId, {
    RoutingDispatchRoute? route,
  }) {
    final target = _routingTarget(agentId);
    final policyAgent = (_routingModule?.activePolicy.agents ?? const [])
        .where((agent) => agent.id == agentId)
        .firstOrNull;
    return AgentDispatchBind(
      model: route?.modelName ?? policyAgent?.modelName ?? '',
      reasoningEffort:
          route?.reasoningEffort ?? policyAgent?.reasoningEffort ?? '',
      binaryPath: target?.binaryPath ?? '',
    );
  }

  String _routingTurnText(Map<String, dynamic> raw) {
    for (final key in const ['text', 'outputText', 'finalMessage', 'message']) {
      final value = raw[key];
      if (value is String && value.trim().isNotEmpty) {
        return value;
      }
    }
    final output = raw['output'];
    if (output is String) {
      return output;
    }
    if (output is Map) {
      return _routingTurnText(Map<String, dynamic>.from(output));
    }
    return '';
  }

  String _mergeOrchestrationProgressiveText(String current, String incoming) {
    if (current.isEmpty || incoming.startsWith(current)) {
      return incoming;
    }
    if (current.endsWith(incoming)) {
      return current;
    }
    return '$current$incoming';
  }

  (int, int) _routingUsage(Map<String, dynamic> raw) {
    final usage = raw['usage'];
    if (usage is! Map) {
      return (0, 0);
    }
    int value(String primary, String alternate) =>
        int.tryParse((usage[primary] ?? usage[alternate] ?? 0).toString()) ?? 0;
    return (
      value('promptTokens', 'inputTokens'),
      value('completionTokens', 'outputTokens'),
    );
  }

  String _beginOrchestrationConversationTurn(String userText) {
    final turnId =
        'orchestration-turn-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    _updateOrchestrationConversation(
      userText: userText,
      update: (messages, now) => [
        ...messages,
        AgentConversationMessage(
          id: '$turnId-user',
          role: 'user',
          text: userText,
          createdAt: now,
        ),
      ],
    );
    return turnId;
  }

  void _upsertOrchestrationAssistantReply({
    required String messageId,
    required RoutingDispatchRoute route,
    required String text,
  }) {
    if (text.trim().isEmpty) {
      return;
    }
    _updateOrchestrationConversation(
      update: (messages, now) {
        final existing = messages.where((message) => message.id == messageId);
        final createdAt = existing.isEmpty ? now : existing.first.createdAt;
        return [
          for (final message in messages)
            if (message.id != messageId) message,
          AgentConversationMessage(
            id: messageId,
            role: 'assistant',
            text: text,
            createdAt: createdAt,
            cardSubtitle: route.agentLabel,
            stableIdentity: messageId,
          ),
        ];
      },
    );
    _setLocalizedStatusMessage(
      '正在接收 ${route.agentLabel} 回复…',
      'Receiving the ${route.agentLabel} reply…',
    );
    statusCaption = text.length > 80 ? '${text.substring(0, 80)}…' : text;
    _notifyStateChanged();
  }

  void _publishOrchestrationStreamActivity({
    required String turnId,
    required RoutingDispatchRoute route,
    required AgentDispatchEvent event,
  }) {
    final kind = event.kind.trim();
    if (kind.isEmpty || kind == 'dispatch.lane.event') {
      return;
    }
    final messageId = '$turnId-${route.agentId}-activity-$kind';
    _updateOrchestrationConversation(
      update: (messages, now) => [
        for (final message in messages)
          if (message.id != messageId) message,
        AgentConversationMessage(
          id: messageId,
          role: 'event',
          text: '${route.agentLabel} · $kind',
          createdAt: now,
          layer: AgentConversationSemanticLayer.execution,
          cardType: 'event',
          cardTitle: route.agentLabel,
          cardSubtitle: kind,
          stableIdentity: messageId,
        ),
      ],
    );
  }

  void _appendOrchestrationExecutionStatus({
    required String turnId,
    required RoutingDispatchPlan plan,
    required List<_RoutingDispatchOutcome> outcomes,
    required List<RoutingDispatchSkip> skipped,
  }) {
    final text = _orchestrationStatusMessage(
      plan: plan,
      outcomes: outcomes,
      skipped: skipped,
    );
    _updateOrchestrationConversation(
      update: (messages, now) => [
        ...messages,
        AgentConversationMessage(
          id: '$turnId-status',
          role: 'event',
          text: text,
          createdAt: now,
          layer: AgentConversationSemanticLayer.execution,
          cardType: 'event',
          cardTitle: 'Agent orchestration',
          stableIdentity: '$turnId-status',
        ),
      ],
    );
  }

  void _updateOrchestrationConversation({
    String userText = '',
    required List<AgentConversationMessage> Function(
      List<AgentConversationMessage> messages,
      String now,
    )
    update,
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
    final messages = update(existing?.messages ?? const [], now);
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
    required RoutingDispatchPlan plan,
    required RoutingDispatchRoute route,
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
    final coordinator = plan.strategy == 'coordinator-workers'
        ? (route.coordinator
              ? '你是主智能体；请核验给出的工作结果并生成最终综合答复。'
              : '你是工作智能体，只处理分配给你的角色；结果将交给主智能体核验。')
        : '你是独立执行节点，只处理分配给你的角色；Lico Arc 会按策略展示各节点结果。';
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
    required RoutingDispatchPlan plan,
    required List<_RoutingDispatchOutcome> outcomes,
    required List<RoutingDispatchSkip> skipped,
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

  String _strategyStatusLabel(String strategy) {
    return switch (strategy) {
      'priority-fallback' || 'fallback' => '顺序降级',
      'serial-all' => '串行协作',
      'parallel-all' => '并行协作',
      'coordinator-workers' => '指挥官汇总',
      _ => strategy,
    };
  }

  RoutingDispatchFailureDisposition _routingFailureDisposition(
    AgentDispatchTurnResult turn,
  ) {
    return RoutingDispatchFailureFacts.fromEnvelope(
      ok: turn.ok,
      errorCode: turn.errorCode,
      envelope: turn.raw,
    ).disposition;
  }

  String _skipReasonLabel(String reason) {
    return switch (reason) {
      'quota-insufficient' || 'allowance_exhausted' => '额度不足，已跳过并熔断',
      'circuit-open' || 'circuit_broken' => '熔断中，已跳过',
      'not_ready' => '未就绪，已跳过',
      'allowance_data_stale' => '额度数据过期，已跳过',
      'model-library-excluded' => '不在模型库中，已跳过',
      _ => '不可用，已跳过',
    };
  }

  String _routeModelStatus(RoutingDispatchRoute route) {
    final model = route.modelName.trim();
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

class _RoutingDispatchOutcome {
  const _RoutingDispatchOutcome({
    required this.route,
    required this.ok,
    required this.status,
    this.replyText = '',
  });

  final RoutingDispatchRoute route;
  final bool ok;
  final String status;
  final String replyText;
}

class _OrchestrationRouteResult {
  const _OrchestrationRouteResult({
    required this.turn,
    required this.replyText,
  });

  final AgentDispatchTurnResult turn;
  final String replyText;
}
