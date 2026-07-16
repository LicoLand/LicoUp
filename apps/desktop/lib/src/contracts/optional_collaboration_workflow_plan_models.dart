import 'package:flutter_client/src/contracts/optional_collaboration_local_assembly_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_mcp_workflow_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_kind.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_parsing.dart';

final class OptionalCollaborationFileChange {
  const OptionalCollaborationFileChange({
    required this.agentId,
    required this.selectionId,
    required this.sourceRelativePath,
    required this.destination,
    required this.destinationRelativePath,
    required this.digestSha256,
    required this.bytes,
  });

  final String agentId;
  final String selectionId;
  final String sourceRelativePath;
  final String destination;
  final String destinationRelativePath;
  final String digestSha256;
  final int bytes;

  factory OptionalCollaborationFileChange.fromJson(Map<String, dynamic> json) {
    return OptionalCollaborationFileChange(
      agentId: optionalWorkflowOptionalText(json, 'agentId'),
      selectionId: optionalWorkflowRequiredId(json, 'selectionId'),
      sourceRelativePath: optionalWorkflowRequiredRelativePath(
        json,
        'sourceRelativePath',
      ),
      destination: optionalWorkflowRequiredAbsolutePath(json, 'destination'),
      destinationRelativePath: optionalWorkflowRequiredRelativePath(
        json,
        'destinationRelativePath',
      ),
      digestSha256: optionalWorkflowRequiredSha256(json, 'digestSha256'),
      bytes: optionalWorkflowNonNegativeInt(json, 'bytes'),
    );
  }

  bool sameAs(OptionalCollaborationFileChange other) {
    return agentId == other.agentId &&
        selectionId == other.selectionId &&
        sourceRelativePath == other.sourceRelativePath &&
        destination == other.destination &&
        destinationRelativePath == other.destinationRelativePath &&
        digestSha256 == other.digestSha256 &&
        bytes == other.bytes;
  }
}

final class OptionalCollaborationWorkflowPlan {
  const OptionalCollaborationWorkflowPlan({
    required this.kind,
    required this.planId,
    required this.planDigestSha256,
    required this.packageDigestSha256,
    required this.pluginId,
    required this.selectedIds,
    required this.destination,
    required this.agents,
    required this.fileChanges,
    required this.agentRegistrations,
    required this.localAssembly,
    required this.expiresAtEpochSeconds,
  });

  final OptionalCollaborationWorkflowKind kind;
  final String planId;
  final String planDigestSha256;
  final String packageDigestSha256;
  final String pluginId;
  final List<String> selectedIds;
  final String destination;
  final List<OptionalCollaborationAgentDestination> agents;
  final List<OptionalCollaborationFileChange> fileChanges;
  final List<OptionalCollaborationAgentRegistrationPlan> agentRegistrations;
  final OptionalLocalAssemblyPlan? localAssembly;
  final int expiresAtEpochSeconds;

  factory OptionalCollaborationWorkflowPlan.fromJson(
    Map<String, dynamic> json,
  ) {
    final kind = OptionalCollaborationWorkflowKind.parse(json['workflowKind']);
    if (json['ok'] != true ||
        json['status'] != 'planned' ||
        json['oneTime'] != true ||
        json['cancellable'] != true ||
        json['requiresDirectConfirmation'] != true ||
        json['pluginExecuted'] != false ||
        json['pluginCodeWillExecute'] != false ||
        json['assemblyAdapterWillExecute'] !=
            (kind == OptionalCollaborationWorkflowKind.localDeployment) ||
        json['vendorConfigurationModified'] != false ||
        json['agentRegistrationModified'] != false ||
        json['externalFileTransferAuthorized'] != false ||
        json['outboundPolicy'] !=
            (kind == OptionalCollaborationWorkflowKind.mcpInstall
                ? 'direct-user-exact-scope-one-shot'
                : null) ||
        json['requiresPerFileApproval'] !=
            (kind == OptionalCollaborationWorkflowKind.mcpInstall)) {
      throw const FormatException(
        'optional_collaboration_workflow_plan_policy_invalid',
      );
    }
    final selectedIds = optionalWorkflowRequiredIds(
      json,
      kind == OptionalCollaborationWorkflowKind.localDeployment
          ? 'selectedFeatureIds'
          : 'selectedPluginIds',
    );
    final otherSelection =
        json[kind == OptionalCollaborationWorkflowKind.localDeployment
            ? 'selectedPluginIds'
            : 'selectedFeatureIds'];
    if (otherSelection != null) {
      throw const FormatException(
        'optional_collaboration_workflow_plan_selection_invalid',
      );
    }
    final plan = OptionalCollaborationWorkflowPlan(
      kind: kind,
      planId: optionalWorkflowRequiredUuid(json, 'planId'),
      planDigestSha256: optionalWorkflowRequiredSha256(
        json,
        'planDigestSha256',
      ),
      packageDigestSha256: optionalWorkflowRequiredSha256(
        json,
        'packageDigestSha256',
      ),
      pluginId: optionalWorkflowRequiredId(json, 'pluginId'),
      selectedIds: selectedIds,
      destination: json['destination'] == null
          ? ''
          : optionalWorkflowRequiredAbsolutePath(json, 'destination'),
      agents: List.unmodifiable(
        optionalWorkflowMaps(
          json,
          'agents',
          maxItems: 32,
          allowEmpty: true,
        ).map(OptionalCollaborationAgentDestination.fromJson),
      ),
      fileChanges: List.unmodifiable(
        optionalWorkflowMaps(
          json,
          'fileChanges',
          maxItems: 4096,
        ).map(OptionalCollaborationFileChange.fromJson),
      ),
      agentRegistrations: List.unmodifiable(
        optionalWorkflowMaps(
          json,
          'agentRegistrations',
          maxItems: 32,
          allowEmpty: true,
        ).map(OptionalCollaborationAgentRegistrationPlan.fromJson),
      ),
      localAssembly: json['assemblyPlan'] == null
          ? null
          : OptionalLocalAssemblyPlan.fromJson(
              optionalWorkflowRequiredMap(json, 'assemblyPlan'),
            ),
      expiresAtEpochSeconds: optionalWorkflowNonNegativeInt(
        json,
        'expiresAtEpochSeconds',
      ),
    );
    plan._validateShape();
    return plan;
  }

