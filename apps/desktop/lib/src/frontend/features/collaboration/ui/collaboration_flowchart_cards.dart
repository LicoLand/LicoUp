import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_card_model.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_style.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/presentation/agents/agent_product_identity.dart';

/// A synthetic roster entry so [MessagingAgentAvatar] can brand an agent id.
/// A node without an agent belongs to the Lead, the Lico Agent.
TargetCandidate collaborationAvatarTarget(String? agentId) {
  final id = agentId ?? 'lico';
  return TargetCandidate(
    target: agentProductId(id),
    label: agentProductLabel(id),
    kind: 'conversation-member',
    status: TargetCandidateStatus.synthesizedMembership,
    configured: false,
    confidence: 1,
    adapterStatus: 'runtime-unavailable',
    scanSource: 'collaboration-run',
  );
}

/// Loops shared by every card so the canvas runs two tickers, not one per
/// card.
final class CollaborationCardAnimations {
  const CollaborationCardAnimations({
    required this.ambient,
    required this.spin,
    required this.enabled,
  });

  /// 0..1 over [LicoMotion.loopLong]: sheens, pulses and glows.
  final Animation<double> ambient;

  /// 0..1 over [LicoMotion.loopShort]: spinners and avatar rings.
  final Animation<double> spin;

  /// False under reduced motion; effects then render one static frame.
  final bool enabled;
}

/// One positioned display node: frame, content, status effects and input.
final class CollaborationCardView extends StatefulWidget {
  const CollaborationCardView({
    super.key,
    required this.model,
    required this.metrics,
    required this.animations,
    required this.focusNode,
    required this.onOpen,
    required this.onHover,
    this.entrance,
  });

  final CollaborationCardModel model;
  final CollaborationCardMetrics metrics;
  final CollaborationCardAnimations animations;
  final FocusNode focusNode;

  /// Opens the node details; null for a card without details.
  final VoidCallback? onOpen;
  final ValueChanged<bool> onHover;

  /// Plan-change entrance for a node the new revision added.
  final Animation<double>? entrance;

  @override
  State<CollaborationCardView> createState() => _CollaborationCardViewState();
}

