import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/shared/l10n/lico_strings_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/assistant_sparkles_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class GroupStrategyProjection {
  const GroupStrategyProjection({
    required this.revision,
    required this.agentIds,
    required this.runtimeProfiles,
  });

  final String revision;
  final Set<String> agentIds;
  final Map<String, AgentParticipantRuntimeProfile> runtimeProfiles;
}

final class GroupStrategyPickerCapsule extends StatelessWidget {
  const GroupStrategyPickerCapsule({
    super.key,
    required this.label,
    required this.strategies,
    required this.selectedRevision,
    required this.onSelected,
    required this.onCleared,
    this.onOpen,
  });

  final String label;
  final List<AdaptiveFlywheelDefinition> strategies;
  final String? selectedRevision;
  final ValueChanged<String> onSelected;
  final VoidCallback onCleared;
  final ValueChanged<String?>? onOpen;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final menuRadius = BorderRadius.circular(
      AppleControlMetrics.menuCornerRadius,
    );
    return MessagingHoverPopover(
      popoverKey: const Key('canonical-group-strategy-picker-panel'),
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      offset: const Offset(0, -4),
      maxHeight: MessagingDesktopMetrics.composerOptionPopoverMaxHeight,
      borderRadius: menuRadius,
      wrapInGlass: false,
      cardBuilder: (context, close) {
        return _GroupStrategyGlassOptionCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MessagingGlassMenuItem(
                key: const Key('canonical-group-strategy-option-none'),
                label: strings.automaticAdaptation,
                dense: true,
                selected: selectedRevision == null,
                leading: Icon(
                  Icons.account_tree_outlined,
                  size: 14,
                  color: context.licoColors.textMuted,
                ),
                onTap: () {
                  onCleared();
                  close();
                },
              ),
              if (strategies.isEmpty)
                MessagingGlassMenuItem(
                  label: strings.noAuthorizedStrategies,
                  dense: true,
                  enabled: false,
                )
              else
                for (final strategy in strategies)
                  _GroupStrategyGlassMenuItem(
                    key: Key(
                      'canonical-group-strategy-option-${strategy.revisionDigest}',
                    ),
                    label: strategy.name.trim().isEmpty
                        ? strategy.id
                        : strategy.name,
                    selected: strategy.revisionDigest == selectedRevision,
                    iconColor: context.licoColors.text,
                    accentColor: context.licoColors.accent,
                    editTooltip: strings.edit,
                    editKey: Key(
                      'canonical-group-strategy-edit-${strategy.revisionDigest}',
                    ),
                    onEdit: onOpen == null
                        ? null
                        : () {
                            close();
                            onOpen!(strategy.revisionDigest);
                          },
                    onTap: () {
                      onSelected(strategy.revisionDigest);
                      close();
                    },
                  ),
            ],
          ),
        );
      },
      triggerBuilder:
          (context, {required open, required toggle, required close}) {
            return _GroupStrategyPickerTrigger(
              label: label,
              open: open,
              onTap: onOpen == null
                  ? toggle
                  : () {
                      close();
                      onOpen!(selectedRevision);
                    },
            );
          },
    );
  }
}

final class _GroupStrategyGlassOptionCard extends MessagingGlassOptionCard {
  const _GroupStrategyGlassOptionCard({required super.child})
    : super(
        constraints: const BoxConstraints(
          minWidth: 156,
          maxWidth: 240,
          maxHeight: MessagingDesktopMetrics.composerOptionPopoverMaxHeight,
        ),
        padding: const EdgeInsets.symmetric(vertical: 4),
      );
}

final class _GroupStrategyGlassMenuItem extends MessagingGlassMenuItem {
  _GroupStrategyGlassMenuItem({
    super.key,
    required super.label,
    required bool selected,
    required Color iconColor,
    required Color accentColor,
    required String editTooltip,
    required Key editKey,
    required VoidCallback? onEdit,
    required VoidCallback onTap,
  }) : super(
         selected: selected && onEdit == null,
         dense: true,
         leading: Icon(Icons.account_tree_outlined, size: 14, color: iconColor),
         trailing: onEdit == null
             ? null
             : _GroupStrategyOptionTrailing(
                 selected: selected,
                 accentColor: accentColor,
                 editTooltip: editTooltip,
                 editKey: editKey,
                 onEdit: onEdit,
               ),
         onTap: onTap,
       );
}

final class _GroupStrategyOptionTrailing extends StatelessWidget {
  const _GroupStrategyOptionTrailing({
    required this.selected,
    required this.accentColor,
    required this.editTooltip,
    required this.editKey,
    required this.onEdit,
  });

  final bool selected;
  final Color accentColor;
  final String editTooltip;
  final Key editKey;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selected) ...[
          Icon(Icons.check_rounded, size: 15, color: accentColor),
          const SizedBox(width: 3),
        ],
        LicoIconButton(
          key: editKey,
          icon: const Icon(Icons.edit_outlined),
          tooltip: editTooltip,
          size: LicoIconButtonSize.small,
          onPressed: onEdit,
        ),
      ],
    );
  }
}

final class _GroupStrategyPickerTrigger extends StatelessWidget {
  const _GroupStrategyPickerTrigger({
    required this.label,
    required this.open,
    required this.onTap,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Semantics(
      button: true,
      label: strings.automaticAdaptation,
      child: AppleGlassSurface(
        borderRadius: kComposerCapsuleBorderRadius,
        fillAlpha: colors.isDark ? 22 : 10,
        child: InkWell(
          key: const Key('canonical-group-strategy-picker'),
          onTap: onTap,
          borderRadius: kComposerCapsuleBorderRadius,
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 15,
                  color: colors.primaryStrong,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text.withAlpha(235),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.08,
                      height: 1.15,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 15,
                  color: colors.textMuted.withAlpha(160),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class AssistantToggleButton extends StatelessWidget {
  const AssistantToggleButton({
    super.key,
    required this.active,
    required this.configured,
    required this.onTap,
  });

  final bool active;
  final bool configured;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final enabled = active && configured;
    final tooltip = !configured
        ? strings.configureAssistantTooltip
        : enabled
        ? strings.assistantActiveTooltip
        : strings.assistantPausedTooltip;
    return SizedBox.square(
      key: const Key('canonical-group-assistant-control'),
      dimension: 40,
      child: Tooltip(
        message: tooltip,
        waitDuration: LicoMotion.tooltipWait,
        child: Semantics(
          button: true,
          toggled: enabled,
          label: tooltip,
          child: Material(
            color: enabled ? colors.accent : colors.surfaceRaised,
            shape: CircleBorder(
              side: BorderSide(
                color: enabled ? colors.accent : colors.line,
                width: 1,
              ),
            ),
            child: InkWell(
              key: const Key('canonical-group-assistant-toggle'),
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Center(
                child: AssistantSparklesIcon(
                  color: enabled ? colors.textOnAccent : colors.textMuted,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
