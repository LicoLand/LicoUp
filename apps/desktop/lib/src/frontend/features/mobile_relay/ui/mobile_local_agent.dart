import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/directory_path_field.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class MobileAgentConversation extends StatelessWidget {
  const MobileAgentConversation({
    super.key,
    required this.controller,
    required this.targets,
    required this.target,
    required this.onBack,
    required this.onConfiguration,
  });

  final ClientController controller;
  final List<TargetCandidate> targets;
  final TargetCandidate target;
  final VoidCallback onBack;
  final VoidCallback onConfiguration;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _MobileAgentHeader(
          target: target,
          title: agentConversationTargetDisplayName(target),
          leadingTooltip: MaterialLocalizations.of(context).backButtonTooltip,
          leadingIcon: Icons.chevron_left_rounded,
          onLeading: onBack,
          trailing: IconButton(
            key: const Key('mobile-agent-open-configuration'),
            tooltip: LicoStrings.of(context).settings,
            onPressed: onConfiguration,
            icon: const Icon(Icons.tune_rounded),
          ),
        ),
        Expanded(
          child: AgentConversationWorkspace(
            controller: controller,
            targets: targets,
            scanning: controller.isScanningTargets,
            adding: controller.isAddingTarget,
            onAddTarget: () {},
            allowManualTargetActions: false,
          ),
        ),
      ],
    );
  }
}

class MobileAgentConfiguration extends StatelessWidget {
  const MobileAgentConfiguration({
    super.key,
    required this.controller,
    required this.target,
    required this.onBack,
  });

  final ClientController controller;
  final TargetCandidate target;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final historyRoots = target.historyRoots;
    return Column(
      children: [
        _MobileAgentHeader(
          target: target,
          title: strings.agentConfiguration,
          leadingTooltip: MaterialLocalizations.of(context).backButtonTooltip,
          leadingIcon: Icons.chevron_left_rounded,
          onLeading: onBack,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            children: [
              MobileConfigRow(
                icon: Icons.smart_toy_outlined,
                label: strings.agent,
                value: agentConversationTargetDisplayName(target),
              ),
              MobileConfigRow(
                icon: target.configured
                    ? Icons.check_circle_outline_rounded
                    : Icons.radio_button_unchecked_rounded,
                label: strings.target,
                value: target.configured
                    ? strings.configured
                    : strings.notConfigured,
              ),
              MobileConfigRow(
                icon: Icons.category_outlined,
                label: strings.protocol,
                value: target.kind.trim().isEmpty
                    ? target.adapterStatus
                    : target.kind,
              ),
              DirectoryPathField(
                title: strings.configPath,
                label: strings.configPath,
                path: target.configPath?.trim() ?? '',
                icon: Icons.settings_applications_outlined,
                readOnly: true,
                showHeader: false,
                compactBreakpoint: 360,
                padding: const EdgeInsets.symmetric(vertical: 12),
                onOpen: (path) => controller.openDirectoryPath(
                  _directoryForMobilePath(path),
                  caption: strings.configPath,
                ),
              ),
              MobileConfigRow(
                icon: Icons.terminal_outlined,
                label: strings.binaryPath,
                value: _displayValue(target.binaryPath, strings),
              ),
              MobileConfigRow(
                icon: Icons.history_rounded,
                label: strings.historyRoot,
                value: historyRoots.isEmpty
                    ? strings.unavailable
                    : historyRoots.join('\n'),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      unawaited(controller.inspectTarget(target.target)),
                  icon: const Icon(Icons.search_rounded, size: 18),
                  label: Text(strings.inspect),
                ),
              ),
              if (controller.displayStatusMessage.trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  controller.displayStatusMessage,
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _displayValue(String? value, LicoStrings strings) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? strings.unavailable : trimmed;
  }
}

String _directoryForMobilePath(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed == '-') {
    return '';
  }
  final basename = p.basename(trimmed);
  return basename.contains('.') ? p.dirname(trimmed) : trimmed;
}

class _MobileAgentHeader extends StatelessWidget {
  const _MobileAgentHeader({
    required this.target,
    required this.title,
    required this.leadingTooltip,
    required this.leadingIcon,
    required this.onLeading,
    this.trailing,
  });

  final TargetCandidate target;
  final String title;
  final String leadingTooltip;
  final IconData leadingIcon;
  final VoidCallback onLeading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.line.withAlpha(120))),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
        child: Row(
          children: [
            IconButton(
              tooltip: leadingTooltip,
              onPressed: onLeading,
              icon: Icon(leadingIcon),
            ),
            AgentBrandIcon(
              target: target,
              selected: true,
              detected: target.status != 'not-detected',
              size: 36,
              iconSize: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class MobileConfigRow extends StatelessWidget {
  const MobileConfigRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 21, color: colors.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
