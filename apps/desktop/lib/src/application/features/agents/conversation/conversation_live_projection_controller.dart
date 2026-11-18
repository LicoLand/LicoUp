import 'dart:async';

import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_state_holder.dart';
import 'package:licoup/src/application/features/agents/conversation/native_approval_request.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_process_state.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';

/// Ephemeral message/process projection for an in-flight native turn.
///
/// One [ConversationTurnProcessState] per conversation scope is the blackboard
/// of that conversation's active turn: stream events only advance the state
/// machine, and the live message list is re-derived from the state on every
/// transition. The live messages are part of the owning conversation's message
/// stream; other conversations have no live entries of their own. The
/// frontend card is bound to the turn id, so it stays pinned in the flow and
/// only its content advances.
mixin AgentConversationLiveProjectionController on AgentWorkspaceCoordinator {
  final ConversationStateHolder conversationStateHolder =
      ConversationStateHolder();
  bool _liveRevisionBridgeAttached = false;
  StreamSubscription<ApplicationChange>? _liveProjectionSubscription;
  int _memoryLiveTurnCount = 0;

  ConversationScopeProjection conversationProjectionFor(String scopeKey) =>
      conversationStateHolder.projectionFor(scopeKey);

  /// Passes an already decoded native event into the sole projection mutation
  /// path. The generated protocol decoder has already bound request,
  /// workflow, and sequence before the gateway exposes this event.
  bool conversationApplyDelta({
    required String scopeKey,
    required AgentDispatchEvent event,
    required String participantAgentId,
    required String participantLabel,
    String participantRole = '',
  }) {
    final payload = <String, dynamic>{
      ...event.payload,
      if (event.payload['turnHandle'] != null)
        'turnHandle': event.payload['turnHandle'],
    };
    final applied = conversationStateHolder.applyDelta(
      ConversationDeltaEvent(<String, dynamic>{
        'event': event.kind,
        'sessionId': event.sessionId,
        'turnId': event.turnId,
        if (payload['turnHandle'] != null) 'turnHandle': payload['turnHandle'],
        'payload': payload,
      }),
      scopeKey: scopeKey,
      participantAgentId: participantAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
    );
    if (!applied) return false;
    // Bridge the holder's coalesced publish to the renderer-facing live
    // revision (one notification per publish interval, never per delta). The
    // mirrors are re-derived from the sole authority so the notified snapshot
    // is never stale relative to the holder publish that triggered it.
    if (!_liveRevisionBridgeAttached) {
      _liveRevisionBridgeAttached = true;
      _liveProjectionSubscription = conversationStateHolder.changes.listen(
        (_) => _syncLiveMirrorsAndNotify(),
      );
    }
    // Transitional mirrors remain for non-rendering acceptance probes and
    // readback persistence. Rendering reads [conversationStateHolder]
    // directly, so these maps are not a second UI authority.
    liveConversationMessagesByScope = <String, List<AgentConversationMessage>>{
      ...liveConversationMessagesByScope,
      scopeKey: conversationStateHolder.messagesFor(scopeKey),
    };
    return true;
  }

  void _syncLiveMirrorsAndNotify() {
    liveConversationMessagesByScope = <String, List<AgentConversationMessage>>{
      for (final scopeKey in conversationStateHolder.scopeKeys)
        scopeKey: conversationStateHolder.messagesFor(scopeKey),
    };
    _observeWorkspaceMemory();
    agentWorkspaceNotifyLiveConversationChanged();
  }

  void _observeWorkspaceMemory() {
    var liveMessageCount = 0;
    for (final messages in liveConversationMessagesByScope.values) {
      liveMessageCount += messages.length;
    }
    final liveTurnCount = conversationStateHolder.scopeKeys.length;
    final event = liveTurnCount > 0 && _memoryLiveTurnCount == 0
        ? ClientMemoryDiagnosticEvent.liveTurnOpened
        : liveTurnCount == 0 && _memoryLiveTurnCount > 0
        ? ClientMemoryDiagnosticEvent.liveTurnClosed
        : ClientMemoryDiagnosticEvent.sample;
    _memoryLiveTurnCount = liveTurnCount;
    observeClientMemory(
      ClientMemoryDiagnosticObservation(
        event: event,
        surface: ClientMemoryDiagnosticSurface.workspace,
        liveTurnCount: liveTurnCount,
        liveMessageCount: liveMessageCount,
        livePartCount: liveMessageCount,
      ),
    );
  }

  void disposeConversationLiveProjection() {
    unawaited(_liveProjectionSubscription?.cancel());
    _liveProjectionSubscription = null;
  }

  /// Legacy fixture seam. Production code has no call site; release builds do
  /// not execute the debug-only seed. Stream rendering always enters through
  /// [conversationApplyDelta].
  void conversationStartLiveProjection({
    required String scopeKey,
    required String turnId,
    required String userText,
  }) {
    assert(() {
      conversationTurnProcessStateByScope = {
        ...conversationTurnProcessStateByScope,
        scopeKey: ConversationTurnProcessState(
          turnId: turnId,
          userText: userText,
          createdAt: '',
          scopeKey: scopeKey,
        ),
      };
      _projectLegacyFixture(scopeKey);
      return true;
    }());
  }

  void conversationUpsertLiveReply({
    required String scopeKey,
    required String turnId,
    required String text,
  }) {
    assert(() {
      final state = conversationTurnProcessStateByScope[scopeKey];
      if (state != null && state.turnId == turnId) {
        state.setReplyText(text, createdAt: '');
        _projectLegacyFixture(scopeKey);
      }
      return true;
    }());
  }

  void conversationUpsertLiveLifecycle({
    required String scopeKey,
    required String turnId,
    required String stage,
  }) {
    assert(() {
      final state = conversationTurnProcessStateByScope[scopeKey];
      if (state != null && state.turnId == turnId) {
        state.advanceStage(stage);
        _projectLegacyFixture(scopeKey);
      }
      return true;
    }());
  }

  void _projectLegacyFixture(String scopeKey) {
    final state = conversationTurnProcessStateByScope[scopeKey];
    if (state == null) return;
    liveConversationMessagesByScope = {
      ...liveConversationMessagesByScope,
      scopeKey: state.projectedMessages(),
    };
  }

  /// Records a native permission request the Agent parked in a live turn
  /// and marks its tab as waiting for approval.
  ///
  /// The turn envelope carries the session and turn the request is scoped
  /// to; the payload carries the parked route's callback token, the pending
  /// operation and its display summary.
  Future<void> conversationHandleNativeApprovalNeeded({
    required String agentId,
    required AgentDispatchEvent event,
  }) async {
    setConversationTabActivity(
      agentId,
      AgentConversationTabActivity.needsApproval,
    );
    final payload = event.payload;
    final summary = (payload['displaySummary'] ?? '').toString().trim();
    final token = (payload['adapterCallbackTokenRef'] ?? '').toString().trim();
    final pendingOperationId = (payload['pendingOperationId'] ?? '')
        .toString()
        .trim();
    final tools = payload['requestedTools'];
    if (token.isNotEmpty && pendingOperationId.isNotEmpty) {
      final request = NativeApprovalRequest(
        agentId: (payload['agentId'] ?? agentId).toString().trim(),
        sessionId: event.sessionId.trim(),
        turnId: event.turnId.trim(),
        adapterCallbackTokenRef: token,
        pendingOperationId: pendingOperationId,
        summary: summary,
        requestedTools: [
          if (tools is List)
            for (final tool in tools)
              if (tool.toString().trim().isNotEmpty) tool.toString().trim(),
        ],
      );
      pendingNativeApprovals = List<NativeApprovalRequest>.unmodifiable([
        for (final item in pendingNativeApprovals)
          if (item.pendingOperationId != pendingOperationId) item,
        request,
      ]);
    }
    agentWorkspaceSetLocalizedStatusMessage(
      summary.isEmpty ? '智能体等待审批。' : '智能体等待审批：$summary',
      summary.isEmpty
          ? 'The agent is waiting for approval.'
          : 'The agent is waiting for approval: $summary',
    );
    statusCaption = 'Approval';
    agentWorkspaceNotifyStateChanged();
  }

  /// Delivers Allow or Deny for one pending native permission request.
  ///
  /// A delivered decision, and a request the Agent already settled, remove
  /// the request; any other failure keeps it so the user can decide again.
  Future<void> resolveNativeApproval(
    String pendingOperationId, {
    required bool allow,
  }) async {
    final request = pendingNativeApprovals
        .where((item) => item.pendingOperationId == pendingOperationId)
        .firstOrNull;
    if (request == null ||
        resolvingNativeApprovals.contains(pendingOperationId)) {
      return;
    }
    resolvingNativeApprovals = {
      ...resolvingNativeApprovals,
      pendingOperationId,
    };
    nativeApprovalErrorCode = '';
    agentWorkspaceNotifyStateChanged();
    String failure;
    try {
      failure = await conversationGateway.resolveNativeApproval(
        agentId: request.agentId,
        sessionId: request.sessionId,
        turnId: request.turnId,
        adapterCallbackTokenRef: request.adapterCallbackTokenRef,
        allow: allow,
      );
    } on Object {
      failure = 'native_interaction_resolve_failed';
    }
    resolvingNativeApprovals = {
      for (final id in resolvingNativeApprovals)
        if (id != pendingOperationId) id,
    };
    if (failure.isEmpty) {
      pendingNativeApprovals = List<NativeApprovalRequest>.unmodifiable([
        for (final item in pendingNativeApprovals)
          if (item.pendingOperationId != pendingOperationId) item,
      ]);
      if (!pendingNativeApprovals.any(
            (item) => item.agentId == request.agentId,
          ) &&
          conversationTabActivityFor(request.agentId) ==
              AgentConversationTabActivity.needsApproval) {
        setConversationTabActivity(
          request.agentId,
          AgentConversationTabActivity.none,
        );
      }
    } else {
      nativeApprovalErrorCode = failure;
    }
    agentWorkspaceNotifyStateChanged();
  }
}
