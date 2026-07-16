import 'package:flutter_client/src/contracts/optional_collaboration_workflow_parsing.dart';

final class OptionalCollaborationAgentDestination {
  const OptionalCollaborationAgentDestination({
    required this.agentId,
    required this.installDestination,
  });

  final String agentId;
  final String installDestination;

  factory OptionalCollaborationAgentDestination.fromJson(
    Map<String, dynamic> json,
  ) {
    return OptionalCollaborationAgentDestination(
      agentId: optionalWorkflowRequiredId(json, 'agentId'),
      installDestination: optionalWorkflowRequiredAbsolutePath(
        json,
        'installDestination',
      ),
    );
  }

  Map<String, dynamic> toConfirmedJson() => {
    'agentId': agentId,
    'installDestination': installDestination,
    'confirmed': true,
  };

  bool sameAs(OptionalCollaborationAgentDestination other) {
    return agentId == other.agentId &&
        installDestination == other.installDestination;
  }
}

final class OptionalCollaborationPayloadRoot {
  const OptionalCollaborationPayloadRoot({
    required this.pluginId,
    required this.path,
  });

  final String pluginId;
  final String path;

  factory OptionalCollaborationPayloadRoot.fromJson(Map<String, dynamic> json) {
    return OptionalCollaborationPayloadRoot(
      pluginId: optionalWorkflowRequiredId(json, 'pluginId'),
      path: optionalWorkflowRequiredAbsolutePath(json, 'path'),
    );
  }
}

final class OptionalCollaborationAgentRegistration {
  const OptionalCollaborationAgentRegistration({
    required this.registrationId,
    required this.agentId,
    required this.collaborationPluginId,
    required this.packageDigestSha256,
    required this.selectedPluginIds,
    required this.payloadRoots,
  });

  final String registrationId;
  final String agentId;
  final String collaborationPluginId;
  final String packageDigestSha256;
  final List<String> selectedPluginIds;
  final List<OptionalCollaborationPayloadRoot> payloadRoots;

  factory OptionalCollaborationAgentRegistration.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json['schemaVersion'] != 'licoarc.mcp-agent-registration.v2' ||
        json['bridgeKind'] != 'licoarc-stdio-mcp-gate' ||
        json['activationPolicy'] !=
            'disabled-authenticated-broker-unavailable' ||
        json['automaticTriggersAllowed'] != false ||
        json['pluginExecutedDuringInstall'] != false ||
        json['externalFileTransferAuthorized'] != false ||
        json['outboundPolicy'] != 'direct-user-exact-scope-one-shot' ||
        json['requiresDirectUserConfirmation'] != true) {
      throw const FormatException(
        'optional_collaboration_agent_registration_policy_invalid',
      );
    }
    final selectedPluginIds = optionalWorkflowRequiredIds(
      json,
      'selectedPluginIds',
    );
    final payloadRoots = optionalWorkflowMaps(
      json,
      'payloadRoots',
      maxItems: 256,
    ).map(OptionalCollaborationPayloadRoot.fromJson).toList(growable: false);
    if (!optionalWorkflowSameStrings(
      selectedPluginIds,
      payloadRoots.map((root) => root.pluginId).toList(growable: false),
    )) {
      throw const FormatException(
        'optional_collaboration_agent_registration_selection_invalid',
      );
    }
    return OptionalCollaborationAgentRegistration(
      registrationId: optionalWorkflowRequiredUuid(json, 'registrationId'),
      agentId: optionalWorkflowRequiredId(json, 'agentId'),
      collaborationPluginId: optionalWorkflowRequiredId(
        json,
        'collaborationPluginId',
      ),
      packageDigestSha256: optionalWorkflowRequiredSha256(
        json,
        'packageDigestSha256',
      ),
      selectedPluginIds: selectedPluginIds,
      payloadRoots: List.unmodifiable(payloadRoots),
    );
  }
}

final class OptionalCollaborationAgentRegistrationPlan {
  const OptionalCollaborationAgentRegistrationPlan({
    required this.agentId,
    required this.registrationId,
    required this.destination,
    required this.digestSha256,
    required this.registration,
  });

  final String agentId;
  final String registrationId;
  final String destination;
  final String digestSha256;
  final OptionalCollaborationAgentRegistration registration;

  factory OptionalCollaborationAgentRegistrationPlan.fromJson(
    Map<String, dynamic> json,
  ) {
    final registration = OptionalCollaborationAgentRegistration.fromJson(
      optionalWorkflowRequiredMap(json, 'registration'),
    );
    final plan = OptionalCollaborationAgentRegistrationPlan(
      agentId: optionalWorkflowRequiredId(json, 'agentId'),
      registrationId: optionalWorkflowRequiredUuid(json, 'registrationId'),
      destination: optionalWorkflowRequiredAbsolutePath(json, 'destination'),
      digestSha256: optionalWorkflowRequiredSha256(json, 'digestSha256'),
      registration: registration,
    );
    if (plan.agentId != registration.agentId ||
        plan.registrationId != registration.registrationId) {
      throw const FormatException(
        'optional_collaboration_agent_registration_binding_invalid',
      );
    }
    return plan;
  }
}
