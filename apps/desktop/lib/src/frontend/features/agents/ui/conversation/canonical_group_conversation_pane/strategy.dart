import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
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

/// Assistant readiness projected into name color and accessible status.
/// Every state derives from controller, profile, and turn signals.
enum GroupAssistantStatusLight {
  /// No assistant Membership is designated on the group.
  unconfigured,

  /// An assistant is designated but paused by the toggle.
  paused,

  /// Designated, active, and idle.
  ready,

  /// An assistant turn is live or a dispatch is pending.
  working,

  /// A live turn waits on the human (approval, permission, input).
  waiting,

  /// The conversation failure banner carries a group-operation failure.
  failure,
}

final class GroupStrategyPickerCapsule extends StatelessWidget {
  const GroupStrategyPickerCapsule({
    super.key,
    required this.selectedRevision,
    this.onOpen,
  });

  final String? selectedRevision;

  /// Opens the orchestration edit surface for [selectedRevision]. The capsule
  /// shows no hover list; tapping is the only gesture and it always edits.
  final ValueChanged<String?>? onOpen;

  @override
  Widget build(BuildContext context) {
    final onOpen = this.onOpen;
    return _GroupStrategyPickerTrigger(
      onTap: onOpen == null ? null : () => onOpen(selectedRevision),
    );
  }
}