final class _CollaborationCardViewState extends State<CollaborationCardView>
    with SingleTickerProviderStateMixin {
  AnimationController? _shake;
  bool _focused = false;

  @override
  void didUpdateWidget(CollaborationCardView old) {
    super.didUpdateWidget(old);
    if (widget.model.status == CollaborationNodeStatus.failed &&
        old.model.status != CollaborationNodeStatus.failed) {
      final duration = context.motion(LicoMotion.long);
      if (duration > Duration.zero) {
        (_shake ??= AnimationController(vsync: this, duration: duration))
          ..duration = duration
          ..forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _shake?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    Widget card = switch (model) {
      CollaborationTaskCardModel() => _TaskCard(
        model: model,
        metrics: widget.metrics,
        animations: widget.animations,
        focused: _focused,
        onOpen: widget.onOpen,
      ),
      CollaborationStackCardModel() => _StackCard(
        model: model,
        metrics: widget.metrics,
        animations: widget.animations,
        focused: _focused,
      ),
      CollaborationConnectorModel() => _ConnectorCard(
        model: model,
        focused: _focused,
      ),
      CollaborationTerminalModel() => _TerminalCard(
        model: model,
        focused: _focused,
      ),
    };

    final opacity = switch (model.presence) {
      CollaborationPresence.proposed => 0.55,
      CollaborationPresence.removed => 0.5,
      CollaborationPresence.planned =>
        model.status == CollaborationNodeStatus.succeeded ? 0.78 : 1.0,
    };
    if (opacity < 1) card = Opacity(opacity: opacity, child: card);

    final shake = _shake;
    if (shake != null) {
      card = AnimatedBuilder(
        animation: shake,
        builder: (context, child) {
          final t = shake.value;
          return Transform.translate(
            offset: Offset(math.sin(t * math.pi * 4) * 5 * (1 - t), 0),
            child: child,
          );
        },
        child: card,
      );
    }

    final entrance = widget.entrance;
    if (entrance != null) {
      card = FadeTransition(
        opacity: entrance,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1).animate(entrance),
          child: card,
        ),
      );
    }

    final open = widget.onOpen;
    return Semantics(
      button: open != null,
      label: model.semanticLabel,
      child: Focus(
        focusNode: widget.focusNode,
        canRequestFocus: open != null,
        skipTraversal: open == null,
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: (node, event) {
          if (open != null &&
              event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            open();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: open == null ? MouseCursor.defer : SystemMouseCursors.click,
          onEnter: (_) => widget.onHover(true),
          onExit: (_) => widget.onHover(false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: open,
            child: card,
          ),
        ),
      ),
    );
  }
}

/// Rounded card frame with the status border and its painted effects.
final class _CardFrame extends StatelessWidget {
  const _CardFrame({
    required this.model,
    required this.width,
    required this.focused,
    required this.child,
    this.animations,
    this.padding = EdgeInsets.zero,
    this.minHeight = 0,
  });

  final CollaborationCardModel model;
  final double width;
  final bool focused;
  final Widget child;
  final CollaborationCardAnimations? animations;
  final EdgeInsets padding;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final ink = CollaborationInk(colors);
    final radius = BorderRadius.circular(CollaborationCardMetrics.radius);
    final ghost = model.presence != CollaborationPresence.planned;
    final border = focused
        ? ink.brand
        : switch (model.status) {
            CollaborationNodeStatus.running ||
            CollaborationNodeStatus.retrying => colors.brandBorder,
            CollaborationNodeStatus.waitingUser => colors.accent,
            _ => colors.lineStrong,
          };
    final animations = this.animations;
    final effect = animations == null || ghost
        ? _FrameEffect.none
        : switch (model.status) {
            CollaborationNodeStatus.running => _FrameEffect.sheen,
            CollaborationNodeStatus.waitingUser => _FrameEffect.glow,
            _ => _FrameEffect.none,
          };
    return CustomPaint(
      foregroundPainter: _FramePainter(
        effect: effect,
        ghost: ghost
            ? (model.presence == CollaborationPresence.proposed
                  ? colors.accent
                  : colors.lineStrong)
            : null,
        radius: radius,
        colors: colors,
        animation: animations?.ambient,
        animate: animations?.enabled ?? false,
      ),
      child: Container(
        width: width,
        constraints: BoxConstraints(minHeight: minHeight),
        padding: padding,
        decoration: continuousHairlineDecoration(
          color: colors.isDark
              ? LicoPaneGlass.contentInnerCardFill
              : (colors.isDark
                    ? LicoPaneGlass.contentInnerCardFill
                    : colors.surfaceRaised),
          borderRadius: radius,
          stroke: ghost ? null : border,
          strokeWidth: CollaborationCardMetrics.border,
          shadows: ghost ? null : LicoElevation.card.shadows(colors),
        ),
        child: child,
      ),
    );
  }
}

enum _FrameEffect { none, sheen, glow }

final class _FramePainter extends CustomPainter {
  _FramePainter({
    required this.effect,
    required this.ghost,
    required this.radius,
    required this.colors,
    required this.animation,
    required this.animate,
  }) : super(repaint: effect == _FrameEffect.none ? null : animation);

  final _FrameEffect effect;

