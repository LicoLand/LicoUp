import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

/// Frosted-glass backdrop for the Dashboard desktop content zone, including
/// the margin gutters around the unified content region. The tint is fully
/// transparent; blur comes from the native NSVisualEffectView beneath the
/// transparent window base.
final class DashboardContentRegion extends StatelessWidget {
  const DashboardContentRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = context.layoutPalette.isDark;
    return ColoredBox(
      key: const Key('dashboard-content-region'),
      color: MessagingDesktopMetrics.surfaceGlassTint(isDark: dark),
      child: child,
    );
  }
}
