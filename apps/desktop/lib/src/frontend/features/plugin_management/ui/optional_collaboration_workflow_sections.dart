import 'package:flutter/material.dart';

import 'package:licoup/src/presentation/plugin_management/optional_collaboration_presentation_actions.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_local_assembly_section.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_local_server_section.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_mcp_install_section.dart';

export 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_local_assembly_section.dart'
    show OptionalCollaborationDeploymentSection;
export 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_mcp_install_section.dart'
    show OptionalCollaborationMcpInstallSection;

final class OptionalCollaborationWorkflowSections extends StatelessWidget {
  const OptionalCollaborationWorkflowSections({
    super.key,
    required this.catalog,
    required this.controller,
    required this.isChinese,
  });

  final OptionalCollaborationWorkflowCatalog catalog;
  final OptionalCollaborationWorkflowPresentationActions controller;
  final bool isChinese;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OptionalCollaborationDeploymentSection(
          choices: catalog.localDeploymentChoices,
          controller: controller,
          isChinese: isChinese,
        ),
        const SizedBox(height: 12),
        OptionalCollaborationLocalServerSection(
          controller: controller,
          isChinese: isChinese,
        ),
        const SizedBox(height: 12),
        OptionalCollaborationMcpInstallSection(
          choices: catalog.mcpInstallChoices,
          controller: controller,
          requiresPerFileApproval: catalog.requiresPerFileApproval,
          isChinese: isChinese,
        ),
      ],
    );
  }
}