  bool matchesLocalRequest(List<String> selectedFeatureIds, String target) {
    return kind == OptionalCollaborationWorkflowKind.localDeployment &&
        optionalWorkflowSameStrings(selectedIds, selectedFeatureIds) &&
        destination == target &&
        agents.isEmpty;
  }

  bool matchesMcpRequest(
    List<String> selectedPluginIds,
    List<OptionalCollaborationAgentDestination> destinations,
  ) {
    return kind == OptionalCollaborationWorkflowKind.mcpInstall &&
        optionalWorkflowSameStrings(selectedIds, selectedPluginIds) &&
        destination.isEmpty &&
        optionalWorkflowSameDestinations(agents, destinations);
  }

  void _validateShape() {
    final selected = selectedIds.toSet();
    if (fileChanges.isEmpty ||
        fileChanges.any(
          (change) =>
              !selected.contains(change.selectionId) &&
              !(kind == OptionalCollaborationWorkflowKind.localDeployment &&
                  change.selectionId == 'licoarc-assembly-manifest'),
        )) {
      throw const FormatException(
        'optional_collaboration_workflow_file_selection_invalid',
      );
    }
    if (kind == OptionalCollaborationWorkflowKind.localDeployment) {
      if (destination.isEmpty ||
          agents.isNotEmpty ||
          agentRegistrations.isNotEmpty ||
          localAssembly == null ||
          !localAssembly!.matchesWorkflow(
            expectedPluginId: pluginId,
            expectedPackageDigestSha256: packageDigestSha256,
            expectedComponentIds: selectedIds,
            expectedDestination: destination,
          ) ||
          fileChanges.any(
            (change) =>
                change.agentId.isNotEmpty ||
                (!selected.contains(change.selectionId) &&
                    change.selectionId != 'licoarc-assembly-manifest'),
          )) {
        throw const FormatException(
          'optional_collaboration_local_deployment_plan_invalid',
        );
      }
      return;
    }
    final agentIds = agents.map((agent) => agent.agentId).toSet();
    final registrationIds = agentRegistrations
        .map((registration) => registration.agentId)
        .toSet();
    if (destination.isNotEmpty ||
        localAssembly != null ||
        agents.isEmpty ||
        agentIds.length != agents.length ||
        registrationIds.length != agentRegistrations.length ||
        !optionalWorkflowSameStringSets(agentIds, registrationIds) ||
        fileChanges.any(
          (change) =>
              change.agentId.isEmpty || !agentIds.contains(change.agentId),
        )) {
      throw const FormatException(
        'optional_collaboration_mcp_install_plan_invalid',
      );
    }
    for (final planned in agentRegistrations) {
      if (planned.registration.collaborationPluginId != pluginId ||
          planned.registration.packageDigestSha256 != packageDigestSha256 ||
          !optionalWorkflowSameStrings(
            planned.registration.selectedPluginIds,
            selectedIds,
          )) {
        throw const FormatException(
          'optional_collaboration_agent_registration_binding_invalid',
        );
      }
    }
  }
}

bool optionalWorkflowSameDestinations(
  List<OptionalCollaborationAgentDestination> left,
  List<OptionalCollaborationAgentDestination> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (!left[index].sameAs(right[index])) return false;
  }
  return true;
}

bool optionalWorkflowSameFiles(
  List<OptionalCollaborationFileChange> left,
  List<OptionalCollaborationFileChange> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (!left[index].sameAs(right[index])) return false;
  }
  return true;
}
