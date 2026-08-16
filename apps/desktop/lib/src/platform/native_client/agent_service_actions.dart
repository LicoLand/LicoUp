import 'dart:convert';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

/// Stateless native command builder. It has no process or service lifecycle.
class NativeCommandActions {
  const NativeCommandActions({
    required NativeCommandExecutor commandExecutor,
    required NativeCommandExecutor concurrentCommandExecutor,
    AgentCommandRunner? privateRunner,
  }) : _commandExecutor = commandExecutor,
       _concurrentCommandExecutor = concurrentCommandExecutor,
       _privateRunner = privateRunner;

  final NativeCommandExecutor _commandExecutor;
  final NativeCommandExecutor _concurrentCommandExecutor;
  final AgentCommandRunner? _privateRunner;

  static const List<String> packagedScanTargetIds = [
    'lico-agent',
    'openclaw',
    'claude-code',
    'codex',
    'code',
    'antigravity',
    'opencode',
    'copilot',
    'kilo-code',
    'cursor',
    'hermes',
    'kimi',
    'kimi-code',
    'pi',
  ];

  Future<List<Map<String, dynamic>>> listSnapshots({String target = ''}) async {
    final arguments = ['snapshots', 'list'];
    _appendOptionalArgument(arguments, '--target', target);
    final output = await _commandExecutor.execute(arguments);
    return _listFromOutput(output, 'snapshots');
  }

  Future<List<Map<String, dynamic>>> listPairings({String agent = ''}) async {
    final arguments = ['agents', 'pair', 'list'];
    _appendOptionalArgument(arguments, '--agent', agent);
    final output = await _commandExecutor.execute(arguments);
    return _listFromOutput(output, 'pairings');
  }

  Future<Map<String, dynamic>> requestPairing({
    required String agent,
    String target = '',
  }) {
    final arguments = ['agents', 'pair', 'request', '--agent', agent];
    _appendOptionalArgument(arguments, '--target', target);
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> approvePairing({required String agent}) {
    return _commandExecutor.execute([
      'agents',
      'pair',
      'approve',
      '--agent',
      agent,
    ]);
  }

  Future<Map<String, dynamic>> revokePairing({required String agent}) {
    return _commandExecutor.execute([
      'agents',
      'pair',
      'revoke',
      '--agent',
      agent,
    ]);
  }

  Future<List<Map<String, dynamic>>> listSkills({required String agent}) async {
    final output = await _commandExecutor.execute([
      'skill',
      'list',
      '--agent',
      agent,
    ]);
    return _listFromOutput(output, 'skills');
  }

  /// Explicit, user-consented Antigravity vendor OAuth start. Long-running,
  /// so it uses the one-shot executor: no client-side watchdog may interrupt
  /// the bounded native authorization flow.
  Future<Map<String, dynamic>> authorizeAntigravityRuntime({
    String binaryPath = '',
  }) {
    final arguments = ['adapter', 'antigravity', 'authorize'];
    _appendOptionalArgument(arguments, '--binary-path', binaryPath);
    return _concurrentCommandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> planSkillDelete({
    required String skillId,
    required String path,
  }) {
    final arguments = [
      'skill',
      'delete',
      'plan',
      '--skill',
      skillId,
      '--path',
      path,
    ];
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> applySkillDelete({
    required String skillId,
    required String path,
    required String confirmation,
  }) {
    final arguments = [
      'skill',
      'delete',
      'apply',
      '--skill',
      skillId,
      '--path',
      path,
      '--confirmation',
      confirmation,
    ];
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> reportSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) {
    final arguments = ['skill', 'usage', 'report', '--days', days.toString()];
    _appendOptionalArgument(arguments, '--agent', agent);
    _appendOptionalArgument(arguments, '--skill', skillId);
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> scanSkillUsage({
    String agent = '',
    bool forceRefresh = false,
  }) {
    final arguments = ['skill', 'usage', 'scan'];
    _appendOptionalArgument(arguments, '--agent', agent);
    if (forceRefresh) {
      arguments.add('--force-refresh');
    }
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> opencodeServeStatus() {
    return _commandExecutor.execute(['opencode-serve', 'status']);
  }

  Future<Map<String, dynamic>> ensureOpencodeServe({
    int port = 24173,
    String? executable,
    String? attachUrl,
  }) {
    final arguments = ['opencode-serve', 'ensure', '--port', port.toString()];
    _appendOptionalArgument(arguments, '--executable', executable ?? '');
    _appendOptionalArgument(arguments, '--attach-url', attachUrl ?? '');
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> stopOpencodeServe() {
    return _commandExecutor.execute(['opencode-serve', 'stop']);
  }

  Future<List<TargetCandidate>> scanTargets() async {
    final output = await _commandExecutor.execute([
      'targets',
      'scan',
      '--include-accessible-environments',
      'true',
      '--include-history-model-catalog',
      'false',
    ]);
    if (output['ok'] != true || output['candidates'] is! List) {
      return const [];
    }
    return (output['candidates'] as List)
        .whereType<Map>()
        .map(
          (candidate) =>
              TargetCandidate.fromJson(Map<String, dynamic>.from(candidate)),
        )
        .where((candidate) => candidate.visibleInClient)
        .toList();
  }

  Future<TargetCandidate?> scanOneTarget(String targetId) async {
    final normalizedTargetId = targetId.trim();
    if (normalizedTargetId.isEmpty) {
      return null;
    }
    final output = await _concurrentCommandExecutor.execute([
      'targets',
      'inspect',
      normalizedTargetId,
      '--include-accessible-environments',
      'true',
    ]);
    if (output['ok'] != true || output['target'] is! Map) {
      return null;
    }
    final candidate = TargetCandidate.fromJson(
      Map<String, dynamic>.from(output['target'] as Map),
    );
    return candidate.visibleInClient ? candidate : null;
  }

  Future<Map<String, dynamic>> addTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
    String location = 'local',
    Map<String, dynamic> runtimeConnection = const <String, dynamic>{},
  }) {
    if (runtimeConnection.isNotEmpty) {
      final runner = _privateRunner;
      if (runner == null) {
        throw StateError('private target configuration transport unavailable');
      }
      return runner.runCliWithStdin(
        ['targets', 'add', '--target', target, '--stdin-json', 'true'],
        jsonEncode(<String, dynamic>{
          'target': target,
          'location': location,
          'runtimeConnection': runtimeConnection,
        }),
      );
    }
    final arguments = ['targets', 'add', '--target', target];
    _appendOptionalArgument(arguments, '--config-path', configPath);
    _appendOptionalArgument(arguments, '--binary-path', binaryPath);
    _appendOptionalArgument(arguments, '--history-root', historyRoot);
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> inspectTarget(String target) {
    return _commandExecutor.execute([
      'targets',
      'inspect',
      target,
      '--include-accessible-environments',
      'true',
    ]);
  }

  Future<Map<String, dynamic>> restoreSnapshot(String snapshotId) {
    return _commandExecutor.execute(['snapshots', 'restore', snapshotId]);
  }

  void _appendOptionalArgument(
    List<String> arguments,
    String flag,
    String value,
  ) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      arguments.addAll([flag, trimmed]);
    }
  }

  List<Map<String, dynamic>> _listFromOutput(
    Map<String, dynamic> output,
    String key,
  ) {
    if (output['ok'] == true && output[key] is List) {
      return (output[key] as List).whereType<Map<String, dynamic>>().toList();
    }
    return const [];
  }
}
