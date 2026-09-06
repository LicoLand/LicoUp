import 'dart:async';

import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_state_holder.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_process_state.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

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
    agentWorkspaceNotifyLiveConversationChanged();
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

  Future<void> conversationHandleNativeApprovalNeeded({
    required String agentId,
    required AgentDispatchEvent event,
  }) async {
    setConversationTabActivity(
      agentId,
      AgentConversationTabActivity.needsApproval,
    );
    final summary = (event.payload['displaySummary'] ?? '').toString().trim();
    final pendingOperationId = (event.payload['pendingOperationId'] ?? '')
        .toString()
        .trim();
    final token = (event.payload['adapterCallbackTokenRef'] ?? '')
        .toString()
        .trim();
    final nonce = (event.payload['responseNonce'] ?? '').toString().trim();
    final expiresAt = (event.payload['expiresAt'] ?? '').toString().trim();
    final originEndpointId =
        (event.payload['originEndpointId'] ?? 'local-desktop')
            .toString()
            .trim();
    final tools = <String>[];
    final rawTools = event.payload['requestedTools'];
    if (rawTools is List) {
      for (final tool in rawTools) {
        final name = tool.toString().trim();
        if (name.isNotEmpty) {
          tools.add(name);
        }
      }
    }
    if (pendingOperationId.isNotEmpty && token.isNotEmpty) {
      final request = SecureMeshApprovalRequest(
        pendingOperationId: pendingOperationId,
        requesterAgentId: (event.payload['agentId'] ?? agentId).toString(),
        targetClientId: 'local-desktop',
        originEndpointId: originEndpointId,
        riskLevel: 'local_effect',
        displaySummary: summary.isEmpty ? 'Agent permission request' : summary,
        policyReason: 'ACP session/request_permission',
        expiresAt: expiresAt,
        responseNonce: nonce,
        adapterCallbackTokenRef: token,
        adapterStyle: 'callback',
        requestedTools: List<String>.unmodifiable(tools),
        trustedEndpointCount: 1,
        status: SecureMeshApprovalStatus.pending,
      );
      final next = <SecureMeshApprovalRequest>[
        for (final item in secureMeshApprovalInbox)
          if (item.pendingOperationId != request.pendingOperationId) item,
        request,
      ];
      secureMeshApprovalInbox = List<SecureMeshApprovalRequest>.unmodifiable(
        next.length <= 24 ? next : next.sublist(next.length - 24),
      );
    }
    agentWorkspaceSetLocalizedStatusMessage(
      summary.isEmpty ? '智能体等待远程审批。' : '智能体等待审批：$summary',
      summary.isEmpty
          ? 'The agent is waiting for remote approval.'
          : 'The agent is waiting for approval: $summary',
    );
    statusCaption = 'Remote approval';
    agentWorkspaceNotifyStateChanged();
    await refreshSecureMeshApprovalInbox(includeResolved: false);
  }
}
