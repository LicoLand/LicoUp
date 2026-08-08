import 'package:licoup/src/contracts/optional_collaboration_model_parsing.dart';
import 'package:licoup/src/contracts/optional_collaboration_plugin_models.dart';

final class OptionalCollaborationWorkflowChoice {
  const OptionalCollaborationWorkflowChoice({
    required this.id,
    required this.label,
    required this.description,
    required this.packagePath,
  });

  final String id;
  final String label;
  final String description;
  final String packagePath;

  factory OptionalCollaborationWorkflowChoice.fromJson(
    Map<String, dynamic> json,
  ) {
    return OptionalCollaborationWorkflowChoice(
      id: optionalCollaborationRequiredText(json, 'id'),
      label: optionalCollaborationRequiredText(json, 'label'),
      description: optionalCollaborationOptionalText(json, 'description'),
      packagePath: optionalCollaborationRequiredText(json, 'packagePath'),
    );
  }
}

final class OptionalCollaborationWorkflowCatalog {
  const OptionalCollaborationWorkflowCatalog({
    required this.plugin,
    required this.localDeploymentChoices,
    required this.mcpInstallChoices,
    required this.requiresPerFileApproval,
    required this.externalTransferPolicy,
  });

  final OptionalCollaborationPlugin plugin;
  final List<OptionalCollaborationWorkflowChoice> localDeploymentChoices;
  final List<OptionalCollaborationWorkflowChoice> mcpInstallChoices;
  final bool requiresPerFileApproval;
  final String externalTransferPolicy;

  factory OptionalCollaborationWorkflowCatalog.fromJson(
    Map<String, dynamic> json,
  ) {
    optionalCollaborationRejectExecutableDirectives(json);
    if (json['pluginLoaded'] != true ||
        json['loadPolicy'] != 'explicit-command-only' ||
        json['externalTransferPolicy'] !=
            'direct-exact-operation-approval-required') {
      throw const FormatException(
        'optional_collaboration_catalog_policy_invalid',
      );
    }
    final workflows = optionalCollaborationRequiredMap(json, 'workflows');
    final deployment = optionalCollaborationRequiredMap(
      workflows,
      'localDeployment',
    );
    final mcp = optionalCollaborationRequiredMap(workflows, 'mcpInstall');
    if (deployment['schemaVersion'] !=
            'licoup.collaboration.local-deployment.v1' ||
        mcp['schemaVersion'] != 'licoup.collaboration.mcp-install.v2' ||
        deployment['manualOnly'] != true ||
        mcp['manualOnly'] != true ||
        mcp['requiresPerFileApproval'] != true ||
        mcp['outboundPolicy'] != 'direct-user-exact-scope-one-shot') {
      throw const FormatException(
        'optional_collaboration_workflow_policy_invalid',
      );
    }
    return OptionalCollaborationWorkflowCatalog(
      plugin: OptionalCollaborationPlugin.fromJson(
        optionalCollaborationRequiredMap(json, 'plugin'),
      ),
      localDeploymentChoices: _workflowChoices(deployment['features']),
      mcpInstallChoices: _workflowChoices(mcp['plugins']),
      requiresPerFileApproval: true,
      externalTransferPolicy: optionalCollaborationRequiredText(
        json,
        'externalTransferPolicy',
      ),
    );
  }
}

List<OptionalCollaborationWorkflowChoice> _workflowChoices(Object? value) {
  if (value is! List || value.isEmpty || value.length > 256) {
    throw const FormatException(
      'optional_collaboration_workflow_choices_invalid',
    );
  }
  final result = <OptionalCollaborationWorkflowChoice>[];
  final ids = <String>{};
  final packagePaths = <String>{};
  for (final item in value) {
    if (item is! Map) {
      throw const FormatException(
        'optional_collaboration_workflow_choices_invalid',
      );
    }
    final choice = OptionalCollaborationWorkflowChoice.fromJson(
      item.map((key, value) => MapEntry(key.toString(), value)),
    );
    if (!ids.add(choice.id) ||
        !packagePaths.add(choice.packagePath) ||
        !optionalCollaborationIsRelativePackagePath(choice.packagePath)) {
      throw const FormatException(
        'optional_collaboration_workflow_choice_identity_invalid',
      );
    }
    result.add(choice);
  }
  return List.unmodifiable(result);
}
