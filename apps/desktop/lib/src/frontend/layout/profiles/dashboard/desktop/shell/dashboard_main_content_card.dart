import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

/// The Dashboard desktop shell's unified outer content card: transparent glass
/// over native VE with a black readability veil, hairline border, soft
/// shadow, and shared corner radius. Sits inset from the content region on
/// every edge by [MessagingDesktopMetrics.mainCardMargin].
///
/// Geometry and veil **must** come from [MessagingDesktopMetrics.mainContentCard*]
/// helpers — do not hardcode radius, alphas, or shadow values here.
final class DashboardMainContentCard extends StatelessWidget {
  const DashboardMainContentCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(MessagingDesktopMetrics.mainCardMargin),
  });

  final Widget child;

  /// Outer inset of the card within [DashboardContentRegion]. Defaults to the
  /// uniform [MessagingDesktopMetrics.mainCardMargin] gutter.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Padding(
      padding: padding,
      child: Container(
        key: const Key('dashboard-desktop-main-card'),
        decoration: BoxDecoration(
          color: MessagingDesktopMetrics.mainContentCardFill(
            isDark: colors.isDark,
          ),
          borderRadius: BorderRadius.circular(
            MessagingDesktopMetrics.mainCardCornerRadius,
          ),
          border: Border.all(
            color: MessagingDesktopMetrics.mainContentCardBorder(
              colors.line,
              isDark: colors.isDark,
            ),
            width: MessagingDesktopMetrics.hairline,
          ),
          boxShadow: MessagingDesktopMetrics.mainContentCardShadows(
            isDark: colors.isDark,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
