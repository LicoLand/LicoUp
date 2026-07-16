import 'dart:io';

import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'stdio RPC rejects invalid arguments before resolving a process',
    () async {
      final context = _FakeProcessContext();
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);

      await expectLater(
        client.execute(const []),
        throwsA(
          isA<LicoClientRpcException>().having(
            (error) => error.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      expect(context.resolveCount, 0);
      expect(context.startCount, 0);
    },
  );

  test('stdio RPC redacts process setup failures', () async {
    final context = _FakeProcessContext(failSetup: true);
    final client = NativeStdioRpcClient(processContext: context);
    addTearDown(client.dispose);

    Object? caught;
    try {
      await client.execute(const ['state', 'get']);
    } on Object catch (error) {
      caught = error;
    }

    expect(caught, isA<LicoClientRpcException>());
    expect((caught! as LicoClientRpcException).code, 'setup_failed');
    expect(caught.toString(), isNot(contains('setup-detail')));
    expect(context.startCount, 0);
  });
}

class _FakeProcessContext implements NativeCliProcessContext {
  _FakeProcessContext({this.failSetup = false});

  final bool failSetup;
  var resolveCount = 0;
  var startCount = 0;

  @override
  Duration get requestTimeout => const Duration(seconds: 1);

  @override
  Future<Map<String, String>?> buildEnvironment() async {
    if (failSetup) {
      throw StateError('setup-detail');
    }
    return null;
  }

  @override
  Future<File?> resolveCliBinary() async {
    resolveCount += 1;
    return null;
  }

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  ) async {
    startCount += 1;
    throw StateError('unexpected process start');
  }
}
