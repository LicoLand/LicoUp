import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agent_list_items.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';

final class MobileDesktopAgentList extends StatelessWidget {
  const MobileDesktopAgentList({
    super.key,
    required this.device,
    required this.targets,
    required this.scanning,
    required this.onBack,
    required this.onRefresh,
    required this.onSelect,
    this.iconBuilder,
  });

  final RelayPeerProjection device;
  final List<AgentTargetProjection> targets;
  final bool scanning;
  final VoidCallback onBack;
  final VoidCallback onRefresh;
  final ValueChanged<AgentTargetProjection> onSelect;
  final MobileAgentIconBuilder? iconBuilder;

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
                        device.displayName,
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
                  onPressed: scanning ? null : onRefresh,
                  icon: scanning
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
              ? _MobileDesktopEmptyState(
                  scanning: scanning,
                  onRefresh: onRefresh,
                )
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
                      iconBuilder: iconBuilder,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

final class _MobileDesktopEmptyState extends StatelessWidget {
  const _MobileDesktopEmptyState({
    required this.scanning,
    required this.onRefresh,
  });

  final bool scanning;
  final VoidCallback onRefresh;

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
              onPressed: scanning ? null : onRefresh,
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
    this.iconBuilder,
  });

  final AgentTargetProjection target;
  final String subtitle;
  final VoidCallback onTap;
  final MobileAgentIconBuilder? iconBuilder;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Material(
      key: Key('mobile-desktop-agent-${target.id}'),
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          child: Row(
            children: [
              iconBuilder?.call(
                    context,
                    target,
                    selected: true,
                    size: 48,
                    iconSize: 32,
                  ) ??
                  Icon(
                    target.available
                        ? Icons.smart_toy_outlined
                        : Icons.extension_outlined,
                    size: 32,
                    color: target.available ? colors.text : colors.textMuted,
                  ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      target.displayName,
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
