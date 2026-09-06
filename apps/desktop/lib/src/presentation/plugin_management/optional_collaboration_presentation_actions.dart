import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_workflow_models.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class OptionalCollaborationPresentationActions {
  const OptionalCollaborationPresentationActions(this._intents);

  final IntentSink<PluginManagementIntent> _intents;

  Future<bool> loadStatus() => _send(const LoadCollaborationStatus());
  Future<bool> enable({required bool confirmed}) =>
      _send(const SetCollaborationEnabled(true));
  Future<bool> disable({required bool confirmed}) =>
      _send(const DisableCollaboration());
  Future<bool> uninstall({required bool confirmed}) =>
      _send(const UninstallCollaboration());
  Future<bool> loadWorkflowCatalog() => _send(const LoadCollaborationCatalog());
  Future<bool> planInstall({
    required String githubUrl,
    String gitRef = '',
    String pluginPath = '',
    bool confirmed = false,
  }) => _send(
    PlanCollaborationInstall(
      githubUrl: githubUrl,
      gitRef: gitRef,
      pluginPath: pluginPath,
    ),
  );
  Future<bool> applyInstall({required bool confirmed}) =>
      _send(const ApplyCollaborationInstall());
  Future<bool> cancelInstall({required bool confirmed}) =>
      _send(const CancelCollaborationInstall());
  Future<bool> importRunnerTrust({
    required String keyId,
    required String publicKeyBase64url,
    required String sourceRepositoryUrl,
    required String expectedFingerprintSha256,
    required bool confirmed,
  }) => _send(
    ImportCollaborationRunnerTrust(
      keyId: keyId,
      publicKeyBase64url: publicKeyBase64url,
      sourceRepositoryUrl: sourceRepositoryUrl,
      expectedFingerprintSha256: expectedFingerprintSha256,
    ),
  );
  Future<bool> removeRunnerTrust({required bool confirmed}) =>
      _send(const RemoveCollaborationRunnerTrust());

  Future<bool> _send(PluginManagementIntent intent) async {
    _intents.send(intent);
    return true;
  }
}

final class OptionalCollaborationWorkflowPresentationActions {
  const OptionalCollaborationWorkflowPresentationActions(
    this._intents,
    this._projection,
  );

  final IntentSink<PluginManagementIntent> _intents;
  final CollaborationProjection _projection;

  OptionalCollaborationWorkflowPlan? get localDeploymentPlan =>
      _projection.localDeploymentPlan;
  OptionalCollaborationWorkflowPlan? get mcpInstallPlan =>
      _projection.mcpInstallPlan;
  List<OptionalLocalServerState> get localServers => _projection.localServers;
  bool get busy => _projection.phase == PresentationPhase.applying;

  Future<bool> planLocalDeployment({
    required List<String> selectedFeatureIds,
    required String destination,
  }) => _send(
    PlanCollaborationLocalDeployment(
      selectedFeatureIds: selectedFeatureIds,
      destination: destination,
    ),
  );
  Future<bool> applyLocalDeployment({required bool confirmed}) =>
      _send(const ApplyCollaborationLocalDeployment());
  Future<bool> planMcpInstall({
    required List<String> selectedPluginIds,
    required List<OptionalCollaborationAgentDestination> agentDestinations,
  }) => _send(
    PlanCollaborationMcpInstall(
      selectedPluginIds: selectedPluginIds,
      agentDestinations: agentDestinations,
    ),
  );
  Future<bool> applyMcpInstall({required bool confirmed}) =>
      _send(const ApplyCollaborationMcpInstall());
  Future<bool> cancel(
    OptionalCollaborationWorkflowKind kind, {
    required bool confirmed,
  }) => _send(CancelCollaborationWorkflow(kind));
  Future<bool> startLocalServer(
    String deploymentId, {
    required bool confirmed,
  }) => _send(StartCollaborationLocalServer(deploymentId));
  Future<bool> loadLocalServerStatus() =>
      _send(const LoadCollaborationLocalServers());
  Future<bool> stopLocalServer(
    String deploymentId, {
    required bool confirmed,
  }) => _send(StopCollaborationLocalServer(deploymentId));
  Future<bool> uninstallLocalServer(
    String deploymentId, {
    required bool confirmed,
  }) => _send(UninstallCollaborationLocalServer(deploymentId));

  Future<bool> _send(PluginManagementIntent intent) async {
    _intents.send(intent);
    return true;
  }
}