  /// Dashed rim color for a proposal ghost; null for a planned card.
  final Color? ghost;
  final BorderRadius radius;
  final LicoThemeColors colors;
  final Animation<double>? animation;
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect);
    final ghost = this.ghost;
    if (ghost != null) {
      _paintDashed(
        canvas,
        Path()..addRRect(rrect.deflate(CollaborationCardMetrics.border / 2)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = CollaborationCardMetrics.border
          ..color = ghost,
        dash: 5,
        gap: 4,
      );
    }
    final t = animation?.value ?? 0;
    switch (effect) {
      case _FrameEffect.none:
        break;
      case _FrameEffect.sheen:
        // Opacity rises to a peak at 35% of the loop and is gone by 70%.
        final opacity = !animate
            ? 0.0
            : t < 0.35
            ? t / 0.35 * 0.9
            : t < 0.7
            ? (0.7 - t) / 0.35 * 0.9
            : 0.0;
        if (opacity <= 0) return;
        final ink = CollaborationInk(colors);
        canvas.drawRRect(
          rrect.deflate(CollaborationCardMetrics.border / 2),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = CollaborationCardMetrics.border
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                ink.brand.withValues(alpha: 0),
                ink.brand.withValues(alpha: opacity),
                ink.accent.withValues(alpha: opacity),
                ink.accent.withValues(alpha: 0),
              ],
              stops: const [0.3, 0.46, 0.54, 0.7],
            ).createShader(rect),
        );
      case _FrameEffect.glow:
        final strength = animate
            ? 0.35 + 0.65 * (0.5 - 0.5 * math.cos(t * math.pi * 2))
            : 0.7;
        final ring = rrect.inflate(4);
        final glow = colors.accentGlow;
        canvas
          ..drawRRect(
            ring,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 6
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
              ..color = glow.withValues(alpha: glow.a * strength),
          )
          ..drawRRect(
            ring,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..color = glow.withValues(alpha: glow.a * strength),
          );
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.effect != effect ||
      old.ghost != ghost ||
      old.colors != colors ||
      old.animate != animate ||
      old.animation != animation;
}

void _paintDashed(
  Canvas canvas,
  Path path,
  Paint paint, {
  required double dash,
  required double gap,
}) {
  for (final metric in path.computeMetrics()) {
    var start = 0.0;
    while (start < metric.length) {
      canvas.drawPath(
        metric.extractPath(start, math.min(start + dash, metric.length)),
        paint,
      );
      start += dash + gap;
    }
  }
}

