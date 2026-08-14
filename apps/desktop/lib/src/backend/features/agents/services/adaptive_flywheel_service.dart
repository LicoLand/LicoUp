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
}
