import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_catalog_action.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_install_section.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_lifecycle_sections.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_runner_trust_section.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_settings_policy.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_status_card.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_workflow_sections.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/plugin_management/optional_collaboration_presentation_actions.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class OptionalCollaborationSettings extends StatelessWidget {
  const OptionalCollaborationSettings({
    super.key,
    required this.binding,
    required this.projection,
  });

  final PluginManagementBinding binding;
  final CollaborationProjection projection;

  @override
  Widget build(BuildContext context) {
    final isChinese = LicoStrings.of(context).isChinese;
    final state = projection.runtimeState;
    final catalog = projection.workflowCatalog;
    final busy = projection.phase == PresentationPhase.applying;
    final actions = OptionalCollaborationPresentationActions(binding.intents);
    final workflowActions = OptionalCollaborationWorkflowPresentationActions(
      binding.intents,
      projection,
    );
    return Padding(
      key: const Key('optional-collaboration-settings'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OptionalCollaborationSettingsHeader(isChinese: isChinese),
          const SizedBox(height: 12),
          OptionalCollaborationPolicyNotice(isChinese: isChinese),
          const SizedBox(height: 16),
          OptionalCollaborationStatusCard(
            state: state,
            statusLoaded: projection.statusLoaded,
            busy: busy,
            isChinese: isChinese,
            onLoadStatus: () => unawaited(actions.loadStatus()),
          ),
          const SizedBox(height: 12),
          if (state?.capabilityEnabled != true)
            OptionalCollaborationEnableSection(
              controller: actions,
              busy: busy,
              isChinese: isChinese,
            ),
          if (state?.capabilityEnabled == true) ...[
            OptionalCollaborationRunnerTrustSection(
              controller: actions,
              state: state!,
              busy: busy,
              isChinese: isChinese,
            ),
            if (!state.pluginInstalled) ...[
              const SizedBox(height: 12),
              OptionalCollaborationInstallSection(
                controller: actions,
                plan: projection.installPlan,
                busy: busy,
                isChinese: isChinese,
              ),
            ],
          ],
          if (state?.pluginInstalled == true &&
              state?.capabilityEnabled == true) ...[
            const SizedBox(height: 12),
            OptionalCollaborationCatalogAction(
              loaded: catalog != null,
              busy: busy,
              isChinese: isChinese,
              onLoad: () => unawaited(actions.loadWorkflowCatalog()),
            ),
            if (catalog != null) ...[
              const SizedBox(height: 12),
              OptionalCollaborationWorkflowSections(
                catalog: catalog,
                controller: workflowActions,
                isChinese: isChinese,
              ),
            ],
          ],
          if (state != null &&
              (state.pluginInstalled || state.capabilityEnabled)) ...[
            const SizedBox(height: 12),
            OptionalCollaborationTeardownSection(
              controller: actions,
              state: state,
              busy: busy,
              isChinese: isChinese,
            ),
          ],
          if (projection.notice case final notice?) ...[
            const SizedBox(height: 10),
            Text(
              notice.reasonCode,
              key: const Key('optional-collaboration-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
