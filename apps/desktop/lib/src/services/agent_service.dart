import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'target_candidate.dart';

export 'target_candidate.dart';

part 'agent_service_actions.dart';

typedef _RunCliExecutable =
    Future<ProcessResult> Function(
      String executable,
      List<String> args,
      Map<String, String>? environment,
    );
typedef _ResolveCliBinary = Future<File?> Function();

class AgentService with AgentServiceActions {
  AgentService({
    Future<String> Function()? dataDirectory,
    Future<File?> Function()? resolveCliBinary,
    Future<ProcessResult> Function(
      String executable,
      List<String> args,
      Map<String, String>? environment,
    )?
    runCliExecutable,
  }) : _dataDirectory = dataDirectory,
       _resolveCliBinaryOverride = resolveCliBinary,
       _runCliExecutable = runCliExecutable ?? _defaultRunCliExecutable;

  final Future<String> Function()? _dataDirectory;
  final _ResolveCliBinary? _resolveCliBinaryOverride;
  final _RunCliExecutable _runCliExecutable;

  static Future<ProcessResult> _defaultRunCliExecutable(
    String executable,
    List<String> args,
    Map<String, String>? environment,
  ) {
    return Process.run(executable, args, environment: environment);
  }

  Future<File?> _resolveCliBinary() async {
    final resolveCliBinaryOverride = _resolveCliBinaryOverride;
    if (resolveCliBinaryOverride != null) {
      return resolveCliBinaryOverride();
    }

    final suffix = Platform.isWindows ? '.exe' : '';
    final override = Platform.environment['LICO_CLIENT_PATH'];
    final cargoTargetDir = Platform.environment['CARGO_TARGET_DIR'];
    final candidates = <String>[
      if (override != null && override.trim().isNotEmpty) override.trim(),
      if (cargoTargetDir != null && cargoTargetDir.trim().isNotEmpty)
        p.join(cargoTargetDir.trim(), 'debug', 'lico-client$suffix'),
      p.join(
        File(Platform.resolvedExecutable).parent.path,
        'lico-client$suffix',
      ),
      p.join(
        Directory.current.path,
        'build',
        'crates',
        'lico-client-native',
        'target',
        'debug',
        'lico-client$suffix',
      ),
      p.join(Directory.current.path, 'target', 'debug', 'lico-client$suffix'),
    ];
    for (final candidate in candidates) {
      final file = File(p.normalize(candidate));
      if (await file.exists()) {
        return file;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _runCli(List<String> args) async {
    final cli = await _resolveCliBinary();

    Map<String, String>? env;
    if (_dataDirectory != null) {
      final dir = await _dataDirectory();
      env = {'LICO_PORTABLE_DIR': dir};
    }

    if (cli == null) {
      try {
        final result = await _runCliExecutable('lico-client', args, env);
        if (result.exitCode != 0) {
          throw Exception('lico-client failed: ${result.stderr}');
        }
        return jsonDecode(result.stdout as String) as Map<String, dynamic>;
      } catch (e) {
        throw Exception('lico-client not found. Make sure it is compiled. $e');
      }
    }

    final result = await _runCliExecutable(cli.path, args, env);
    if (result.exitCode != 0) {
      throw Exception('lico-client failed: ${result.stderr}');
    }
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> runCli(List<String> args) {
    return _runCli(args);
  }

  Future<List<TargetCandidate>> scanTargets() async {
    final output = await _runCli([
      'targets',
      'scan',
      '--include-accessible-environments',
      'false',
    ]);
    if (output['ok'] == true && output['candidates'] is List) {
      final list = output['candidates'] as List;
      return list
          .whereType<Map<String, dynamic>>()
          .map((json) => TargetCandidate.fromJson(json))
          .where((target) => target.visibleInClient)
          .toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> addTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
  }) async {
    final args = ['targets', 'add', '--target', target];
    if (configPath.trim().isNotEmpty) {
      args.addAll(['--config-path', configPath.trim()]);
    }
    if (binaryPath.trim().isNotEmpty) {
      args.addAll(['--binary-path', binaryPath.trim()]);
    }
    if (historyRoot.trim().isNotEmpty) {
      args.addAll(['--history-root', historyRoot.trim()]);
    }
    return _runCli(args);
  }

  Future<Map<String, dynamic>> inspectTarget(String target) async {
    return _runCli(['targets', 'inspect', target]);
  }

  Future<Map<String, dynamic>> planTargetConfig(String target) async {
    return _runCli(['mcp', 'config', 'plan', '--target', target]);
  }

  Future<Map<String, dynamic>> restoreSnapshot(String snapshotId) async {
    return _runCli(['snapshots', 'restore', snapshotId]);
  }
}
