import 'dart:io';

import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_one_shot_command_executor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one-shot executor returns only decoded JSON projections', () async {
    final executor = NativeOneShotCommandExecutor(
      processContext: _FakeProcessContext(),
      runCliExecutable: (executable, arguments, environment) async {
        return ProcessResult(0, 0, '{"ok":true,"count":2}', '');
      },
    );

    expect(await executor.execute(const ['status']), {'ok': true, 'count': 2});
  });

  test('one-shot executor redacts process failures', () async {
    final executor = NativeOneShotCommandExecutor(
      processContext: _FakeProcessContext(),
      runCliExecutable: (executable, arguments, environment) async {
        throw ProcessException(executable, arguments, 'runtime-detail');
      },
    );

    Object? caught;
    try {
      await executor.execute(const ['status']);
    } on Object catch (error) {
      caught = error;
    }

    expect(caught.toString(), contains('could not be completed'));
    expect(caught.toString(), isNot(contains('runtime-detail')));
    expect(caught.toString(), isNot(contains('private-sidecar')));
  });
}

class _FakeProcessContext implements NativeCliProcessContext {
  @override
  Duration get requestTimeout => const Duration(seconds: 1);

  @override
  Future<Map<String, String>?> buildEnvironment() async => null;

  @override
  Future<File?> resolveCliBinary() async => File('/private-sidecar');

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  ) {
    throw UnimplementedError();
  }
}
