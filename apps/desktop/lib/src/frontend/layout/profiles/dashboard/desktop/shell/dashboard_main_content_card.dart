import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

/// The Dashboard desktop shell's unified outer content region: transparent
/// and chromeless so every destination sits directly on the clear window
/// veil — the macOS split-view idiom where the content pane is flush with
/// the window and the sidebar list is the single floating glass card.
/// Sits inset from the content region on every edge by
/// [MessagingDesktopMetrics.mainCardMargin]; the rounded clip keeps content
/// inside the window's corner shape.
final class DashboardMainContentCard extends StatelessWidget {
  const DashboardMainContentCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(MessagingDesktopMetrics.mainCardMargin),
  });

  final Widget child;

  /// Outer inset of the region within [DashboardContentRegion]. Defaults to
  /// the uniform [MessagingDesktopMetrics.mainCardMargin] gutter.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: ClipRRect(
        key: const Key('dashboard-desktop-main-card'),
        borderRadius: BorderRadius.circular(
          MessagingDesktopMetrics.mainCardCornerRadius,
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
