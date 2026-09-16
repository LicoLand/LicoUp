import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
    );
  }
}

/// Assistant identity toggles dispatch; the separate pencil edits configuration.
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
    final tooltip = !configured
        ? strings.configureAssistantTooltip
        : enabled
        ? strings.assistantActiveTooltip
        : strings.assistantPausedTooltip;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Tooltip(
            message: '$statusLabel · $tooltip',
            child: Semantics(
              button: true,
              enabled: configured,
              toggled: enabled,
              label: label,
              value: statusLabel,
              hint: tooltip,
              child: InkWell(
                key: const Key('canonical-group-assistant-toggle'),
                onTap: configured ? onTap : null,
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  key: const Key('canonical-group-assistant-control'),
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
        LicoIconButton(
          key: const Key('canonical-group-assistant-edit'),
          tooltip: strings.configureAssistantTooltip,
          onPressed: onEdit,
          icon: const Icon(CupertinoIcons.pencil, size: 13),
        ),
      ],
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
    final spectrum = context.licoColors.isDark
        ? [
            widget.baseColor,
            const Color(0xFFC4A0FF),
            const Color(0xFFF5A46E),
            const Color(0xFFF3D889),
            widget.baseColor,
          ]
        : [
            widget.baseColor,
            const Color(0xFF8050AD),
            const Color(0xFFA75B30),
            const Color(0xFF92701D),
            widget.baseColor,
          ];
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
