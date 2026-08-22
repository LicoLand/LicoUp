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
    final Map<String, dynamic> output;
    try {
      output = await runner.runCliWithStdin(const [
        'conversation',
        'execute',
        '--stdin-json',
        'true',
      ], jsonEncode(request));
    } catch (error) {
      final mapped = _failureFromRpcException(error);
      if (mapped != null) throw mapped;
      rethrow;
    }
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

/// Maps a platform RPC exception without importing platform types.
ClientConversationServiceFailure? _failureFromRpcException(Object error) {
  if (error.runtimeType.toString() != 'LicoClientRpcException') {
    return null;
  }
  try {
    final code = (error as dynamic).code;
    if (code is String && code.trim().isNotEmpty) {
      return ClientConversationServiceFailure(code);
    }
  } catch (_) {}
  return null;
}
