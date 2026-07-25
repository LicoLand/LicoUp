import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/contracts/generated/client_error.g.dart';

/// Pure validation for native dispatch results. It never mutates UI state.
abstract final class ConversationRuntimeResultPolicy {
  static bool submissionConsumed(String failureCode) {
    final code = failureCode.trim();
    return code.isEmpty || code == 'conversation_turn_duplicate_ignored';
  }

  static ClientError clientError(Map<String, dynamic> result) {
    final nested = result['error'];
    if (nested is Map) {
      return ClientError.fromJson(Map<String, Object?>.from(nested));
    }
    return ClientError.fromJson(const <String, Object?>{
      'code': 'terminal_result_invalid',
      'stage': 'conversation/terminal_result',
      'component': 'conversation_runtime',
      'retryable': false,
      'recovery': 'review_terminal_result',
    });
  }

  static bool outcomeMayBeUnknown(ClientError error) {
    return error.retryable &&
        (error.stage == ClientErrorStage.conversationDispatch ||
            error.stage == ClientErrorStage.conversationStreamReceive);
  }

  static bool preserveDraft(ClientError error) {
    if (error.isUnknown) return true;
    return switch (error.recovery) {
      ClientErrorRecovery.correctRequest ||
      ClientErrorRecovery.useCliHelp ||
      ClientErrorRecovery.correctCommandArguments ||
      ClientErrorRecovery.provideValidJson ||
      ClientErrorRecovery.reduceCommandArguments ||
      ClientErrorRecovery.selectSupportedAdapter ||
      ClientErrorRecovery.installOrRetryRuntime ||
      ClientErrorRecovery.preserveDraftAndRetry => true,
      ClientErrorRecovery.reviewTerminalResult ||
      ClientErrorRecovery.retryOrReviewRequest ||
      ClientErrorRecovery.unknown => false,
    };
  }

  static bool effectiveSettingsMatch(
    Map<String, dynamic> result, {
    required bool throughMobileRelay,
    required String requestedModel,
    required String requestedReasoningEffort,
  }) {
    final model = requestedModel.trim();
    final reasoning = requestedReasoningEffort.trim();
    if (model.isEmpty && reasoning.isEmpty) {
      return true;
    }
    Map<String, dynamic>? effective;
    if (throughMobileRelay) {
      final polled = agentRelayMap(result['result']);
      final opened = agentRelayMap(polled?['openedResult']);
      final execution = agentRelayMap(opened?['execution']);
      final output = agentRelayMap(execution?['output']);
      final runtime = agentRelayMap(output?['output']);
      effective = agentRelayMap(runtime?['effective']);
    } else {
      effective = agentRelayMap(result['effective']);
    }
    if (effective == null) {
      return false;
    }
    return (model.isEmpty || (effective['model'] ?? '').toString() == model) &&
        (reasoning.isEmpty ||
            (effective['reasoningEffort'] ?? '').toString() == reasoning);
  }

  static String mergeProgressiveText(
    String current,
    String incoming, {
    required bool completed,
  }) {
    if (completed || current.isEmpty) {
      return incoming;
    }
    if (incoming.startsWith(current)) {
      return incoming;
    }
    if (current.endsWith(incoming)) {
      return current;
    }
    return '$current$incoming';
  }
}
