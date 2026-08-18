import 'dart:io';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/generated/client_state.g.dart';
import 'package:licoup/src/contracts/mcp_adapter.dart';
import 'package:licoup/src/contracts/skill_delete.dart';
import 'package:licoup/src/contracts/skill_hub.dart';
import 'package:licoup/src/contracts/skill_usage.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/contracts/target_management.dart';
import 'package:licoup/src/platform/native_client/agent_service_actions.dart';
import 'package:licoup/src/platform/native_client/agent_service_process_io.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_catalog_actions.dart';
import 'package:licoup/src/platform/native_client/native_cli_runtime_context.dart';
import 'package:licoup/src/platform/native_client/native_command_router.dart';
import 'package:licoup/src/platform/native_client/native_mcp_actions.dart';
import 'package:licoup/src/platform/native_client/native_one_shot_command_executor.dart';
import 'package:licoup/src/platform/native_client/native_state_actions.dart';

export 'package:licoup/src/contracts/target_candidate.dart';
export 'package:licoup/src/platform/native_client/native_cli_ports.dart'
    show LicoClientRpcException;

/// Public native-client facade.
///
/// Process lifecycle, stdio framing, and command construction are owned by
/// injected components. This class only preserves the
/// stable client-facing contract and coordinates component disposal.
class AgentService
    implements
        AgentCommandRunner,
        McpAdapterGateway,
        SkillDeleteGateway,
        SkillHubGateway,
        SkillUsageGateway,
        TargetManagementGateway {
  AgentService({
    Future<String> Function()? dataDirectory,
    NativeResolveCliBinary? resolveCliBinary,
    NativeRunCliExecutable? runCliExecutable,
    NativeStartCliExecutable? startCliExecutable,
    Duration privateRuntimeTimeout = const Duration(seconds: 150),
    NativeCliProcessContext? processContext,
    NativeCommandExecutor? oneShotCommandExecutor,
    NativeStdioRpcTransport? stdioRpcTransport,
    AgentCommandRunner? processIo,
    NativeCommandActions? commandActions,
    bool? persistentStdioRpcEnabled,
  }) {
    final runtimeContext =
        processContext ??
        NativeCliRuntimeContext(
          dataDirectory: dataDirectory,
          resolveCliBinary: resolveCliBinary,
          startCliExecutable: startCliExecutable,
          requestTimeout: privateRuntimeTimeout,
        );
    final oneShotExecutor =
        oneShotCommandExecutor ??
        NativeOneShotCommandExecutor(
          processContext: runtimeContext,
          runCliExecutable: runCliExecutable,
        );
    final rpcTransport =
        stdioRpcTransport ??
        NativeStdioRpcClient(processContext: runtimeContext);
    final persistentEnabled =
        persistentStdioRpcEnabled ??
        ((Platform.isMacOS || Platform.isLinux || Platform.isWindows) &&
            runCliExecutable == null &&
            startCliExecutable == null &&
            oneShotCommandExecutor == null &&
            stdioRpcTransport == null &&
            processIo == null);
    final commandExecutor = NativeCommandRouter(
      oneShotExecutor: oneShotExecutor,
      stdioRpcTransport: rpcTransport,
      persistentStdioRpcEnabled: persistentEnabled,
    );

    _commandExecutor = commandExecutor;
    _stdioRpcTransport = rpcTransport;
    _processIo =
        processIo ??
        BoundedNativeProcessIo(
          processContext: runtimeContext,
          commandExecutor: commandExecutor,
          stdioRpcTransport: rpcTransport,
          persistentStdioRpcEnabled: persistentEnabled,
        );
    _commandActions =
        commandActions ??
        NativeCommandActions(
          commandExecutor: commandExecutor,
          concurrentCommandExecutor: oneShotExecutor,
          privateRunner: _processIo,
        );
    _mcpActions = NativeMcpActions(privateRunner: _processIo);
    _catalogActions = NativeCatalogActions(
      privateRunner: _processIo,
      stdioRpcTransport: rpcTransport,
      persistentStdioRpcEnabled: persistentEnabled,
    );
    _stateActions = NativeStateActions(stdioRpcTransport: rpcTransport);
  }

  late final NativeCommandExecutor _commandExecutor;
  late final NativeStdioRpcTransport _stdioRpcTransport;
  late final AgentCommandRunner _processIo;
  late final NativeCommandActions _commandActions;
  late final NativeMcpActions _mcpActions;
  late final NativeCatalogActions _catalogActions;
  late final NativeStateActions _stateActions;

  static const List<String> packagedScanTargetIds =
      NativeCommandActions.packagedScanTargetIds;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      _commandExecutor.execute(args);

  Future<Map<String, dynamic>> planCodexPlugin({required String binaryPath}) {
    return runCli([
      'adapter',
      'codex',
      'plugin',
      'plan',
      '--binary-path',
      binaryPath,
    ]);
  }

  Future<Map<String, dynamic>> codexPluginStatus({required String binaryPath}) {
    return runCli([
      'adapter',
      'codex',
      'plugin',
      'status',
      '--binary-path',
      binaryPath,
    ]);
  }

  Future<Map<String, dynamic>> installCodexPlugin({
    required String binaryPath,
    required String confirmation,
  }) {
    return runCli([
      'adapter',
      'codex',
      'plugin',
      'install',
      '--binary-path',
      binaryPath,
      '--confirmation',
      confirmation,
      '--confirmed',
    ]);
  }

  Future<Map<String, dynamic>> subagentMcpStatus({
    required String agentId,
    String? binaryPath,
    String? mcpBinaryPath,
  }) {
    return runCli([
      'adapter',
      'subagent-mcp',
      'status',
      '--agent-id',
      agentId,
      if (binaryPath != null && binaryPath.trim().isNotEmpty) ...[
        '--binary-path',
        binaryPath.trim(),
      ],
      if (mcpBinaryPath != null && mcpBinaryPath.trim().isNotEmpty) ...[
        '--mcp-binary-path',
        mcpBinaryPath.trim(),
      ],
    ]);
  }

  Future<Map<String, dynamic>> planSubagentMcp({
    required String agentId,
    String? binaryPath,
    String? mcpBinaryPath,
  }) {
    return runCli([
      'adapter',
      'subagent-mcp',
      'plan',
      '--agent-id',
      agentId,
      if (binaryPath != null && binaryPath.trim().isNotEmpty) ...[
        '--binary-path',
        binaryPath.trim(),
      ],
      if (mcpBinaryPath != null && mcpBinaryPath.trim().isNotEmpty) ...[
        '--mcp-binary-path',
        mcpBinaryPath.trim(),
      ],
    ]);
  }

  Future<Map<String, dynamic>> installSubagentMcp({
    required String agentId,
    required String confirmation,
    String? binaryPath,
    String? mcpBinaryPath,
  }) {
    return runCli([
      'adapter',
      'subagent-mcp',
      'install',
      '--agent-id',
      agentId,
      if (binaryPath != null && binaryPath.trim().isNotEmpty) ...[
        '--binary-path',
        binaryPath.trim(),
      ],
      if (mcpBinaryPath != null && mcpBinaryPath.trim().isNotEmpty) ...[
        '--mcp-binary-path',
        mcpBinaryPath.trim(),
      ],
      '--confirmation',
      confirmation,
      '--confirmed',
    ]);
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) {
    return _processIo.runCliWithStdin(args, stdinText);
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) {
    return _processIo.streamCliJsonLines(args);
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) {
    return _processIo.streamCliJsonLinesWithStdin(args, stdinText);
  }

  Future<List<Map<String, dynamic>>> listSnapshots({String target = ''}) =>
      _commandActions.listSnapshots(target: target);

  @override
  Future<List<Map<String, dynamic>>> listPairings({String agent = ''}) =>
      _commandActions.listPairings(agent: agent);

  @override
  Future<Map<String, dynamic>> requestPairing({
    required String agent,
    String target = '',
  }) {
    return _commandActions.requestPairing(agent: agent, target: target);
  }

  @override
  Future<Map<String, dynamic>> approvePairing({required String agent}) {
    return _commandActions.approvePairing(agent: agent);
  }

  @override
  Future<Map<String, dynamic>> revokePairing({required String agent}) {
    return _commandActions.revokePairing(agent: agent);
  }

  @override
  Future<List<Map<String, dynamic>>> listSkills({required String agent}) {
    return _commandActions.listSkills(agent: agent);
  }

  Future<Map<String, dynamic>> authorizeAntigravityRuntime({
    String binaryPath = '',
  }) => _commandActions.authorizeAntigravityRuntime(binaryPath: binaryPath);

  @override
  Future<Map<String, dynamic>> planSkillDelete({
    required String skillId,
    required String path,
  }) {
    return _commandActions.planSkillDelete(skillId: skillId, path: path);
  }

  @override
  Future<Map<String, dynamic>> applySkillDelete({
    required String skillId,
    required String path,
    required String confirmation,
  }) {
    return _commandActions.applySkillDelete(
      skillId: skillId,
      path: path,
      confirmation: confirmation,
    );
  }

  @override
  Future<Map<String, dynamic>> reportSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) {
    return _commandActions.reportSkillUsage(
      days: days,
      agent: agent,
      skillId: skillId,
    );
  }

  @override
  Future<Map<String, dynamic>> scanSkillUsage({
    String agent = '',
    bool forceRefresh = false,
  }) {
    return _commandActions.scanSkillUsage(
      agent: agent,
      forceRefresh: forceRefresh,
    );
  }

  Future<Map<String, dynamic>> opencodeServeStatus() {
    return _commandActions.opencodeServeStatus();
  }

  Future<Map<String, dynamic>> runCatalogCommand(
    String operation, {
    Map<String, dynamic> params = const {},
  }) => _catalogActions.execute(operation, params: params);

  Future<ClientStateGetResult> getClientState(ClientStateGetRequest request) =>
      _stateActions.get(request);

  Future<ClientStateSetResult> setClientState(ClientStateSetRequest request) =>
      _stateActions.set(request);

  Future<Map<String, dynamic>> ensureOpencodeServe({
    int port = 24173,
    String? executable,
    String? attachUrl,
  }) {
    return _commandActions.ensureOpencodeServe(
      port: port,
      executable: executable,
      attachUrl: attachUrl,
    );
  }

  Future<Map<String, dynamic>> stopOpencodeServe() =>
      _commandActions.stopOpencodeServe();

  Future<List<TargetCandidate>> scanTargets() => _commandActions.scanTargets();

  @override
  Future<TargetCandidate?> scanOneTarget(
    String targetId, {
    bool enableAgentCliModelLookup = false,
  }) {
    return _commandActions.scanOneTarget(
      targetId,
      enableAgentCliModelLookup: enableAgentCliModelLookup,
    );
  }

  @override
  Future<Map<String, dynamic>> addTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
    String location = 'local',
    Map<String, dynamic> runtimeConnection = const <String, dynamic>{},
  }) {
    return _commandActions.addTarget(
      target: target,
      configPath: configPath,
      binaryPath: binaryPath,
      historyRoot: historyRoot,
      location: location,
      runtimeConnection: runtimeConnection,
    );
  }

  @override
  Future<Map<String, dynamic>> inspectTarget(String target) {
    return _commandActions.inspectTarget(target);
  }

  @override
  Future<Map<String, dynamic>> restoreSnapshot(String snapshotId) {
    return _commandActions.restoreSnapshot(snapshotId);
  }

  @override
  Future<McpHttpTransferPreview> previewHttpTransfer(
    McpHttpTransferRequest request,
  ) {
    return _mcpActions.previewHttpTransfer(request);
  }

  @override
  Future<McpHttpTransferResult> executeHttpTransfer(
    McpHttpTransferPreview preview, {
    required bool confirmed,
  }) {
    return _mcpActions.executeHttpTransfer(preview, confirmed: confirmed);
  }

  Future<void> dispose() {
    return _stdioRpcTransport.dispose();
  }
}
