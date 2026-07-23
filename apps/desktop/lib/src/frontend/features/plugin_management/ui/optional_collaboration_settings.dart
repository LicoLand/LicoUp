import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_catalog_action.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_install_section.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_lifecycle_sections.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_runner_trust_section.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_settings_policy.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_status_card.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_workflow_sections.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

final class OptionalCollaborationSettings extends StatelessWidget {
  const OptionalCollaborationSettings({super.key, required this.controller});

  final OptionalCollaborationController controller;

  @override
  Widget build(BuildContext context) {
    final isChinese = LicoStrings.of(context).isChinese;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = controller.state;
        final catalog = controller.workflowCatalog;
        final busy = controller.busy;
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
                statusLoaded: controller.statusLoaded,
                busy: busy,
                isChinese: isChinese,
                onLoadStatus: () => unawaited(controller.loadStatus()),
              ),
              const SizedBox(height: 12),
              if (state?.capabilityEnabled != true)
                OptionalCollaborationEnableSection(
                  controller: controller,
                  busy: busy,
                  isChinese: isChinese,
                ),
              if (state?.capabilityEnabled == true) ...[
                OptionalCollaborationRunnerTrustSection(
                  controller: controller,
                  state: state!,
                  busy: busy,
                  isChinese: isChinese,
                ),
                if (!state.pluginInstalled) ...[
                  const SizedBox(height: 12),
                  OptionalCollaborationInstallSection(
                    controller: controller,
                    plan: controller.installPlan,
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
                  onLoad: () => unawaited(controller.loadWorkflowCatalog()),
                ),
                if (catalog != null) ...[
                  const SizedBox(height: 12),
                  OptionalCollaborationWorkflowSections(
                    catalog: catalog,
                    controller: controller.workflows,
                    isChinese: isChinese,
                  ),
                ],
              ],
              if (state != null &&
                  (state.pluginInstalled || state.capabilityEnabled)) ...[
                const SizedBox(height: 12),
                OptionalCollaborationTeardownSection(
                  controller: controller,
                  state: state,
                  busy: busy,
                  isChinese: isChinese,
                ),
              ],
              if (controller.errorCode.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  controller.errorCode,
                  key: const Key('optional-collaboration-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
