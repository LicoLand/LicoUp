import 'dart:io';

import 'package:flutter_client/src/contracts/generated/client_error.g.dart';

typedef NativeRunCliExecutable =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments,
      Map<String, String>? environment,
    );

typedef NativeStartCliExecutable =
    Future<Process> Function(
      String executable,
      List<String> arguments,
      Map<String, String>? environment,
    );

typedef NativeResolveCliBinary = Future<File?> Function();

/// Minimal command port consumed by platform command builders.
abstract interface class NativeCommandExecutor {
  Future<Map<String, dynamic>> execute(List<String> arguments);
}

/// Process setup required by both one-shot and persistent transports.
abstract interface class NativeCliProcessContext {
  Duration get requestTimeout;

  Future<File?> resolveCliBinary();

  Future<Map<String, String>?> buildEnvironment();

  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  );
}

/// Persistent stdio transport used only on supported desktop runtimes.
abstract interface class NativeStdioRpcTransport {
  Future<Map<String, dynamic>> execute(List<String> arguments);

  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  );

  Stream<Map<String, dynamic>> streamConversation(Map<String, dynamic> request);

  Future<void> dispose();
}

class LicoClientRpcException implements Exception {
  const LicoClientRpcException(this.code) : clientError = null;
  LicoClientRpcException.fromClientError(ClientError error)
    : clientError = error,
      code = error.code.wireName;

  final String code;
  final ClientError? clientError;

  bool get authorizationRequired => code == 'authorization_required';

  @override
  String toString() {
    if (authorizationRequired) {
      return 'lico-client authorization is required.';
    }
    return 'lico-client RPC request failed (code: $code).';
  }
}
