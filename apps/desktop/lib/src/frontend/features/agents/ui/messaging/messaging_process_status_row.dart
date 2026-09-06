import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_event_details_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_lifecycle_indicator.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_process_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_process_operations.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_process_projection.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Inline presentation of a structured process run for the messaging
/// strategy: a glass-backed status capsule ("Working…" while active,
/// otherwise duration + step count) that stays collapsed while an active
/// turn streams — header title/status plus the top-edge pulse — and expands
/// on tap to reveal the redacted step list. The messaging counterpart of
/// [ConversationProcessCard].
class MessagingProcessStatusRow extends StatefulWidget {
  const MessagingProcessStatusRow({
    super.key,
    required this.events,
    required this.adapter,
    required this.detailsBuilder,
    this.active = false,
    this.topOverlayInset = 0,
  });

  final List<AgentConversationMessage> events;
  final AgentRenderAdapter adapter;
  final ConversationEventDetailsBuilder detailsBuilder;
  final bool active;
  final double topOverlayInset;

  @override
  State<MessagingProcessStatusRow> createState() =>
      _MessagingProcessStatusRowState();
}

class _MessagingProcessStatusRowState extends State<MessagingProcessStatusRow> {
  static const _cornerRadius = 10.0;

  final GlobalKey _headerAnchorKey = GlobalKey(
    debugLabel: 'messaging-process-status-header',
  );
  final ScrollController _operationScrollController = ScrollController();

  /// Whether the operation list body is revealed. Defaults to collapsed; the
  /// user expands on demand. A new turn (active false→true) resets to the
  /// collapsed default.
  bool _expanded = false;

  /// Arms one height animation for a manual expand/collapse while the run is
  /// working. Delta-driven size changes during streaming never animate —
  /// animating every publish would stack a layout animation on the scroll
  /// surface per streamed frame.
  bool _sizeAnimationArmed = false;

  bool get _working =>
      widget.active &&
      projectConversationTurnLifecycle(widget.events)?.terminal != true;

