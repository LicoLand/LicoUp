import 'dart:convert';

import 'package:licoup/src/contracts/agent_command_runner.dart';

final class ClientConversationServiceFailure implements Exception {
  const ClientConversationServiceFailure(this.code);

  final String code;

  @override
  String toString() => code;
}

final class ClientConversationService {
  const ClientConversationService();

  Future<Object?> execute(
    AgentCommandRunner runner,
    Map<String, dynamic> request,
  ) async {
    final output = await runner.runCliWithStdin(const [
      'conversation',
      'execute',
      '--stdin-json',
      'true',
    ], jsonEncode(request));
    if (output['ok'] != true) {
      final error = output['error'];
      final code = error is Map
          ? (error['code'] ?? 'conversation_operation_failed').toString()
          : 'conversation_operation_failed';
      throw ClientConversationServiceFailure(code);
    }
    return output['result'];
  }
}
