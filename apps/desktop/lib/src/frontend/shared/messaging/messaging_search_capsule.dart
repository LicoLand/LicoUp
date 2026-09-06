import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_search_capsule.dart';

/// Messaging-chrome binding of [LicoSearchCapsule]. The Agents page hosts it
/// at the top of the conversation list; other destinations retain it in the
/// chrome band. Visual tokens stay on glass; ranking is bound by the caller.
final class MessagingSearchCapsule extends StatelessWidget {
  const MessagingSearchCapsule({super.key, required this.onTap, this.width});

  final VoidCallback onTap;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    return LicoSearchCapsule(
      onTap: onTap,
      width: width,
      hintText: strings.sidebarSearchHint,
      colors: LicoSearchCapsuleColors(
        fill: MessagingDesktopMetrics.chromeControlFill(isDark: colors.isDark),
        border: MessagingDesktopMetrics.chromeSearchBorder(),
        icon: MessagingDesktopMetrics.chromeSearchIcon(),
        hint: MessagingDesktopMetrics.chromeSearchPlaceholder(),
        text: MessagingDesktopMetrics.chromeForeground(),
      ),
    );
  }
}