final class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.model,
    required this.metrics,
    required this.animations,
    required this.focused,
    required this.onOpen,
  });

  final CollaborationTaskCardModel model;
  final CollaborationCardMetrics metrics;
  final CollaborationCardAnimations animations;
  final bool focused;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final ink = CollaborationInk(colors);
    final strings = LicoStrings.of(context);
    final status = model.status;
    final tag = model.tag;
    final modelChip = model.modelChip;
    final approvedReason = model.approvedReason;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: metrics.topRowHeight,
          child: Row(
            children: [
              _Avatar(
                agentId: model.agentId,
                size: CollaborationCardMetrics.avatar,
                ring: status == CollaborationNodeStatus.running
                    ? animations
                    : null,
              ),
              const SizedBox(width: 8),
              Text(
                model.roleLabel.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: metrics.role.copyWith(color: ink.role),
              ),
              if (modelChip != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    widthFactor: 1,
                    child: CollaborationPill(
                      label: modelChip,
                      metrics: metrics,
                      fill: colors.isDark
                          ? colors.background
                          : (colors.isDark
                                ? LicoPaneGlass.contentInnerCardFill
                                : colors.surfaceLow),
                      ink: colors.textMuted,
                      rim: colors.line,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: CollaborationCardMetrics.rowGap),
        SizedBox(
          height: metrics.lineHeight(metrics.title),
          child: Text(
            model.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: metrics.title.copyWith(
              color: model.presence == CollaborationPresence.removed
                  ? colors.textDisabled
                  : colors.text,
              decoration: model.presence == CollaborationPresence.removed
                  ? TextDecoration.lineThrough
                  : null,
            ),
          ),
        ),
        if (metrics.hasStatusRow(model)) ...[
          const SizedBox(height: CollaborationCardMetrics.rowGap),
          SizedBox(
            height: metrics.statusRowHeight,
            child: Row(
              children: [
                if (model.locked)
                  Icon(Icons.lock_outline_rounded, size: 11, color: ink.accent)
                else
                  CollaborationStatusDot(
                    color: ink.dot(status),
                    pulse:
                        status == CollaborationNodeStatus.running ||
                            status == CollaborationNodeStatus.retrying
                        ? animations
                        : null,
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    model.statusLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metrics.status.copyWith(
                      color: model.locked ? ink.accent : ink.statusText(status),
                    ),
                  ),
                ),
                if (model.actionLabel != null && onOpen != null)
                  _CardLink(
                    label: model.actionLabel!,
                    style: metrics.small,
                    onTap: onOpen!,
                  ),
              ],
            ),
          ),
        ],
        if (approvedReason != null) ...[
          const SizedBox(height: CollaborationCardMetrics.rowGap),
          SizedBox(
            height: metrics.pillHeight(metrics.small),
            child: Row(
              children: [
                CollaborationPill(
                  label: strings.collaborationAssistantApproved,
                  icon: Icons.verified_user_outlined,
                  metrics: metrics,
                  fill: colors.brandSurface,
                  ink: ink.brand,
                  rim: colors.brandBorder,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    approvedReason,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metrics.small.copyWith(color: colors.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ],
        for (final note in model.notes) ...[
          const SizedBox(height: CollaborationCardMetrics.noteGap),
          SizedBox(
            height: 1,
            child: CustomPaint(painter: _DashedRulePainter(colors.line)),
          ),
          const SizedBox(height: CollaborationCardMetrics.noteInset),
          SizedBox(
            height: metrics.noteHeight(note.text),
            child: Text(
              note.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: metrics.small.copyWith(color: ink.note(note.tone)),
            ),
          ),
        ],
      ],
    );
    final frame = _CardFrame(
      model: model,
      width: CollaborationCardMetrics.taskWidth,
      focused: focused,
      animations: animations,
      minHeight: CollaborationCardMetrics.taskMinHeight,
      // The rim is added by the frame's decoration; the measured metrics
      // count it once per side.
      padding: const EdgeInsets.symmetric(
        horizontal: CollaborationCardMetrics.padX,
        vertical: CollaborationCardMetrics.padY,
      ),
      child: content,
    );
    if (tag == null) return frame;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        frame,
        Positioned(
          top: -metrics.pillHeight(metrics.small) / 2,
          right: 10,
          child: _TagPill(tag: tag, metrics: metrics),
        ),
      ],
    );
  }
}

final class _StackCard extends StatelessWidget {
  const _StackCard({
    required this.model,
    required this.metrics,
    required this.animations,
    required this.focused,
  });

  final CollaborationStackCardModel model;
  final CollaborationCardMetrics metrics;
  final CollaborationCardAnimations animations;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final ink = CollaborationInk(colors);
    final children = <Widget>[
      SizedBox(
        height: metrics.stackHeadHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: CollaborationCardMetrics.padX,
          ),
          child: Row(
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: CollaborationCardMetrics.stackHeadIcon,
                color: colors.isDark
                    ? colors.accentStrong
                    : colors.primaryStrong,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${model.headLabel} ${model.succeeded}/${model.steps.length}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: metrics.status.copyWith(color: colors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
      _Divider(colors.line),
    ];
    for (var i = 0; i < model.steps.length; i++) {
      final step = model.steps[i];
      children.add(
        SizedBox(
          height: metrics.stepHeight(step),
          child: _StepRow(
            step: step,
            metrics: metrics,
            animations: animations,
            ink: ink,
          ),
        ),
      );
      if (i < model.steps.length - 1) children.add(_Divider(colors.line));
    }
    return _CardFrame(
      model: model,
      width: CollaborationCardMetrics.stackWidth,
      focused: focused,
      animations: animations,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

final class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.metrics,
    required this.animations,
    required this.ink,
  });

  final CollaborationStepModel step;
  final CollaborationCardMetrics metrics;
  final CollaborationCardAnimations animations;
  final CollaborationInk ink;

  @override
  Widget build(BuildContext context) {
    final colors = ink.colors;
    final strings = LicoStrings.of(context);
    final removed = step.presence == CollaborationPresence.removed;
    final titleColor = removed
        ? colors.textDisabled
        : step.status == CollaborationNodeStatus.succeeded
        ? colors.textMuted
        : colors.text;
    final tag = step.tag;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CollaborationCardMetrics.padX,
        vertical: CollaborationCardMetrics.stepPadY,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: metrics.lineHeight(metrics.status),
                  child: Text(
                    step.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metrics.status.copyWith(
                      color: titleColor,
                      decoration: removed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                SizedBox(
                  height: metrics.lineHeight(metrics.small),
                  child: Text(
                    step.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metrics.small.copyWith(color: colors.textMuted),
                  ),
                ),
                if (tag != null) ...[
                  const SizedBox(height: 4),
                  _TagPill(tag: tag, metrics: metrics),
                ],
                if (step.locked) ...[
                  const SizedBox(height: CollaborationCardMetrics.lockGap),
                  SizedBox(
                    height: metrics.lineHeight(metrics.small),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 10,
                          color: ink.accent,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            strings.collaborationHeldForPlan,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: metrics.small.copyWith(color: ink.accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox.square(
            dimension: CollaborationCardMetrics.stepIcon,
            child: Center(
              child: _StepStatusIcon(
                status: step.structureOnly
                    ? CollaborationNodeStatus.pending
                    : step.status,
                animations: animations,
                ink: ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A step's trailing status glyph; the check pops when a step completes.
final class _StepStatusIcon extends StatefulWidget {
  const _StepStatusIcon({
    required this.status,
    required this.animations,
    required this.ink,
  });

  final CollaborationNodeStatus status;
  final CollaborationCardAnimations animations;
  final CollaborationInk ink;

  @override
  State<_StepStatusIcon> createState() => _StepStatusIconState();
}

final class _StepStatusIconState extends State<_StepStatusIcon>
    with SingleTickerProviderStateMixin {
  AnimationController? _pop;
  CurvedAnimation? _popCurve;

  @override
  void didUpdateWidget(_StepStatusIcon old) {
    super.didUpdateWidget(old);
    if (widget.status == CollaborationNodeStatus.succeeded &&
        old.status != CollaborationNodeStatus.succeeded) {
      final duration = context.motion(LicoMotion.short);
      if (duration > Duration.zero) {
        final pop = _pop ??= AnimationController(
          vsync: this,
          duration: duration,
        );
        _popCurve ??= CurvedAnimation(
          parent: pop,
          curve: LicoMotion.decelerate,
        );
        pop
          ..duration = duration
          ..forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _popCurve?.dispose();
    _pop?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = widget.ink;
    final colors = ink.colors;
    switch (widget.status) {
      case CollaborationNodeStatus.succeeded:
        final check = Icon(
          Icons.check_rounded,
          size: 15,
          color: colors.success,
        );
        final curve = _popCurve;
        if (curve == null) return check;
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.6, end: 1).animate(curve),
            child: check,
          ),
        );
      case CollaborationNodeStatus.failed:
        return Icon(Icons.close_rounded, size: 15, color: colors.error);
      case CollaborationNodeStatus.waitingUser:
        return Icon(Icons.priority_high_rounded, size: 15, color: ink.gate);
      case CollaborationNodeStatus.running:
      case CollaborationNodeStatus.retrying:
        return SizedBox.square(
          dimension: 13,
          child: CustomPaint(
            painter: _SpinnerPainter(
              spin: widget.animations.spin,
              track: colors.brandBorder,
              arc: ink.brand,
            ),
          ),
        );
      case CollaborationNodeStatus.waitingAssistant:
        return CollaborationStatusDot(color: colors.warning);
      case CollaborationNodeStatus.pending:
      case CollaborationNodeStatus.cancelled:
      case CollaborationNodeStatus.heldForPlan:
        return CollaborationStatusDot(color: colors.textDisabled);
    }
  }
}

final class _ConnectorCard extends StatelessWidget {
  const _ConnectorCard({required this.model, required this.focused});

  final CollaborationConnectorModel model;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final ink = CollaborationInk(colors);
    final done = model.status == CollaborationNodeStatus.succeeded;
    final color = done ? ink.brand : colors.textMuted;
    final size = CollaborationCardMetrics.connectorSize;
    return Container(
      width: size.width,
      height: size.height,
      decoration: continuousHairlineDecoration(
        color: done
            ? colors.brandSurface
            : (colors.isDark
                  ? LicoPaneGlass.contentInnerCardFill
                  : colors.surfaceLow),
        borderRadius: BorderRadius.circular(size.height / 2),
        stroke: focused
            ? ink.brand
            : done
            ? colors.brandBorder
            : colors.lineStrong,
        strokeWidth: CollaborationCardMetrics.border,
        shadows: LicoElevation.card.shadows(colors),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            switch (model.nodeKind) {
              CollaborationNodeKind.fork => Icons.call_split_rounded,
              CollaborationNodeKind.join => Icons.call_merge_rounded,
              CollaborationNodeKind.choice => Icons.alt_route_rounded,
              _ => Icons.arrow_forward_rounded,
            },
            size: 14,
            color: color,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              model.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

final class _TerminalCard extends StatelessWidget {
  const _TerminalCard({required this.model, required this.focused});

  final CollaborationTerminalModel model;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final done = model.status == CollaborationNodeStatus.succeeded;
    final color = done ? colors.success : colors.textMuted;
    final size = CollaborationCardMetrics.terminalSize;
    return Container(
      width: size.width,
      height: size.height,
      decoration: continuousHairlineDecoration(
        color: colors.isDark
            ? LicoPaneGlass.contentInnerCardFill
            : (colors.isDark
                  ? LicoPaneGlass.contentInnerCardFill
                  : colors.surfaceRaised),
        borderRadius: BorderRadius.circular(size.height / 2),
        stroke: focused
            ? CollaborationInk(colors).brand
            : done
            ? colors.success
            : colors.lineStrong,
        strokeWidth: CollaborationCardMetrics.border,
        shadows: LicoElevation.card.shadows(colors),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.flag_outlined, size: 15, color: color),
          Text(
            model.label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

final class _Avatar extends StatelessWidget {
  const _Avatar({required this.agentId, required this.size, this.ring});

  final String? agentId;
  final double size;

  /// Spins a brand arc around a running agent.
  final CollaborationCardAnimations? ring;

  @override
  Widget build(BuildContext context) {
    final ring = this.ring;
    final avatar = MessagingAgentAvatar(
      target: collaborationAvatarTarget(agentId),
      size: size,
      iconSize: size * 0.58,
    );
    if (ring == null) return avatar;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            left: -3,
            top: -3,
            right: -3,
            bottom: -3,
            child: IgnorePointer(
              child: CustomPaint(
                painter: _SpinnerPainter(
                  spin: ring.spin,
                  arc: CollaborationInk(context.licoColors).brand,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A quarter-turn arc rotating with [spin], over an optional full track.
final class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({required this.spin, required this.arc, this.track})
    : super(repaint: spin);

  final Animation<double> spin;
  final Color arc;
  final Color? track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final track = this.track;
    if (track != null) {
      canvas.drawOval(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = track,
      );
    }
    canvas.drawArc(
      rect,
      -math.pi / 2 + spin.value * math.pi * 2,
      math.pi / 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = arc,
    );
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) =>
      old.arc != arc || old.track != track || old.spin != spin;
}

/// A 7px status dot; pulses with [pulse] while work runs.
final class CollaborationStatusDot extends StatelessWidget {
  const CollaborationStatusDot({super.key, required this.color, this.pulse});

  final Color color;

  /// Pulses the dot while work runs.
  final CollaborationCardAnimations? pulse;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 7,
      child: CustomPaint(
        painter: _DotPainter(color: color, pulse: pulse),
      ),
    );
  }
}

final class _DotPainter extends CustomPainter {
  _DotPainter({required this.color, required this.pulse})
    : super(repaint: pulse?.ambient);

  final Color color;
  final CollaborationCardAnimations? pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final pulse = this.pulse;
    final alpha = pulse == null || !pulse.enabled
        ? 1.0
        : 0.45 +
              0.55 * (0.5 + 0.5 * math.cos(pulse.ambient.value * math.pi * 2));
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide / 2,
      Paint()..color = color.withValues(alpha: color.a * alpha),
    );
  }

  @override
  bool shouldRepaint(_DotPainter old) =>
      old.color != color || old.pulse != pulse;
}

/// A one-line capsule whose height [CollaborationCardMetrics.pillHeight]
/// measures.
final class CollaborationPill extends StatelessWidget {
  const CollaborationPill({
    super.key,
    required this.label,
    required this.metrics,
    required this.fill,
    required this.ink,
    required this.rim,
    this.icon,
    this.maxWidth = double.infinity,
  });

  final String label;
  final CollaborationCardMetrics metrics;
  final Color fill;
  final Color ink;
  final Color? rim;
  final IconData? icon;

  /// Caps the capsule so a long label ellipsizes instead of pushing siblings.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final height = metrics.pillHeight(metrics.small);
    final label = Text(
      this.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: metrics.small.copyWith(color: ink),
    );
    return Container(
      height: height,
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(
        horizontal: CollaborationCardMetrics.pillPadX,
      ),
      alignment: Alignment.center,
      decoration: continuousHairlineDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(height / 2),
        stroke: rim,
      ),
      child: icon == null
          ? label
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 10, color: ink),
                const SizedBox(width: 4),
                Flexible(child: label),
              ],
            ),
    );
  }
}

final class _TagPill extends StatelessWidget {
  const _TagPill({required this.tag, required this.metrics});

  final CollaborationCardTag tag;
  final CollaborationCardMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final ink = CollaborationInk(colors);
    return switch (tag.tone) {
      CollaborationTagTone.added => CollaborationPill(
        label: tag.label,
        metrics: metrics,
        fill: colors.success,
        ink: colors.isDark
            ? colors.background
            : (colors.isDark
                  ? LicoPaneGlass.contentInnerCardFill
                  : colors.surfaceRaised),
        rim: null,
      ),
      CollaborationTagTone.changed ||
      CollaborationTagTone.proposal => CollaborationPill(
        label: tag.label,
        metrics: metrics,
        fill: colors.accentSurface,
        ink: ink.accent,
        rim: colors.accentBorder,
      ),
      CollaborationTagTone.removed => CollaborationPill(
        label: tag.label,
        metrics: metrics,
        fill: (colors.isDark
            ? LicoPaneGlass.contentInnerCardFill
            : colors.surfaceLow),
        ink: colors.textMuted,
        rim: colors.line,
      ),
    };
  }
}

/// The status row's text action; opens the node details.
final class _CardLink extends StatefulWidget {
  const _CardLink({
    required this.label,
    required this.style,
    required this.onTap,
  });

  final String label;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  State<_CardLink> createState() => _CardLinkState();
}

final class _CardLinkState extends State<_CardLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: context.motion(LicoMotion.micro),
          padding: const EdgeInsets.symmetric(
            horizontal: CollaborationCardMetrics.pillPadX,
            vertical: CollaborationCardMetrics.pillPadY,
          ),
          decoration: BoxDecoration(
            color: _hovered
                ? colors.brandSurface
                : colors.brandSurface.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(LicoRadius.chip),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            style: widget.style.copyWith(color: CollaborationInk(colors).brand),
          ),
        ),
      ),
    );
  }
}

final class _Divider extends StatelessWidget {
  const _Divider(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 1,
    child: CustomPaint(
      painter: ContinuousEdgeHairlinePainter(
        color: color,
        edge: AxisDirection.up,
      ),
    ),
  );
}

final class _DashedRulePainter extends CustomPainter {
  const _DashedRulePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var x = 0.0; x < size.width; x += 6) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, math.min(3, size.width - x), size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedRulePainter old) => old.color != color;
}