final class _GroupStrategyPickerTrigger extends StatelessWidget {
  const _GroupStrategyPickerTrigger({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: strings.adaptiveFlywheel,
      child: AppleGlassSurface(
        borderRadius: kComposerCapsuleBorderRadius,
        fillAlpha: colors.isDark ? 22 : 10,
        child: InkWell(
          key: const Key('canonical-group-strategy-picker'),
          onTap: onTap,
          borderRadius: kComposerCapsuleBorderRadius,
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: SizedBox(
            height: 32,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome_outlined,
                    size: 14,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      strings.adaptiveFlywheel,
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Assistant identity in one glass capsule: the name opens the editor, and
/// the small trailing toggle pauses or resumes future dispatch. An active
/// capsule carries the sunset light on its rim.
final class AssistantToggleButton extends StatelessWidget {
  const AssistantToggleButton({
    super.key,
    required this.active,
    required this.configured,
    required this.label,
    required this.status,
    required this.onTap,
    required this.onEdit,
  });

  final bool active;
  final bool configured;
  final String label;
  final GroupAssistantStatusLight status;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final enabled = active && configured;
    final statusLabel = switch (status) {
      GroupAssistantStatusLight.unconfigured =>
        strings.assistantNeedsConfigurationStatus,
      GroupAssistantStatusLight.paused => strings.assistantPausedStatus,
      GroupAssistantStatusLight.ready => strings.active,
      GroupAssistantStatusLight.working => strings.assistantWorkingAloneStatus,
      GroupAssistantStatusLight.waiting => strings.waiting,
      GroupAssistantStatusLight.failure => strings.lifecycleFailed,
    };
    final textColor = switch (status) {
      GroupAssistantStatusLight.waiting => colors.accent,
      GroupAssistantStatusLight.failure => colors.error,
      GroupAssistantStatusLight.paused ||
      GroupAssistantStatusLight.unconfigured => colors.textMuted,
      _ => colors.text,
    };
    const radius = kComposerCapsuleBorderRadius;
    return _AssistantCapsuleSunsetRim(
      active: enabled,
      borderRadius: radius,
      child: AppleGlassSurface(
        borderRadius: radius,
        fillAlpha: colors.isDark ? 22 : 10,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Semantics(
                button: true,
                label: label,
                hint: strings.configureAssistantTooltip,
                child: Tooltip(
                  message: strings.configureAssistantTooltip,
                  child: InkWell(
                    key: const Key('canonical-group-assistant-control'),
                    onTap: onEdit,
                    borderRadius: radius,
                    mouseCursor: SystemMouseCursors.click,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: SizedBox(
                        height: 32,
                        child: Center(
                          widthFactor: 1,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 160),
                            child: RepaintBoundary(
                              child: _AssistantNameLight(
                                active: enabled,
                                baseColor: textColor,
                                child: Text(
                                  label,
                                  key: Key(
                                    'canonical-group-assistant-status-${status.name}',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: textColor,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: _AssistantParticipationToggle(
                key: const Key('canonical-group-assistant-toggle'),
                enabled: enabled,
                interactive: configured,
                label: label,
                statusLabel: statusLabel,
                tooltip: enabled
                    ? strings.assistantActiveTooltip
                    : strings.assistantPausedTooltip,
                onTap: configured ? onTap : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 紫气东来 · 浮光铄金: a violet aura trailing into a molten-gold core, shared
/// by the active assistant name and its capsule rim.
List<Color> _assistantSunsetSpectrum(Color baseColor, {required bool isDark}) =>
    isDark
    ? [
        baseColor,
        const Color(0xFF8A3FFC),
        const Color(0xFFC27DFF),
        const Color(0xFFFB923C),
        const Color(0xFFFBBF24),
        const Color(0xFFFCD34D),
        baseColor,
      ]
    : [
        baseColor,
        const Color(0xFF7C3AED),
        const Color(0xFF9333EA),
        const Color(0xFFEA580C),
        const Color(0xFFD97706),
        const Color(0xFFB45309),
        baseColor,
      ];

const _assistantSunsetStops = [0.0, 0.24, 0.40, 0.56, 0.70, 0.78, 1.0];

/// Closed chroma loop of the sunset spectrum for the capsule rim sweep.
List<Color> _assistantSunsetLoop({required bool isDark}) {
  final chroma = _assistantSunsetSpectrum(
    const Color(0x00000000),
    isDark: isDark,
  ).sublist(1, 6);
  return [...chroma, chroma.first];
}

/// Sunset rim for the assistant capsule: a purple-and-gold light travels the
/// silhouette while the assistant participates. Paused or unconfigured
/// capsules rest as plain glass; reduced motion keeps a static rim.
final class _AssistantCapsuleSunsetRim extends StatefulWidget {
  const _AssistantCapsuleSunsetRim({
    required this.active,
    required this.borderRadius,
    required this.child,
  });

  final bool active;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  State<_AssistantCapsuleSunsetRim> createState() =>
      _AssistantCapsuleSunsetRimState();
}

final class _AssistantCapsuleSunsetRimState
    extends State<_AssistantCapsuleSunsetRim>
    with SingleTickerProviderStateMixin {
  late final AnimationController _light = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_AssistantCapsuleSunsetRim oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.active && context.allowsAmbientMotion) {
      if (!_light.isAnimating) _light.repeat();
    } else {
      _light.stop();
    }
  }

  @override
  void dispose() {
    _light.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    final animate = context.allowsAmbientMotion;
    return CustomPaint(
      key: const Key('canonical-group-assistant-sunset-rim'),
      foregroundPainter: _AssistantSunsetRimPainter(
        progress: _light,
        animate: animate,
        borderRadius: widget.borderRadius,
        colors: _assistantSunsetLoop(isDark: context.licoColors.isDark),
      ),
      child: widget.child,
    );
  }
}

final class _AssistantSunsetRimPainter extends CustomPainter {
  const _AssistantSunsetRimPainter({
    required this.progress,
    required this.animate,
    required this.borderRadius,
    required this.colors,
  }) : super(repaint: animate ? progress : null);

  final Animation<double> progress;
  final bool animate;
  final BorderRadius borderRadius;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const width = 1.2;
    final rect = Offset.zero & size;
    final path = Path()
      ..addRRect(continuousStrokeRRect(size, borderRadius, width));
    final rotation = GradientRotation(
      (animate ? progress.value : 0.5) * math.pi * 2,
    );
    canvas.drawPath(
      path,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
        ..shader = SweepGradient(
          colors: [
            for (final color in colors) color.withValues(alpha: color.a * 0.45),
          ],
          transform: rotation,
        ).createShader(rect),
    );
    canvas.drawPath(
      path,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = SweepGradient(
          colors: colors,
          transform: rotation,
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_AssistantSunsetRimPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.animate != animate ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.colors != colors;
}

/// Small trailing switch for Assistant participation: a purple track while
/// on, a muted track while off. The name and pencil own editing; this owns
/// dispatch.
final class _AssistantParticipationToggle extends StatelessWidget {
  const _AssistantParticipationToggle({
    super.key,
    required this.enabled,
    required this.interactive,
    required this.label,
    required this.statusLabel,
    required this.tooltip,
    required this.onTap,
  });

  final bool enabled;
  final bool interactive;
  final String label;
  final String statusLabel;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final track = enabled
        ? (colors.isDark ? const Color(0xFF8A3FFC) : const Color(0xFF7C3AED))
        : colors.textMuted.withAlpha(colors.isDark ? 64 : 48);
    final duration = context.motion(LicoMotion.micro);
    return Semantics(
      button: true,
      enabled: interactive,
      toggled: enabled,
      label: label,
      value: statusLabel,
      hint: tooltip,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Center(
              child: AnimatedContainer(
                duration: duration,
                curve: LicoMotion.standard,
                width: 26,
                height: 16,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: track.withValues(
                    alpha: interactive ? track.a : track.a * 0.5,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: AnimatedAlign(
                  duration: duration,
                  curve: LicoMotion.standard,
                  alignment: enabled
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 2,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                    child: const SizedBox(width: 12, height: 12),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Quiet readout of the assistant's selected model and reasoning effort,
/// placed before the send button: the model name in the readable text color,
/// the effort muted behind it. Visible only while the assistant participates;
/// tapping opens the assistant editor.
final class AssistantModelReadout extends StatelessWidget {
  const AssistantModelReadout({
    super.key,
    required this.visible,
    required this.modelLabel,
    required this.effortLabel,
    required this.tooltip,
    required this.onTap,
  });

  final bool visible;
  final String modelLabel;

  /// Localized reasoning-effort label; empty hides the muted half.
  final String effortLabel;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final colors = context.licoColors;
    return Semantics(
      button: true,
      label: effortLabel.isEmpty ? modelLabel : '$modelLabel $effortLabel',
      hint: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          key: const Key('canonical-group-assistant-model-readout'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      modelLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (effortLabel.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(
                      effortLabel,
                      maxLines: 1,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _AssistantNameLight extends StatefulWidget {
  const _AssistantNameLight({
    required this.active,
    required this.baseColor,
    required this.child,
  });
  final bool active;
  final Color baseColor;
  final Widget child;
  @override
  State<_AssistantNameLight> createState() => _AssistantNameLightState();
}

final class _AssistantNameLightState extends State<_AssistantNameLight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _light = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_AssistantNameLight oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.active && !MediaQuery.disableAnimationsOf(context)) {
      if (!_light.isAnimating) _light.repeat();
    } else {
      _light.stop();
    }
  }

  @override
  void dispose() {
    _light.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active || MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    final spectrum = _assistantSunsetSpectrum(
      widget.baseColor,
      isDark: context.licoColors.isDark,
    );
    return AnimatedBuilder(
      animation: _light,
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) {
          final center = -1.0 + _light.value * 3.0;
          return LinearGradient(
            begin: Alignment(center * 2 - 1 - 1.8, 0),
            end: Alignment(center * 2 - 1 + 1.8, 0),
            colors: spectrum,
            stops: _assistantSunsetStops,
          ).createShader(rect);
        },
        child: child,
      ),
    );
  }
}

/// Detached floating action menu for the canonical group composer, anchored to
/// a quiet plus icon before the assistant name. The menu
/// is a plain transparent overlay child (no glass card) of circular
/// overlay-glass action buttons stacked exactly above the trigger: attachments
/// nearest the button, discard-pending-images above it while images are
/// staged, reset history next, and new conversation on top. Hovering a circle
/// expands it rightward into a highlighted capsule — the icon stays pinned in
/// a fixed left slot and the label extends right. Tapping outside dismisses
/// the menu.
final class CanonicalGroupAssistantActions extends StatefulWidget {
  const CanonicalGroupAssistantActions({
    super.key,
    this.onPickAttachments,
    this.onNewConversation,
    this.onClearHistory,
    this.onDiscardImages,
    this.showDiscardImages = false,
  });

  /// Stages picked images into the group composer scope.
  final VoidCallback? onPickAttachments;

  /// Runs the same assistant thread refresh as the slash-new composer command.
  final VoidCallback? onNewConversation;

  /// Empties Canonical history after confirmation in the group pane.
  final VoidCallback? onClearHistory;

  /// Abandons the staged images (scope clear, which also releases the files).
  final VoidCallback? onDiscardImages;

  /// Whether the discard circle is visible (images are currently staged).
  final bool showDiscardImages;

  /// Extent of the detached menu actions; the toolbar trigger uses its own recipe.
  static const double circleExtent = 40;

  @override
  State<CanonicalGroupAssistantActions> createState() =>
      _CanonicalGroupAssistantActionsState();
}

final class _CanonicalGroupAssistantActionsState
    extends State<CanonicalGroupAssistantActions> {
  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _portalController = OverlayPortalController();
  final Object _tapRegionGroup = Object();
  bool _open = false;

  void _toggle() {
    setState(() => _open = !_open);
    _syncPortal();
  }

  void _close() {
    if (!_open) return;
    setState(() => _open = false);
    _syncPortal();
  }

  void _syncPortal() {
    if (_open) {
      if (!_portalController.isShowing) _portalController.show();
    } else if (_portalController.isShowing) {
      _portalController.hide();
    }
  }

  void _runAction(VoidCallback? action) {
    _close();
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return OverlayPortal(
      controller: _portalController,
      overlayChildBuilder: (context) {
        return Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _layerLink,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            offset: const Offset(0, -8),
            showWhenUnlinked: false,
            child: TapRegion(
              groupId: _tapRegionGroup,
              onTapOutside: (_) => _close(),
              child: Column(
                key: const Key('canonical-group-assistant-actions-menu'),
                mainAxisSize: MainAxisSize.min,
                verticalDirection: VerticalDirection.up,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AssistantActionCircle(
                    actionKey: const Key('canonical-group-action-attachments'),
                    icon: Icons.image_outlined,
                    label: strings.attachments,
                    onTap: () => _runAction(widget.onPickAttachments),
                  ),
                  if (widget.showDiscardImages) ...[
                    const SizedBox(height: 8),
                    _AssistantActionCircle(
                      actionKey: const Key(
                        'canonical-group-action-discard-images',
                      ),
                      icon: Icons.delete_outline_rounded,
                      label: strings.discardPendingImages,
                      onTap: () => _runAction(widget.onDiscardImages),
                    ),
                  ],
                  const SizedBox(height: 8),
                  _AssistantActionCircle(
                    actionKey: const Key(
                      'canonical-group-action-clear-history',
                    ),
                    icon: Icons.restart_alt,
                    label: strings.clearCanonicalConversationHistory,
                    onTap: widget.onClearHistory == null
                        ? null
                        : () => _runAction(widget.onClearHistory),
                  ),
                  const SizedBox(height: 8),
                  _AssistantActionCircle(
                    actionKey: const Key(
                      'canonical-group-action-new-conversation',
                    ),
                    icon: Icons.add_comment_outlined,
                    label: strings.newAssistantConversation,
                    onTap: widget.onNewConversation == null
                        ? null
                        : () => _runAction(widget.onNewConversation),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      child: TapRegion(
        groupId: _tapRegionGroup,
        child: CompositedTransformTarget(
          link: _layerLink,
          child: SizedBox(
            key: const Key('canonical-group-assistant-actions'),
            child: LicoIconButton(
              key: const Key('canonical-group-assistant-actions-trigger'),
              tooltip: strings.assistantActionsTooltip,
              onPressed: _toggle,
              icon: Icon(_open ? Icons.close_rounded : Icons.add_rounded),
            ),
          ),
        ),
      ),
    );
  }
}

/// One circular overlay-glass action. Collapsed it is a 40 px circle with a
/// centered icon; on hover it expands rightward into a highlighted capsule
/// whose icon stays pinned in the fixed left slot while the label extends
/// right. The width animates intrinsically through [AnimatedSize].
final class _AssistantActionCircle extends StatefulWidget {
  const _AssistantActionCircle({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Key actionKey;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  State<_AssistantActionCircle> createState() => _AssistantActionCircleState();
}

final class _AssistantActionCircleState extends State<_AssistantActionCircle> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final enabled = widget.onTap != null;
    const radius = BorderRadius.all(
      Radius.circular(CanonicalGroupAssistantActions.circleExtent / 2),
    );
    final duration = context.motion(LicoMotion.short);
    final content = SizedBox(
      height: CanonicalGroupAssistantActions.circleExtent,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: CanonicalGroupAssistantActions.circleExtent,
            child: Center(
              child: Icon(
                widget.icon,
                size: 19,
                color: enabled
                    ? (_hovering ? colors.text : colors.textMuted)
                    : colors.textMuted.withAlpha(120),
              ),
            ),
          ),
          if (_hovering)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Text(
                widget.label,
                maxLines: 1,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.08,
                  height: 1.15,
                ),
              ),
            ),
        ],
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: MessagingConversationOverlayGlass(
        borderRadius: radius,
        child: Material(
          color: _hovering ? colors.hoverOverlay : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            key: widget.actionKey,
            customBorder: const RoundedRectangleBorder(borderRadius: radius),
            onTap: widget.onTap,
            child: duration == Duration.zero
                ? content
                : AnimatedSize(
                    duration: duration,
                    curve: LicoMotion.standard,
                    alignment: Alignment.centerLeft,
                    child: content,
                  ),
          ),
        ),
      ),
    );
  }
}
