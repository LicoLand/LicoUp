import 'dart:io';

import 'package:flutter_client/src/platform/native_client/agent_service_process_io.dart';
import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bounded process I/O delegates public commands to its narrow port',
    () async {
      final executor = _StaticExecutor({'ok': true});
      final context = _FakeProcessContext();
      final transport = _FakeStdioTransport();
      final processIo = BoundedNativeProcessIo(
        processContext: context,
        commandExecutor: executor,
        stdioRpcTransport: transport,
        persistentStdioRpcEnabled: false,
      );

      expect(await processIo.runCli(const ['status']), {'ok': true});
      expect(executor.arguments, ['status']);
    },
  );

  test(
    'bounded process I/O rejects oversized stdin before process start',
    () async {
      final context = _FakeProcessContext();
      final processIo = BoundedNativeProcessIo(
        processContext: context,
        commandExecutor: _StaticExecutor(const {}),
        stdioRpcTransport: _FakeStdioTransport(),
        persistentStdioRpcEnabled: false,
      );

      await expectLater(
        processIo.runCliWithStdin(const [
          'private',
          'request',
        ], List<String>.filled(1024 * 1024 + 1, 'x').join()),
        throwsA(
          predicate(
            (error) => error.toString().contains('request is too large'),
          ),
        ),
      );
      expect(context.startCount, 0);
    },
  );

  test(
    'persistent conversation streaming delegates decoded request only',
    () async {
      final transport = _FakeStdioTransport();
      final context = _FakeProcessContext();
      final processIo = BoundedNativeProcessIo(
        processContext: context,
        commandExecutor: _StaticExecutor(const {}),
        stdioRpcTransport: transport,
        persistentStdioRpcEnabled: true,
      );

      final events = await processIo.streamCliJsonLinesWithStdin(const [
        'agent',
        'conversation',
        'send',
      ], '{"request":"bounded"}').toList();

      expect(events, [
        {'event': 'done'},
      ]);
      expect(transport.conversationRequest, {'request': 'bounded'});
      expect(context.startCount, 0);
    },
  );

  test(
    'persistent conversation controls share the same structured RPC transport',
    () async {
      final transport = _FakeStdioTransport();
      final context = _FakeProcessContext();
      final processIo = BoundedNativeProcessIo(
        processContext: context,
        commandExecutor: _StaticExecutor(const {}),
        stdioRpcTransport: transport,
        persistentStdioRpcEnabled: true,
      );

      for (final operation in const [
        'open',
        'history',
        'cleanup',
        'capabilities',
        'cancel',
      ]) {
        final result = await processIo.runCliWithStdin([
          'agent',
          'conversation',
          operation,
          '--stdin-json',
          'true',
        ], '{"agent":"claude-code","sessionId":"opaque-session"}');
        expect(result, {'ok': true, 'operation': operation});
      }

      expect(context.startCount, 0);
      expect(transport.structuredCalls.map((call) => call.method), [
        for (final operation in const [
          'open',
          'history',
          'cleanup',
          'capabilities',
          'cancel',
        ])
          'agent.conversation.$operation',
      ]);
      for (final call in transport.structuredCalls) {
        expect(call.params, {
          'agent': 'claude-code',
          'sessionId': 'opaque-session',
        });
      }
    },
  );

  test(
    'persistent conversation controls reject malformed private JSON',
    () async {
      final transport = _FakeStdioTransport();
      final context = _FakeProcessContext();
      final processIo = BoundedNativeProcessIo(
        processContext: context,
        commandExecutor: _StaticExecutor(const {}),
        stdioRpcTransport: transport,
        persistentStdioRpcEnabled: true,
      );

      await expectLater(
        processIo.runCliWithStdin(const [
          'agent',
          'conversation',
          'cleanup',
          '--stdin-json',
          'true',
        ], '{invalid'),
        throwsA(
          isA<LicoClientRpcException>().having(
            (error) => error.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      expect(context.startCount, 0);
      expect(transport.structuredCalls, isEmpty);
    },
  );

  test('process I/O drains stderr with a fixed upper bound', () async {
    if (Platform.isWindows) {
      return;
    }
    final directory = await Directory.systemTemp.createTemp(
      'bounded-native-io-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final executable = File('${directory.path}/sidecar');
    await executable.writeAsString(r'''#!/bin/sh
head -c 524289 /dev/zero 1>&2
printf '{"ok":true}'
''');
    expect((await Process.run('chmod', ['+x', executable.path])).exitCode, 0);
    final processIo = BoundedNativeProcessIo(
      processContext: _LiveProcessContext(executable),
      commandExecutor: _StaticExecutor(const {}),
      stdioRpcTransport: _FakeStdioTransport(),
      persistentStdioRpcEnabled: false,
    );

    await expectLater(
      processIo.runCliWithStdin(const ['private', 'request'], '{}'),
      throwsA(
        predicate(
          (error) => error.toString().contains('output exceeded its limit'),
        ),
      ),
    );
  });
}

class _StaticExecutor implements NativeCommandExecutor {
  _StaticExecutor(this.response);

  final Map<String, dynamic> response;
  List<String>? arguments;

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) async {
    this.arguments = List<String>.unmodifiable(arguments);
    return response;
  }
}

class _FakeProcessContext implements NativeCliProcessContext {
  @override
  Duration get requestTimeout => const Duration(seconds: 1);

  var startCount = 0;

  @override
  Future<Map<String, String>?> buildEnvironment() async => null;

  @override
  Future<File?> resolveCliBinary() async => null;

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

class _FakeStdioTransport implements NativeStdioRpcTransport {
  Map<String, dynamic>? conversationRequest;
  final List<({String method, Map<String, dynamic> params})> structuredCalls =
      [];

  @override
  Future<void> dispose() async {}

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) async {
    return const {};
  }

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  ) async {
    final copied = Map<String, dynamic>.from(params);
    structuredCalls.add((method: method, params: copied));
    return <String, dynamic>{'ok': true, 'operation': method.split('.').last};
  }

  @override
  Stream<Map<String, dynamic>> streamConversation(
    Map<String, dynamic> request,
  ) async* {
    conversationRequest = Map<String, dynamic>.unmodifiable(request);
    yield const {'event': 'done'};
  }
}

class _LiveProcessContext implements NativeCliProcessContext {
  const _LiveProcessContext(this.executable);

  final File executable;

  @override
  Duration get requestTimeout => const Duration(seconds: 10);

  @override
  Future<Map<String, String>?> buildEnvironment() async => null;

  @override
  Future<File?> resolveCliBinary() async => executable;

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  ) {
    return Process.start(executable, arguments, environment: environment);
  }
}
