import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agent_list_items.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';

typedef MobileAgentContentBuilder =
    Widget Function(BuildContext context, AgentTargetProjection target);

class MobileAgentConversation extends StatelessWidget {
  const MobileAgentConversation({
    super.key,
    required this.target,
    required this.contentBuilder,
    required this.onBack,
    required this.onConfiguration,
    this.iconBuilder,
  });

  final AgentTargetProjection target;
  final MobileAgentContentBuilder contentBuilder;
  final VoidCallback onBack;
  final VoidCallback onConfiguration;
  final MobileAgentIconBuilder? iconBuilder;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _MobileAgentHeader(
          target: target,
          title: target.displayName,
          leadingTooltip: MaterialLocalizations.of(context).backButtonTooltip,
          leadingIcon: Icons.chevron_left_rounded,
          onLeading: onBack,
          iconBuilder: iconBuilder,
          trailing: IconButton(
            key: const Key('mobile-agent-open-configuration'),
            tooltip: LicoStrings.of(context).settings,
            onPressed: onConfiguration,
            icon: const Icon(Icons.tune_rounded),
          ),
        ),
        Expanded(child: contentBuilder(context, target)),
      ],
    );
  }
}

class MobileAgentConfiguration extends StatelessWidget {
  const MobileAgentConfiguration({
    super.key,
    required this.target,
    required this.contentBuilder,
    required this.onBack,
    this.iconBuilder,
  });

  final AgentTargetProjection target;
  final MobileAgentContentBuilder contentBuilder;
  final VoidCallback onBack;
  final MobileAgentIconBuilder? iconBuilder;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _MobileAgentHeader(
          target: target,
          title: LicoStrings.of(context).agentConfiguration,
          leadingTooltip: MaterialLocalizations.of(context).backButtonTooltip,
          leadingIcon: Icons.chevron_left_rounded,
          onLeading: onBack,
          iconBuilder: iconBuilder,
        ),
        Expanded(child: contentBuilder(context, target)),
      ],
    );
  }
}

class _MobileAgentHeader extends StatelessWidget {
  const _MobileAgentHeader({
    required this.target,
    required this.title,
    required this.leadingTooltip,
    required this.leadingIcon,
    required this.onLeading,
    this.iconBuilder,
    this.trailing,
  });

  final AgentTargetProjection target;
  final String title;
  final String leadingTooltip;
  final IconData leadingIcon;
  final VoidCallback onLeading;
  final MobileAgentIconBuilder? iconBuilder;
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
            iconBuilder?.call(
                  context,
                  target,
                  selected: true,
                  size: 36,
                  iconSize: 24,
                ) ??
                Icon(
                  target.available
                      ? Icons.smart_toy_outlined
                      : Icons.extension_outlined,
                  size: 24,
                  color: target.available ? colors.text : colors.textMuted,
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
