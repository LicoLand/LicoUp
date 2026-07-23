import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_layout_metrics.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_pane_controls.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:flutter_client/src/frontend/shared/platform/client_platform.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class ConversationPaneHeader extends StatelessWidget {
  const ConversationPaneHeader({
    super.key,
    required this.state,
    required this.actions,
    this.orchestrationControls,
  });

  final AgentConversationHeaderState state;
  final AgentConversationHeaderActions actions;
  final Widget? orchestrationControls;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final sessionTitle = state.session?.title.trim();
    final headerTitle = sessionTitle == null || sessionTitle.isEmpty
        ? agentConversationTargetDisplayName(state.target)
        : sessionTitle;
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobileClient = isMobileClientPlatform(context);
        final identity = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: mobileClient
              ? const <Widget>[]
              : [
                  if (state.showSidebarToggle) ...[
                    ConversationIconButton(
                      key: const Key('conversation-history-toggle'),
                      tooltip: state.historyCollapsed
                          ? state.expandHistoryTooltip
                          : state.collapseHistoryTooltip,
                      onPressed: actions.onToggleHistory,
                      child: _SidebarToggleGlyph(
                        expanded: !state.historyCollapsed,
                        color: colors.textMuted.withAlpha(230),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        headerTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  if (!state.orchestrationSelected) ...[
                    const SizedBox(width: 10),
                    ConversationParityDisclosurePanel(target: state.target),
                  ],
                  if (state.target.target == 'opencode') ...[
                    const SizedBox(width: 8),
                    _OpencodeServeStatusChip(state: state.opencodeServeState),
                  ],
                  if (state.orchestrationSelected &&
                      orchestrationControls != null) ...[
                    const SizedBox(width: 12),
                    orchestrationControls!,
                  ],
                ],
        );

        final content = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: identity,
        );
        if (mobileClient) {
          return content;
        }
        return SizedBox(height: conversationHeaderHeight, child: content);
      },
    );
  }
}

class _OpencodeServeStatusChip extends StatelessWidget {
  const _OpencodeServeStatusChip({required this.state});

  final AgentConversationServeState? state;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final status = state?.status ?? AgentConversationServeStatus.stopped;
    final port = state?.port;
    final label = switch (status) {
      AgentConversationServeStatus.running =>
        port == null ? 'OpenCode serve' : 'OpenCode :$port',
      AgentConversationServeStatus.blocked =>
        state?.portConflict == true
            ? 'OpenCode port blocked'
            : 'OpenCode blocked',
      AgentConversationServeStatus.unavailable => 'OpenCode unavailable',
      _ => 'OpenCode stopped',
    };
    final color = switch (status) {
      AgentConversationServeStatus.running => colors.success,
      AgentConversationServeStatus.blocked ||
      AgentConversationServeStatus.unavailable => colors.error,
      _ => colors.textMuted,
    };
    return Container(
      key: const Key('opencode-serve-status'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class AgentsSidebarCollapseControl extends StatefulWidget {
  const AgentsSidebarCollapseControl({
    super.key,
    required this.expanded,
    required this.tooltip,
    required this.onPressed,
  });

  final bool expanded;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<AgentsSidebarCollapseControl> createState() =>
      _AgentsSidebarCollapseControlState();
}

class _AgentsSidebarCollapseControlState
    extends State<AgentsSidebarCollapseControl> {
  bool _hovered = false;
  bool _pressed = false;

  static const double _hitSize = 32;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final iconColor = colors.text.withAlpha(220);
    final showCircle = _hovered || _pressed;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) {
            setState(() => _pressed = false);
            widget.onPressed();
          },
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: _hitSize,
            height: _hitSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: showCircle
                  ? colors.surface.withAlpha(colors.isDark ? 160 : 220)
                  : Colors.transparent,
              border: showCircle
                  ? Border.all(color: colors.line.withAlpha(110))
                  : null,
            ),
            child: _SidebarToggleGlyph(
              expanded: widget.expanded,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarToggleGlyph extends StatelessWidget {
  const _SidebarToggleGlyph({required this.expanded, required this.color});

  final bool expanded;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(22, 22),
      painter: _SidebarToggleGlyphPainter(expanded: expanded, color: color),
    );
  }
}

class _SidebarToggleGlyphPainter extends CustomPainter {
  const _SidebarToggleGlyphPainter({
    required this.expanded,
    required this.color,
  });

  final bool expanded;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outerRect = Rect.fromLTWH(3, 4, size.width - 6, size.height - 8);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color.withAlpha(76)
      ..style = PaintingStyle.fill;
    final outer = RRect.fromRectAndRadius(
      outerRect,
      const Radius.circular(2.5),
    );
    canvas.drawRRect(outer, stroke);

    final panelWidth = outerRect.width * 0.4;
    final panelRect = expanded
        ? Rect.fromLTWH(
            outerRect.left,
            outerRect.top,
            panelWidth,
            outerRect.height,
          )
        : Rect.fromLTWH(
            outerRect.right - panelWidth,
            outerRect.top,
            panelWidth,
            outerRect.height,
          );
    canvas.drawRRect(
      RRect.fromRectAndRadius(panelRect.deflate(1.8), const Radius.circular(1)),
      fill,
    );
    final dividerX = expanded ? panelRect.right : panelRect.left;
    canvas.drawLine(
      Offset(dividerX, outerRect.top + 1.5),
      Offset(dividerX, outerRect.bottom - 1.5),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_SidebarToggleGlyphPainter oldDelegate) {
    return oldDelegate.expanded != expanded || oldDelegate.color != color;
  }
}
