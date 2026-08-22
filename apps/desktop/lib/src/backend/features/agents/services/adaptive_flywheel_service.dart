import 'dart:convert';

import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';

final class AdaptiveFlywheelService {
  const AdaptiveFlywheelService();

  Future<Object?> execute(
    AgentCommandRunner runner,
    Map<String, dynamic> request,
  ) async {
    final output = await runner.runCliWithStdin(const [
      'strategy',
      'execute',
      '--stdin-json',
      'true',
    ], jsonEncode(request));
    if (output['ok'] != true) {
      final error = adaptiveFlywheelStringMap(output['error']);
      throw AdaptiveFlywheelFailure(
        code: (error['code'] ?? 'strategy_operation_failed').toString(),
        recovery: (error['recovery'] ?? '').toString(),
        retryable: error['retryable'] == true,
      );
    }
    return output['result'];
  }

  /// Compiles, preflights, durably admits and executes one assistant-temporary
  /// Graph. Exact Membership facts are derived by the native owner.
  Future<Map<String, dynamic>> assistantWorkflowExecute({
    required AgentCommandRunner runner,
    required String conversationId,
    required String membershipId,
    required Map<String, dynamic> workflow,
    required List<Map<String, dynamic>> bindings,
    Map<String, dynamic> filters = const {},
    Map<String, dynamic> input = const {},
    required String idempotencyKey,
  }) async {
    return _resultMap(
      await execute(runner, {
        'action': 'strategy.assistant.workflow.execute',
        'conversationId': conversationId,
        'membershipId': membershipId,
        'workflow': workflow,
        'bindings': bindings,
        'filters': filters,
        'input': input,
        'idempotencyKey': idempotencyKey,
      }),
    );
  }

  /// Inspects one assistant Graph run projection with typed terminal facts.
  Future<Map<String, dynamic>> assistantWorkflowInspect({
    required AgentCommandRunner runner,
    required String runId,
  }) async {
    return _resultMap(
      await execute(runner, {
        'action': 'strategy.assistant.workflow.inspect',
        'runId': runId,
      }),
    );
  }

  /// Cancels one assistant Graph run.
  Future<Map<String, dynamic>> assistantWorkflowCancel({
    required AgentCommandRunner runner,
    required String runId,
  }) async {
    return _resultMap(
      await execute(runner, {
        'action': 'strategy.assistant.workflow.cancel',
        'runId': runId,
      }),
    );
  }
}

Map<String, dynamic> _resultMap(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}
