import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_card_model.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_cards.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_style.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';

enum CollaborationActionTone {
  /// A raised neutral button.
  neutral,

  /// The one action the surface exists for.
  brand,

  /// A tinted brand choice among peers, such as gate options.
  soft,
}

/// The compact text button used on banners, rows and popovers.
final class CollaborationActionButton extends StatelessWidget {
  const CollaborationActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.tone = CollaborationActionTone.neutral,
  });

  final String label;
  final VoidCallback? onPressed;
  final CollaborationActionTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final ink = CollaborationInk(colors);
    final text = Theme.of(
      context,
    ).textTheme.labelMedium!.copyWith(fontWeight: FontWeight.w600);
    final shape = ContinuousRoundedBorder(
      borderRadius: BorderRadius.circular(LicoRadius.chip),
    );
    const padding = EdgeInsets.symmetric(horizontal: 11, vertical: 5);
    const minimumSize = Size(0, 28);
    final child = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    return switch (tone) {
      CollaborationActionTone.brand => FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: colors.textOnPrimary,
          disabledBackgroundColor: (colors.isDark
              ? LicoPaneGlass.contentInnerCardFill
              : colors.surfaceLow),
          disabledForegroundColor: colors.textDisabled,
          textStyle: text,
          padding: padding,
          minimumSize: minimumSize,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          shape: shape,
          side: BorderSide(color: colors.brandBorder),
        ),
        child: child,
      ),
      CollaborationActionTone.soft ||
      CollaborationActionTone.neutral => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: tone == CollaborationActionTone.soft
              ? colors.brandSurface
              : (colors.isDark
                    ? LicoPaneGlass.contentInnerCardFill
                    : colors.surfaceRaised),
          foregroundColor: tone == CollaborationActionTone.soft
              ? ink.brand
              : colors.text,
          disabledForegroundColor: colors.textDisabled,
          side: BorderSide(
            color: tone == CollaborationActionTone.soft
                ? colors.brandBorder
                : colors.line,
          ),
          textStyle: text,
          padding: padding,
          minimumSize: minimumSize,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          shape: shape,
        ),
        child: child,
      ),
    };
  }
}

/// A label with a compact switch; the whole row toggles.
final class CollaborationToggle extends StatelessWidget {
  const CollaborationToggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.expand = false,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Pushes the switch to the trailing edge of the available width.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final onChanged = this.onChanged;
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(color: colors.textSecondary),
    );
    return MergeSemantics(
      child: MouseRegion(
        cursor: onChanged == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onChanged == null ? null : () => onChanged(!value),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
              if (expand) Expanded(child: text) else text,
              const SizedBox(width: 6),
              CollaborationSwitch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// The themed switch at toolbar scale.
final class CollaborationSwitch extends StatelessWidget {
  const CollaborationSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 32,
    height: 19,
    child: FittedBox(
      child: Switch(
        value: value,
        onChanged: onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
  );
}

/// The run header: status, caption, participants, revision and view
/// controls.
final class CollaborationHeaderBar extends StatelessWidget {
  const CollaborationHeaderBar({
    super.key,
    required this.projection,
    required this.title,
    required this.compare,
    required this.follow,
    required this.historyOpen,
    required this.settingsOpen,
    required this.onCompareChanged,
    required this.onFollowChanged,
    required this.onToggleHistory,
    required this.onToggleSettings,
  });

  /// Below this width the view switches move into the settings menu.
  static const double compactWidth = 760;

  final CollaborationProjection projection;
  final String title;
  final bool compare;
  final bool follow;
  final bool historyOpen;
  final bool settingsOpen;
  final ValueChanged<bool> onCompareChanged;
  final ValueChanged<bool> onFollowChanged;
  final VoidCallback onToggleHistory;
  final VoidCallback onToggleSettings;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final textTheme = Theme.of(context).textTheme;
    final active = projection.isActive && projection.graph != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < compactWidth;
        final viewedNumber = projection.viewedNumber ?? projection.headNumber;
        CollaborationRevisionSummary? viewed;
        for (final revision in projection.revisions) {
          if (revision.number == viewedNumber) viewed = revision;
        }
        final children = <Widget>[
          if (!active)
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall,
              ),
            )
          else ...[
            _RunChip(projection: projection),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _caption(strings, projection),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall,
              ),
            ),
            if (!compact) ...[
              const SizedBox(width: 10),
              _Participants(agentIds: _participants(projection)),
            ],
            if (viewed != null) ...[
              const SizedBox(width: 10),
              _RevisionChip(
                label: strings.collaborationRevisionChip(
                  viewed.number,
                  viewed.shortDigest,
                ),
                open: historyOpen,
                onTap: onToggleHistory,
              ),
            ],
            if (!compact) ...[
              const SizedBox(width: 14),
              CollaborationToggle(
                key: const Key('collab-toggle-diff'),
                label: strings.collaborationShowDiff,
                value: compare,
                onChanged: onCompareChanged,
              ),
              const SizedBox(width: 12),
              CollaborationToggle(
                key: const Key('collab-toggle-follow'),
                label: strings.collaborationFollow,
                value: follow,
                onChanged: onFollowChanged,
              ),
            ],
            const SizedBox(width: 6),
            LicoIconButton(
              key: const Key('collab-settings-button'),
              icon: const Icon(Icons.tune_rounded),
              tooltip: strings.collaborationSettings,
              size: LicoIconButtonSize.compact,
              selected: settingsOpen,
              onPressed: onToggleSettings,
            ),
          ],
        ];
        return Container(
          constraints: const BoxConstraints(minHeight: 50),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: colors.isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.07),
                width: 0.5,
              ),
            ),
          ),
          child: Row(children: children),
        );
      },
    );
  }
}