  @override
  void didUpdateWidget(covariant MessagingProcessStatusRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      // A new turn starts: return to the collapsed default and forget the
      // previous run's manual expansion.
      _expanded = false;
    }
    if (!_working) {
      _sizeAnimationArmed = false;
    }
  }

  @override
  void dispose() {
    _operationScrollController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    final expanding = !_expanded;
    _sizeAnimationArmed = true;
    setState(() {
      _expanded = expanding;
    });
    if (expanding) {
      _pinHeaderBelowOverlay();
    }
  }

  void _pinHeaderBelowOverlay() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_expanded) return;
      final headerContext = _headerAnchorKey.currentContext;
      if (headerContext == null || !headerContext.mounted) return;
      pinConversationProcessHeaderBelowOverlay(
        headerContext,
        widget.topOverlayInset,
      );
    });
  }

  void _onSizeAnimationEnd() {
    _sizeAnimationArmed = false;
    _pinHeaderBelowOverlay();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final projection = projectConversationProcessEvents(widget.events);
    final lifecycle = projectConversationTurnLifecycle(widget.events);
    final operations = projection.events
        .where((event) => !isConversationLifecycleEvent(event))
        .toList(growable: false);
    final durationTitle = conversationProcessDurationTitle(
      projection.startedAt,
      projection.endedAt,
      strings,
    );
    final title = lifecycle == null
        ? conversationProcessSemanticTitle(operations, strings)
        : conversationLifecycleStageLabel(lifecycle.stage, strings);
    final summary = lifecycle == null
        ? '${_working ? strings.working : durationTitle} · ${conversationProcessSummary(projection.totalOperations, projection.issues, false, strings)}'
        : lifecycle.terminal
        ? durationTitle
        : '';
    final showLifecycleRail =
        lifecycle != null &&
        operations.isEmpty &&
        (!lifecycle.terminal || lifecycle.observedStages.length < 5);
    final motionDisabled = MediaQuery.disableAnimationsOf(context);
    final containerDuration = motionDisabled ? Duration.zero : LicoMotion.short;
    final sizeDuration = motionDisabled
        ? Duration.zero
        : const Duration(milliseconds: 200);
    // While the run streams, each delta republishes the row; the expanded
    // body's height then applies instantly (zero-duration size change)
    // instead of running a layout animation per publish. Manual
    // expand/collapse keeps its animation through the armed flag.
    final animateSizeChanges = !_working || _sizeAnimationArmed;
    // The collapsed default skips constructing the operation list entirely —
    // rows are neither built nor updated until the user expands the card.
    final Widget? expandedBody;
    if (_expanded) {
      expandedBody = ConversationProcessOperationViewport(
        processId: widget.events.first.id,
        controller: _operationScrollController,
        child: ConversationProcessOperationList(
          operations: operations,
          adapter: widget.adapter,
          detailsBuilder: widget.detailsBuilder,
          activeStepIndex: widget.active ? operations.length - 1 : -1,
        ),
      );
    } else {
      expandedBody = null;
    }
    final borderRadius = BorderRadius.circular(_cornerRadius);
    // Neutral chrome only — brand/primary border reads as olive 泛黄 and was
    // the visible “无效” leftover after transcript bubbles were neutralized.
    final decoration = BoxDecoration(
      color: MessagingDesktopMetrics.conversationOverlayGlassFill(
        isDark: colors.isDark,
      ),
      borderRadius: borderRadius,
      border: Border.all(
        color: MessagingDesktopMetrics.conversationOverlayGlassBorder(
          colors.line,
          isDark: colors.isDark,
        ),
        width: AppleControlMetrics.hairline,
      ),
      boxShadow: MessagingDesktopMetrics.conversationOverlayGlassShadows(
        isDark: colors.isDark,
      ),
    );

    final header = KeyedSubtree(
      key: _headerAnchorKey,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('messaging-process-status-toggle'),
          onTap: _toggleExpanded,
          borderRadius: borderRadius,
          hoverColor: colors.text.withAlpha(8),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: _working ? 10 : 8,
              vertical: _working ? 8 : 6,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: _StatusIcon(
                    working: _working,
                    lifecycle: lifecycle,
                    colors: colors,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LicoShimmerText(
                        text: title,
                        enabled: _working,
                        style: TextStyle(
                          color: _working ? colors.text : colors.textMuted,
                          fontSize: _working ? 13 : 12.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.06,
                        ),
                      ),
                      if (summary.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        LicoShimmerText(
                          text: summary,
                          enabled: _working,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.04,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: containerDuration,
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 15,
                      color: colors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (showLifecycleRail)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
            child: ConversationLifecycleSteps(projection: lifecycle),
          ),
        if (motionDisabled)
          _expanded ? expandedBody! : const SizedBox.shrink()
        else
          AnimatedSize(
            // While the run streams, each delta republishes the row; a
            // near-zero duration applies the new height on the same frame
            // instead of stacking a layout animation per publish. (Exactly
            // zero would complete the controller synchronously inside
            // performLayout, which RenderAnimatedSize forbids.) Manual
            // expand/collapse keeps its animation through the armed flag.
            duration: animateSizeChanges
                ? sizeDuration
                : const Duration(milliseconds: 1),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            onEnd: _onSizeAnimationEnd,
            child: _expanded ? expandedBody! : const SizedBox.shrink(),
          ),
      ],
    );

    // Explicit infinite width on the painted surface — Align/Stack alone let
    // the card shrink to header text and looked narrower than agent bubbles.
    return SizedBox(
      width: double.infinity,
      child: LicoTopEdgePulse(
        key: Key(
          _working
              ? 'messaging-process-status-active'
              : 'messaging-process-status-idle',
        ),
        enabled: _working,
        borderRadius: borderRadius,
        color: colors.text.withAlpha(colors.isDark ? 90 : 70),
        child: AnimatedContainer(
          width: double.infinity,
          duration: containerDuration,
          curve: Curves.easeOutCubic,
          decoration: decoration,
          clipBehavior: Clip.antiAlias,
          child: body,
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({
    required this.working,
    required this.lifecycle,
    required this.colors,
  });

  final bool working;
  final ConversationTurnLifecycleProjection? lifecycle;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    if (working) {
      return LicoSpinningRefreshIcon(
        size: 15,
        strokeWidth: 1.8,
        color: colors.textMuted,
      );
    }
    if (lifecycle?.stage == ConversationTurnLifecycleStage.completed) {
      return Icon(Icons.check_circle_rounded, size: 14, color: colors.success);
    }
    if (lifecycle?.stage == ConversationTurnLifecycleStage.failed) {
      return Icon(Icons.error_rounded, size: 14, color: colors.error);
    }
    return Icon(
      Icons.format_list_bulleted_rounded,
      size: 14,
      color: colors.textMuted,
    );
  }
}
