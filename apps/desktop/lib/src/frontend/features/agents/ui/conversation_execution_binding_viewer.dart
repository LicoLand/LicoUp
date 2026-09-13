import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/conversation_execution.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/execution_process/conversation_execution_viewer.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/conversation/conversation_execution_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';

/// Renders one exact execution projection through the conversation binding.
/// Opening an older reply never falls back to the current membership turn.
Future<void> showBoundConversationExecution({
  required BuildContext context,
  required AgentConversationMessage message,
  required TargetCandidate target,
  required String conversationTitle,
  required ProjectionSource<ConversationExecutionProjection>? projection,
  required IntentSink<ConversationIntent> intents,
  required Future<void> Function(String) onCopyText,
  required FocusNode returnFocusNode,
}) async {
  final reference = message.executionReference;
  final viewId = ConversationExecutionViewId();
  final strings = LicoStrings.of(context);
  final unavailable = strings.executionProcessUnavailable;
  ConversationExecutionSnapshot snapshot(ConversationExecutionState state) =>
      ConversationExecutionSnapshot(
        records: state.records,
        loading: state.loading,
        error: state.errorCode.isNotEmpty
            ? state.errorCode
            : !state.loading &&
                  state.terminal &&
                  !state.terminalPayloadAvailable
            ? strings.executionProcessIncomplete
            : !state.loading &&
                  !state.observationAvailable &&
                  (!state.terminal || state.records.isEmpty)
            ? unavailable
            : null,
      );
  final source = ValueNotifier<ConversationExecutionSnapshot>(
    ConversationExecutionSnapshot(error: unavailable),
  );
  ConversationExecutionState? renderedState;
  void render(ConversationExecutionProjection next) {
    final state = next.views[viewId];
    if (state != null && !identical(state, renderedState)) {
      renderedState = state;
      source.value = snapshot(state);
    }
  }

  final subscription = projection?.changes.listen((update) {
    render(update.value);
  });
  try {
    if (projection != null && reference != null) {
      intents.send(
        OpenConversationExecutionView(viewId: viewId, reference: reference),
      );
      render(projection.current);
    }
    await showConversationExecutionViewer(
      context: context,
      source: source,
      agentIcon: MessagingAgentAvatar(target: target, size: 30, iconSize: 20),
      agentName: message.participantLabel.trim().isNotEmpty
          ? message.participantLabel
          : agentConversationTargetDisplayName(target),
      conversationTitle: conversationTitle,
      onCopyText: onCopyText,
      returnFocusNode: returnFocusNode,
    );
  } finally {
    if (projection != null && reference != null) {
      intents.send(CloseConversationExecutionView(viewId));
    }
    await subscription?.cancel();
    source.dispose();
  }
}