String _caption(LicoStrings strings, CollaborationProjection projection) {
  if (!projection.viewingHead) {
    return strings.collaborationCaptionHistorical(projection.viewedNumber!);
  }
  final proposal = projection.proposal;
  if (proposal != null) {
    return strings.collaborationCaptionProposal(proposal.revision.number);
  }
  if (projection.status == CollaborationRunStatus.completed) {
    return strings.collaborationCaptionCompleted(projection.headNumber);
  }
  final nodes = projection.graph!.nodes;
  for (final node in nodes) {
    final state = projection.nodeStates[node.id];
    final gate = state?.gate;
    if (state?.status == CollaborationNodeStatus.waitingUser && gate != null) {
      return strings.collaborationCaptionGate(gate.title);
    }
  }
  for (final node in nodes) {
    final status = projection.nodeStates[node.id]?.status;
    if (status != null && collaborationInProgress.contains(status)) {
      return strings.collaborationCaptionActive(
        strings.collaborationNodeStatus(status),
        node.label,
      );
    }
  }
  return strings.collaborationProgress(
    projection.succeededWork,
    projection.totalWork,
  );
}

/// Agents in the viewed plan, in plan order, then fallback targets.
List<String> _participants(CollaborationProjection projection) {
  final ids = <String>{};
  for (final node in projection.graph!.nodes) {
    final agent = node.agentId;
    if (agent != null) ids.add(agent);
  }
  for (final state in projection.nodeStates.values) {
    final fallback = state.fallback;
    if (fallback != null) ids.add(fallback.toAgentId);
  }
  return ids.toList(growable: false);
}

final class _RunChip extends StatelessWidget {
  const _RunChip({required this.projection});

  final CollaborationProjection projection;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final status = projection.status;
    final waiting =
        (projection.viewingHead && projection.proposal != null) ||
        projection.nodeStates.values.any(
          (state) => state.status == CollaborationNodeStatus.waitingUser,
        );
    final label = waiting
        ? strings.collaborationAwaitingYou
        : status == null
        ? strings.collaborationTitle
        : strings.collaborationRunStatus(status);
    final failed = status == CollaborationRunStatus.failed;
    return Container(
      key: const Key('collab-run-chip'),
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: failed
            ? (colors.isDark
                  ? LicoPaneGlass.contentInnerCardFill
                  : colors.surfaceLow)
            : colors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (waiting && !failed) ...[
            const _WaitingDot(),
            const SizedBox(width: 5),
          ],
          Text(
            strings.collaborationRunChip(
              label,
              projection.succeededWork,
              projection.totalWork,
            ),
            maxLines: 1,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: failed ? colors.error : colors.primaryStrong,
            ),
          ),
        ],
      ),
    );
  }
}

/// The 6pt primary dot that pulses while the run waits on the user; it
/// rests solid under reduced motion.
final class _WaitingDot extends StatefulWidget {
  const _WaitingDot();

  @override
  State<_WaitingDot> createState() => _WaitingDotState();
}

