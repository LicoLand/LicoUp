import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_layout_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class ResizableConversationSplit extends StatefulWidget {
  const ResizableConversationSplit({
    super.key,
    required this.historyPane,
    required this.chatPane,
    required this.initialHistoryWidth,
    required this.historyCollapsed,
  });

  final Widget historyPane;
  final Widget chatPane;
  final double initialHistoryWidth;
  final bool historyCollapsed;

  @override
  State<ResizableConversationSplit> createState() =>
      _ResizableConversationSplitState();
}

class _ResizableConversationSplitState
    extends State<ResizableConversationSplit> {
  static const double _minChatWidth = 360;
  static const double _dragHandleWidth = 12;

  double? _historyWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHistoryWidth =
            (constraints.maxWidth - _dragHandleWidth - _minChatWidth)
                .clamp(conversationHistoryMinWidth, constraints.maxWidth)
                .toDouble();
        final historyWidth = (_historyWidth ?? widget.initialHistoryWidth)
            .clamp(conversationHistoryMinWidth, maxHistoryWidth)
            .toDouble();
        return ColoredBox(
          key: const Key('conversation-split-page'),
          color: colors.surface,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.historyCollapsed)
                SizedBox(width: historyWidth, child: widget.historyPane),
              Expanded(
                child: PaneEdgeDragHandle(
                  width: _dragHandleWidth,
                  enabled: !widget.historyCollapsed,
                  onDragDelta: (delta) {
                    setState(() {
                      _historyWidth = (historyWidth + delta)
                          .clamp(conversationHistoryMinWidth, maxHistoryWidth)
                          .toDouble();
                    });
                  },
                  child: widget.chatPane,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class PaneEdgeDragHandle extends StatelessWidget {
  const PaneEdgeDragHandle({
    super.key,
    this.dragHandleKey,
    required this.width,
    required this.onDragDelta,
    required this.child,
    this.enabled = true,
  });

  final Key? dragHandleKey;
  final double width;
  final ValueChanged<double> onDragDelta;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }
    return Stack(
      children: [
        child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              key: dragHandleKey,
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) =>
                  onDragDelta(details.delta.dx),
              child: SizedBox(width: width),
            ),
          ),
        ),
      ],
    );
  }
}
