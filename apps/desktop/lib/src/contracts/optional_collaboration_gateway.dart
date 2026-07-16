import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_models.dart';

abstract interface class OptionalCollaborationGateway {
  Future<OptionalCollaborationRuntimeState> status();

  Future<OptionalCollaborationMutation> enable({required bool confirmed});

  Future<OptionalCollaborationRunnerTrustMutation> importRunnerTrust({
    required String keyId,
    required String publicKeyBase64url,
    required String sourceRepositoryUrl,
    required String runnerIdentity,
    required String expectedFingerprintSha256,
    required bool confirmed,
  });

  Future<OptionalCollaborationRunnerTrustMutation> removeRunnerTrust({
    required String expectedFingerprintSha256,
    required String expectedSourceRepositoryUrl,
    required String expectedRunnerIdentity,
    required bool confirmed,
  });

  Future<OptionalCollaborationInstallPlan> planInstall({
    required String githubUrl,
    String gitRef = '',
    String pluginPath = '',
    required bool confirmed,
  });

  Future<OptionalCollaborationMutation> applyInstall({
    required String planId,
    required String expectedDigestSha256,
    required bool confirmed,
  });

  Future<OptionalCollaborationInstallCancellation> cancelInstall({
    required OptionalCollaborationInstallPlan plan,
    required bool confirmed,
  });

  Future<OptionalCollaborationWorkflowCatalog> loadWorkflowCatalog();

  Future<OptionalCollaborationWorkflowPlan> planLocalDeployment({
    required List<String> selectedFeatureIds,
    required String destination,
  });

  Future<OptionalCollaborationWorkflowApplyResult> applyLocalDeployment({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  });

  Future<OptionalCollaborationWorkflowPlan> planMcpInstall({
    required List<String> selectedPluginIds,
    required List<OptionalCollaborationAgentDestination> agentDestinations,
  });

  Future<OptionalCollaborationWorkflowApplyResult> applyMcpInstall({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  });

  Future<OptionalCollaborationWorkflowCancellation> cancelWorkflow({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  });

  Future<List<OptionalLocalServerState>> loadLocalServerStatus();

  Future<OptionalLocalServerState> startLocalServer({
    required String deploymentId,
    required bool confirmed,
  });

  Future<OptionalLocalServerState> stopLocalServer({
    required String deploymentId,
    required bool confirmed,
  });

  Future<OptionalLocalServerUninstallResult> uninstallLocalServer({
    required String deploymentId,
    required String expectedAssemblyManifestDigestSha256,
    required bool confirmed,
  });

  Future<OptionalCollaborationMutation> disable({required bool confirmed});

  Future<OptionalCollaborationMutation> uninstall({
    required String expectedDigestSha256,
    required bool confirmed,
  });
}