final class _WaitingDotState extends State<_WaitingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  bool _animating = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      lowerBound: 0.4,
      upperBound: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final live = context.allowsAmbientMotion;
    if (live && !_animating) {
      _pulse.repeat(reverse: true);
      _animating = true;
    } else if (!live && _animating) {
      _pulse.stop();
      _pulse.value = 1;
      _animating = false;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return FadeTransition(
      opacity: _pulse,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: colors.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

final class _Participants extends StatelessWidget {
  const _Participants({required this.agentIds});

  final List<String> agentIds;

  static const int maxShown = 6;
  static const double size = 24;
  static const double ring = 2;
  static const double step = 18;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final shown = agentIds.take(maxShown).toList(growable: false);
    if (shown.isEmpty) return const SizedBox.shrink();
    return Semantics(
      label:
          '${strings.collaborationParticipants}: '
          '${shown.map(collaborationAgentLabel).join(', ')}',
      child: ExcludeSemantics(
        child: SizedBox(
          width: size + step * (shown.length - 1),
          height: size,
          child: Stack(
            children: [
              for (var i = 0; i < shown.length; i++)
                Positioned(
                  left: step * i,
                  child: Container(
                    width: size,
                    height: size,
                    padding: const EdgeInsets.all(ring),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colors.isDark
                          ? (colors.isDark
                                ? LicoPaneGlass.contentInnerCardFill
                                : colors.surfaceLow)
                          : colors.surface,
                    ),
                    child: MessagingAgentAvatar(
                      target: collaborationAvatarTarget(shown[i]),
                      size: size - ring * 2,
                      iconSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _RevisionChip extends StatefulWidget {
  const _RevisionChip({
    required this.label,
    required this.open,
    required this.onTap,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  State<_RevisionChip> createState() => _RevisionChipState();
}

final class _RevisionChipState extends State<_RevisionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final radius = BorderRadius.circular(13);
    final isDark = colors.isDark;
    return Semantics(
      button: true,
      expanded: widget.open,
      label: '${strings.collaborationPlanHistory} ${widget.label}',
      child: ExcludeSemantics(
        child: InkWell(
          key: const Key('collab-revision-chip'),
          onTap: widget.onTap,
          onHover: (v) => setState(() => _hovered = v),
          borderRadius: radius,
          child: AnimatedContainer(
            duration: context.motion(LicoMotion.micro),
            height: 26,
            padding: const EdgeInsets.fromLTRB(9, 0, 6, 0),
            decoration: continuousHairlineDecoration(
              color: _hovered
                  ? (isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06))
                  : (isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.black.withValues(alpha: 0.04)),
              borderRadius: radius,
              stroke: isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : Colors.black.withValues(alpha: 0.08),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.expand_more_rounded,
                  size: 12,
                  color: colors.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Policy choices, plus the view switches when the header is compact.
final class CollaborationSettingsMenu extends StatelessWidget {
  const CollaborationSettingsMenu({
    super.key,
    required this.projection,
    required this.compact,
    required this.compare,
    required this.follow,
    required this.onCompareChanged,
    required this.onFollowChanged,
    required this.onPlanChangePolicy,
    required this.onGateReviewPolicy,
  });

  static const double width = 280;

  final CollaborationProjection projection;
  final bool compact;
  final bool compare;
  final bool follow;
  final ValueChanged<bool> onCompareChanged;
  final ValueChanged<bool> onFollowChanged;
  final ValueChanged<CollaborationPlanChangePolicy> onPlanChangePolicy;
  final ValueChanged<CollaborationGateReviewPolicy> onGateReviewPolicy;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final enabled = !projection.commandPending;
    return MessagingGlassOptionCard(
      key: const Key('collab-settings-menu'),
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (compact) ...[
            MessagingGlassMenuItem(
              label: strings.collaborationShowDiff,
              trailing: CollaborationSwitch(
                value: compare,
                onChanged: onCompareChanged,
              ),
              onTap: () => onCompareChanged(!compare),
            ),
            MessagingGlassMenuItem(
              label: strings.collaborationFollow,
              trailing: CollaborationSwitch(
                value: follow,
                onChanged: onFollowChanged,
              ),
              onTap: () => onFollowChanged(!follow),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(height: 1, child: ColoredBox(color: colors.line)),
            ),
          ],
          _MenuCaption(strings.collaborationPlanChangePolicy),
          for (final (policy, label) in [
            (
              CollaborationPlanChangePolicy.auto,
              strings.collaborationPlanChangeAuto,
            ),
            (
              CollaborationPlanChangePolicy.ask,
              strings.collaborationPlanChangeAsk,
            ),
          ])
            MessagingGlassMenuItem(
              key: Key('collab-plan-policy-${policy.name}'),
              label: label,
              selected: projection.planChangePolicy == policy,
              enabled: enabled,
              onTap: () => onPlanChangePolicy(policy),
            ),
          _MenuCaption(strings.collaborationGateReviewPolicy),
          for (final (policy, label) in [
            (
              CollaborationGateReviewPolicy.assistant,
              strings.collaborationGateReviewAssistant,
            ),
            (
              CollaborationGateReviewPolicy.user,
              strings.collaborationGateReviewUser,
            ),
          ])
            MessagingGlassMenuItem(
              key: Key('collab-gate-policy-${policy.name}'),
              label: label,
              selected: projection.gateReviewPolicy == policy,
              enabled: enabled,
              onTap: () => onGateReviewPolicy(policy),
            ),
        ],
      ),
    );
  }
}

final class _MenuCaption extends StatelessWidget {
  const _MenuCaption(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 7, 12, 3),
    child: Text(
      label,
      style: LicoTypography.eyebrow(color: context.licoColors.textDisabled),
    ),
  );
}
