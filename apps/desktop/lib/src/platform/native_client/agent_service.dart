import 'dart:io';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/generated/client_state.g.dart';
import 'package:licoup/src/contracts/mcp_adapter.dart';
import 'package:licoup/src/contracts/skill_delete.dart';
import 'package:licoup/src/contracts/skill_hub.dart';
import 'package:licoup/src/contracts/skill_update.dart';
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
import 'package:licoup/src/platform/native_client/orchestrator_ipc/client.dart';

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
        SkillUpdateGateway,
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

  late final NativeOrchestratorClient orchestratorClient =
      NativeOrchestratorClient(transport: _stdioRpcTransport);

  static const List<String> packagedScanTargetIds =
      NativeCommandActions.packagedScanTargetIds;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) {
    return _commandExecutor.execute(args);
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

  Future<List<Map<String, dynamic>>> listSnapshots({String target = ''}) {
    return _commandActions.listSnapshots(target: target);
  }

  @override
  Future<List<Map<String, dynamic>>> listPairings({String agent = ''}) {
    return _commandActions.listPairings(agent: agent);
  }

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

  @override
  Future<Map<String, dynamic>> planSkillInstall({
    required String agent,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
    String name = '',
    bool overwrite = false,
  }) {
    return _commandActions.planSkillInstall(
      agent: agent,
      url: url,
      sourcePath: sourcePath,
      installRoot: installRoot,
      name: name,
      overwrite: overwrite,
    );
  }

  @override
  Future<Map<String, dynamic>> applySkillInstall({
    required String agent,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
    String name = '',
    bool overwrite = false,
    bool pin = false,
  }) {
    return _commandActions.applySkillInstall(
      agent: agent,
      url: url,
      sourcePath: sourcePath,
      installRoot: installRoot,
      name: name,
      overwrite: overwrite,
      pin: pin,
    );
  }

  @override
  Future<Map<String, dynamic>> rollbackSkillInstall({
    required String agent,
    required String snapshotId,
  }) {
    return _commandActions.rollbackSkillInstall(
      agent: agent,
      snapshotId: snapshotId,
    );
  }

  @override
  Future<Map<String, dynamic>> planSkillUpdate({
    required String agent,
    required String skillId,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  }) {
    return _commandActions.planSkillUpdate(
      agent: agent,
      skillId: skillId,
      url: url,
      sourcePath: sourcePath,
      installRoot: installRoot,
    );
  }

  @override
  Future<Map<String, dynamic>> applySkillUpdate({
    required String agent,
    required String skillId,
    required String confirmation,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  }) {
    return _commandActions.applySkillUpdate(
      agent: agent,
      skillId: skillId,
      confirmation: confirmation,
      url: url,
      sourcePath: sourcePath,
      installRoot: installRoot,
    );
  }

  @override
  Future<Map<String, dynamic>> configureSkillAutoUpdate({
    required String agent,
    required String skillId,
    required bool enabled,
    String url = '',
    String sourcePath = '',
  }) {
    return _commandActions.configureSkillAutoUpdate(
      agent: agent,
      skillId: skillId,
      enabled: enabled,
      url: url,
      sourcePath: sourcePath,
    );
  }

  @override
  Future<Map<String, dynamic>> runConfiguredSkillUpdates({
    required String agent,
    String skillId = '',
  }) {
    return _commandActions.runConfiguredSkillUpdates(
      agent: agent,
      skillId: skillId,
    );
  }

  @override
  Future<Map<String, dynamic>> runDueSkillUpdates() {
    return _commandActions.runDueSkillUpdates();
  }

  @override
  Future<Map<String, dynamic>> planSkillDelete({
    required List<String> agents,
    required String skillId,
    String installRoot = '',
  }) {
    return _commandActions.planSkillDelete(
      agents: agents,
      skillId: skillId,
      installRoot: installRoot,
    );
  }

  @override
  Future<Map<String, dynamic>> applySkillDelete({
    required List<String> agents,
    required String skillId,
    required String confirmation,
    String installRoot = '',
  }) {
    return _commandActions.applySkillDelete(
      agents: agents,
      skillId: skillId,
      confirmation: confirmation,
      installRoot: installRoot,
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

  Future<Map<String, dynamic>> stopOpencodeServe() {
    return _commandActions.stopOpencodeServe();
  }

  Future<List<TargetCandidate>> scanTargets() {
    return _commandActions.scanTargets();
  }

  @override
  Future<TargetCandidate?> scanOneTarget(String targetId) {
    return _commandActions.scanOneTarget(targetId);
  }

  @override
  Future<Map<String, dynamic>> addTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
  }) {
    return _commandActions.addTarget(
      target: target,
      configPath: configPath,
      binaryPath: binaryPath,
      historyRoot: historyRoot,
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
