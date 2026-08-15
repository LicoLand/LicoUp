import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Circular jump-to-latest control that floats above the composer. Uses the
/// shared messaging overlay glass — not a separate visual system.
class MessagingScrollToLatestButton extends StatelessWidget {
  const MessagingScrollToLatestButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final extent = MessagingDesktopMetrics.conversationScrollToLatestExtent;
    final radius = BorderRadius.circular(extent / 2);
    return Semantics(
      button: true,
      label: strings.scrollToLatestMessages,
      child: Tooltip(
        message: strings.scrollToLatestMessages,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: MessagingConversationOverlayGlass(
              borderRadius: radius,
              child: SizedBox(
                width: extent,
                height: extent,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: colors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
