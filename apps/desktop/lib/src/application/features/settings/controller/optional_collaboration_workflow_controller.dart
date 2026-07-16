import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_local_assembly_actions.dart';
import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_mcp_actions.dart';
import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_server_runtime_actions.dart';
import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_workflow_action_context.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_gateway.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_models.dart';

typedef OptionalCollaborationWorkflowStatusSink =
    void Function({
      required String chinese,
      required String english,
      String errorCode,
    });

/// Inert façade over local assembly, signed-runner deployment, and MCP action
/// controllers. Construction never issues a command.
final class OptionalCollaborationWorkflowController extends ChangeNotifier
    implements OptionalCollaborationWorkflowActionContext {
  OptionalCollaborationWorkflowController({
    required OptionalCollaborationGateway gateway,
    OptionalCollaborationWorkflowStatusSink? onStatus,
  }) : _gateway = gateway,
       _onStatus = onStatus {
    _localAssembly = OptionalCollaborationLocalAssemblyActions(this);
    _serverRuntime = OptionalCollaborationServerRuntimeActions(this);
    _mcp = OptionalCollaborationMcpActions(this);
  }

  final OptionalCollaborationGateway _gateway;
  final OptionalCollaborationWorkflowStatusSink? _onStatus;
  late final OptionalCollaborationLocalAssemblyActions _localAssembly;
  late final OptionalCollaborationServerRuntimeActions _serverRuntime;
  late final OptionalCollaborationMcpActions _mcp;

  OptionalCollaborationWorkflowCatalog? _catalog;
  OptionalCollaborationWorkflowPlan? _localDeploymentPlan;
  OptionalCollaborationWorkflowPlan? _mcpInstallPlan;
  OptionalCollaborationWorkflowApplyResult? _lastApplyResult;
  List<OptionalLocalServerState> _localServers = const [];
  bool _busy = false;
  String _errorCode = '';

  @override
  OptionalCollaborationGateway get gateway => _gateway;

  @override
  OptionalCollaborationWorkflowCatalog? get catalog => _catalog;

  @override
  OptionalCollaborationWorkflowPlan? get localDeploymentPlan =>
      _localDeploymentPlan;

  @override
  set localDeploymentPlan(OptionalCollaborationWorkflowPlan? value) =>
      _localDeploymentPlan = value;

  @override
  OptionalCollaborationWorkflowPlan? get mcpInstallPlan => _mcpInstallPlan;

  @override
  set mcpInstallPlan(OptionalCollaborationWorkflowPlan? value) =>
      _mcpInstallPlan = value;

  @override
  OptionalCollaborationWorkflowApplyResult? get lastApplyResult =>
      _lastApplyResult;

  @override
  set lastApplyResult(OptionalCollaborationWorkflowApplyResult? value) =>
      _lastApplyResult = value;

  @override
  List<OptionalLocalServerState> get localServers => _localServers;

  @override
  set localServers(List<OptionalLocalServerState> value) =>
      _localServers = List.unmodifiable(value);

  bool get busy => _busy;
  String get errorCode => _errorCode;

  void replaceCatalog(OptionalCollaborationWorkflowCatalog? catalog) {
    if (identical(_catalog, catalog)) return;
    _catalog = catalog;
    _localDeploymentPlan = null;
    _mcpInstallPlan = null;
    _lastApplyResult = null;
    _errorCode = '';
    notifyListeners();
  }

  Future<bool> planLocalDeployment({
    required List<String> selectedFeatureIds,
    required String destination,
  }) => _localAssembly.plan(
    selectedFeatureIds: selectedFeatureIds,
    destination: destination,
  );

  Future<bool> applyLocalDeployment({required bool confirmed}) =>
      _localAssembly.apply(confirmed: confirmed);

  Future<bool> planMcpInstall({
    required List<String> selectedPluginIds,
    required List<OptionalCollaborationAgentDestination> agentDestinations,
  }) => _mcp.plan(
    selectedPluginIds: selectedPluginIds,
    agentDestinations: agentDestinations,
  );

  Future<bool> applyMcpInstall({required bool confirmed}) =>
      _mcp.apply(confirmed: confirmed);

  Future<bool> cancel(
    OptionalCollaborationWorkflowKind kind, {
    required bool confirmed,
  }) => kind == OptionalCollaborationWorkflowKind.localDeployment
      ? _localAssembly.cancel(confirmed: confirmed)
      : _mcp.cancel(confirmed: confirmed);

  Future<bool> loadLocalServerStatus() => _serverRuntime.loadStatus();

  Future<bool> startLocalServer(
    String deploymentId, {
    required bool confirmed,
  }) => _serverRuntime.start(deploymentId, confirmed: confirmed);

  Future<bool> stopLocalServer(
    String deploymentId, {
    required bool confirmed,
  }) => _serverRuntime.stop(deploymentId, confirmed: confirmed);

  Future<bool> uninstallLocalServer(
    String deploymentId, {
    required bool confirmed,
  }) => _serverRuntime.uninstall(deploymentId, confirmed: confirmed);

  @override
  OptionalLocalServerState? localServerById(String deploymentId) {
    for (final server in _localServers) {
      if (server.deploymentId == deploymentId) return server;
    }
    return null;
  }

  @override
  void replaceLocalServer(OptionalLocalServerState server) {
    final next = [
      for (final existing in _localServers)
        if (existing.deploymentId != server.deploymentId) existing,
      server,
    ]..sort((left, right) => left.deploymentId.compareTo(right.deploymentId));
    _localServers = List.unmodifiable(next);
  }

  @override
  bool beginAction() {
    if (_busy) return false;
    _busy = true;
    _errorCode = '';
    notifyListeners();
    return true;
  }

  @override
  void endAction() {
    _busy = false;
    notifyListeners();
  }

  @override
  bool rejectAction(String errorCode, String chinese, String english) {
    _errorCode = errorCode;
    reportAction(chinese, english, errorCode: errorCode);
    notifyListeners();
    return false;
  }

  @override
  void failAction(String errorCode, String chinese, String english) {
    _errorCode = errorCode;
    reportAction(chinese, english, errorCode: errorCode);
  }

  @override
  void reportAction(String chinese, String english, {String errorCode = ''}) {
    _onStatus?.call(chinese: chinese, english: english, errorCode: errorCode);
  }
}
