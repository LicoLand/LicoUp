part of 'package:flutter_client/src/platform/native_client/agent_service.dart';

mixin AgentServiceActions {
  Future<Map<String, dynamic>> mcpPluginStatus({
    required String target,
    String configPath = '',
  }) async {
    final args = ['mcp', 'plugin', 'status', '--target', target];
    _appendOptionalArg(args, '--config-path', configPath);
    return (this as AgentService)._runCli(args);
  }

  Future<Map<String, dynamic>> updateMcpPlugin({
    required String target,
    String configPath = '',
  }) async {
    final args = ['mcp', 'plugin', 'update', '--target', target];
    _appendOptionalArg(args, '--config-path', configPath);
    return (this as AgentService)._runCli(args);
  }

  Future<Map<String, dynamic>> rollbackMcpPlugin({
    required String target,
    required String snapshotId,
    String configPath = '',
  }) async {
    final args = [
      'mcp',
      'plugin',
      'rollback',
      '--target',
      target,
      '--snapshot-id',
      snapshotId,
    ];
    _appendOptionalArg(args, '--config-path', configPath);
    return (this as AgentService)._runCli(args);
  }

  Future<List<Map<String, dynamic>>> listSnapshots({String target = ''}) async {
    final args = ['snapshots', 'list'];
    _appendOptionalArg(args, '--target', target);
    final output = await (this as AgentService)._runCli(args);
    return _listFromOutput(output, 'snapshots');
  }

  Future<List<Map<String, dynamic>>> listPairings({String agent = ''}) async {
    final args = ['agents', 'pair', 'list'];
    if (agent.isNotEmpty) args.addAll(['--agent', agent]);
    final output = await (this as AgentService)._runCli(args);
    return _listFromOutput(output, 'pairings');
  }

  Future<Map<String, dynamic>> requestPairing({
    required String agent,
    String target = '',
  }) async {
    final args = ['agents', 'pair', 'request', '--agent', agent];
    if (target.isNotEmpty) args.addAll(['--target', target]);
    return (this as AgentService)._runCli(args);
  }

  Future<Map<String, dynamic>> approvePairing({required String agent}) async {
    return (this as AgentService)._runCli([
      'agents',
      'pair',
      'approve',
      '--agent',
      agent,
    ]);
  }

  Future<Map<String, dynamic>> revokePairing({required String agent}) async {
    return (this as AgentService)._runCli([
      'agents',
      'pair',
      'revoke',
      '--agent',
      agent,
    ]);
  }

  Future<List<Map<String, dynamic>>> listSkills({required String agent}) async {
    final output = await (this as AgentService)._runCli([
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
  }) async {
    final args = ['skill', 'install', 'plan', '--agent', agent];
    _appendOptionalArg(args, '--url', url);
    _appendOptionalArg(args, '--source-path', sourcePath);
    _appendOptionalArg(args, '--install-root', installRoot);
    _appendOptionalArg(args, '--name', name);
    if (overwrite) args.addAll(['--overwrite', 'true']);
    return (this as AgentService)._runCli(args);
  }

  Future<Map<String, dynamic>> applySkillInstall({
    required String agent,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
    String name = '',
    bool overwrite = false,
    bool pin = false,
  }) async {
    final args = ['skill', 'install', 'apply', '--agent', agent];
    _appendOptionalArg(args, '--url', url);
    _appendOptionalArg(args, '--source-path', sourcePath);
    _appendOptionalArg(args, '--install-root', installRoot);
    _appendOptionalArg(args, '--name', name);
    if (overwrite) args.addAll(['--overwrite', 'true']);
    if (pin) args.addAll(['--pin', 'true']);
    return (this as AgentService)._runCli(args);
  }

  Future<Map<String, dynamic>> rollbackSkillInstall({
    required String agent,
    required String snapshotId,
  }) async {
    return (this as AgentService)._runCli([
      'skill',
      'install',
      'rollback',
      '--agent',
      agent,
      '--snapshot-id',
      snapshotId,
    ]);
  }

  Future<Map<String, dynamic>> localRuntimeStatus() async {
    return (this as AgentService)._runCli(['local-runtime', 'status']);
  }

  Future<Map<String, dynamic>> ensureLocalRuntime({
    required String sourceRoot,
    required String presetConfig,
    int port = 17328,
    bool rebuild = false,
  }) async {
    final args = [
      'local-runtime',
      'ensure',
      '--source-root',
      sourceRoot,
      '--preset-config',
      presetConfig,
      '--port',
      port.toString(),
    ];
    if (rebuild) {
      args.addAll(['--rebuild', 'true']);
    }
    return (this as AgentService)._runCli(args);
  }

  Future<Map<String, dynamic>> startLocalRuntime({int port = 17328}) async {
    return (this as AgentService)._runCli([
      'local-runtime',
      'start',
      '--port',
      port.toString(),
    ]);
  }

  Future<Map<String, dynamic>> restartLocalRuntime({int port = 17328}) async {
    return (this as AgentService)._runCli([
      'local-runtime',
      'restart',
      '--port',
      port.toString(),
    ]);
  }

  Future<Map<String, dynamic>> stopLocalRuntime() async {
    return (this as AgentService)._runCli(['local-runtime', 'stop']);
  }

  Future<Map<String, dynamic>> localRuntimeLogs({int tail = 200}) async {
    return (this as AgentService)._runCli([
      'local-runtime',
      'logs',
      '--tail',
      tail.toString(),
    ]);
  }

  Future<Map<String, dynamic>> opencodeServeStatus() async {
    return (this as AgentService)._runCli(['opencode-serve', 'status']);
  }

  Future<Map<String, dynamic>> ensureOpencodeServe({
    int port = 24173,
    String? executable,
    String? attachUrl,
  }) async {
    final args = <String>[
      'opencode-serve',
      'ensure',
      '--port',
      port.toString(),
    ];
    _appendOptionalArg(args, '--executable', executable ?? '');
    _appendOptionalArg(args, '--attach-url', attachUrl ?? '');
    return (this as AgentService)._runCli(args);
  }

  Future<Map<String, dynamic>> stopOpencodeServe() async {
    return (this as AgentService)._runCli(['opencode-serve', 'stop']);
  }

  void _appendOptionalArg(List<String> args, String flag, String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      args.addAll([flag, trimmed]);
    }
  }

  List<Map<String, dynamic>> _listFromOutput(
    Map<String, dynamic> output,
    String key,
  ) {
    if (output['ok'] == true && output[key] is List) {
      return (output[key] as List).whereType<Map<String, dynamic>>().toList();
    }
    return [];
  }
}
