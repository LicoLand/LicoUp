import 'dart:convert';

import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';

/// Routes catalog payloads through a structured private transport.
final class NativeCatalogActions {
  const NativeCatalogActions({
    required AgentCommandRunner privateRunner,
    required NativeStdioRpcTransport stdioRpcTransport,
    required bool persistentStdioRpcEnabled,
  }) : _privateRunner = privateRunner,
       _stdioRpcTransport = stdioRpcTransport,
       _persistentStdioRpcEnabled = persistentStdioRpcEnabled;

  static const _allowedOperations = {
    'status',
    'invalidate',
    'refresh',
    'receipt',
    'purge',
    'reconnect',
    'list',
    'observe',
  };

  final AgentCommandRunner _privateRunner;
  final NativeStdioRpcTransport _stdioRpcTransport;
  final bool _persistentStdioRpcEnabled;

  Future<Map<String, dynamic>> execute(
    String operation, {
    Map<String, dynamic> params = const {},
  }) {
    if (!_allowedOperations.contains(operation)) {
      return Future<Map<String, dynamic>>.error(
        const FormatException('catalog_operation_unsupported'),
      );
    }
    if (_persistentStdioRpcEnabled) {
      return _stdioRpcTransport.executeStructured('catalog.$operation', params);
    }
    return _privateRunner.runCliWithStdin([
      'catalog',
      operation,
      '--stdin-json',
      'true',
    ], jsonEncode(params));
  }
}
