import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/shared/l10n/lico_strings_catalog.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/assistant_sparkles_icon.dart';
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

/// Five-state assistant readiness projection for the group composer capsule's
/// leading light. Every state derives from existing controller, profile, and
/// turn-projection signals; nothing is fabricated for the visual.
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
    required this.label,
    required this.statusLight,
    required this.selectedRevision,
    this.onOpen,
  });

  final String label;
  final GroupAssistantStatusLight statusLight;
  final String? selectedRevision;

  /// Opens the orchestration edit surface for [selectedRevision]. The capsule
  /// shows no hover list; tapping is the only gesture and it always edits.
  final ValueChanged<String?>? onOpen;

  @override
  Widget build(BuildContext context) {
    final onOpen = this.onOpen;
    return _GroupStrategyPickerTrigger(
      label: label,
      statusLight: statusLight,
      onTap: onOpen == null ? null : () => onOpen(selectedRevision),
    );
  }
}

final class _GroupStrategyPickerTrigger extends StatelessWidget {
  const _GroupStrategyPickerTrigger({
    required this.label,
    required this.statusLight,
    required this.onTap,
  });

  final String label;
  final GroupAssistantStatusLight statusLight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: strings.automaticAdaptation,
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GroupAssistantStatusDot(state: statusLight),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The capsule's leading readiness light. Colors come only from existing theme
/// roles: success for ready/working, accent for waiting, error for failure,
/// and textMuted for unconfigured/paused. Working pulses; every other state
/// is static. The dot key encodes the state for focused tests:
/// `canonical-group-assistant-status-<state>`.
final class GroupAssistantStatusDot extends StatelessWidget {
  const GroupAssistantStatusDot({super.key, required this.state});

  final GroupAssistantStatusLight state;

  static const double extent = 8;

  Color _color(LicoThemeColors colors) => switch (state) {
    GroupAssistantStatusLight.unconfigured ||
    GroupAssistantStatusLight.paused => colors.textMuted,
    GroupAssistantStatusLight.ready ||
    GroupAssistantStatusLight.working => colors.success,
    GroupAssistantStatusLight.waiting => colors.accent,
    GroupAssistantStatusLight.failure => colors.error,
  };

  @override
  Widget build(BuildContext context) {
    final color = _color(context.licoColors);
    final dot = Container(
      key: Key('canonical-group-assistant-status-${state.name}'),
      width: extent,
      height: extent,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (state != GroupAssistantStatusLight.working) return dot;
    return _GroupAssistantStatusDotPulse(color: color, child: dot);
  }
}

/// Gentle opacity pulse for the working light. Reduced-motion settings pin the
/// dot at full opacity instead of animating.
final class _GroupAssistantStatusDotPulse extends StatefulWidget {
  const _GroupAssistantStatusDotPulse({
    required this.color,
    required this.child,
  });

  final Color color;
  final Widget child;

  @override
  State<_GroupAssistantStatusDotPulse> createState() =>
      _GroupAssistantStatusDotPulseState();
}

final class _GroupAssistantStatusDotPulseState
    extends State<_GroupAssistantStatusDotPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: LicoMotion.loopShort,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  void _syncAnimation() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 1;
      return;
    }
    if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final opacity = (0.45 + 0.55 * _controller.value).clamp(0.0, 1.0);
        return Opacity(opacity: opacity, child: child);
      },
      child: widget.child,
    );
  }
}

/// Compact assistant control inside the group composer field's interior left.
/// Unconfigured shows the default sparkles mark and tapping opens the
/// configuration surface; configured shows the assistant agent's brand mark
/// and tapping toggles the assistant between active and paused.
final class AssistantToggleButton extends StatelessWidget {
  const AssistantToggleButton({
    super.key,
    required this.active,
    required this.configured,
    required this.onTap,
    this.assistantTarget,
  });

  final bool active;
  final bool configured;
  final VoidCallback onTap;

  /// The configured assistant's brand target; null while unconfigured.
  final TargetCandidate? assistantTarget;

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
    final target = assistantTarget;
    return SizedBox.square(
      key: const Key('canonical-group-assistant-control'),
      dimension: MessagingDesktopMetrics.conversationComposerAssistantExtent,
      child: Tooltip(
        message: tooltip,
        waitDuration: LicoMotion.tooltipWait,
        child: Semantics(
          button: true,
          toggled: enabled,
          label: tooltip,
          child: Material(
            color: enabled ? colors.accentSurface : Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              key: const Key('canonical-group-assistant-toggle'),
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Center(
                child: !configured || target == null
                    ? AssistantSparklesIcon(
                        color: colors.textMuted,
                        size: MessagingDesktopMetrics
                            .conversationComposerAssistantMarkExtent,
                      )
                    : Opacity(
                        opacity: enabled ? 1 : 0.45,
                        child: AgentBrandIcon(
                          target: target,
                          size: MessagingDesktopMetrics
                              .conversationComposerAssistantExtent,
                          iconSize: MessagingDesktopMetrics
                              .conversationComposerAssistantMarkExtent,
                          detected: true,
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

/// Detached floating action menu for the canonical group composer, anchored to
/// a circular plus button immediately right of the assistant toggle. The menu
/// is a plain transparent overlay child (no glass card) of circular
/// overlay-glass action buttons stacked exactly above the trigger: attachments
/// nearest the button, discard-pending-images above it while images are
/// staged, and new conversation on top. Hovering a circle expands it rightward
/// into a highlighted capsule — the icon stays pinned in a fixed left slot and
/// the label extends right. Tapping outside dismisses the menu.
final class CanonicalGroupAssistantActions extends StatefulWidget {
  const CanonicalGroupAssistantActions({
    super.key,
    this.onPickAttachments,
    this.onNewConversation,
    this.onDiscardImages,
    this.showDiscardImages = false,
  });

  /// Stages picked images into the group composer scope.
  final VoidCallback? onPickAttachments;

  /// Runs the same assistant thread refresh as the slash-new composer command.
  final VoidCallback? onNewConversation;

  /// Abandons the staged images (scope clear, which also releases the files).
  final VoidCallback? onDiscardImages;

  /// Whether the discard circle is visible (images are currently staged).
  final bool showDiscardImages;

  /// Shared circular extent, matching the assistant toggle's 40 px language.
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
    final colors = context.licoColors;
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
          child: SizedBox.square(
            key: const Key('canonical-group-assistant-actions'),
            dimension: CanonicalGroupAssistantActions.circleExtent,
            child: Tooltip(
              message: strings.assistantActionsTooltip,
              waitDuration: LicoMotion.tooltipWait,
              child: Semantics(
                button: true,
                label: strings.assistantActionsTooltip,
                child: Material(
                  color: colors.surfaceRaised,
                  shape: CircleBorder(
                    side: BorderSide(color: colors.line, width: 1),
                  ),
                  child: InkWell(
                    key: const Key('canonical-group-assistant-actions-trigger'),
                    customBorder: const CircleBorder(),
                    onTap: _toggle,
                    child: Center(
                      child: Icon(
                        _open ? Icons.close_rounded : Icons.add_rounded,
                        size: 20,
                        color: colors.textMuted,
                      ),
                    ),
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
            child: AnimatedSize(
              duration: context.motion(LicoMotion.short),
              curve: LicoMotion.standard,
              alignment: Alignment.centerLeft,
              child: SizedBox(
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
