import 'package:flutter_client/src/contracts/optional_collaboration_local_server_state.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_mcp_workflow_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_kind.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_parsing.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_plan_models.dart';

final class OptionalCollaborationWorkflowApplyResult {
  const OptionalCollaborationWorkflowApplyResult({
    required this.plan,
    required this.cleanupPending,
    required this.localServer,
  });

  final OptionalCollaborationWorkflowPlan plan;
  final bool cleanupPending;
  final OptionalLocalServerState? localServer;

  factory OptionalCollaborationWorkflowApplyResult.fromJson(
    Map<String, dynamic> json, {
    required OptionalCollaborationWorkflowPlan expectedPlan,
  }) {
    final kind = OptionalCollaborationWorkflowKind.parse(json['workflowKind']);
    if (json['ok'] != true ||
        json['status'] !=
            (kind == OptionalCollaborationWorkflowKind.localDeployment
                ? 'assembled'
                : 'applied') ||
        json['planConsumed'] != true ||
        json['pluginExecuted'] != false ||
        json['pluginCodeExecuted'] != false ||
        json['assemblyAdapterExecuted'] !=
            (kind == OptionalCollaborationWorkflowKind.localDeployment) ||
        json['vendorConfigurationModified'] != false ||
        json['agentRegistrationModified'] !=
            (kind == OptionalCollaborationWorkflowKind.mcpInstall) ||
        json['externalFileTransferAuthorized'] != false ||
        json['outboundPolicy'] !=
            (kind == OptionalCollaborationWorkflowKind.mcpInstall
                ? 'direct-user-exact-scope-one-shot'
                : null) ||
        json['requiresPerFileApproval'] !=
            (kind == OptionalCollaborationWorkflowKind.mcpInstall) ||
        json['cleanupPending'] is! bool ||
        kind != expectedPlan.kind ||
        json['planId'] != expectedPlan.planId ||
        json['packageDigestSha256'] != expectedPlan.packageDigestSha256 ||
        json['pluginId'] != expectedPlan.pluginId) {
      throw const FormatException(
        'optional_collaboration_workflow_apply_binding_invalid',
      );
    }
    final selected = optionalWorkflowRequiredIds(
      json,
      kind == OptionalCollaborationWorkflowKind.localDeployment
          ? 'selectedFeatureIds'
          : 'selectedPluginIds',
    );
    final destination = json['destination'] == null
        ? ''
        : optionalWorkflowRequiredAbsolutePath(json, 'destination');
    final agents =
        optionalWorkflowMaps(json, 'agents', maxItems: 32, allowEmpty: true)
            .map(OptionalCollaborationAgentDestination.fromJson)
            .toList(growable: false);
    final files = optionalWorkflowMaps(
      json,
      'fileChanges',
      maxItems: 4096,
    ).map(OptionalCollaborationFileChange.fromJson).toList(growable: false);
    if (!optionalWorkflowSameStrings(selected, expectedPlan.selectedIds) ||
        destination != expectedPlan.destination ||
        !optionalWorkflowSameDestinations(agents, expectedPlan.agents) ||
        !optionalWorkflowSameFiles(files, expectedPlan.fileChanges)) {
      throw const FormatException(
        'optional_collaboration_workflow_apply_projection_mismatch',
      );
    }
    final registrations = optionalWorkflowMaps(
      json,
      'agentRegistrations',
      maxItems: 32,
      allowEmpty: true,
    );
    if (registrations.length != expectedPlan.agentRegistrations.length) {
      throw const FormatException(
        'optional_collaboration_workflow_apply_registrations_mismatch',
      );
    }
    for (var index = 0; index < registrations.length; index += 1) {
      final registration = registrations[index];
      final expected = expectedPlan.agentRegistrations[index];
      if (registration['registered'] != true ||
          optionalWorkflowRequiredId(registration, 'agentId') !=
              expected.agentId ||
          optionalWorkflowRequiredUuid(registration, 'registrationId') !=
              expected.registrationId ||
          optionalWorkflowRequiredAbsolutePath(registration, 'destination') !=
              expected.destination ||
          optionalWorkflowRequiredSha256(registration, 'digestSha256') !=
              expected.digestSha256) {
        throw const FormatException(
          'optional_collaboration_workflow_apply_registrations_mismatch',
        );
      }
    }
    final localServer = json['localServer'] == null
        ? null
        : OptionalLocalServerState.fromJson(
            optionalWorkflowRequiredMap(json, 'localServer'),
          );
    if ((kind == OptionalCollaborationWorkflowKind.localDeployment) !=
            (localServer != null) ||
        (localServer != null &&
            (expectedPlan.localAssembly == null ||
                !localServer.matchesAssemblyPlan(expectedPlan.localAssembly!) ||
                !localServer.isStopped))) {
      throw const FormatException(
        'optional_collaboration_local_server_apply_binding_invalid',
      );
    }
    return OptionalCollaborationWorkflowApplyResult(
      plan: expectedPlan,
      cleanupPending: json['cleanupPending'] as bool,
      localServer: localServer,
    );
  }
}

final class OptionalCollaborationWorkflowCancellation {
  const OptionalCollaborationWorkflowCancellation({required this.plan});

  final OptionalCollaborationWorkflowPlan plan;

  factory OptionalCollaborationWorkflowCancellation.fromJson(
    Map<String, dynamic> json, {
    required OptionalCollaborationWorkflowPlan expectedPlan,
  }) {
    if (json['ok'] != true ||
        json['status'] != 'cancelled' ||
        json['planConsumed'] != true ||
        OptionalCollaborationWorkflowKind.parse(json['workflowKind']) !=
            expectedPlan.kind ||
        json['planId'] != expectedPlan.planId ||
        json['planDigestSha256'] != expectedPlan.planDigestSha256 ||
        json['packageDigestSha256'] != expectedPlan.packageDigestSha256 ||
        json['pluginId'] != expectedPlan.pluginId) {
      throw const FormatException(
        'optional_collaboration_workflow_cancel_binding_invalid',
      );
    }
    return OptionalCollaborationWorkflowCancellation(plan: expectedPlan);
  }
}
