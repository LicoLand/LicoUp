import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'lib/src/platform/native_client';
  final stdioRpcLeafPaths =
      Directory('$root/agent_service_stdio_rpc')
          .listSync()
          .whereType<File>()
          .map((file) => file.path)
          .where((path) => path.endsWith('.dart'))
          .toList()
        ..sort();
  final componentPaths = <String>[
    '$root/agent_service_actions.dart',
    '$root/agent_service_process_io.dart',
    '$root/agent_service_stdio_rpc.dart',
    '$root/native_cli_ports.dart',
    '$root/native_catalog_actions.dart',
    '$root/native_cli_runtime_context.dart',
    '$root/native_command_router.dart',
    '$root/native_one_shot_command_executor.dart',
    ...stdioRpcLeafPaths,
  ];

  test('native-client components are normal import libraries', () {
    for (final path in <String>[
      '$root/agent_service.dart',
      ...componentPaths,
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        RegExp(r'^\s*part(?:\s+of)?\s+', multiLine: true).hasMatch(source),
        isFalse,
        reason: path,
      );
    }
  });

  test('components depend on narrow ports and never reverse-import facade', () {
    for (final path in componentPaths) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('/agent_service.dart')), reason: path);
    }

    final actions = File('$root/agent_service_actions.dart').readAsStringSync();
    final processIo = File(
      '$root/agent_service_process_io.dart',
    ).readAsStringSync();
    final stdioRpcFacade = File(
      '$root/agent_service_stdio_rpc.dart',
    ).readAsStringSync();
    final stdioRpcClient = File(
      '$root/agent_service_stdio_rpc/client.dart',
    ).readAsStringSync();
    expect(actions, contains('NativeCommandExecutor'));
    expect(actions, isNot(contains("import 'dart:io'")));
    expect(processIo, contains('NativeCliProcessContext'));
    expect(stdioRpcFacade.split('\n').length, lessThanOrEqualTo(3));
    expect(stdioRpcFacade, contains('show NativeStdioRpcClient'));
    expect(stdioRpcClient, contains('NativeCliProcessContext'));
  });

  test('AgentService stays a facade with explicit component composition', () {
    final source = File('$root/agent_service.dart').readAsStringSync();

    expect(source.split('\n').length, lessThanOrEqualTo(430));
    expect(source, contains('NativeStdioRpcClient'));
    expect(source, contains('BoundedNativeProcessIo'));
    expect(source, contains('NativeCommandActions'));
    expect(source, contains('implements'));
    expect(source, contains('TargetManagementGateway'));
  });
}
