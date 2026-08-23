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
  state.recordParticipant(
    participantAgentId: agentId,
    participantLabel: participantLabel,
    participantRole: participantRole,
  );
  final rawPrefix = event.payload['lifecyclePrefix'];
  if (rawPrefix is List) {
    for (final stage in rawPrefix) {
      state.advanceStage(stage.toString());
    }
  }
  final replyEvent =
      kind == 'agent.message.chunk' || kind == 'agent.message.completed';
  if (replyEvent) {
    final next = ConversationRuntimeResultPolicy.mergeProgressiveText(
      state.replyText,
      (event.payload['text'] ?? '').toString(),
      completed: kind == 'agent.message.completed',
    );
    if (next.isNotEmpty) {
      state.setReplyText(
        next,
        createdAt: _eventCreatedAt(event),
        participantAgentId: agentId,
        participantLabel: participantLabel,
        participantRole: participantRole,
      );
    }
  }
  final terminalTransition = event.payload['terminalTransition'];
  if (terminalTransition is Map) {
    final terminalKind = (terminalTransition['kind'] ?? '').toString();
    if (terminalKind == 'failed') {
      state.advanceStage('failed');
      _appendPersistentTurnEvidence(state, event);
      return true;
    }
    if (terminalKind == 'lifecycle' &&
        terminalTransition['stage'] == 'completed') {
      state.advanceStage('completed');
      return true;
    }
  }
  if (!replyEvent && kind.isNotEmpty && kind != 'dispatch.turn.started') {
    _appendPersistentTurnEvidence(state, event);
  }
  return false;
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
              event.payload['toolName'] ??
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
      createdAt: _eventCreatedAt(event),
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

String _eventCreatedAt(AgentDispatchEvent event) {
  final value = event.payload['createdAt'];
  return value is String ? value.trim() : '';
}

/// Only a successful terminal may advance the next Graph actor.
bool persistentTurnAllowsNextActor(ConversationTurnProcessState state) {
  return state.stage == ConversationTurnProcessStage.completed;
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
  final terminal = event.payload['terminalTransition'];
  if (terminal is! Map || terminal['kind'] != 'failed') return null;
  final code = (terminal['code'] ?? '').toString().trim();
  final stage = (terminal['stage'] ?? '').toString().trim();
  final turnStatus =
      (terminal['turnStatus'] ?? event.payload['turnStatus'] ?? '')
          .toString()
          .trim();
  final nestedError = event.payload['error'];
  final message = nestedError is Map
      ? (nestedError['message'] ?? '').toString().trim()
      : '';
  if (code.isEmpty && turnStatus.isEmpty) return null;
  return jsonEncode({
    if (code.isNotEmpty) 'code': code,
    if (stage.isNotEmpty) 'stage': stage,
    if (turnStatus.isNotEmpty) 'turnStatus': turnStatus,
    if (message.isNotEmpty) 'message': message,
  });
}
