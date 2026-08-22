import 'dart:convert';

import 'package:licoup/src/application/features/agents/conversation/conversation_runtime_result_policy.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_process_state.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';

/// Applies one PersistentTurn event to the shared turn blackboard used by
/// one-to-one and Canonical Conversation observers.
///
/// Empty text still advances lifecycle and terminal failures, so an attached
/// process card never waits for a catalog reload to reveal the outcome.
bool applyPersistentTurnProcessEvent({
  required ConversationTurnProcessState state,
  required AgentDispatchEvent event,
  required String agentId,
  required String participantLabel,
  String participantRole = '',
}) {
  final kind = event.kind.trim();
  if (kind.isEmpty || kind == 'dispatch.turn.started') {
    return false;
  }
  state.recordParticipant(
    participantAgentId: agentId,
    participantLabel: participantLabel,
    participantRole: participantRole,
  );
  if (kind == 'agent.message.chunk' || kind == 'agent.message.completed') {
    final next = ConversationRuntimeResultPolicy.mergeProgressiveText(
      state.replyText,
      (event.payload['text'] ?? '').toString(),
      completed: kind == 'agent.message.completed',
    );
    if (next.isNotEmpty) {
      state.setReplyText(
        next,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        participantAgentId: agentId,
        participantLabel: participantLabel,
        participantRole: participantRole,
      );
      state.advanceStage('responding');
    }
    return false;
  }
  if (kind == 'agent.turn.accepted') {
    state.advanceStage('accepted');
    return false;
  }
  if (kind == 'agent.turn.processing' || kind == 'dispatch.turn.bound') {
    state.advanceStage('processing');
  }
  final terminal =
      kind == 'dispatch.turn.completed' ||
      kind == 'dispatch.turn.failed' ||
      kind == 'agent.turn.completed' ||
      kind == 'agent.turn.failed';
  if (terminal) {
    final failed = kind.contains('failed') || event.payload['ok'] == false;
    state.advanceStage(failed ? 'failed' : 'completed');
  }
  if (kind == 'dispatch.turn.completed' || kind == 'agent.turn.completed') {
    return true;
  }
  _appendPersistentTurnEvidence(state, event);
  return terminal;
}

void _appendPersistentTurnEvidence(
  ConversationTurnProcessState state,
  AgentDispatchEvent event,
) {
  final kind = event.kind.trim();
  final diagnostic = _persistentTurnDiagnosticText(event);
  final rawText =
      diagnostic ??
      (event.payload['text'] ??
              event.payload['summary'] ??
              event.payload['status'] ??
              event.payload['evidenceKind'] ??
              kind)
          .toString()
          .trim();
  if (rawText.isEmpty) return;
  final role = kind.contains('error') || kind.contains('failed')
      ? 'error'
      : kind.contains('reason')
      ? 'reasoning'
      : kind.contains('tool') && kind.contains('result')
      ? 'tool_result'
      : kind.contains('tool')
      ? 'tool_call'
      : 'event';
  final messageId = '${state.turnId}-process-${state.evidence.length}';
  state.appendEvidence(
    AgentConversationMessage(
      id: messageId,
      role: role,
      text: rawText,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      layer: AgentConversationSemanticLayer.execution,
      cardType: diagnostic != null ? 'diagnostic' : role.replaceAll('_', '-'),
      cardTitle: kind,
      stableIdentity: messageId,
      participantAgentId: state.participantAgentId,
      participantLabel: state.participantLabel,
      participantRole: state.participantRole,
    ),
  );
}

/// Only a successful terminal may advance the next Graph actor.
bool persistentTurnAllowsNextActor(ConversationTurnProcessState state) {
  return state.stage == ConversationTurnProcessStage.completed;
}

void failPersistentTurnIfOpen(ConversationTurnProcessState state) {
  if (state.stage == ConversationTurnProcessStage.completed ||
      state.stage == ConversationTurnProcessStage.failed) {
    return;
  }
  state.advanceStage('failed');
}

String? persistentTurnDiagnosticFailureCode(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is! Map) return null;
    final code = (decoded['code'] ?? '').toString().trim();
    return code.isEmpty ? null : code;
  } catch (_) {
    return null;
  }
}

String? _persistentTurnDiagnosticText(AgentDispatchEvent event) {
  final kind = event.kind.trim();
  if (kind != 'dispatch.turn.failed' && kind != 'agent.turn.failed') {
    return null;
  }
  final nested = event.payload['error'];
  final source = nested is Map ? nested : event.payload;
  final code = (source['code'] ?? event.payload['code'] ?? '')
      .toString()
      .trim();
  final stage = (source['stage'] ?? 'turn/completed').toString().trim();
  final turnStatus = (source['turnStatus'] ?? event.payload['turnStatus'] ?? '')
      .toString()
      .trim();
  if (code.isEmpty && turnStatus.isEmpty) return null;
  return jsonEncode({
    if (code.isNotEmpty) 'code': code,
    if (stage.isNotEmpty) 'stage': stage,
    if (turnStatus.isNotEmpty) 'turnStatus': turnStatus,
  });
}
