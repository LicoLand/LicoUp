import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

/// Clear window veil for the Dashboard desktop content zone, including the
/// margin gutters around the unified content region. The tint is a
/// see-through black (dark) or white (light) mask — not a frosted blur.
final class DashboardContentRegion extends StatelessWidget {
  const DashboardContentRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = context.layoutPalette.isDark;
    // Paint the veil as a sibling behind [child]. A ColoredBox ancestor
    // would sit between ListTiles and the shell Material and hide their
    // ink — Flutter asserts on that.
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          key: const Key('dashboard-content-region'),
          color: MessagingDesktopMetrics.surfaceGlassTint(isDark: dark),
        ),
        child,
      ],
    );
  }
}
