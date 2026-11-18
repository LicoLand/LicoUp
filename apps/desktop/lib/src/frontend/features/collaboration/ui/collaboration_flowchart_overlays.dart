import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_card_model.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_cards.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_header.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_paint.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_style.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';

/// Zoom controls above the minimap.
final class CollaborationZoomHud extends StatelessWidget {
  const CollaborationZoomHud({
    super.key,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final isDark = colors.isDark;
    final fill = isDark ? const Color(0xCC0E0E13) : const Color(0xD9FFFFFF);
    final stroke = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.08);
    Widget button(Key key, IconData icon, String tooltip, VoidCallback fn) =>
        _ZoomHudButton(key: key, icon: icon, tooltip: tooltip, onPressed: fn);
    return Container(
      key: const Key('collab-hud'),
      height: 32,
      decoration: continuousHairlineDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(16),
        stroke: stroke,
        shadows: LicoElevation.card.shadows(colors),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(
            const Key('collab-zoom-in'),
            Icons.add_rounded,
            strings.collaborationZoomIn,
            onZoomIn,
          ),
          Container(
            width: 0.5,
            height: 16,
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.08),
          ),
          button(
            const Key('collab-zoom-out'),
            Icons.remove_rounded,
            strings.collaborationZoomOut,
            onZoomOut,
          ),
          Container(
            width: 0.5,
            height: 16,
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.08),
          ),
          button(
            const Key('collab-zoom-fit'),
            Icons.fit_screen_outlined,
            strings.collaborationFit,
            onFit,
          ),
        ],
      ),
    );
  }
}

/// One 28-wide zoom button inside the HUD capsule: 16pt glyph,
/// textSecondary at rest, text on a white-7% hover slab.
final class _ZoomHudButton extends StatefulWidget {
  const _ZoomHudButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_ZoomHudButton> createState() => _ZoomHudButtonState();
}

