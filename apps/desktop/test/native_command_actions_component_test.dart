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
      final actions = NativeCommandActions(
        commandExecutor: serialized,
        concurrentCommandExecutor: concurrent,
      );

      await actions.listPairings(agent: ' codex ');
      final target = await actions.scanOneTarget(' codex ');

      expect(serialized.calls.single, [
        'agents',
        'pair',
        'list',
        '--agent',
        'codex',
      ]);
      expect(concurrent.calls.single, [
        'targets',
        'inspect',
        'codex',
        '--include-accessible-environments',
        'true',
      ]);
      expect(target?.target, 'codex');
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

  test('skill management mutations encode explicit user intent', () async {
    final executor = _RecordingExecutor({'ok': true});
    final actions = NativeCommandActions(
      commandExecutor: executor,
      concurrentCommandExecutor: executor,
    );

    await actions.configureSkillAutoUpdate(
      agent: 'codex',
      skillId: 'review',
      enabled: true,
      sourcePath: ' /mirror/review ',
    );
    await actions.runConfiguredSkillUpdates(agent: 'codex', skillId: 'review');
    await actions.runDueSkillUpdates();
    await actions.applySkillDelete(
      agents: const ['claude-code', 'codex'],
      skillId: 'review',
      confirmation: 'delete:review:claude-code,codex',
    );

    expect(
      executor.calls[0],
      containsAllInOrder([
        'skill',
        'auto-update',
        'set',
        '--direct-user-action',
        'true',
        '--source-path',
        '/mirror/review',
      ]),
    );
    expect(
      executor.calls[1],
      containsAllInOrder([
        'skill',
        'auto-update',
        'run',
        '--direct-user-action',
        'true',
      ]),
    );
    expect(executor.calls[2], equals(['skill', 'auto-update', 'tick']));
    expect(
      executor.calls[3],
      containsAllInOrder([
        '--agents',
        'claude-code,codex',
        '--confirmation',
        'delete:review:claude-code,codex',
      ]),
    );
  });
}

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
