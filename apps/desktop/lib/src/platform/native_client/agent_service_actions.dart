import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

/// Stateless native command builder. It has no process or service lifecycle.
class NativeCommandActions {
  const NativeCommandActions({
    required NativeCommandExecutor commandExecutor,
    required NativeCommandExecutor concurrentCommandExecutor,
  }) : _commandExecutor = commandExecutor,
       _concurrentCommandExecutor = concurrentCommandExecutor;

  final NativeCommandExecutor _commandExecutor;
  final NativeCommandExecutor _concurrentCommandExecutor;

  static const List<String> packagedScanTargetIds = [
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

  Future<Map<String, dynamic>> planSkillInstall({
    required String agent,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
    String name = '',
    bool overwrite = false,
  }) {
    final arguments = ['skill', 'install', 'plan', '--agent', agent];
    _appendOptionalArgument(arguments, '--url', url);
    _appendOptionalArgument(arguments, '--source-path', sourcePath);
    _appendOptionalArgument(arguments, '--install-root', installRoot);
    _appendOptionalArgument(arguments, '--name', name);
    if (overwrite) {
      arguments.addAll(['--overwrite', 'true']);
    }
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> applySkillInstall({
    required String agent,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
    String name = '',
    bool overwrite = false,
    bool pin = false,
  }) {
    final arguments = ['skill', 'install', 'apply', '--agent', agent];
    _appendOptionalArgument(arguments, '--url', url);
    _appendOptionalArgument(arguments, '--source-path', sourcePath);
    _appendOptionalArgument(arguments, '--install-root', installRoot);
    _appendOptionalArgument(arguments, '--name', name);
    if (overwrite) {
      arguments.addAll(['--overwrite', 'true']);
    }
    if (pin) {
      arguments.addAll(['--pin', 'true']);
    }
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> rollbackSkillInstall({
    required String agent,
    required String snapshotId,
  }) {
    return _commandExecutor.execute([
      'skill',
      'install',
      'rollback',
      '--agent',
      agent,
      '--snapshot-id',
      snapshotId,
    ]);
  }

  Future<Map<String, dynamic>> planSkillUpdate({
    required String agent,
    required String skillId,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  }) {
    final arguments = [
      'skill',
      'update',
      'plan',
      '--agent',
      agent,
      '--skill',
      skillId,
    ];
    _appendOptionalArgument(arguments, '--url', url);
    _appendOptionalArgument(arguments, '--source-path', sourcePath);
    _appendOptionalArgument(arguments, '--install-root', installRoot);
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> applySkillUpdate({
    required String agent,
    required String skillId,
    required String confirmation,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  }) {
    final arguments = [
      'skill',
      'update',
      'apply',
      '--agent',
      agent,
      '--skill',
      skillId,
      '--confirmation',
      confirmation,
    ];
    _appendOptionalArgument(arguments, '--url', url);
    _appendOptionalArgument(arguments, '--source-path', sourcePath);
    _appendOptionalArgument(arguments, '--install-root', installRoot);
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> configureSkillAutoUpdate({
    required String agent,
    required String skillId,
    required bool enabled,
    String url = '',
    String sourcePath = '',
  }) {
    final arguments = [
      'skill',
      'auto-update',
      'set',
      '--agent',
      agent,
      '--skill',
      skillId,
      '--enabled',
      enabled.toString(),
      '--direct-user-action',
      'true',
    ];
    _appendOptionalArgument(arguments, '--url', url);
    _appendOptionalArgument(arguments, '--source-path', sourcePath);
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> runConfiguredSkillUpdates({
    required String agent,
    String skillId = '',
  }) {
    final arguments = [
      'skill',
      'auto-update',
      'run',
      '--agent',
      agent,
      '--direct-user-action',
      'true',
    ];
    _appendOptionalArgument(arguments, '--skill', skillId);
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> runDueSkillUpdates() {
    return _concurrentCommandExecutor.execute(['skill', 'auto-update', 'tick']);
  }

  Future<Map<String, dynamic>> planSkillDelete({
    required List<String> agents,
    required String skillId,
    String installRoot = '',
  }) {
    final arguments = [
      'skill',
      'delete',
      'plan',
      '--agents',
      agents.join(','),
      '--skill',
      skillId,
    ];
    _appendOptionalArgument(arguments, '--install-root', installRoot);
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> applySkillDelete({
    required List<String> agents,
    required String skillId,
    required String confirmation,
    String installRoot = '',
  }) {
    final arguments = [
      'skill',
      'delete',
      'apply',
      '--agents',
      agents.join(','),
      '--skill',
      skillId,
      '--confirmation',
      confirmation,
    ];
    _appendOptionalArgument(arguments, '--install-root', installRoot);
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
      'true',
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
  }) {
    final arguments = ['targets', 'add', '--target', target];
    _appendOptionalArgument(arguments, '--config-path', configPath);
    _appendOptionalArgument(arguments, '--binary-path', binaryPath);
    _appendOptionalArgument(arguments, '--history-root', historyRoot);
    return _commandExecutor.execute(arguments);
  }

  Future<Map<String, dynamic>> inspectTarget(String target) {
    return _commandExecutor.execute(['targets', 'inspect', target]);
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
