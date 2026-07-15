import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

export 'package:flutter_client/src/contracts/target_candidate.dart';

part 'agent_service_actions.dart';
part 'agent_service_process_io.dart';
part 'agent_service_stdio_rpc.dart';
part 'proxy_bridge_service_actions.dart';

typedef _RunCliExecutable =
    Future<ProcessResult> Function(
      String executable,
      List<String> args,
      Map<String, String>? environment,
    );
typedef _StartCliExecutable =
    Future<Process> Function(
      String executable,
      List<String> args,
      Map<String, String>? environment,
    );
typedef _ResolveCliBinary = Future<File?> Function();

class LicoClientRpcException implements Exception {
  const LicoClientRpcException(this.code);

  final String code;

  bool get authorizationRequired => code == 'authorization_required';

  @override
  String toString() {
    if (authorizationRequired) {
      return 'lico-client authorization is required.';
    }
    return 'lico-client RPC request failed (code: $code).';
  }
}

class AgentService
    with AgentServiceStdioRpc, AgentServiceActions, AgentServiceProcessIo
    implements AgentCommandRunner {
  AgentService({
    Future<String> Function()? dataDirectory,
    Future<File?> Function()? resolveCliBinary,
    Future<ProcessResult> Function(
      String executable,
      List<String> args,
      Map<String, String>? environment,
    )?
    runCliExecutable,
    Future<Process> Function(
      String executable,
      List<String> args,
      Map<String, String>? environment,
    )?
    startCliExecutable,
    Duration privateRuntimeTimeout = const Duration(seconds: 150),
  }) : _dataDirectory = dataDirectory,
       _resolveCliBinaryOverride = resolveCliBinary,
       _runCliExecutable = runCliExecutable ?? _defaultRunCliExecutable,
       _startCliExecutable = startCliExecutable ?? _defaultStartCliExecutable,
       _persistentStdioRpcEnabled =
           (Platform.isMacOS || Platform.isLinux || Platform.isWindows) &&
           runCliExecutable == null &&
           startCliExecutable == null,
       _privateRuntimeTimeout = privateRuntimeTimeout;

  final Future<String> Function()? _dataDirectory;
  final _ResolveCliBinary? _resolveCliBinaryOverride;
  final _RunCliExecutable _runCliExecutable;
  final _StartCliExecutable _startCliExecutable;
  final bool _persistentStdioRpcEnabled;
  final Duration _privateRuntimeTimeout;

  static Future<ProcessResult> _defaultRunCliExecutable(
    String executable,
    List<String> args,
    Map<String, String>? environment,
  ) {
    return Process.run(executable, args, environment: environment);
  }

  static Future<Process> _defaultStartCliExecutable(
    String executable,
    List<String> args,
    Map<String, String>? environment,
  ) {
    return Process.start(executable, args, environment: environment);
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
    if (_persistentStdioRpcEnabled) {
      return _runCliOverStdioRpc(args);
    }
    return _runCliOneShot(args);
  }

  /// Short-lived process per call — safe to fan out concurrently.
  Future<Map<String, dynamic>> _runCliOneShot(List<String> args) async {
    final cli = await _resolveCliBinary();
    final env = await _cliEnvironment();

    if (cli == null) {
      try {
        final result = await _runCliExecutable('lico-client', args, env);
        if (result.exitCode != 0) {
          throw Exception(
            'lico-client command failed '
            '(exit code ${result.exitCode}, stderr bytes ${utf8.encode(result.stderr.toString()).length}).',
          );
        }
        return _decodeCliResponse(result.stdout);
      } catch (_) {
        throw Exception('lico-client command could not be completed.');
      }
    }

    final result = await _runCliExecutable(cli.path, args, env);
    if (result.exitCode != 0) {
      throw Exception(
        'lico-client command failed '
        '(exit code ${result.exitCode}, stderr bytes ${utf8.encode(result.stderr.toString()).length}).',
      );
    }
    return _decodeCliResponse(result.stdout);
  }

  Map<String, dynamic> _decodeCliResponse(Object? stdout) {
    try {
      final decoded = jsonDecode(stdout?.toString() ?? '');
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on Object {
      // The caller receives a fixed error without command output.
    }
    throw Exception('lico-client returned an invalid JSON response.');
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) {
    return _runCli(args);
  }

  Future<Map<String, String>?> _cliEnvironment() async {
    final environment = <String, String>{
      ..._macOSLocalAuthenticationEnvironment(),
    };
    if (_dataDirectory != null) {
      final dir = await _dataDirectory();
      environment['LICO_CLIENT_PORTABLE_DIR'] = dir;
      environment['LICO_PORTABLE_DIR'] = dir;
      environment.addAll(await _proxyBridgeEnvironment(dir));
    }
    return environment.isEmpty ? null : environment;
  }

  Map<String, String> _macOSLocalAuthenticationEnvironment() {
    if (!Platform.isMacOS) {
      return const {};
    }
    return const {
      'LICO_SECURE_MESH_MACOS_USER_PRESENCE_REQUIRED': 'production',
    };
  }

  Future<Map<String, String>> _proxyBridgeEnvironment(String dataDir) async {
    final file = File(p.join(dataDir, 'lico-client', 'proxy-bridge.json'));
    if (!await file.exists()) {
      return const {};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return const {};
      }
      if (decoded['enabled'] != true) {
        return const {};
      }
      final clientBridge = decoded['clientBridge'];
      if (clientBridge is! Map || clientBridge['enabled'] != true) {
        return const {};
      }
      final environment = clientBridge['environment'];
      if (environment is! Map) {
        return const {};
      }
      final result = <String, String>{};
      for (final entry in environment.entries) {
        final key = entry.key.toString();
        final value = entry.value?.toString() ?? '';
        if (key.trim().isNotEmpty && value.trim().isNotEmpty) {
          result[key] = value;
        }
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  Future<List<TargetCandidate>> scanTargets() async {
    final output = await _runCli([
      'targets',
      'scan',
      '--include-accessible-environments',
      'true',
      '--include-history-model-catalog',
      'true',
    ]);
    if (output['ok'] == true && output['candidates'] is List) {
      final list = output['candidates'] as List;
      return list
          .whereType<Map>()
          .map(
            (json) => TargetCandidate.fromJson(Map<String, dynamic>.from(json)),
          )
          .where((target) => target.visibleInClient)
          .toList();
    }
    return [];
  }

  /// Canonical host-adapter IDs scanned one-at-a-time for incremental discovery.
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

  /// One isolated `targets inspect` process for [targetId].
  ///
  /// Uses a short-lived CLI process (not the serialized stdio RPC queue) so
  /// many agents can be searched concurrently. Returns null when the adapter
  /// is not visible in the client (`not-detected`).
  Future<TargetCandidate?> scanOneTarget(String targetId) async {
    final id = targetId.trim();
    if (id.isEmpty) {
      return null;
    }
    final output = await _runCliOneShot([
      'targets',
      'inspect',
      id,
      '--include-accessible-environments',
      'true',
    ]);
    if (output['ok'] != true) {
      return null;
    }
    final raw = output['target'];
    if (raw is! Map) {
      return null;
    }
    final candidate = TargetCandidate.fromJson(Map<String, dynamic>.from(raw));
    return candidate.visibleInClient ? candidate : null;
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
