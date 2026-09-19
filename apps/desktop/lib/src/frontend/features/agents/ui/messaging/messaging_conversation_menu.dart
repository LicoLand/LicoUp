import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';

/// One keyboard-accessible overflow menu for conversation chrome.
class MessagingConversationMenu extends StatefulWidget {
  const MessagingConversationMenu({
    super.key,
    required this.triggerKey,
    required this.panelKey,
    required this.childrenBuilder,
  });

  final Key triggerKey;
  final Key panelKey;
  final List<Widget> Function(VoidCallback close) childrenBuilder;

  @override
  State<MessagingConversationMenu> createState() =>
      _MessagingConversationMenuState();
}

class _MessagingConversationMenuState extends State<MessagingConversationMenu> {
  final MenuController _controller = MenuController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppleControlMetrics.menuCornerRadius);
    final view = MediaQuery.sizeOf(context);
    final menuWidth = math.min(320.0, view.width - 24);
    return MenuAnchor(
      controller: _controller,
      childFocusNode: _focusNode,
      alignmentOffset: Offset(-menuWidth, 6),
      style: const MenuStyle(
        alignment: Alignment.bottomRight,
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
      ),
      menuChildren: [
        SizedBox(
          key: widget.panelKey,
          width: menuWidth,
          child: MessagingConversationOverlayGlass(
            borderRadius: radius,
            readabilityVeil: true,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.min(440, view.height - 96),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.childrenBuilder(_controller.close),
                ),
              ),
            ),
          ),
        ),
      ],
      builder: (context, controller, child) =>
          MessagingConversationOverlayGlass(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox.square(
              dimension: MessagingDesktopMetrics.conversationHeaderMenuExtent,
              child: IconButton(
                key: widget.triggerKey,
                focusNode: _focusNode,
                tooltip: LicoStrings.of(context).moreActions,
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.more_horiz_rounded, size: 21),
              ),
            ),
          ),
    );
  }
}
