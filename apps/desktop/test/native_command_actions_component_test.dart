import 'dart:convert';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/platform/native_client/agent_service_actions.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native command actions depend only on command executor ports',
    () async {
      final serialized = _RecordingExecutor({
        'ok': true,
        'pairings': <Map<String, dynamic>>[],
      });
      final concurrent = _RecordingExecutor({
        'ok': true,
        'target': {
          'target': 'codex',
          'label': 'Codex',
          'kind': 'cli',
          'status': 'detected',
          'configured': true,
          'confidence': 1.0,
          'adapterStatus': 'implemented',
        },
      });
      final privateRunner = _RecordingRunner(serialized.response);
      final actions = NativeCommandActions(
        commandExecutor: serialized,
        concurrentCommandExecutor: concurrent,
        privateRunner: privateRunner,
      );

      await actions.listPairings(agent: ' codex ');
      serialized.response
        ..clear()
        ..addAll({
          'ok': true,
          'results': [
            {
              'targetId': 'codex',
              'ok': true,
              'candidate': {
                'target': 'codex',
                'label': 'Codex',
                'kind': 'cli',
                'status': 'detected',
                'configured': true,
                'confidence': 1.0,
                'adapterStatus': 'implemented',
              },
            },
          ],
        });
      final targetBatch = await actions.scanTargetsBatch([' codex ']);

      expect(serialized.calls.first, [
        'agents',
        'pair',
        'list',
        '--agent',
        'codex',
      ]);
      expect(privateRunner.arguments.last, [
        'targets',
        'scan',
        '--include-accessible-environments',
        'true',
        '--stdin-json',
        'true',
      ]);
      expect(targetBatch.slots.single.candidate?.target, 'codex');
      expect(
        serialized.calls.last,
        isNot(contains('--enable-agent-cli-model-lookup')),
      );

      privateRunner.arguments.clear();
      privateRunner.stdin.clear();
      serialized.response['results'] = [
        {
          'targetId': 'cursor',
          'ok': false,
          'error': {'code': 'target_scan_failed'},
        },
      ];
      await actions.scanTargetsBatch([
        'cursor',
      ], enableAgentCliModelLookup: true);
      expect(privateRunner.arguments.single, [
        'targets',
        'scan',
        '--include-accessible-environments',
        'true',
        '--stdin-json',
        'true',
      ]);
      expect(jsonDecode(privateRunner.stdin.single), {
        'targetIds': ['cursor'],
        'modelCatalogTargetIds': ['cursor'],
      });

      serialized.calls.clear();
      await actions.inspectTarget('codex');
      expect(serialized.calls.single, [
        'targets',
        'inspect',
        'codex',
        '--include-accessible-environments',
        'true',
        '--enable-agent-cli-model-lookup',
        'true',
      ]);
    },
  );

  test(
    'invalid list projections fail closed without exposing payloads',
    () async {
      final executor = _RecordingExecutor({
        'ok': true,
        'snapshots': 'not-a-list',
      });
      final actions = NativeCommandActions(
        commandExecutor: executor,
        concurrentCommandExecutor: executor,
      );

      expect(await actions.listSnapshots(target: 'codex'), isEmpty);
    },
  );

  test('local skill removal encodes exact path and confirmation', () async {
    final executor = _RecordingExecutor({'ok': true});
    final actions = NativeCommandActions(
      commandExecutor: executor,
      concurrentCommandExecutor: executor,
    );

    await actions.applySkillDelete(
      skillId: 'review',
      path: '/workspace/.agents/skills/review',
      confirmation: 'trash:review:plan-digest',
    );

    expect(
      executor.calls.single,
      containsAllInOrder([
        '--path',
        '/workspace/.agents/skills/review',
        '--confirmation',
        'trash:review:plan-digest',
      ]),
    );
  });

  test(
    'VM targets use private stdin and never place connection data in argv',
    () async {
      final executor = _RecordingExecutor({'ok': true});
      final privateRunner = _RecordingRunner(const {'ok': true});
      final workingDirectory = _guestPath(['srv', 'project']);
      final actions = NativeCommandActions(
        commandExecutor: executor,
        concurrentCommandExecutor: executor,
        privateRunner: privateRunner,
      );

      await actions.addTarget(
        target: 'hermes',
        location: 'virtual-machine',
        runtimeConnection: {
          'kind': 'ssh',
          'host': 'vm.example',
          'remoteExecutable': 'hermes',
          'workingDirectory': workingDirectory,
        },
      );

      expect(executor.calls, isEmpty);
      expect(privateRunner.arguments.single, [
        'targets',
        'add',
        '--target',
        'hermes',
        '--stdin-json',
        'true',
      ]);
      expect(
        privateRunner.arguments.single.join(' '),
        isNot(contains('vm.example')),
      );
      final payload =
          jsonDecode(privateRunner.stdin.single) as Map<String, dynamic>;
      expect(payload['location'], 'virtual-machine');
      expect(
        (payload['runtimeConnection'] as Map<String, dynamic>)['host'],
        'vm.example',
      );
    },
  );
}

String _guestPath(List<String> segments) => ['', ...segments].join('/');

class _RecordingExecutor implements NativeCommandExecutor {
  _RecordingExecutor(this.response);

  final Map<String, dynamic> response;
  final List<List<String>> calls = [];

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) async {
    calls.add(List<String>.unmodifiable(arguments));
    return response;
  }
}

class _RecordingRunner implements AgentCommandRunner {
  _RecordingRunner(this.response);

  final Map<String, dynamic> response;
  final List<List<String>> arguments = [];
  final List<String> stdin = [];

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      throw UnsupportedError('runCli');

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    arguments.add(List<String>.unmodifiable(args));
    stdin.add(stdinText);
    return response;
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}
