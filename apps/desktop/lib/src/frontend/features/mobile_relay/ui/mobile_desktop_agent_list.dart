import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class MobileDesktopAgentList extends StatelessWidget {
  const MobileDesktopAgentList({
    super.key,
    required this.controller,
    required this.device,
    required this.targets,
    required this.onBack,
    required this.onRefresh,
    required this.onSelect,
  });

  final ClientController controller;
  final MobileRelayPairedDevice device;
  final List<TargetCandidate> targets;
  final VoidCallback onBack;
  final Future<void> Function() onRefresh;
  final ValueChanged<TargetCandidate> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Column(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.background,
            border: Border(
              bottom: BorderSide(color: colors.line.withAlpha(120)),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
            child: Row(
              children: [
                IconButton(
                  key: const Key('mobile-desktop-agents-back'),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: onBack,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Icon(Icons.computer_rounded, color: colors.accent, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.arcDesktop,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        device.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('mobile-desktop-agents-refresh'),
                  tooltip: strings.refreshAgents,
                  onPressed: () => unawaited(onRefresh()),
                  icon: controller.isScanningTargets
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: targets.isEmpty
              ? _MobileDesktopEmptyState(onRefresh: onRefresh)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 14),
                  itemCount: targets.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 2),
                  itemBuilder: (context, index) {
                    final target = targets[index];
                    return _MobileDesktopAgentListItem(
                      target: target,
                      subtitle: strings.secureRelay,
                      onTap: () => onSelect(target),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

final class _MobileDesktopEmptyState extends StatelessWidget {
  const _MobileDesktopEmptyState({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined, color: colors.accent, size: 34),
            const SizedBox(height: 12),
            Text(
              strings.desktopAgents,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.text,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              strings.noDesktopAgents,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => unawaited(onRefresh()),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(strings.refreshAgents),
            ),
          ],
        ),
      ),
    );
  }
}

final class _MobileDesktopAgentListItem extends StatelessWidget {
  const _MobileDesktopAgentListItem({
    required this.target,
    required this.subtitle,
    required this.onTap,
  });

  final TargetCandidate target;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Material(
      key: Key('mobile-desktop-agent-${target.target}'),
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          child: Row(
            children: [
              AgentBrandIcon(
                target: target,
                selected: true,
                detected: target.status != 'not-detected',
                size: 48,
                iconSize: 32,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      target.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
