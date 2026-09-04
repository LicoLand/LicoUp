import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/optional_collaboration_workflow_models.dart';

sealed class PluginManagementIntent {
  const PluginManagementIntent({this.trace});

  final TraceContext? trace;
}

final class RefreshPlugins extends PluginManagementIntent {
  const RefreshPlugins({super.trace});
}

final class PlanPluginInstall extends PluginManagementIntent {
  const PlanPluginInstall(this.agentId, this.pluginId, {super.trace});

  final String agentId;
  final String pluginId;
}

final class PlanPluginUninstall extends PluginManagementIntent {
  const PlanPluginUninstall(this.agentId, this.pluginId, {super.trace});

  final String agentId;
  final String pluginId;
}

final class ApplyPluginLifecyclePlan extends PluginManagementIntent {
  const ApplyPluginLifecyclePlan(this.planId, {super.trace});

  final String planId;
}

final class LoadCollaborationStatus extends PluginManagementIntent {
  const LoadCollaborationStatus({super.trace});
}

final class SetCollaborationEnabled extends PluginManagementIntent {
  const SetCollaborationEnabled(this.enabled, {super.trace});

  final bool enabled;
}

final class LoadCollaborationCatalog extends PluginManagementIntent {
  const LoadCollaborationCatalog({super.trace});
}

final class PlanCollaborationInstall extends PluginManagementIntent {
  const PlanCollaborationInstall({
    required this.githubUrl,
    this.gitRef = '',
    this.pluginPath = '',
    super.trace,
  });

  final String githubUrl;
  final String gitRef;
  final String pluginPath;
}

final class ApplyCollaborationInstall extends PluginManagementIntent {
  const ApplyCollaborationInstall({super.trace});
}

final class CancelCollaborationInstall extends PluginManagementIntent {
  const CancelCollaborationInstall({super.trace});
}

final class ImportCollaborationRunnerTrust extends PluginManagementIntent {
  const ImportCollaborationRunnerTrust({
    required this.keyId,
    required this.publicKeyBase64url,
    required this.sourceRepositoryUrl,
    required this.expectedFingerprintSha256,
    super.trace,
  });

  final String keyId;
  final String publicKeyBase64url;
  final String sourceRepositoryUrl;
  final String expectedFingerprintSha256;
}

final class RemoveCollaborationRunnerTrust extends PluginManagementIntent {
  const RemoveCollaborationRunnerTrust({super.trace});
}

final class DisableCollaboration extends PluginManagementIntent {
  const DisableCollaboration({super.trace});
}

final class UninstallCollaboration extends PluginManagementIntent {
  const UninstallCollaboration({super.trace});
}

final class PlanCollaborationLocalDeployment extends PluginManagementIntent {
  PlanCollaborationLocalDeployment({
    required Iterable<String> selectedFeatureIds,
    required this.destination,
    super.trace,
  }) : selectedFeatureIds = List.unmodifiable(selectedFeatureIds);

  final List<String> selectedFeatureIds;
  final String destination;
}

final class ApplyCollaborationLocalDeployment extends PluginManagementIntent {
  const ApplyCollaborationLocalDeployment({super.trace});
}

final class PlanCollaborationMcpInstall extends PluginManagementIntent {
  PlanCollaborationMcpInstall({
    required Iterable<String> selectedPluginIds,
    required Iterable<OptionalCollaborationAgentDestination> agentDestinations,
    super.trace,
  }) : selectedPluginIds = List.unmodifiable(selectedPluginIds),
       agentDestinations = List.unmodifiable(agentDestinations);

  final List<String> selectedPluginIds;
  final List<OptionalCollaborationAgentDestination> agentDestinations;
}

final class ApplyCollaborationMcpInstall extends PluginManagementIntent {
  const ApplyCollaborationMcpInstall({super.trace});
}

final class CancelCollaborationWorkflow extends PluginManagementIntent {
  const CancelCollaborationWorkflow(this.kind, {super.trace});

  final OptionalCollaborationWorkflowKind kind;
}

final class StartCollaborationLocalServer extends PluginManagementIntent {
  const StartCollaborationLocalServer(this.deploymentId, {super.trace});

  final String deploymentId;
}

final class LoadCollaborationLocalServers extends PluginManagementIntent {
  const LoadCollaborationLocalServers({super.trace});
}

final class StopCollaborationLocalServer extends PluginManagementIntent {
  const StopCollaborationLocalServer(this.deploymentId, {super.trace});

  final String deploymentId;
}

final class UninstallCollaborationLocalServer extends PluginManagementIntent {
  const UninstallCollaborationLocalServer(this.deploymentId, {super.trace});

  final String deploymentId;
}