final class _ZoomHudButtonState extends State<_ZoomHudButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: LicoMotion.tooltipWait,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        onTap: widget.onPressed,
        child: InkResponse(
          onTap: widget.onPressed,
          onHover: (v) => setState(() => _hovered = v),
          child: AnimatedContainer(
            duration: context.motion(LicoMotion.micro),
            width: 28,
            height: 32,
            color: _hovered
                ? (colors.isDark
                      ? Colors.white.withValues(alpha: 0.07)
                      : Colors.black.withValues(alpha: 0.05))
                : Colors.transparent,
            child: Icon(
              widget.icon,
              size: 16,
              color: _hovered ? colors.text : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The overview map; tapping or dragging recenters the canvas.
final class CollaborationMinimap extends StatelessWidget {
  const CollaborationMinimap({
    super.key,
    required this.cards,
    required this.world,
    required this.transform,
    required this.viewport,
    required this.onPanTo,
  });

  static const Size size = Size(168, 72);

  final List<(Rect, CollaborationMinimapTone)> cards;
  final Size world;
  final ValueListenable<Matrix4> transform;
  final Size viewport;

  /// Centers the view on the world coordinate.
  final ValueChanged<Offset> onPanTo;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final geometry = CollaborationMinimapGeometry(world, size);
    void panTo(Offset local) => onPanTo(geometry.toWorld(local));
    return Semantics(
      label: strings.collaborationMinimap,
      child: Container(
        key: const Key('collab-minimap'),
        width: size.width,
        height: size.height,
        decoration: continuousHairlineDecoration(
          color: colors.isDark
              ? const Color(0xCC0E0E13)
              : const Color(0xD9FFFFFF),
          borderRadius: BorderRadius.circular(10),
          stroke: colors.isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.08),
          shadows: LicoElevation.card.shadows(colors),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => panTo(details.localPosition),
              onPanStart: (details) => panTo(details.localPosition),
              onPanUpdate: (details) => panTo(details.localPosition),
              child: CustomPaint(
                painter: CollaborationMinimapPainter(
                  cards: cards,
                  world: world,
                  transform: transform,
                  viewport: viewport,
                  colors: colors,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Which banner the canvas shows.
enum CollaborationBannerKind {
  /// The held proposal waits for the user.
  proposal,

  /// A plan revision just applied under the auto policy.
  applied,

  /// The newest revision reverts an earlier one.
  reverted,

  /// The viewed revision is historical.
  historical,
}

/// The plan banner across the top of the canvas.
final class CollaborationFlowchartBanner extends StatelessWidget {
  const CollaborationFlowchartBanner({
    super.key,
    required this.kind,
    required this.projection,
    required this.pending,
    required this.reviseOpen,
    required this.noteController,
    required this.onApprove,
    required this.onReject,
    required this.onReviseTap,
    required this.onReviseSubmit,
    required this.onViewChanges,
    required this.onReplay,
    required this.onRevert,
    required this.onRestore,
    required this.onBackToHead,
    required this.onDismiss,
  });

  final CollaborationBannerKind kind;
  final CollaborationProjection projection;

  /// A command is in flight; actions render disabled.
  final bool pending;

  /// The revise note field is open (proposal banner only).
  final bool reviseOpen;
  final TextEditingController noteController;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onReviseTap;
  final ValueChanged<String> onReviseSubmit;

  /// Turns the compare overlay on (applied/reverted).
  final VoidCallback onViewChanges;

  /// Replays the plan-change sweep (applied/reverted).
  final VoidCallback onReplay;

  /// Reverts to the revision's parent (applied).
  final VoidCallback onRevert;

  /// Creates a new revision with this revision's content (historical).
  final VoidCallback onRestore;
  final VoidCallback onBackToHead;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final ink = CollaborationInk(colors);
    final proposal = kind == CollaborationBannerKind.proposal;
    final (icon, tint) = switch (kind) {
      CollaborationBannerKind.proposal => (
        Icons.account_tree_outlined,
        ink.accent,
      ),
      CollaborationBannerKind.applied => (Icons.history_toggle_off, ink.accent),
      CollaborationBannerKind.reverted => (Icons.undo_rounded, ink.accent),
      CollaborationBannerKind.historical => (
        Icons.history_rounded,
        colors.textMuted,
      ),
    };
    return Container(
      key: Key('collab-banner-${kind.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: continuousHairlineDecoration(
        color: proposal
            ? colors.accentSurface
            : (colors.isDark
                  ? LicoPaneGlass.contentInnerCardFill
                  : colors.surfaceRaised),
        borderRadius: BorderRadius.circular(LicoRadius.card),
        stroke: proposal ? ink.accent : colors.accentBorder,
        shadows: LicoElevation.card.shadows(colors),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 6,
        children: [
          Icon(icon, size: 15, color: tint),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220),
            child: Text(
              _text(strings, projection),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.text),
            ),
          ),
          ..._actions(context, strings),
        ],
      ),
    );
  }

  String _text(LicoStrings strings, CollaborationProjection projection) {
    final head = projection.head;
    switch (kind) {
      case CollaborationBannerKind.proposal:
        final proposal = projection.proposal!;
        return strings.collaborationProposalBanner(
          proposal.revision.number,
          proposal.revision.reason,
        );
      case CollaborationBannerKind.applied:
        return strings.collaborationAppliedBanner(
          head?.parent ?? projection.headNumber - 1,
          projection.headNumber,
          head == null
              ? ''
              : strings.collaborationRevisionApproval(head.approval),
          head?.reason ?? '',
        );
      case CollaborationBannerKind.reverted:
        return strings.collaborationRevertedBanner(
          projection.headNumber,
          head?.reason ?? '',
        );
      case CollaborationBannerKind.historical:
        return strings.collaborationCaptionHistorical(projection.viewedNumber!);
    }
  }

  List<Widget> _actions(BuildContext context, LicoStrings strings) {
    VoidCallback? when(void Function() action) => pending ? null : action;
    return switch (kind) {
      CollaborationBannerKind.proposal =>
        reviseOpen
            ? [
                SizedBox(
                  width: 240,
                  height: 30,
                  child: TextField(
                    key: const Key('collab-revise-field'),
                    controller: noteController,
                    autofocus: true,
                    style: Theme.of(context).textTheme.bodySmall,
                    decoration: InputDecoration(
                      hintText: strings.collaborationReviseHint,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                    ),
                    onSubmitted: onReviseSubmit,
                  ),
                ),
                CollaborationActionButton(
                  label: strings.collaborationSend,
                  tone: CollaborationActionTone.brand,
                  onPressed: pending
                      ? null
                      : () => onReviseSubmit(noteController.text),
                ),
                CollaborationActionButton(
                  label: strings.collaborationCancel,
                  onPressed: onDismiss,
                ),
              ]
            : [
                CollaborationActionButton(
                  label: strings.collaborationApprove,
                  tone: CollaborationActionTone.brand,
                  onPressed: when(onApprove),
                ),
                CollaborationActionButton(
                  label: strings.collaborationReject,
                  onPressed: when(onReject),
                ),
                CollaborationActionButton(
                  label: strings.collaborationAskRevise,
                  onPressed: when(onReviseTap),
                ),
              ],
      CollaborationBannerKind.applied => [
        CollaborationActionButton(
          label: strings.collaborationViewChanges,
          onPressed: onViewChanges,
        ),
        CollaborationActionButton(
          label: strings.collaborationReplay,
          onPressed: onReplay,
        ),
        CollaborationActionButton(
          label: strings.collaborationRevert,
          onPressed: when(onRevert),
        ),
        CollaborationActionButton(
          label: strings.collaborationDismiss,
          onPressed: onDismiss,
        ),
      ],
      CollaborationBannerKind.reverted => [
        CollaborationActionButton(
          label: strings.collaborationViewChanges,
          onPressed: onViewChanges,
        ),
        CollaborationActionButton(
          label: strings.collaborationReplay,
          onPressed: onReplay,
        ),
        CollaborationActionButton(
          label: strings.collaborationDismiss,
          onPressed: onDismiss,
        ),
      ],
      CollaborationBannerKind.historical => [
        CollaborationActionButton(
          label: strings.collaborationRestore,
          onPressed: when(onRestore),
        ),
        CollaborationActionButton(
          label: strings.collaborationBackToHead,
          onPressed: when(onBackToHead),
        ),
      ],
    };
  }
}

/// The plan history drawer sliding in from the right.
final class CollaborationHistoryDrawer extends StatelessWidget {
  const CollaborationHistoryDrawer({
    super.key,
    required this.projection,
    required this.compare,
    required this.pending,
    required this.onCompareChanged,
    required this.onSelect,
    required this.onRevert,
    required this.onClose,
  });

  static const double width = 264;

  final CollaborationProjection projection;
  final bool compare;
  final bool pending;
  final ValueChanged<bool> onCompareChanged;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onRevert;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final head = projection.headNumber;
    final proposal = projection.proposal;
    return Container(
      key: const Key('collab-history-drawer'),
      width: width,
      decoration: BoxDecoration(
        color: colors.isDark
            ? LicoPaneGlass.contentInnerCardFill
            : (colors.isDark
                  ? LicoPaneGlass.contentInnerCardFill
                  : colors.surfaceRaised),
        border: Border(left: BorderSide(color: colors.line)),
        boxShadow: LicoElevation.raised.shadows(colors),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            child: Row(
              children: [
                Icon(Icons.history_rounded, size: 15, color: colors.textMuted),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    strings.collaborationPlanHistory,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                LicoIconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: strings.collaborationDismiss,
                  size: LicoIconButtonSize.small,
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          SizedBox(height: 1, child: ColoredBox(color: colors.line)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final revision in projection.revisions)
                  CollaborationRevisionRow(
                    revision: revision,
                    selected:
                        projection.viewedNumber == revision.number ||
                        (projection.viewingHead && revision.number == head),
                    held: proposal?.revision.number == revision.number,
                    revertable:
                        revision.number < head &&
                        projection.viewingHead &&
                        !pending,
                    onSelect: () => onSelect(
                      revision.number == head ? -1 : revision.number,
                    ),
                    onRevert: revision.number < head
                        ? () => onRevert(revision.number)
                        : null,
                  ),
              ],
            ),
          ),
          SizedBox(height: 1, child: ColoredBox(color: colors.line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: CollaborationToggle(
              key: const Key('collab-drawer-compare'),
              label: strings.collaborationCompare,
              value: compare,
              onChanged: onCompareChanged,
              expand: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// One revision in the history drawer.
final class CollaborationRevisionRow extends StatelessWidget {
  const CollaborationRevisionRow({
    super.key,
    required this.revision,
    required this.selected,
    required this.held,
    required this.revertable,
    required this.onSelect,
    required this.onRevert,
  });

  final CollaborationRevisionSummary revision;
  final bool selected;

  /// This revision is the held proposal.
  final bool held;

  /// Reverting to this revision is currently allowed.
  final bool revertable;
  final VoidCallback onSelect;
  final VoidCallback? onRevert;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final ink = CollaborationInk(colors);
    final textTheme = Theme.of(context).textTheme;
    final authoredAt = DateTime.fromMillisecondsSinceEpoch(revision.authoredAt);
    final stamp =
        '${authoredAt.month.toString().padLeft(2, '0')}-'
        '${authoredAt.day.toString().padLeft(2, '0')} '
        '${authoredAt.hour.toString().padLeft(2, '0')}:'
        '${authoredAt.minute.toString().padLeft(2, '0')}';
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      decoration: continuousHairlineDecoration(
        color: selected
            ? colors.selectedSurface
            : (colors.isDark
                  ? LicoPaneGlass.contentInnerCardFill
                  : colors.surfaceLow),
        borderRadius: BorderRadius.circular(LicoRadius.floating),
        stroke: selected ? ink.brand : colors.line,
        shadows: selected
            ? [BoxShadow(color: colors.brandGlow, blurRadius: 3)]
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(LicoRadius.floating),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('v${revision.number}', style: textTheme.labelLarge),
                    const SizedBox(width: 7),
                    Text(revision.shortDigest, style: textTheme.labelSmall),
                    const Spacer(),
                    _ApprovalBadge(
                      approval: held
                          ? CollaborationRevisionApproval.pending
                          : revision.approval,
                      yours:
                          revision.author == CollaborationRevisionAuthor.user,
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '${strings.collaborationRevisionAuthor(revision.author)}'
                  ' · $stamp',
                  style: textTheme.labelSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  strings.collaborationRevisionStats(
                    revision.added,
                    revision.removed,
                    revision.changed,
                  ),
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                if (revision.reason.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    revision.reason,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
                if (revision.revertOf != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    strings.collaborationRevertOf(revision.revertOf!),
                    style: textTheme.labelSmall,
                  ),
                ],
                if (onRevert != null) ...[
                  const SizedBox(height: 8),
                  CollaborationActionButton(
                    label: strings.collaborationRevert,
                    onPressed: revertable ? onRevert : null,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _ApprovalBadge extends StatelessWidget {
  const _ApprovalBadge({required this.approval, required this.yours});

  final CollaborationRevisionApproval approval;
  final bool yours;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final (fill, ink, rim) = switch (approval) {
      CollaborationRevisionApproval.pending => (
        colors.accentSurface,
        CollaborationInk(colors).accent,
        colors.accentBorder,
      ),
      CollaborationRevisionApproval.rejected => (
        (colors.isDark
            ? LicoPaneGlass.contentInnerCardFill
            : colors.surfaceRaised),
        colors.textDisabled,
        colors.line,
      ),
      _ when yours => (colors.selectedSurface, colors.text, colors.line),
      _ => (
        colors.brandSurface,
        CollaborationInk(colors).brand,
        colors.brandBorder,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: continuousHairlineDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
        stroke: rim,
      ),
      child: Text(
        strings.collaborationRevisionApproval(approval),
        maxLines: 1,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: ink,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// One node's details, anchored to its card in world space.
final class CollaborationNodePopover extends StatelessWidget {
  const CollaborationNodePopover({
    super.key,
    required this.model,
    required this.metrics,
    required this.pending,
    required this.onGateOption,
    required this.onClose,
  });

  static const double width = 270;

  /// The card whose details are shown; a task or a stack's hot step.
  final CollaborationTaskCardModel model;
  final CollaborationCardMetrics metrics;
  final bool pending;
  final void Function(String gateId, String optionId) onGateOption;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final ink = CollaborationInk(colors);
    final strings = LicoStrings.of(context);
    final textTheme = Theme.of(context).textTheme;
    final state = model.state;
    final gate = state?.gate;
    final awaiting =
        model.status == CollaborationNodeStatus.waitingUser && gate != null;
    final escalated = gate?.review is CollaborationGateEscalated;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        key: const Key('collab-popover'),
        width: width,
        padding: const EdgeInsets.all(14),
        decoration: continuousHairlineDecoration(
          color: colors.isDark
              ? LicoPaneGlass.contentInnerCardFill
              : (colors.isDark
                    ? LicoPaneGlass.contentInnerCardFill
                    : colors.surfaceRaised),
          borderRadius: BorderRadius.circular(LicoRadius.card),
          stroke: colors.line,
          shadows: LicoElevation.raised.shadows(colors),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MessagingAgentAvatar(
                  target: collaborationAvatarTarget(model.agentId),
                  size: 40,
                  iconSize: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall,
                      ),
                      Text(
                        [
                          if (model.roleLabel.isNotEmpty) model.roleLabel,
                          model.agentLabel,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                if (model.modelChip != null) ...[
                  const SizedBox(width: 8),
                  CollaborationPill(
                    label: model.modelChip!,
                    metrics: metrics,
                    fill: colors.isDark
                        ? colors.background
                        : (colors.isDark
                              ? LicoPaneGlass.contentInnerCardFill
                              : colors.surfaceLow),
                    ink: colors.textMuted,
                    rim: colors.line,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                CollaborationStatusDot(color: ink.dot(model.status)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    model.statusLabel.isEmpty
                        ? strings.collaborationNodeStatus(model.status)
                        : model.statusLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelMedium?.copyWith(
                      color: ink.statusText(model.status),
                    ),
                  ),
                ),
                if (state != null && state.maxAttempts > 1)
                  Text(
                    strings.collaborationAttempt(
                      state.attempt,
                      state.maxAttempts,
                    ),
                    style: textTheme.labelSmall,
                  ),
              ],
            ),
            for (final note in model.notes) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: continuousHairlineDecoration(
                  color: note.tone == CollaborationNoteTone.receipt
                      ? colors.accentSurface
                      : (colors.isDark
                            ? LicoPaneGlass.contentInnerCardFill
                            : colors.surfaceLow),
                  borderRadius: BorderRadius.circular(LicoRadius.chip),
                  stroke: note.tone == CollaborationNoteTone.receipt
                      ? colors.accentBorder
                      : colors.line,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      switch (note.tone) {
                        CollaborationNoteTone.warning =>
                          Icons.warning_amber_rounded,
                        CollaborationNoteTone.receipt =>
                          Icons.swap_horiz_rounded,
                        CollaborationNoteTone.muted => Icons.schedule_rounded,
                      },
                      size: 13,
                      color: ink.note(note.tone),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        note.text,
                        style: textTheme.labelSmall?.copyWith(
                          color: ink.note(note.tone),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (state != null && state.artifactCount > 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.description_outlined,
                    size: 13,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      strings.collaborationArtifactCount(state.artifactCount),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (awaiting) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    escalated
                        ? Icons.shield_outlined
                        : Icons.priority_high_rounded,
                    size: 15,
                    color: ink.gate,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      escalated
                          ? '${strings.collaborationEscalatedTitle} · '
                                '${gate.title}'
                          : '${strings.collaborationGateWaiting} · '
                                '${gate.title}',
                      style: textTheme.labelLarge?.copyWith(height: 1.3),
                    ),
                  ),
                ],
              ),
              if (gate.detail.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  gate.detail,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
              if (gate.review case CollaborationGateEscalated(
                :final assistantNote,
              )) ...[
                const SizedBox(height: 6),
                Text(
                  strings.collaborationAssistantNote(assistantNote),
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 9),
              Wrap(
                spacing: 7,
                runSpacing: 6,
                children: [
                  for (final option in gate.options)
                    CollaborationActionButton(
                      key: Key('collab-gate-option-${option.id}'),
                      label: option.label,
                      tone: CollaborationActionTone.soft,
                      onPressed: pending
                          ? null
                          : () => onGateOption(gate.gateId, option.id),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
