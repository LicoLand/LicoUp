import 'package:flutter_client/src/application/features/agents/policy/conversation_session_index.dart';

/// Pure validation for native dispatch results. It never mutates UI state.
abstract final class ConversationRuntimeResultPolicy {
  static String errorCode(Map<String, dynamic> result) {
    final nested = result['error'];
    final raw = nested is Map ? (nested['code'] ?? '') : (result['code'] ?? '');
    final code = raw.toString().trim();
    return RegExp(r'^[a-z0-9][a-z0-9_-]{0,127}$').hasMatch(code)
        ? code
        : 'native_agent_dispatch_failed';
  }

  static bool outcomeMayBeUnknown(String errorCode) {
    return const {
      'secure_relay_result_timeout',
      'secure_relay_result_fetch_failed',
      'native_agent_timeout',
      'native_agent_transport_failed',
    }.contains(errorCode);
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
