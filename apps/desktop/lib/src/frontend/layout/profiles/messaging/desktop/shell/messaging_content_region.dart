import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

/// Frosted-glass backdrop for the messaging desktop content zone: the area
/// to the right of the destination rail and below the chrome band, including
/// the margin gutters around the unified content card. Uses the same tint as
/// [MessagingChromeBand] and [MessagingDestinationRail]; blur comes from the
/// native NSVisualEffectView beneath the transparent window base.
final class MessagingContentRegion extends StatelessWidget {
  const MessagingContentRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = context.layoutPalette.isDark;
    return ColoredBox(
      key: const Key('messaging-content-region'),
      color: MessagingDesktopMetrics.surfaceGlassTint(isDark: dark),
      child: child,
    );
  }
}
