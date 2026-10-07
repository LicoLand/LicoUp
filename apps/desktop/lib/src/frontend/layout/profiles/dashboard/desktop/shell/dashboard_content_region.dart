import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Clear window veil for the Dashboard desktop content zone, including the
/// margin gutters around the unified content region. The tint is the preset's
/// own opaque sunken ground — not a frosted blur.
final class DashboardContentRegion extends StatelessWidget {
  const DashboardContentRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Paint the veil as a sibling behind [child]. A ColoredBox ancestor
    // would sit between ListTiles and the shell Material and hide their
    // ink — Flutter asserts on that.
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          key: const Key('dashboard-content-region'),
          color: MessagingDesktopMetrics.surfaceGlassTint(context.licoColors),
        ),
        child,
      ],
    );
  }
}
